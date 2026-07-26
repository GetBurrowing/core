defmodule Platform.Responsibilities.Handlers.ArchitectureReviewPlan do
  @moduledoc """
  `architecture.review_plan` responsibility provider (ADR-0044 stage 3,
  task `019f3da3`).

  Stage 1 (`32e92bcc`) shipped the registration placeholder + ADR
  0044. Stage 2 (`e7e91ebd`) wired the plan-submit `fire/2` hook in
  `Platform.Tasks.submit_plan_for_review/1` behind the
  `try/rescue/catch :exit` guard mandated by the progressive-enhancement
  contract. This stage 3 revision fills in the real content:

    * `gather_context/2` composes two `ContextProviders` slots and reads
      the `docs/decisions/` ADR filesystem listing. Neither payload is
      built here any more — `Platform.Responsibilities.ContextProviders`
      is the single per-slot resolver, so the Router's batch path and
      this handler see identical payloads.

      `:plan_payload` (task 019f9b28-6ca7 stage 3) REFUSES an
      unresolvable plan and the refusal propagates out of
      `gather_context/2`: ADR-0046 runs this pass strictly after plan
      submission, so "no plan" means a broken trigger, not an empty
      review.

      `:sibling_tasks` (stage 4) NEVER refuses, and the asymmetry is the
      design. It resolves siblings through a stack → epic → bounded
      project-window ladder, and "no siblings" is an ordinary correct
      state for a standalone task, not a wiring bug. Its old private
      implementation here walked every in-flight task in the project
      with no limit at all; the slot caps the project window at 10 and
      discloses every drop in the rendered block.
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
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  @key "architecture.review_plan"
  @feature "architecture"
  @template_slug "architecture.review_plan.v1"

  # Shape of the `:sibling_tasks` slot when the anchor task can't be
  # resolved. The slot itself never errors (it is optional context), so
  # this only covers the defensive arm and the refusal-rendering path in
  # `empty_context/1`. Kept in sync with
  # `ContextProviders.empty_siblings/1`.
  @empty_siblings %{
    scope: :no_anchor,
    total: 0,
    shown: 0,
    truncated?: false,
    dropped: 0,
    unplanned_excluded: 0,
    tasks: []
  }

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
  def gather_context(_responsibility, ctx) when is_map(ctx), do: do_gather_context(ctx)

  def gather_context(_responsibility, _ctx), do: {:error, :no_plan_payload}

  @doc """
  Assemble the architect prompt context from the plan payload the
  plan-submit hook fires.

  Public so tests can exercise the sibling-walk / ADR-index shape
  without standing up a fully-populated Router pipeline. Accepts the
  same map shape `Platform.Tasks.fire_architecture_review_plan/1`
  publishes: `%{plan: %Plan{}, plan_id: id, task_id: id}`.

  Unlike the arity-2 Provider callback this **always returns a map** —
  the refusal is rendered as `plan_payload.error` so callers that just
  want something to format keep getting one. Dispatch decisions must use
  the arity-2 callback, which propagates `{:error, :no_plan_payload}`.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx) when is_map(ctx) do
    case do_gather_context(ctx) do
      {:ok, gathered} -> gathered
      {:error, reason} -> empty_context(reason)
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

  # The plan payload is no longer materialised here — `ContextProviders`
  # is the single per-slot resolver (task 019f9b28-6ca7 stage 1) and
  # `:plan_payload` is a slot like any other. A refusal propagates: the
  # Router's context-refusal arm stops the dispatch rather than sending
  # the architect an empty plan to review.
  defp do_gather_context(ctx) do
    case ContextProviders.gather_context(:plan_payload, ctx) do
      {:ok, %{plan_payload: payload}} ->
        {:ok,
         %{
           plan_payload: payload,
           sibling_tasks: sibling_tasks(payload),
           adr_index: adr_index(),
           similar_tasks: similar_tasks_hint(payload)
         }}

      {:error, reason} ->
        Logger.warning(
          "[architecture.review_plan] gather_context could not resolve a plan — " <>
            "refusing dispatch reason=#{inspect(reason)} keys=#{inspect(ctx_keys(ctx))}"
        )

        {:error, reason}
    end
  end

  defp ctx_keys(ctx) when is_map(ctx), do: Map.keys(ctx)
  defp ctx_keys(_ctx), do: []

  defp empty_context(reason) do
    %{
      plan_payload: %{
        missing?: true,
        error: reason,
        note: "no plan payload supplied (#{inspect(reason)})"
      },
      sibling_tasks: @empty_siblings,
      adr_index: [],
      similar_tasks: []
    }
  end

  # The sibling walk is no longer materialised here either — it is the
  # `:sibling_tasks` slot on `ContextProviders`, which owns the
  # stack → epic → bounded-project-window ladder and every truncation
  # disclosure that goes with it.
  #
  # Unlike `:plan_payload` this slot NEVER refuses, and the difference
  # is deliberate. "This task has no siblings" is an ordinary, correct
  # state — a standalone task in a fresh project genuinely has none —
  # so refusing on it would stop the architect dispatch for the most
  # common shape in the system. Only `:plan_payload` is load-bearing
  # enough to refuse a dispatch over; the `case` below exists purely so
  # a future contract change can't silently crash the gather.
  defp sibling_tasks(payload) do
    anchor = %{task_id: is_map(payload) && Map.get(payload, :task_id)}

    case ContextProviders.gather_context(:sibling_tasks, anchor) do
      {:ok, %{sibling_tasks: siblings}} ->
        siblings

      other ->
        Logger.warning(
          "[architecture.review_plan] sibling_tasks slot returned an unexpected shape: " <>
            "#{inspect(other)} — rendering an empty sibling block"
        )

        @empty_siblings
    end
  end

  # Probe for the (still-unlanded) `Tasks.similar_tasks/2`. It takes a
  # `%Plan{}`, so the plan is re-read from the payload's id — a query
  # that only ever runs once the helper actually exists.
  defp similar_tasks_hint(%{plan_id: plan_id}) when is_binary(plan_id) do
    if Code.ensure_loaded?(Tasks) and function_exported?(Tasks, :similar_tasks, 2) do
      case load_plan(plan_id) do
        %Plan{} = plan ->
          try do
            apply(Tasks, :similar_tasks, [plan, []])
          rescue
            _ -> []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  defp similar_tasks_hint(_payload), do: []

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
      sibling_tasks: format_sibling_tasks(Map.get(context, :sibling_tasks, @empty_siblings)),
      open_prs: format_open_prs(Map.get(context, :open_prs, [])),
      adr_index: format_adr_index(Map.get(context, :adr_index, []))
    }
  end

  defp format_plan_summary(nil), do: "(no plan summary available)"

  defp format_plan_summary(%{missing?: true} = payload) do
    "(no plan summary available — #{Map.get(payload, :note, "unknown")})"
  end

  defp format_plan_summary(%{} = payload) do
    stages = Map.get(payload, :stages) || []
    stage_lines = Enum.map_join(stages, "\n", &format_stage_line/1)

    """
    Task: #{Map.get(payload, :task_title) || "(untitled)"} (task_id: #{Map.get(payload, :task_id)})
    Task status: #{Map.get(payload, :task_status)}
    Task intent:
    #{format_task_description(Map.get(payload, :task_description))}

    Plan version: #{Map.get(payload, :plan_version)} (status: #{Map.get(payload, :plan_status)})
    Project: #{Map.get(payload, :project_id)}

    Stages (#{Map.get(payload, :stage_count, length(stages))}):
    #{stage_lines}
    """
    |> String.trim_trailing()
  end

  defp format_task_description(nil), do: "  (no task description recorded)"
  defp format_task_description(""), do: "  (no task description recorded)"

  defp format_task_description(description) when is_binary(description) do
    description
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  # The gates are the point: the architect must be able to tell a stage
  # that is protected from one that is not, and by what kind of gate.
  # Descriptions arrive pre-truncated from the `:plan_payload` slot —
  # re-truncating here would silently shrink the budget the slot sized.
  defp format_stage_line(stage) do
    pos = Map.get(stage, :position, "?")
    name = Map.get(stage, :name) || "(unnamed)"
    desc = Map.get(stage, :description) || ""
    status = Map.get(stage, :status) || "pending"

    header = "  - stage #{pos} — #{name} [#{status}]: #{desc}"

    [header, format_gates(Map.get(stage, :validations) || [])]
    |> Enum.concat(format_e2e_expectations(Map.get(stage, :e2e_expected) || []))
    |> Enum.join("\n")
  end

  defp format_gates([]), do: "    gates: (none — this stage is unprotected)"

  defp format_gates(validations) when is_list(validations) do
    rendered =
      Enum.map_join(validations, ", ", fn validation ->
        "#{Map.get(validation, :kind)}(#{Map.get(validation, :status)})"
      end)

    "    gates: " <> rendered
  end

  defp format_e2e_expectations([]), do: []

  defp format_e2e_expectations(expectations) when is_list(expectations) do
    Enum.map(expectations, &"    e2e expects: #{&1}")
  end

  # The leading line is the point of the whole wrapper: it names which
  # of the three sibling tiers produced this list and, when a cap or a
  # filter dropped anything, says exactly how much. Absence must never
  # be silent — a model reads a short list as "there is nothing else",
  # not as "you were shown ten of sixty-three".
  defp format_sibling_tasks(%{tasks: []} = payload), do: sibling_scope_line(payload)

  defp format_sibling_tasks(%{tasks: tasks} = payload) when is_list(tasks) do
    Enum.join([sibling_scope_line(payload) | Enum.map(tasks, &format_sibling/1)], "\n\n")
  end

  defp format_sibling_tasks(_payload),
    do: "(sibling task list unavailable — the slot returned an unrecognised shape)"

  defp sibling_scope_line(%{scope: :no_anchor}),
    do: "[scope: no_anchor] sibling tasks unavailable — the trigger carried no resolvable task"

  defp sibling_scope_line(%{scope: :none} = payload) do
    "[scope: none] no sibling tasks — this task is in no stack and no epic, and its " <>
      "project has no other in-flight task with a submitted plan" <> unplanned_note(payload)
  end

  defp sibling_scope_line(%{scope: scope, total: 0}),
    do: "[scope: #{scope}] no sibling tasks — 0 other #{scope_noun(scope)}"

  defp sibling_scope_line(%{scope: scope} = payload) do
    counts =
      if payload.truncated? do
        "showing #{payload.shown} of #{payload.total} #{scope_noun(scope)}"
      else
        "#{payload.total} #{scope_noun(scope)}"
      end

    "[scope: #{scope}] " <> counts <> ", " <> scope_order(scope) <> unplanned_note(payload)
  end

  defp scope_noun(:stack), do: "stack members"
  defp scope_noun(:epic), do: "in-flight tasks in this epic"
  defp scope_noun(_scope), do: "in-flight tasks in this project"

  defp scope_order(:stack), do: "in stack position order"
  defp scope_order(:epic), do: "most recently created first"
  defp scope_order(_scope), do: "most recently updated first"

  defp unplanned_note(%{unplanned_excluded: count}) when is_integer(count) and count > 0 do
    " (a further #{count} in-flight task(s) in this project have no submitted plan and are " <>
      "omitted — no stage descriptions to collide with)"
  end

  defp unplanned_note(_payload), do: ""

  # Stage descriptions arrive pre-truncated from the `:sibling_tasks`
  # slot, same contract as the plan stages above — re-truncating here
  # would silently shrink the budget the slot sized.
  defp format_sibling(sibling) do
    stages = Map.get(sibling, :stages) || []

    stage_lines =
      Enum.map_join(stages, "\n", fn stage ->
        "    - #{Map.get(stage, :name) || "(unnamed)"}: #{Map.get(stage, :description) || ""}"
      end)

    stage_block =
      cond do
        stages != [] and Map.get(sibling, :truncated?) ->
          stage_lines <>
            "\n    (showing #{Map.get(sibling, :stages_shown)} of " <>
            "#{Map.get(sibling, :stage_count)} stages)"

        stages != [] ->
          stage_lines

        true ->
          "    (no stages yet)"
      end

    "- #{Map.get(sibling, :title) || "(untitled)"} " <>
      "(task_id: #{Map.get(sibling, :task_id)}, " <>
      "status: #{Map.get(sibling, :status)}, " <>
      stack_position_fragment(Map.get(sibling, :stack_position)) <>
      "latest_plan: #{Map.get(sibling, :latest_plan_status) || "n/a"})\n" <>
      stage_block
  end

  defp stack_position_fragment(position) when is_integer(position),
    do: "stack_position: #{position}, "

  defp stack_position_fragment(_position), do: ""

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
