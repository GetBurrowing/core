defmodule Platform.Orchestration do
  @moduledoc """
  Task dispatch, heartbeat management, and execution escalation.

  This domain is responsible for ensuring assigned tasks keep moving. It
  assembles deterministic execution context, dispatches to federated agents
  via the RuntimeChannel, monitors stage progression through PubSub, and
  escalates when agents go silent.

  All routing decisions are deterministic — no LLM in the router.

  ## Public API

    - `assign_task/2` — start orchestrating a task for the given assignee
    - `unassign_task/1` — stop orchestration for a task
    - `task_status/1` — get current router status for a task
  """

  require Logger

  alias Platform.Orchestration.{TaskRouter, TaskRouterAssignment, TaskRouterSupervisor}
  alias Platform.Repo

  @doc """
  Start orchestrating a task for the given assignee.

  The assignee should be `%{type: :federated, id: runtime_id}`.
  """
  @spec assign_task(String.t(), map()) :: DynamicSupervisor.on_start_child()
  def assign_task(task_id, assignee) do
    TaskRouterSupervisor.start_assignment(task_id, assignee)
  end

  @doc "Stop orchestration for a task."
  @spec unassign_task(String.t()) :: :ok | {:error, :not_found}
  def unassign_task(task_id) do
    # Mark the persisted assignment as completed before stopping the router
    mark_assignment_completed(task_id)
    TaskRouterSupervisor.stop_assignment(task_id)
  end

  defp mark_assignment_completed(task_id) do
    case Repo.get(TaskRouterAssignment, task_id) do
      %TaskRouterAssignment{} = assignment ->
        assignment
        |> TaskRouterAssignment.status_changeset(%{status: "completed"})
        |> Repo.update()

      nil ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[Orchestration] failed to mark assignment completed for #{task_id}: #{inspect(e)}"
      )

      :ok
  end

  @doc "Get current router status for a task."
  @spec task_status(String.t()) :: map()
  def task_status(task_id) do
    TaskRouter.current_status(task_id)
  end
end
