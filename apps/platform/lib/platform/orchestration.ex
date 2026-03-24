defmodule Platform.Orchestration do
  @moduledoc """
  Task dispatch, heartbeat management, and execution escalation.

  This domain is responsible for ensuring assigned tasks keep moving. It
  assembles deterministic execution context, dispatches to federated agents
  via the RuntimeChannel, monitors stage progression through PubSub, and
  escalates when agents go silent.

  All routing decisions are deterministic — no LLM in the router.

  Routers are started and stopped declaratively by `TaskRouterWatcher`, which
  monitors task state changes via PubSub. There is no imperative API for
  starting/stopping routers from outside this domain.

  ## Public API

    - `task_status/1` — get current router status for a task
    - `resolve_runtime_for_task/1` — resolve agent runtime for a task
  """

  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Orchestration.TaskRouter

  @doc "Get current router status for a task."
  @spec task_status(String.t()) :: map()
  def task_status(task_id) do
    TaskRouter.current_status(task_id)
  end

  @doc """
  Resolve the agent runtime for a task with an agent assignee.

  Delegates to `TaskRouterWatcher.resolve_runtime_for_task/1`.
  """
  @spec resolve_runtime_for_task(map()) :: {:ok, map()} | {:error, atom()}
  defdelegate resolve_runtime_for_task(task), to: TaskRouterWatcher
end
