defmodule Platform.Orchestration.Rehydrator do
  @moduledoc """
  Restarts active TaskRouter processes after application boot.

  Reads all `"active"` `TaskRouterAssignment` records from the DB and calls
  `Platform.Orchestration.assign_task/2` for each one. Posts a log-only
  message to the execution space so the timeline shows the restart gap.

  Started immediately after `TaskRouterSupervisor` in the supervision tree.
  """

  use GenServer

  require Logger

  alias Platform.Orchestration
  alias Platform.Orchestration.{ExecutionSpace, TaskRouterAssignment}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :rehydrate)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:rehydrate, state) do
    active = TaskRouterAssignment.list_active()
    count = length(active)

    if count > 0 do
      Logger.info("[Rehydrator] found #{count} active assignment(s) — rehydrating")
    end

    rehydrated =
      Enum.count(active, fn assignment ->
        case Orchestration.assign_task(assignment.task_id, %{
               type: :federated,
               id: assignment.assignee_id
             }) do
          {:ok, _pid} ->
            if assignment.execution_space_id do
              ExecutionSpace.post_log(
                assignment.execution_space_id,
                "(system) Router rehydrated after restart — resuming heartbeat"
              )
            end

            true

          {:error, {:already_started, _pid}} ->
            Logger.debug(
              "[Rehydrator] router already running for task #{assignment.task_id} — skipping"
            )

            true

          {:error, reason} ->
            Logger.warning(
              "[Rehydrator] failed to rehydrate task #{assignment.task_id}: #{inspect(reason)}"
            )

            false
        end
      end)

    if count > 0 do
      Logger.info("[Rehydrator] rehydrated #{rehydrated}/#{count} router(s)")
    end

    {:noreply, state}
  end
end
