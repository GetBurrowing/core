defmodule Platform.Responsibilities.Handlers.ArchitectureReviewPlan do
  @moduledoc """
  `architecture.review_plan` responsibility provider (ADR-0044 stage 3,
  task `019f3da3`).

  Stage 1 (`32e92bcc`) shipped the registration placeholder + ADR
  0044. Stage 2 (`e7e91ebd`) wired the plan-submit `fire/2` hook in
  `Platform.Tasks.submit_plan_for_review/1` behind the
  `try/rescue/catch :exit` guard mandated by the progressive-enhancement
  contract. This stage 3 revision fills in the real content:

    * `gather_context/2` walks the sibling task tree in the plan's
      project (excluding self + excluding done/cancelled), fetches active
      plans + their stage descriptions, reads the `docs/decisions/` ADR
      filesystem listing, and packages the plan payload for the prompt.
    * `render_instruction/1` renders `architecture.review_plan.v1` from
      the DB (falls back to the hardcoded template body when the DB
      row is missing so early-boot dispatch doesn't crash).
    * `build_prompt/1` is the M6 Router callback; it returns
      `{:ok, %{system:, user:}}` so the Router hands the pre-built
      prompt to the ExternalDispatcher without the legacy template
      render path.
    * `handle_output/3` posts the architect's annotations to the plan's
      execution space via `Platform.Orchestration.ExecutionSpace.post_log/2`
      — additive, not a blocker. If the space can't be resolved (task
      hasn't been assigned yet) we log and return `:ok` rather than
      crashing the Router.

  ## Spec (unchanged from stage 1)

    * `key` — `"architecture.review_plan"`
    * `feature` — `"architecture"`
    * `trigger_kind` — `event_topic` with `topic: "plan:submitted"`
    * `scope` — `per_project`
    * `context_provided` — `["plan_payload", "sibling_tasks", "adr_index"]`
    * `default_prompt_template` — `"architecture.review_plan.v1"`
    * `cost_profile` — `low_freq_capable`

  ## `similar_tasks/2` opt-in

  Task `019f3dbb` (vectorize-tasks) is landing a
  `Platform.Tasks.similar_tasks/2` helper that could enrich the
  duplicate-abstraction check. This handler probes for it via
  `Code.ensure_loaded?/1` and uses it if present; if not the sibling
  walk alone is enough for v1 and no error is raised.

  ## Native-vs-external dispatch

  The Router only calls `build_prompt/1` / `handle_output/3` for
  `kind: "external"` agents. Native agents (Suite-internal) get an
  AgentResponder signal and run their own attention prompt loop — the
  `context_provided` slots this handler declares are surfaced via the
  usual context bundler on the receiver side. Stage 3 tests exercise
  the handler functions directly; live dispatch is covered by stage 5's
  e2e_behavior cases.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task, as: TaskSchema

  @key "architecture.review_plan"
  @feature "architecture"
  @template_slug "architecture.review_plan.v1"

  # Task statuses considered "in flight" — the architect flags collisions
  # against these. `done` / `cancelled` are excluded so a project's
  # graveyard doesn't drown the annotation in stale references.
  @in_flight_statuses ~w(planning in_progress in_review blocked stack_pending)

  # ADR index lives at `docs/decisions/` relative to the repo root. In
  # test / sandboxed builds the path may not resolve (test cwd differs);
  # we fall back to an empty list rather than crashing.
  @adr_dir_from_repo_root "docs/decisions"

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
        trigger_kind: "event_topic",
        # Plan-submit hook fired by
        # `Platform.Tasks.submit_plan_for_review/1` (ADR-0044 stage 2).
        # The Router doesn't subscribe to this topic through Phoenix.PubSub
        # because the caller invokes `Responsibilities.fire/2` directly
        # — the `topic` slot is documentation for operators inspecting
        # the row.
        trigger_config: %{"topic" => "plan:submitted"},
        scope: "per_project",
        context_provided: ["plan_payload", "sibling_tasks", "adr_index"],
        output_contract: %{
          "comments" => "list[map]"
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
    plan = extract_plan(ctx)

    if plan do
      {:ok, do_gather_context(plan)}
    else
      Logger.warning(
        "[architecture.review_plan] gather_context called without plan payload — " <>
          "keys=#{inspect(Map.keys(ctx))}"
      )

      {:ok, empty_context()}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, empty_context()}

  @doc """
  Assemble the architect prompt context from the plan payload the
  plan-submit hook fires.

  Public so tests can exercise the sibling-walk / ADR-index shape
  without standing up a fully-populated Router pipeline. Accepts the
  same map shape `Platform.Tasks.fire_architecture_review_plan/1`
  publishes: `%{plan: %Plan{}, plan_id: id, task_id: id}`.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx) when is_map(ctx) do
    case extract_plan(ctx) do
      nil -> empty_context()
      %Plan{} = plan -> do_gather_context(plan)
    end
  end

  @doc """
  Render the plan-review instruction for the architect agent by piping
  the gathered context through the `architecture.review_plan.v1`
  prompt template.

  Returns a non-empty string. When the DB row is missing (early boot,
  test seed skipped) we fall back to `default_content_for_slug/1` so
  the caller still gets renderable text.
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = context_to_assigns(context)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        # Fall back to the hardcoded default so a missing seed row
        # doesn't strand the caller. The default carries the full
        # prompt body verbatim from `do_default_templates/0`.
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
  dispatcher (task 019f2570 bug 1 fix pattern — provider owns its
  prompt end-to-end).

  The system slot names the architect role + the additive / non-
  blocking contract; the user slot is the rendered instruction from
  `render_instruction/1`. This callback lands the M6 arity-3
  Provider protocol without churning the arity-2 fallbacks.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    user = render_instruction(context)

    system =
      "You are the Architect on the Suite plan-review path (ADR-0044). " <>
        "Your outputs are additive annotations posted to the plan's execution space — " <>
        "you do not block plan approval. Cite tasks by id and ADRs by number so the " <>
        "human reviewer can jump to sources."

    {:ok, %{system: system, user: user}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(%Responsibility{} = _responsibility, output, trigger_meta)
      when is_map(trigger_meta) do
    task_id = extract_task_id(trigger_meta)

    with :ok <- ensure_task_id(task_id),
         %{} = space <- ExecutionSpace.find_by_task_id(task_id),
         comment when is_binary(comment) and comment != "" <- extract_comment(output) do
      post_annotation(space.id, comment)
    else
      {:error, :missing_task_id} ->
        Logger.warning(
          "[architecture.review_plan] handle_output missing task_id in trigger_meta — " <>
            "keys=#{inspect(Map.keys(trigger_meta))}"
        )

        :ok

      nil ->
        Logger.info(
          "[architecture.review_plan] no execution space for task_id=#{inspect(task_id)} — " <>
            "skipping annotation post"
        )

        :ok

      "" ->
        Logger.debug(
          "[architecture.review_plan] empty architect comment payload — nothing to post"
        )

        :ok

      _ ->
        Logger.debug("[architecture.review_plan] unrecognised output payload — nothing to post")

        :ok
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp extract_plan(ctx) when is_map(ctx) do
    cond do
      match?(%Plan{}, Map.get(ctx, :plan)) -> Map.get(ctx, :plan)
      match?(%Plan{}, Map.get(ctx, "plan")) -> Map.get(ctx, "plan")
      is_binary(Map.get(ctx, :plan_id)) -> load_plan(Map.get(ctx, :plan_id))
      is_binary(Map.get(ctx, "plan_id")) -> load_plan(Map.get(ctx, "plan_id"))
      true -> nil
    end
  end

  defp extract_plan(_), do: nil

  defp load_plan(plan_id) when is_binary(plan_id) do
    Repo.get(Plan, plan_id)
  rescue
    _ -> nil
  end

  defp extract_task_id(trigger_meta) when is_map(trigger_meta) do
    Map.get(trigger_meta, :task_id) || Map.get(trigger_meta, "task_id") ||
      case Map.get(trigger_meta, :plan) || Map.get(trigger_meta, "plan") do
        %Plan{task_id: id} -> id
        _ -> nil
      end
  end

  defp ensure_task_id(id) when is_binary(id), do: :ok
  defp ensure_task_id(_), do: {:error, :missing_task_id}

  defp do_gather_context(%Plan{} = plan) do
    plan = Repo.preload(plan, [:task, stages: :validations])

    %{
      plan_payload: plan_summary_map(plan),
      sibling_tasks: sibling_task_summaries(plan),
      adr_index: adr_index(),
      similar_tasks: similar_tasks_hint(plan)
    }
  end

  defp empty_context do
    %{
      plan_payload: %{missing?: true, note: "no plan payload supplied"},
      sibling_tasks: [],
      adr_index: [],
      similar_tasks: []
    }
  end

  defp plan_summary_map(%Plan{} = plan) do
    task = plan.task

    %{
      plan_id: plan.id,
      plan_version: plan.version,
      plan_status: plan.status,
      task_id: task && task.id,
      task_title: task && task.title,
      task_status: task && task.status,
      project_id: task && task.project_id,
      stages:
        for stage <- plan.stages || [] do
          %{
            stage_id: stage.id,
            name: Map.get(stage, :name),
            position: Map.get(stage, :position),
            description: Map.get(stage, :description)
          }
        end
    }
  end

  defp sibling_task_summaries(%Plan{task: nil}), do: []

  defp sibling_task_summaries(%Plan{task: %TaskSchema{} = task} = plan) do
    task.project_id
    |> Tasks.list_tasks_by_project()
    |> Enum.reject(fn %TaskSchema{} = t ->
      t.id == plan.task_id or t.status not in @in_flight_statuses
    end)
    |> Enum.map(&sibling_task_summary/1)
  rescue
    error ->
      Logger.warning(
        "[architecture.review_plan] sibling walk raised: #{Exception.message(error)}"
      )

      []
  end

  defp sibling_task_summary(%TaskSchema{} = task) do
    plans =
      task.id
      |> safe_list_plans()
      |> Enum.reject(&(&1.status in ~w(superseded rejected)))
      |> Enum.take(-1)

    latest_plan = List.last(plans)

    stage_summaries =
      case latest_plan do
        nil ->
          []

        %Plan{} = plan ->
          plan
          |> Repo.preload(:stages)
          |> Map.get(:stages, [])
          |> Enum.map(fn stage ->
            %{
              name: Map.get(stage, :name),
              position: Map.get(stage, :position),
              description: Map.get(stage, :description)
            }
          end)
      end

    %{
      task_id: task.id,
      title: task.title,
      status: task.status,
      latest_plan_status: latest_plan && latest_plan.status,
      stages: stage_summaries
    }
  end

  defp safe_list_plans(task_id) do
    Tasks.list_plans(task_id)
  rescue
    _ -> []
  end

  defp similar_tasks_hint(%Plan{} = plan) do
    cond do
      Code.ensure_loaded?(Tasks) and function_exported?(Tasks, :similar_tasks, 2) ->
        try do
          apply(Tasks, :similar_tasks, [plan, []])
        rescue
          _ -> []
        end

      true ->
        []
    end
  end

  defp adr_index do
    with root when is_binary(root) <- repo_root(),
         adr_dir <- Path.join(root, @adr_dir_from_repo_root),
         true <- File.dir?(adr_dir),
         entries when is_list(entries) <- File.ls(adr_dir) |> unwrap_ls() do
      entries
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort()
      |> Enum.map(&%{file: &1})
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp unwrap_ls({:ok, entries}), do: entries
  defp unwrap_ls({:error, _}), do: []
  defp unwrap_ls(list) when is_list(list), do: list

  # Walk up from the current file's dir until we find `docs/decisions/`.
  # In test builds `System.cwd()` can point at
  # `apps/platform`; in prod release builds we look at the priv root and
  # walk back to the repo. Return `nil` when we can't find it — callers
  # fall back to an empty ADR list.
  defp repo_root do
    __ENV__.file
    |> Path.expand()
    |> find_ancestor_with_dir(@adr_dir_from_repo_root, 8)
  end

  defp find_ancestor_with_dir(_path, _dir, 0), do: nil

  defp find_ancestor_with_dir(path, dir, depth) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      File.dir?(Path.join(parent, dir)) -> parent
      true -> find_ancestor_with_dir(parent, dir, depth - 1)
    end
  end

  # Turn the structured context map into a template-assigns map. Each
  # `{{variable}}` in the template gets a stringified block — the goal is
  # a readable prompt, not machine-parseable JSON.
  defp context_to_assigns(context) do
    %{
      plan_summary: format_plan_summary(Map.get(context, :plan_payload)),
      sibling_tasks: format_sibling_tasks(Map.get(context, :sibling_tasks, [])),
      open_prs: format_open_prs(Map.get(context, :open_prs, [])),
      adr_index: format_adr_index(Map.get(context, :adr_index, []))
    }
  end

  defp format_plan_summary(nil), do: "(no plan summary available)"

  defp format_plan_summary(%{missing?: true} = payload) do
    "(no plan summary available — #{Map.get(payload, :note, "unknown")})"
  end

  defp format_plan_summary(%{} = payload) do
    stage_lines =
      payload
      |> Map.get(:stages, [])
      |> Enum.map(fn stage ->
        pos = Map.get(stage, :position, "?")
        name = Map.get(stage, :name) || "(unnamed)"
        desc = Map.get(stage, :description) || ""

        "  - stage #{pos} — #{name}: #{truncate(desc, 220)}"
      end)
      |> Enum.join("\n")

    """
    Task: #{Map.get(payload, :task_title) || "(untitled)"} (task_id: #{Map.get(payload, :task_id)})
    Task status: #{Map.get(payload, :task_status)}
    Plan version: #{Map.get(payload, :plan_version)} (status: #{Map.get(payload, :plan_status)})
    Project: #{Map.get(payload, :project_id)}

    Stages:
    #{stage_lines}
    """
    |> String.trim_trailing()
  end

  defp format_sibling_tasks([]), do: "(no in-flight sibling tasks in this project)"

  defp format_sibling_tasks(siblings) when is_list(siblings) do
    Enum.map_join(siblings, "\n\n", fn sibling ->
      stage_lines =
        sibling
        |> Map.get(:stages, [])
        |> Enum.map(fn stage ->
          "    - #{Map.get(stage, :name) || "(unnamed)"}: #{truncate(Map.get(stage, :description) || "", 180)}"
        end)
        |> Enum.join("\n")

      stage_block = if stage_lines == "", do: "    (no stages yet)", else: stage_lines

      "- #{Map.get(sibling, :title) || "(untitled)"} " <>
        "(task_id: #{Map.get(sibling, :task_id)}, " <>
        "status: #{Map.get(sibling, :status)}, " <>
        "latest_plan: #{Map.get(sibling, :latest_plan_status) || "n/a"})\n" <>
        stage_block
    end)
  end

  defp format_open_prs([]),
    do: "(open PR list not gathered — this hook runs at plan submission, not at merge)"

  defp format_open_prs(prs) when is_list(prs) do
    Enum.map_join(prs, "\n", fn pr ->
      "- ##{Map.get(pr, :number, "?")} #{Map.get(pr, :title, "(untitled)")}"
    end)
  end

  defp format_adr_index([]), do: "(ADR index unavailable — `docs/decisions/` not found)"

  defp format_adr_index(entries) when is_list(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      "- #{Map.get(entry, :file, "(unknown)")}"
    end)
  end

  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "…"
  end

  defp truncate(str, _max_len) when is_binary(str), do: str
  defp truncate(_, _), do: ""

  # Fallback interpolation when the DB row is missing — the hardcoded
  # default body carries the same `{{variable}}` placeholders, so we
  # apply the same mustache-style substitution PromptTemplates uses.
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

  defp extract_comment(%{"comments" => [%{"content" => c} | _]}) when is_binary(c), do: c
  defp extract_comment(%{"comments" => [c | _]}) when is_binary(c), do: c
  defp extract_comment(%{"comment" => c}) when is_binary(c), do: c
  defp extract_comment(%{comment: c}) when is_binary(c), do: c
  defp extract_comment(str) when is_binary(str), do: str
  defp extract_comment(_), do: nil

  defp post_annotation(space_id, comment) when is_binary(space_id) and is_binary(comment) do
    case ExecutionSpace.post_log(space_id, format_annotation(comment)) do
      {:ok, _msg} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[architecture.review_plan] failed to post annotation space_id=#{space_id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_annotation(comment) when is_binary(comment) do
    prefix = "[architect] "

    if String.starts_with?(comment, prefix) do
      comment
    else
      prefix <> comment
    end
  end
end
