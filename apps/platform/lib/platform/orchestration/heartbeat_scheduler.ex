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
  """
  @spec dispatch_prompt(map(), map() | nil, map() | nil) :: String.t()
  def dispatch_prompt(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    You have been assigned a task.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Status: #{task.status}
    Priority: #{task.priority}
    #{stage_info}\
    Review the task context and begin working. Report progress by pushing validation evidence as you complete each stage.\
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

    Either push validation evidence or report a blocker.\
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
