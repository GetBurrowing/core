defmodule Platform.Orchestration.TaskRouterWatcher do
  @moduledoc """
  Declarative watcher that enforces the TaskRouter invariant.

  At all times, the following must hold:

      For every task T where:
        T.assignee_type == "agent"
        AND T.assignee_id is not nil
        AND T.status in ["planning", "in_progress", "in_review"]
      → A TaskRouter process MUST be running for T.

      For every other task T:
      → A TaskRouter process MUST NOT be running for T.

  The watcher:
    - Subscribes to `tasks:board` PubSub events on boot.
    - Queries the DB on boot and starts all routers that should be running.
    - Reacts to `{:task_updated, task}` events by evaluating each task's invariant.
    - Runs a periodic reconciliation every 5 minutes as a safety net.

  This replaces the imperative `assign_task/2` / `unassign_task/1` model and
  the `Rehydrator` GenServer. Routers are now a consequence of task state,
  not of explicit calls.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Platform.Orchestration.{RuntimeSupervision, TaskRouterSupervisor}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  @reconcile_interval_ms 5 * 60 * 1_000

  @active_statuses ~w(planning in_progress in_review deploying)

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Tasks.subscribe_board()

    # Query DB for all tasks that should have running routers
    tasks = list_should_run_tasks()

    started =
      Enum.count(tasks, fn task ->
        case resolve_and_start(task) do
          :ok -> true
          _ -> false
        end
      end)

    Logger.info("[TaskRouterWatcher] boot: started #{started} routers")

    schedule_reconcile()

    {:ok, %{}}
  end

  @impl true
  def handle_info({event, task}, state) when event in [:task_created, :task_updated] do
    evaluate_task(task)
    {:noreply, state}
  end

  def handle_info({:runtime_reconnected, runtime_id}, state) do
    redispatch_for_runtime(runtime_id)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    {started, stopped} = reconcile()
    Logger.info("[TaskRouterWatcher] reconcile: started #{started}, stopped #{stopped}")
    schedule_reconcile()
    {:noreply, state}
  end

  # Ignore other PubSub events (plan_updated, stage_transitioned, etc.)
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Invariant evaluation ───────────────────────────────────────────────

  @doc """
  Force a router dispatch for the given task if a router is running. If not,
  re-evaluate the task so an eligible router is started first.
  """
  @spec force_dispatch(String.t()) :: :ok | :noop | {:error, :task_not_found}
  def force_dispatch(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        send(pid, :dispatch)
        :ok

      [] ->
        case Tasks.get_task_detail(task_id) do
          nil ->
            {:error, :task_not_found}

          task ->
            evaluate_task(task)

            case Registry.lookup(Platform.Orchestration.Registry, task_id) do
              [{pid, _}] ->
                send(pid, :dispatch)
                :ok

              [] ->
                :noop
            end
        end
    end
  end

  @doc """
  Returns true if the given task should have a router running.
  """
  @spec should_run?(map()) :: boolean()
  def should_run?(%{assignee_type: "agent", assignee_id: aid, status: status})
      when not is_nil(aid) and status in @active_statuses,
      do: true

  def should_run?(_), do: false

  @doc """
  Returns true if a router is currently running for the given task_id.
  """
  @spec router_running?(String.t()) :: boolean()
  def router_running?(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # ── Runtime resolution ─────────────────────────────────────────────────

  @doc """
  Resolve the agent runtime for a task with an agent assignee.

  Given a task with `assignee_id` (agent UUID), looks up the agent, then
  follows the FK to the `AgentRuntime`, and returns `{:ok, %{type: :federated,
  id: runtime_id}}`.

  Returns `{:error, reason}` if the agent or runtime cannot be resolved.
  """
  @spec resolve_runtime_for_task(map()) :: {:ok, map()} | {:error, atom()}
  def resolve_runtime_for_task(%{assignee_id: nil}), do: {:error, :no_assignee}

  def resolve_runtime_for_task(%{assignee_id: agent_id}) do
    agent = Repo.get(Platform.Agents.Agent, agent_id)

    if agent do
      runtime = Platform.Federation.get_runtime_for_agent(agent)

      if runtime do
        {:ok, %{type: :federated, id: runtime.runtime_id}}
      else
        {:error, :no_runtime}
      end
    else
      {:error, :agent_not_found}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp redispatch_for_runtime(runtime_id) do
    # Find all running routers whose task is assigned to this runtime.
    # Only redispatch tasks that do not already have an active lease for this runtime.
    tasks = list_should_run_tasks()

    redispatched =
      Enum.count(tasks, fn task ->
        case resolve_runtime_for_task(task) do
          {:ok, %{id: ^runtime_id}} ->
            cond do
              !router_running?(task.id) ->
                false

              active_lease_present?(task.id, runtime_id) ->
                false

              true ->
                [{pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
                send(pid, :dispatch)
                true
            end

          _ ->
            false
        end
      end)

    if redispatched > 0 do
      Logger.info(
        "[TaskRouterWatcher] runtime #{runtime_id} reconnected — re-dispatched #{redispatched} task(s)"
      )
    end
  end

  defp active_lease_present?(task_id, runtime_id) do
    case RuntimeSupervision.current_lease_for_task_runtime(task_id, runtime_id) do
      %{expires_at: %DateTime{} = expires_at} ->
        DateTime.compare(expires_at, DateTime.utc_now()) == :gt

      %{status: status} when status in ["active", "blocked"] ->
        true

      _ ->
        false
    end
  end

  defp evaluate_task(task) do
    cond do
      should_run?(task) && !router_running?(task.id) ->
        case resolve_and_start(task) do
          :ok ->
            Logger.debug("[TaskRouterWatcher] started router for task #{task.id}")

          {:error, reason} ->
            Logger.warning(
              "[TaskRouterWatcher] failed to start router for task #{task.id}: #{inspect(reason)}"
            )
        end

      !should_run?(task) && router_running?(task.id) ->
        case TaskRouterSupervisor.stop_assignment(task.id) do
          :ok ->
            Logger.debug("[TaskRouterWatcher] stopped router for task #{task.id}")

          {:error, :not_found} ->
            # Already stopped — no-op
            :ok
        end

      true ->
        # No change needed
        :ok
    end
  end

  defp resolve_and_start(task) do
    case resolve_runtime_for_task(task) do
      {:ok, assignee} ->
        case TaskRouterSupervisor.start_assignment(task.id, assignee) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile do
    # Tasks that should have routers
    should_run_tasks = list_should_run_tasks()
    should_run_ids = MapSet.new(should_run_tasks, & &1.id)

    # Tasks that currently have routers (from Registry)
    running_ids = MapSet.new(running_task_ids())

    # Start missing routers
    missing_ids = MapSet.difference(should_run_ids, running_ids)

    missing_tasks =
      Enum.filter(should_run_tasks, &MapSet.member?(missing_ids, &1.id))

    started =
      Enum.count(missing_tasks, fn task ->
        case resolve_and_start(task) do
          :ok -> true
          _ -> false
        end
      end)

    # Stop orphaned routers (router running but task no longer qualifies)
    orphan_ids = MapSet.difference(running_ids, should_run_ids)

    stopped =
      Enum.count(orphan_ids, fn task_id ->
        case TaskRouterSupervisor.stop_assignment(task_id) do
          :ok -> true
          {:error, :not_found} -> true
        end
      end)

    {started, stopped}
  end

  defp list_should_run_tasks do
    from(t in Task,
      where:
        t.assignee_type == "agent" and
          not is_nil(t.assignee_id) and
          t.status in @active_statuses
    )
    |> Repo.all()
  end

  defp running_task_ids do
    Platform.Orchestration.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
  end
end
