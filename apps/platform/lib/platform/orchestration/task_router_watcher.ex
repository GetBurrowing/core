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
  alias Platform.Tasks.{ReviewRequests, Task}

  @reconcile_interval_ms 5 * 60 * 1_000

  @active_statuses ~w(planning in_progress in_review deploying)

  # Bug #4 (task 019f708f): stall sweep debounce. A stack member that
  # cleared every review validation but never flipped to `deploying`
  # (because the async transition was dropped or the finalizer never
  # observed the last validation pass) will be picked up by the sweep
  # AFTER it has been sitting at `in_review` this long. The debounce
  # keeps normal review latency invisible to the sweep — a task that
  # just landed at `in_review` and is legitimately waiting for its
  # rollup-merge stamp doesn't get auto-transitioned prematurely.
  @in_review_stall_debounce_minutes 15
  @in_review_stall_sweep_cap 50

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

    # Bug #4 (task 019f708f) — piggyback on the reconcile tick to
    # catch stack members that got stranded at `in_review` after
    # every review validation passed. No new GenServer; the tick
    # already fires every 5 min.
    stall_result =
      try do
        sweep_in_review_stalls()
      rescue
        e ->
          Logger.warning(
            "[TaskRouterWatcher] sweep_in_review_stalls raised: #{Exception.message(e)}"
          )

          %{scanned: 0, transitioned: 0, observed: 0}
      end

    Logger.info(
      "[TaskRouterWatcher] reconcile: started #{started}, stopped #{stopped}; " <>
        "in_review stall sweep: scanned=#{stall_result.scanned}, " <>
        "transitioned=#{stall_result.transitioned}, observed=#{stall_result.observed}"
    )

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
  def should_run?(%{assignee_type: "agent", assignee_id: aid, status: status} = task)
      when not is_nil(aid) and status in @active_statuses do
    # `deleted_at` is present on `%Task{}` structs loaded from the DB and
    # absent on the plain maps some test helpers and transient PubSub
    # payloads use. Both "key missing" and "key set to nil" mean "not
    # deleted"; only an actual timestamp suppresses the router.
    is_nil(Map.get(task, :deleted_at))
  end

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
  rescue
    DBConnection.OwnershipError ->
      # The watcher is a globally-supervised singleton receiving
      # `{:task_created, ...}` / `{:task_updated, ...}` PubSub broadcasts.
      # In DataCase-based tests those broadcasts arrive on the watcher's
      # own process, which is NOT part of the sandbox owner chain — the
      # `Repo.get` above raises. Reporting a distinct error tag lets
      # `evaluate_task/1` short-circuit rather than crash the GenServer.
      {:error, :sandbox_unowned}
  end

  # ── Bug #4 (task 019f708f): in-review stall sweep ─────────────────────

  @doc """
  Scan for stack members that got stranded at `in_review` and
  auto-transition ones whose review contract is fully satisfied.

  A stack member should flip from `in_review` to `deploying` once the
  rollup-merge finalizer records the `merged_into_rollup_at` stamp AND
  every review-stage validation is `passed`. If the finalizer's async
  transition was dropped (dead broadcast, missed retry, etc.), the
  task sits at `in_review` forever and Rowan surfaces "why is this
  stalled" hours later. This sweep is the safety net: every reconcile
  tick (5 min) we walk stack members at `in_review` with a merge
  stamp that have been idle for `@in_review_stall_debounce_minutes`,
  confirm the review contract is satisfied, then transition them.

  Non-stack tasks and stack tasks without a merge stamp are surfaced
  as observe-only telemetry — never auto-transitioned. That covers
  the residual-observability gap without changing behavior for
  non-rollup task paths.

  Returns `%{scanned: n, transitioned: t, observed: o}` for the
  reconcile log line.
  """
  @spec sweep_in_review_stalls() :: %{
          scanned: non_neg_integer(),
          transitioned: non_neg_integer(),
          observed: non_neg_integer()
        }
  def sweep_in_review_stalls do
    candidates = list_in_review_stall_candidates()

    if length(candidates) >= @in_review_stall_sweep_cap do
      Logger.warning(
        "[TaskRouterWatcher] in_review stall sweep hit the #{@in_review_stall_sweep_cap}-row " <>
          "LIMIT — indicates a broader stall condition; expect follow-up ticks to drain."
      )
    end

    Enum.reduce(candidates, %{scanned: 0, transitioned: 0, observed: 0}, fn task, acc ->
      acc = %{acc | scanned: acc.scanned + 1}
      handle_in_review_stall_candidate(task, acc)
    end)
  end

  defp list_in_review_stall_candidates do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@in_review_stall_debounce_minutes * 60, :second)

    from(t in Task,
      where:
        t.status == "in_review" and
          not is_nil(t.stack_id) and
          fragment("? \\? ?", t.metadata, "merged_into_rollup_at") and
          is_nil(t.deleted_at) and
          t.updated_at < ^cutoff,
      order_by: [asc: t.updated_at],
      limit: @in_review_stall_sweep_cap
    )
    |> Repo.all()
  end

  defp handle_in_review_stall_candidate(%Task{stack_id: nil} = task, acc) do
    # Defensive: the query already filters `stack_id IS NOT NULL`, but
    # if that changes, non-stack tasks land here and stay observation-only.
    emit_stall_telemetry(task, %{action: :observed_only, reason: :no_stamp_or_no_stack})
    %{acc | observed: acc.observed + 1}
  end

  defp handle_in_review_stall_candidate(%Task{} = task, acc) do
    cond do
      not has_merged_into_rollup_at?(task) ->
        emit_stall_telemetry(task, %{action: :observed_only, reason: :no_stamp_or_no_stack})
        %{acc | observed: acc.observed + 1}

      not review_validations_all_passed?(task) ->
        # Validations still pending — the task is legitimately awaiting
        # something. Observation only.
        emit_stall_telemetry(task, %{
          action: :observed_only,
          reason: :validations_not_passed
        })

        %{acc | observed: acc.observed + 1}

      pending_review_requests?(task) ->
        emit_stall_telemetry(task, %{action: :observed_only, reason: :pending_review_requests})
        %{acc | observed: acc.observed + 1}

      true ->
        auto_transition_stalled(task, acc)
    end
  end

  defp has_merged_into_rollup_at?(%Task{metadata: meta}) when is_map(meta),
    do: Map.has_key?(meta, "merged_into_rollup_at")

  defp has_merged_into_rollup_at?(_task), do: false

  # Confirm every validation on every stage of the current approved
  # plan is `passed`. Missing plan / no stages / any-not-passed → false.
  defp review_validations_all_passed?(%Task{id: task_id}) do
    case Tasks.current_plan(task_id) do
      nil ->
        false

      %{stages: stages} when is_list(stages) ->
        all_validations =
          stages
          |> Enum.flat_map(fn stage ->
            case stage.validations do
              vs when is_list(vs) -> vs
              _ -> []
            end
          end)

        # A plan with zero validations at all cannot be considered
        # "fully passed" for the purpose of auto-advancing — we want
        # evidence, not silence.
        all_validations != [] and Enum.all?(all_validations, &(&1.status == "passed"))

      _ ->
        false
    end
  end

  defp pending_review_requests?(%Task{id: task_id}) do
    ReviewRequests.list_pending_for_task(task_id) != []
  end

  defp auto_transition_stalled(%Task{} = task, acc) do
    case Tasks.transition_task_status(task, "deploying") do
      {:ok, _updated} ->
        Logger.info(
          "[TaskRouterWatcher] in_review stall auto-transitioned task #{task.id} " <>
            "-> deploying (updated_at was #{inspect(task.updated_at)})"
        )

        emit_stall_telemetry(task, %{action: :auto_transitioned_to_deploying})
        %{acc | transitioned: acc.transitioned + 1}

      {:error, reason} ->
        Logger.warning(
          "[TaskRouterWatcher] in_review stall detected on task #{task.id} but " <>
            "transition to deploying failed: #{inspect(reason)}"
        )

        emit_stall_telemetry(task, %{
          action: :observed_only,
          reason: {:transition_failed, reason}
        })

        %{acc | observed: acc.observed + 1}
    end
  end

  defp emit_stall_telemetry(%Task{id: task_id}, metadata) do
    :telemetry.execute(
      [:platform, :orchestration, :stall_detected],
      %{count: 1},
      Map.put(metadata, :task_id, task_id)
    )
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

          {:error, :sandbox_unowned} ->
            # Test-only race: a `{:task_created/updated, ...}` broadcast
            # from a DataCase-owned test reached the singleton watcher
            # before Sandbox.allow was extended to it. Short-circuit at
            # :debug rather than warning so the reconcile tick still
            # covers the row later.
            Logger.debug(
              "[TaskRouterWatcher] sandbox-unowned lookup for task #{task.id} — skipping"
            )

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
          t.status in @active_statuses and
          is_nil(t.deleted_at)
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
