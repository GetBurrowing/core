defmodule Platform.Orchestration.TaskRouterSupervisor do
  @moduledoc """
  DynamicSupervisor for `Platform.Orchestration.TaskRouter` processes.

  One `TaskRouter` process is started per active task assignment. Processes are
  registered via `Platform.Orchestration.Registry` (a `Registry` with unique keys).
  """

  use DynamicSupervisor

  alias Platform.Orchestration.TaskRouter

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a TaskRouter for the given task assignment.

  ## Options
    - `task_id` — the task to route
    - `assignee` — `%{type: :federated, id: runtime_id}`
  """
  @spec start_assignment(String.t(), map()) :: DynamicSupervisor.on_start_child()
  def start_assignment(task_id, assignee) do
    child_spec = {TaskRouter, task_id: task_id, assignee: assignee}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Stop the TaskRouter for the given task."
  @spec stop_assignment(String.t()) :: :ok | {:error, :not_found}
  def stop_assignment(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all active task router assignments."
  @spec list_active() :: [map()]
  def list_active do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        try do
          [GenServer.call(pid, :current_status, 2_000)]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
  end
end
