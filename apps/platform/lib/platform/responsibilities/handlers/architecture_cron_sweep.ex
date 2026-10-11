defmodule Platform.Responsibilities.Handlers.ArchitectureCronSweep do
  @moduledoc """
  `architecture.cron_sweep` responsibility provider (ADR-0044 stage 5,
  task `019f3da3`).

  Stage 1 (`32e92bcc`) shipped the registration placeholder. Stage 5
  (this rewrite) fills in the real handler body + a fresh prompt
  template so the weekly Monday 04:00 UTC sweep can walk open PRs,
  recently-closed tasks, and ADR gaps to file tech-debt follow-ups.

  ## Assignment-gated firing

  Firing is gated entirely on the `architect` role's assignee. The
  Router's own cron tick fires this responsibility every Monday 04:00
  UTC via the registered `trigger_config`; before invoking the handler
  it resolves the role assignee via `Platform.Roles.assignee_for/1`.
  When no agent is assigned to the `architect` role (or the role's
  responsibility bundle does not include `architecture.cron_sweep`),
  the Router's assignee lookup returns `nil` and skips dispatch — no
  LLM call, no side effects.

  `handle_output/3` is only reached when an assignee has run the LLM,
  so no in-handler gate is required. Assignment IS the enable signal.

  ## Spec (unchanged from stage 1)

    * `key` — `"architecture.cron_sweep"`
    * `feature` — `"architecture"`
    * `trigger_kind` — `cron` with `expression: "0 4 * * 1"` (Monday
      04:00 UTC — quiet slot ahead of the working week)
    * `scope` — `per_project`
    * `context_provided` — `["open_prs", "recent_closed_tasks", "adr_index"]`
    * `default_prompt_template` — `"architecture.cron_sweep.v1"`
    * `cost_profile` — `low_freq_capable`

  ## `gather_context/2`

    * `open_prs` — a synchronous `gh pr list --state open --limit 20 --json number,title,url,updatedAt`.
      When `gh` isn't on `PATH` (test builds, sandboxed CI) the slot is
      marked `missing?: true` with a note.
    * `recent_closed_tasks` — tasks that transitioned to `done` in the
      past 7 days across all projects, ordered by `updated_at` desc.
    * `adr_index` — the `:adr_index` slot on `ContextProviders`, rendered
      by `Platform.Responsibilities.ADRIndexRenderer`. Same provider and
      same rendering as the sibling `ArchitectureReviewPlan` handler, so
      the sweep sees each ADR's status and supersessions rather than a
      bare list of filenames. Never refuses: an unreachable directory
      arrives as an explicit reason, not as an empty list.

  ## `handle_output/3`

  When the LLM returns `{"followups": [{title, rationale, refs}, ...]}`,
  the handler files each entry as a backlog task via `Platform.Tasks.create_task/1`
  with metadata `%{"filed_by" => "architect_cron_sweep"}`. Limit is 3
  follow-ups per sweep — enforced client-side so a run-away model can't
  flood the backlog.

  Each follow-up is filed as `kind: "chore"`, `origin: "internal"`,
  `trust: "trusted"` (task `019fa1ac-6685` stage 3). The janitor
  (`Platform.Responsibilities.Janitor`) claims only trusted internal
  chores, and `Task.kind` defaults to `"feature"`, so a follow-up filed
  without an explicit kind could never be drained. Origin and trust are
  the schema defaults today; they are stated anyway so the filing does not
  depend on a default someone may later move.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.ADRIndexRenderer
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @key "architecture.cron_sweep"
  @feature "architecture"
  @template_slug "architecture.cron_sweep.v1"

  # Cap the number of follow-up tasks a single sweep can file. Guards
  # against a mis-prompt run-away. The prompt template also bakes this
  # in, so both sides agree.
  @max_followups 3

  # Shape of the `:adr_index` slot when the directory can't be read.
  # Mirrors the sibling `architecture.review_plan` handler; kept in sync
  # with `ContextProviders.unavailable_index/2` via `ADRIndexRenderer`.
  @unavailable_adr_index ADRIndexRenderer.unavailable_index()

  # Recent-closed window for the closed-tasks slot. One week matches the
  # weekly cron cadence.
  @recent_closed_window_seconds 7 * 24 * 60 * 60

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # 04:00 UTC Mondays — quiet slot ahead of the working week.
        # The Router fires the cron trigger; dispatch is gated by the
        # `architect` role assignee via `Roles.assignee_for/1`.
        trigger_config: %{"expression" => "0 4 * * 1"},
        scope: "per_project",
        context_provided: ["open_prs", "recent_closed_tasks", "adr_index"],
        output_contract: %{
          "followups" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.architecture",
          "status" => "active",
          "role" => "architect",
          "adr" => "0044"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx) do
    {:ok, do_gather_context()}
  end

  def gather_context(_responsibility, _ctx), do: {:ok, do_gather_context()}

  @doc """
  Assemble the sweep context — open PRs, closed tasks, ADR index.

  Public so tests can exercise the shape without the full Router
  pipeline.
  """
  @spec gather_context(map()) :: map()
  def gather_context(_ctx \\ %{}), do: do_gather_context()

  @doc """
  Render the sweep instruction from the DB template with a fallback to
  the hardcoded default. Returns a binary regardless — even if the flag
  is off (the caller checks `build_prompt/1` for the actual gate).
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = context_to_assigns(context)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        fallback =
          case PromptTemplates.default_content_for_slug(@template_slug) do
            nil -> ""
            body -> body
          end

        interpolate_fallback(fallback, assigns)
    end
  end

  @impl true
  @doc """
  Build the (system + user) messages the Router hands to the external
  dispatcher. Always returns `{:ok, _}` — firing is gated upstream at
  the Router by the `architect` role assignee.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    user = render_instruction(context)

    system =
      "You are the Architect on the Suite weekly tech-debt sweep path (ADR-0044). " <>
        "You file at most #{@max_followups} follow-up tasks per sweep. Each follow-up must " <>
        "cite a specific PR number, task id, or ADR number — never a vague concern. " <>
        "Outputs land as backlog tasks with `metadata.filed_by = \"architect_cron_sweep\"`."

    {:ok, %{system: system, user: user}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(%Responsibility{} = _responsibility, output, trigger_meta) do
    followups = extract_followups(output)
    project_id = resolve_project_id(trigger_meta)

    Enum.each(Enum.take(followups, @max_followups), fn followup ->
      file_followup(followup, project_id)
    end)

    :ok
  end

  # Per-project scope: the Router iterates each project and fires once
  # per project — trigger_meta carries `:project_id` (atom key on the
  # Router-native map) or `"project_id"` when the payload has been
  # JSON-round-tripped through the external dispatcher. Fall back to
  # the first project on the board when nothing is provided (tests +
  # dry-run tooling both hit this path).
  defp resolve_project_id(nil), do: fallback_project_id()

  defp resolve_project_id(%{} = meta) do
    case Map.get(meta, :project_id) || Map.get(meta, "project_id") do
      id when is_binary(id) -> id
      _ -> fallback_project_id()
    end
  end

  defp resolve_project_id(_), do: fallback_project_id()

  defp fallback_project_id do
    import Ecto.Query, only: [from: 2]

    Repo.one(
      from(p in Platform.Tasks.Project,
        order_by: [asc: p.inserted_at],
        limit: 1,
        select: p.id
      )
    )
  rescue
    _ -> nil
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp do_gather_context do
    %{
      open_prs: gather_open_prs(),
      recent_closed_tasks: gather_recent_closed_tasks(),
      adr_index: adr_index()
    }
  end

  # Shells out to `gh pr list`. Returns a `missing?: true` marker when
  # gh is unavailable — the prompt template surfaces that verbatim so
  # the LLM knows to say "PR walk unavailable" rather than hallucinate.
  defp gather_open_prs do
    with {:ok, path} when is_binary(path) <- {:ok, System.find_executable("gh")},
         {output, 0} <-
           System.cmd(path, ~w(pr list --state open --limit 20 --json number,title,url,updatedAt),
             stderr_to_stdout: true
           ),
         {:ok, decoded} <- decode_gh(output) do
      decoded
    else
      _ ->
        %{
          missing?: true,
          note: "gh CLI unavailable or `gh pr list` failed — walk skipped"
        }
    end
  rescue
    error ->
      Logger.warning("[architecture.cron_sweep] gh pr list raised: #{Exception.message(error)}")

      %{missing?: true, note: "gh pr list raised: #{Exception.message(error)}"}
  end

  defp decode_gh(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, list} when is_list(list) ->
        {:ok,
         Enum.map(list, fn entry ->
           %{
             number: Map.get(entry, "number"),
             title: Map.get(entry, "title"),
             url: Map.get(entry, "url"),
             updated_at: Map.get(entry, "updatedAt")
           }
         end)}

      _ ->
        :error
    end
  end

  # Recent closed tasks — walks the tasks table for `status: done` +
  # `updated_at within 7d`. Public via `gather_context/1` for tests.
  defp gather_recent_closed_tasks do
    since = DateTime.utc_now() |> DateTime.add(-@recent_closed_window_seconds, :second)

    import Ecto.Query, only: [from: 2]

    from(t in TaskSchema,
      where: t.status == "done" and t.updated_at >= ^since and is_nil(t.deleted_at),
      order_by: [desc: t.updated_at],
      limit: 30
    )
    |> Repo.all()
    |> Enum.map(fn %TaskSchema{} = task ->
      %{
        task_id: task.id,
        title: task.title,
        updated_at: task.updated_at,
        project_id: task.project_id
      }
    end)
  rescue
    error ->
      Logger.warning(
        "[architecture.cron_sweep] recent closed tasks walk raised: " <>
          Exception.message(error)
      )

      []
  end

  # The ADR walk is NOT materialised here. It is the `:adr_index` slot
  # on `ContextProviders`, which owns directory resolution, the header
  # parse, and the collision / supersession flags. What used to be here
  # emitted `%{file: name}` and nothing else, so the sweep could not see
  # whether a decision it was asked to check for drift was still live —
  # and every failure path collapsed to `[]`, which reads as "this
  # codebase has no architectural decisions".
  #
  # Like the sibling review_plan handler, this slot NEVER refuses: prod
  # release images ship no `docs/`, so an unreachable index is the
  # steady state there. It comes back `available?: false` with a reason,
  # and the renderer turns that into an explicit instruction.
  #
  # The match is total: `{:ok, %{adr_index: _}}` is the slot's only return
  # shape. A defensive `other ->` clause used to follow it; the Elixir 1.20
  # type checker proves it unreachable, so it was removed. A contract change
  # adding a second shape will NOT be flagged at compile time and raises
  # `MatchError` here.
  defp adr_index do
    {:ok, %{adr_index: index}} = ContextProviders.gather_context(:adr_index, %{})
    index
  end

  # Turn the structured context map into a template-assigns map. Each
  # `{{variable}}` in the template gets a stringified block.
  defp context_to_assigns(context) do
    %{
      open_prs: format_open_prs(Map.get(context, :open_prs)),
      recent_closed_tasks: format_closed_tasks(Map.get(context, :recent_closed_tasks, [])),
      adr_index:
        ADRIndexRenderer.format_adr_index(Map.get(context, :adr_index, @unavailable_adr_index))
    }
  end

  defp format_open_prs(%{missing?: true} = slot) do
    "(open PRs unavailable — #{Map.get(slot, :note, "unknown")})"
  end

  defp format_open_prs([]), do: "(no open PRs — repo is clean)"

  defp format_open_prs(prs) when is_list(prs) do
    Enum.map_join(prs, "\n", fn pr ->
      "- ##{Map.get(pr, :number, "?")} #{Map.get(pr, :title, "(untitled)")} — #{Map.get(pr, :url, "")}"
    end)
  end

  defp format_open_prs(_), do: "(no open PRs available)"

  defp format_closed_tasks([]), do: "(no tasks closed in the past 7 days)"

  defp format_closed_tasks(tasks) when is_list(tasks) do
    Enum.map_join(tasks, "\n", fn task ->
      "- #{Map.get(task, :title) || "(untitled)"} " <>
        "(task_id: #{Map.get(task, :task_id)}, closed_at: #{Map.get(task, :updated_at)})"
    end)
  end

  defp interpolate_fallback("", _assigns), do: ""

  defp interpolate_fallback(content, assigns) when is_binary(content) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  defp extract_followups(%{"followups" => list}) when is_list(list), do: list
  defp extract_followups(%{followups: list}) when is_list(list), do: list
  defp extract_followups(_), do: []

  defp file_followup(%{} = followup, project_id) do
    title = extract_followup_title(followup)
    rationale = extract_followup_rationale(followup)
    refs = extract_followup_refs(followup)

    cond do
      not is_binary(title) or title == "" ->
        Logger.debug("[architecture.cron_sweep] skipping follow-up with empty title")
        :ok

      is_nil(project_id) ->
        Logger.warning(
          "[architecture.cron_sweep] no project_id resolvable — dropping follow-up " <>
            "title=#{inspect(title)}"
        )

        :ok

      true ->
        description =
          [
            rationale,
            if(refs != [], do: "\n\nRefs: " <> Enum.join(refs, ", "), else: "")
          ]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join("")

        attrs = %{
          project_id: project_id,
          title: "[architect] " <> title,
          description: description,
          status: "backlog",
          kind: "chore",
          origin: "internal",
          trust: "trusted",
          metadata: %{
            "filed_by" => "architect_cron_sweep",
            "adr" => "0044",
            "refs" => refs
          }
        }

        case Tasks.create_task(attrs) do
          {:ok, task} ->
            Logger.info(
              "[architecture.cron_sweep] filed follow-up task_id=#{task.id} title=#{inspect(title)}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[architecture.cron_sweep] create_task failed reason=#{inspect(reason)} " <>
                "title=#{inspect(title)}"
            )

            :ok
        end
    end
  end

  defp file_followup(_, _), do: :ok

  defp extract_followup_title(%{"title" => t}) when is_binary(t), do: t
  defp extract_followup_title(%{title: t}) when is_binary(t), do: t
  defp extract_followup_title(_), do: nil

  defp extract_followup_rationale(%{"rationale" => r}) when is_binary(r), do: r
  defp extract_followup_rationale(%{rationale: r}) when is_binary(r), do: r
  defp extract_followup_rationale(_), do: nil

  defp extract_followup_refs(%{"refs" => refs}) when is_list(refs) do
    Enum.filter(refs, &is_binary/1)
  end

  defp extract_followup_refs(%{refs: refs}) when is_list(refs) do
    Enum.filter(refs, &is_binary/1)
  end

  defp extract_followup_refs(_), do: []
end
