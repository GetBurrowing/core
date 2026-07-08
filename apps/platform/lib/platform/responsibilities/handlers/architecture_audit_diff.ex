defmodule Platform.Responsibilities.Handlers.ArchitectureAuditDiff do
  @moduledoc """
  `architecture.audit_diff` responsibility provider (ADR-0044 stage 4,
  task `019f3da3`).

  Stage 1 (`32e92bcc`) shipped the registration placeholder. Stage 2
  wired the plan-submit hook for `architecture.review_plan`. Stage 3
  filled in the real content for that sibling responsibility. Stage 4
  wires the post-executor drift hook at
  `Platform.Tasks.PlanEngine.transition_stage/2` (called from
  `evaluate_validation/2` when the last stage validation passes) and
  fills in this handler's real body:

    * `gather_context/2` — reads the stage description + plan payload +
      task metadata from the trigger context. **v1 limitation**: the
      executor's git diff is NOT captured today (see ADR-0044
      Consequences). The prompt asks the agent to audit against the
      *planned shape* — divergence-by-file-path detection lands with a
      follow-up task that wires a diff capture into the stage-complete
      signal.
    * `render_instruction/1` renders `architecture.audit_diff.v1` from
      the DB with a fallback to the hardcoded default (mirrors the
      `ArchitectureReviewPlan` shape so both prompts stay diffable).
    * `build_prompt/1` is the M6 Router callback returning
      `{:ok, %{system:, user:}}`.
    * `handle_output/3` posts the architect's annotations to the task's
      execution space via `Platform.Orchestration.ExecutionSpace.post_log/2`.
      Additive only — the stage transitioned to `passed` before this
      hook fired, so nothing this handler emits can block reviewer
      dispatch.

  ## Spec (unchanged from stage 1)

    * `key` — `"architecture.audit_diff"`
    * `feature` — `"architecture"`
    * `trigger_kind` — `event_topic` with `topic: "stage:completed"`
    * `scope` — `per_project`
    * `context_provided` — `["stage_diff", "planned_shape", "org_memory_entries"]`
      (the `stage_diff` slot is declared for forward compat; v1
      populates it with a `missing?: true` marker — see moduledoc).
    * `default_prompt_template` — `"architecture.audit_diff.v1"`
    * `cost_profile` — `low_freq_capable`

  ## Native-vs-external dispatch

  The Router only calls `build_prompt/1` / `handle_output/3` for
  `kind: "external"` agents. Native agents get an AgentResponder signal
  and run their own prompt loop — the `context_provided` slots this
  handler declares are surfaced via the usual context bundler on the
  receiver side. Stage 4 tests exercise the handler functions directly;
  live drift-detection dispatch is covered by stage 5's e2e_behavior
  cases.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task, as: TaskSchema

  @key "architecture.audit_diff"
  @feature "architecture"
  @template_slug "architecture.audit_diff.v1"

  # ORG_MEMORY entries the audit-diff prompt highlights as durable
  # patterns the executor's diff might silently re-introduce. Not
  # exhaustive — the agent has full ORG_MEMORY access at runtime; these
  # are the entries most commonly violated by an in-flight change and
  # get named-in-prompt so the model reliably surfaces them.
  @canonical_memory_flags [
    %{
      key: "ETS for ephemeral state",
      note:
        "meeting-lifetime / session-lifetime queues + caches go in ETS, not Ecto. Durable-by-default creates cleanup obligations Rowan doesn't want."
    },
    %{
      key: "Suite ToolSurface smell",
      note:
        "chat_live.ex and agent_responder.ex calling Platform.Federation.ToolSurface directly is a known-bad pattern; revisit boundary after MCP ships."
    },
    %{
      key: "Correctness over shortcuts",
      note:
        "no symlinks, co-locate files properly (tests next to code, contexts in lib/platform/, components in _web/components/)."
    },
    %{
      key: "Stack rollup ship",
      note:
        "Suite stacks ship as ONE rollup PR via `stack/<name>` branch, not per-member; flag any per-member `pr_merge` dispatch."
    }
  ]

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc """
  ORG_MEMORY entries the audit-diff prompt highlights in-line as
  durable patterns the executor's diff might silently re-introduce.

  Public so tests can lock the shipped list (regressing the highlighted
  set silently weakens the audit's usefulness).
  """
  @spec canonical_memory_flags() :: [%{key: String.t(), note: String.t()}]
  def canonical_memory_flags, do: @canonical_memory_flags

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        # Stage-complete hook fired by
        # `Platform.Tasks.PlanEngine.transition_stage/2` on the "passed"
        # transition (ADR-0044 stage 4). The Router doesn't subscribe
        # to this topic through Phoenix.PubSub because the caller
        # invokes `Responsibilities.fire/2` directly — the `topic` slot
        # is documentation for operators inspecting the row.
        trigger_config: %{"topic" => "stage:completed"},
        scope: "per_project",
        context_provided: ["stage_diff", "planned_shape", "org_memory_entries"],
        output_contract: %{
          "annotations" => "list[map]"
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
    {:ok, do_gather_context(ctx)}
  end

  def gather_context(_responsibility, _ctx), do: {:ok, empty_context()}

  @doc """
  Assemble the architect prompt context from the trigger meta the
  stage-complete hook fires.

  Public so tests can exercise the shape without standing up a fully-
  populated Router pipeline. Accepts the same map shape
  `Platform.Tasks.PlanEngine.after_stage_completed/1` publishes:
  `%{stage: %Stage{}, plan: %Plan{}, task: %Task{}, ...}`.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx) when is_map(ctx) do
    do_gather_context(ctx)
  end

  @doc """
  Render the drift-audit instruction for the architect agent by piping
  the gathered context through the `architecture.audit_diff.v1` prompt
  template.

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

  The system slot names the architect role + the additive / non-blocking
  contract; the user slot is the rendered instruction from
  `render_instruction/1`. Mirrors `ArchitectureReviewPlan.build_prompt/1`
  so both architect surfaces read the same to operators.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    user = render_instruction(context)

    system =
      "You are the Architect on the Suite post-executor drift-audit path (ADR-0044). " <>
        "A stage just transitioned to `passed`; you are annotating what shipped versus " <>
        "what was planned. Your outputs are additive — you do NOT block the reviewer, " <>
        "and you do NOT rewrite the stage. Cite tasks by id, ADRs by number, and " <>
        "ORG_MEMORY entries by their bracketed key so the human reviewer can jump " <>
        "to sources."

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
         annotation when is_binary(annotation) and annotation != "" <-
           extract_annotation(output) do
      post_annotation(space.id, annotation)
    else
      {:error, :missing_task_id} ->
        Logger.warning(
          "[architecture.audit_diff] handle_output missing task_id in trigger_meta — " <>
            "keys=#{inspect(Map.keys(trigger_meta))}"
        )

        :ok

      nil ->
        Logger.info(
          "[architecture.audit_diff] no execution space for task_id=#{inspect(task_id)} — " <>
            "skipping annotation post"
        )

        :ok

      "" ->
        Logger.debug(
          "[architecture.audit_diff] empty architect annotation payload — nothing to post"
        )

        :ok

      _ ->
        Logger.debug("[architecture.audit_diff] unrecognised output payload — nothing to post")

        :ok
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp do_gather_context(ctx) when is_map(ctx) do
    stage = extract_stage(ctx)
    plan = extract_plan(ctx)
    task = extract_task(ctx, plan)

    %{
      planned_shape: planned_shape_map(stage, plan, task),
      # v1 limitation: the git diff is NOT captured at the stage-complete
      # signal today (see ADR-0044 Consequences). Downstream stages / a
      # follow-up task will wire diff capture into the trigger meta; for
      # now the slot advertises the missing-ness explicitly so the
      # prompt template can note it.
      stage_diff: %{
        missing?: true,
        note:
          "v1 limitation — git-diff capture is not wired into the stage-complete signal. " <>
            "The agent audits against the planned shape (stage description + plan payload) alone."
      },
      org_memory_entries: @canonical_memory_flags
    }
  end

  defp empty_context do
    %{
      planned_shape: %{missing?: true, note: "no stage/plan payload supplied"},
      stage_diff: %{missing?: true, note: "no trigger meta supplied"},
      org_memory_entries: []
    }
  end

  defp extract_stage(ctx) do
    cond do
      match?(%Stage{}, Map.get(ctx, :stage)) -> Map.get(ctx, :stage)
      match?(%Stage{}, Map.get(ctx, "stage")) -> Map.get(ctx, "stage")
      is_binary(Map.get(ctx, :stage_id)) -> load_stage(Map.get(ctx, :stage_id))
      is_binary(Map.get(ctx, "stage_id")) -> load_stage(Map.get(ctx, "stage_id"))
      true -> nil
    end
  end

  defp extract_plan(ctx) do
    cond do
      match?(%Plan{}, Map.get(ctx, :plan)) -> Map.get(ctx, :plan)
      match?(%Plan{}, Map.get(ctx, "plan")) -> Map.get(ctx, "plan")
      is_binary(Map.get(ctx, :plan_id)) -> load_plan(Map.get(ctx, :plan_id))
      is_binary(Map.get(ctx, "plan_id")) -> load_plan(Map.get(ctx, "plan_id"))
      true -> nil
    end
  end

  defp extract_task(ctx, plan) do
    cond do
      match?(%TaskSchema{}, Map.get(ctx, :task)) -> Map.get(ctx, :task)
      match?(%TaskSchema{}, Map.get(ctx, "task")) -> Map.get(ctx, "task")
      is_binary(Map.get(ctx, :task_id)) -> load_task(Map.get(ctx, :task_id))
      is_binary(Map.get(ctx, "task_id")) -> load_task(Map.get(ctx, "task_id"))
      match?(%Plan{task_id: id} when is_binary(id), plan) -> load_task(plan.task_id)
      true -> nil
    end
  end

  defp load_stage(id) when is_binary(id) do
    Repo.get(Stage, id)
  rescue
    _ -> nil
  end

  defp load_plan(id) when is_binary(id) do
    Repo.get(Plan, id)
  rescue
    _ -> nil
  end

  defp load_task(id) when is_binary(id) do
    Repo.get(TaskSchema, id)
  rescue
    _ -> nil
  end

  defp planned_shape_map(nil, _plan, _task), do: %{missing?: true, note: "no stage payload"}

  defp planned_shape_map(%Stage{} = stage, plan, task) do
    %{
      stage_id: stage.id,
      stage_name: Map.get(stage, :name),
      stage_position: Map.get(stage, :position),
      stage_description: Map.get(stage, :description),
      stage_status: Map.get(stage, :status),
      plan_id: plan && plan.id,
      plan_version: plan && plan.version,
      task_id: task && task.id,
      task_title: task && task.title,
      task_status: task && task.status,
      project_id: task && task.project_id
    }
  end

  defp extract_task_id(trigger_meta) when is_map(trigger_meta) do
    Map.get(trigger_meta, :task_id) || Map.get(trigger_meta, "task_id") ||
      task_id_from_plan(Map.get(trigger_meta, :plan) || Map.get(trigger_meta, "plan")) ||
      task_id_from_task(Map.get(trigger_meta, :task) || Map.get(trigger_meta, "task"))
  end

  defp task_id_from_plan(%Plan{task_id: id}) when is_binary(id), do: id
  defp task_id_from_plan(_), do: nil

  defp task_id_from_task(%TaskSchema{id: id}) when is_binary(id), do: id
  defp task_id_from_task(_), do: nil

  defp ensure_task_id(id) when is_binary(id), do: :ok
  defp ensure_task_id(_), do: {:error, :missing_task_id}

  # Turn the structured context map into a template-assigns map. Each
  # `{{variable}}` in the template gets a stringified block — the goal is
  # a readable prompt, not machine-parseable JSON.
  defp context_to_assigns(context) do
    %{
      stage_diff: format_stage_diff(Map.get(context, :stage_diff)),
      planned_shape: format_planned_shape(Map.get(context, :planned_shape)),
      org_memory_entries: format_memory_entries(Map.get(context, :org_memory_entries, []))
    }
  end

  defp format_stage_diff(%{missing?: true} = slot) do
    "(#{Map.get(slot, :note, "diff not captured at stage-complete signal")})"
  end

  defp format_stage_diff(other) when is_binary(other), do: other
  defp format_stage_diff(_), do: "(no diff payload)"

  defp format_planned_shape(nil), do: "(no plan/stage payload available)"

  defp format_planned_shape(%{missing?: true} = slot) do
    "(no plan/stage payload — #{Map.get(slot, :note, "unknown")})"
  end

  defp format_planned_shape(%{} = shape) do
    """
    Task: #{Map.get(shape, :task_title) || "(untitled)"} (task_id: #{Map.get(shape, :task_id)})
    Task status: #{Map.get(shape, :task_status)}
    Project: #{Map.get(shape, :project_id)}
    Plan version: #{Map.get(shape, :plan_version)} (plan_id: #{Map.get(shape, :plan_id)})

    Stage: #{Map.get(shape, :stage_name) || "(unnamed)"} (position #{Map.get(shape, :stage_position, "?")})
    Stage id: #{Map.get(shape, :stage_id)}
    Stage status at signal: #{Map.get(shape, :stage_status)}

    Stage description (planner-authored — this is the shape the executor was asked to ship):
    #{truncate(Map.get(shape, :stage_description) || "(no description)", 2000)}
    """
    |> String.trim_trailing()
  end

  defp format_memory_entries([]), do: "(no ORG_MEMORY flags carried by the trigger)"

  defp format_memory_entries(entries) when is_list(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      "- [#{Map.get(entry, :key, "unknown")}] #{Map.get(entry, :note, "")}"
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

  defp extract_annotation(%{"annotations" => [%{"content" => c} | _]}) when is_binary(c), do: c
  defp extract_annotation(%{"annotations" => [%{"note" => n} | _]}) when is_binary(n), do: n
  defp extract_annotation(%{"annotations" => [a | _]}) when is_binary(a), do: a
  defp extract_annotation(%{"annotation" => a}) when is_binary(a), do: a
  defp extract_annotation(%{annotation: a}) when is_binary(a), do: a
  defp extract_annotation(str) when is_binary(str), do: str
  defp extract_annotation(_), do: nil

  defp post_annotation(space_id, annotation)
       when is_binary(space_id) and is_binary(annotation) do
    case ExecutionSpace.post_log(space_id, format_annotation(annotation)) do
      {:ok, _msg} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[architecture.audit_diff] failed to post annotation space_id=#{space_id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_annotation(annotation) when is_binary(annotation) do
    prefix = "[architect | audit_diff] "

    if String.starts_with?(annotation, prefix) do
      annotation
    else
      prefix <> annotation
    end
  end
end
