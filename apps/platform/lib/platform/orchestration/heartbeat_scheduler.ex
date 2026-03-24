defmodule Platform.Orchestration.HeartbeatScheduler do
  @moduledoc """
  Stage-aware heartbeat cadence configuration and prompt generation.

  Provides pure functions for determining heartbeat intervals, stall thresholds,
  and generating dispatch/heartbeat prompt messages. No GenServer — this module
  is called by `TaskRouter` to decide timing and message content.

  Cadence table (from ADR 0025):

  | Stage type        | Heartbeat interval | Stall threshold | Escalation after    |
  |-------------------|--------------------|-----------------|---------------------|
  | planning          | 15 min             | 30 min          | 2 missed heartbeats |
  | coding            | 10 min             | 25 min          | 2 missed heartbeats |
  | ci_check          | 5 min              | 15 min          | 3 missed heartbeats |
  | review            | 20 min             | 60 min          | 1 missed heartbeat  |
  | manual_approval   | n/a                | n/a             | n/a (human gate)    |
  """

  @type stage_type :: String.t()

  # Cadence config: {interval_ms, stall_threshold_ms, max_escalations}
  @cadence %{
    "planning" => {15 * 60_000, 30 * 60_000, 2},
    "coding" => {10 * 60_000, 25 * 60_000, 2},
    "ci_check" => {5 * 60_000, 15 * 60_000, 3},
    "review" => {20 * 60_000, 60 * 60_000, 1},
    "manual_approval" => {nil, nil, nil}
  }

  # Default for unknown stage types — treat like coding
  @default_cadence {10 * 60_000, 25 * 60_000, 2}

  @doc "Heartbeat interval in milliseconds for the given stage type."
  @spec interval_ms(stage_type()) :: non_neg_integer() | nil
  def interval_ms(stage_type) do
    {interval, _stall, _esc} = Map.get(@cadence, stage_type, @default_cadence)
    interval
  end

  @doc "Stall threshold in milliseconds for the given stage type."
  @spec stall_threshold_ms(stage_type()) :: non_neg_integer() | nil
  def stall_threshold_ms(stage_type) do
    {_interval, stall, _esc} = Map.get(@cadence, stage_type, @default_cadence)
    stall
  end

  @doc "Maximum missed heartbeats before escalation."
  @spec max_escalations(stage_type()) :: non_neg_integer() | nil
  def max_escalations(stage_type) do
    {_interval, _stall, esc} = Map.get(@cadence, stage_type, @default_cadence)
    esc
  end

  @doc "Returns true if the stage type is a human gate that should skip heartbeats."
  @spec manual_approval?(stage_type()) :: boolean()
  def manual_approval?(stage_type), do: stage_type == "manual_approval"

  @doc """
  Generate the initial dispatch prompt sent when a task is first assigned.

  Pattern-matched on task status and plan/stage presence:
  - planning (no plan) — instruct agent to create and submit a plan
  - in_progress — execute current stage with evidence
  - in_review — run validations, do not self-approve gates
  - fallback — generic assignment prompt
  """
  @spec dispatch_prompt(map(), map() | nil, map() | nil) :: String.t()
  def dispatch_prompt(%{status: "planning"} = task, nil, nil) do
    """
    You have been assigned a task that requires a plan before any implementation begins.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Priority: #{task.priority}

    Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

    A good plan stage must include:
    - A clear name (not just a category label)
    - A description that explains: what specifically will be changed, which files will be modified or created, what the implementation approach is, and why that approach was chosen
    - Appropriate validations: use test_pass and lint_pass for code changes. Use manual_approval for any stage that requires a human to visually verify a UI change — when you reach that stage, post a screenshot as a canvas into the execution space so the human can review it. Do NOT include code_review as a validation kind — it is not supported.

    Aim for 3–7 stages. Each stage should represent a discrete, reviewable unit of work. "Client-side draft persistence" with no further detail is not acceptable — describe the actual change.

    Example of a good stage description:
    "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every input event, store the current textarea value keyed by space_id (read from data-space-id attribute on the element). On mounted(), restore any saved draft and push it to the server via compose_changed event. On compose_reset, delete the draft for that space."

    Submit the plan with plan_submit when complete. Do not begin implementation until the plan is approved.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project (name, repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan with stages, and execution_space_id. Use it for full context when writing your plan.
    """
  end

  def dispatch_prompt(%{status: "in_progress"} = task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    Plan approved — execute the current stage.

    Task: #{task.title}
    #{stage_info}\
    Push evidence using validation_pass or stage_complete as you finish each step. \
    Post commentary to the execution space so reviewers can follow along. \
    Use report_blocker if you are stuck.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
    """
  end

  def dispatch_prompt(%{status: "in_review"} = task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    Task is in review — run validations and push evidence.

    Task: #{task.title}
    #{stage_info}\
    Run all applicable validations and push evidence. \
    Do not self-approve code_review or manual_approval stages — a human must approve those.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
    """
  end

  def dispatch_prompt(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    You have been assigned a task.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Status: #{task.status}
    Priority: #{task.priority}
    #{stage_info}\
    Review the task context and begin working. Report progress by pushing validation evidence as you complete each stage.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, current plan with stages, and execution_space_id. Use it for full context.
    """
  end

  @doc """
  Generate a stateful heartbeat interrogation prompt.

  This is not a keepalive — it carries elapsed time, stage position, and
  pending validations to force the agent to account for itself.
  """
  @spec heartbeat_prompt(map(), map() | nil, non_neg_integer(), list()) :: String.t()
  def heartbeat_prompt(task, stage, elapsed_seconds, pending_validations) do
    elapsed_str = format_elapsed(elapsed_seconds)
    stage_name = if stage, do: stage.name, else: "unknown"
    stage_status = if stage, do: stage.status, else: "unknown"

    pending_str =
      case pending_validations do
        [] -> "none"
        validations -> Enum.map_join(validations, ", ", & &1.kind)
      end

    """
    Task: #{task.title} [stage: #{stage_name} — #{stage_status}]
    Stage running for: #{elapsed_str}
    Pending validations: #{pending_str}

    Either push validation evidence or report a blocker.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.\
    """
  end

  defp format_stage_info(nil, _stage), do: ""

  defp format_stage_info(plan, nil) do
    stage_count = length(plan.stages || [])
    "Plan: v#{plan.version} (#{stage_count} stages)\n"
  end

  defp format_stage_info(plan, stage) do
    stages = plan.stages || []
    stage_count = length(stages)
    position = stage.position || 0
    "Plan: v#{plan.version} (stage #{position}/#{stage_count} — #{stage.name})\n"
  end

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds} seconds"

  defp format_elapsed(seconds) do
    minutes = div(seconds, 60)

    if minutes < 60 do
      "#{minutes} minutes"
    else
      hours = div(minutes, 60)
      remaining_minutes = rem(minutes, 60)
      "#{hours}h #{remaining_minutes}m"
    end
  end
end
