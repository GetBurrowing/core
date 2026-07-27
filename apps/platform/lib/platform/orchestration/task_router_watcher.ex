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
  alias Platform.Tasks.{Stacks, Task}

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

    started = boot_reconcile()

    Logger.info("[TaskRouterWatcher] boot: started #{started} routers")

    schedule_reconcile()

    {:ok, %{}}
  end

  # Boot-time reconciliation. Isolated from `init/1` and guarded because a
  # supervisor RESTART of this globally-supervised singleton must not be
  # able to cascade into a suite-killing failure in test env.
  #
  # The watcher and Platform.Repo are sibling children of Platform.Supervisor
  # (:one_for_one). When the watcher crashes for any reason and the
  # supervisor restarts it, `init/1` runs `list_should_run_tasks/0` — a Repo
  # query. The restarted process is NOT in any DataCase sandbox allow-list
  # (the test that would allow it isn't driving the restart), so the query
  # raises DBConnection.OwnershipError, or exits `:noproc` if a shared-mode
  # connection was already torn down. Unguarded, that crashes the restart,
  # the supervisor retries immediately, and 3 failed restarts in <5ms trip
  # Platform.Supervisor's max restart intensity — terminating the supervisor
  # and taking sibling Platform.Repo down with it, cascading "could not
  # lookup Ecto repo Platform.Repo" across every subsequent DataCase setup.
  # See notes/2026-07-06-datacase-cascade-rootcause.md for the sibling shape.
  #
  # `DBConnection.OwnershipError` is a sandbox-only error class — production
  # uses a real pool and never raises it — and at real application boot the
  # Repo is up with no sandbox, so this query succeeds and starts routers
  # exactly as before. The guards only ever fire under the test sandbox, so
  # production behaviour is unchanged.
  defp boot_reconcile do
    tasks = list_should_run_tasks()

    Enum.count(tasks, fn task ->
      case resolve_and_start(task) do
        :ok -> true
        _ -> false
      end
    end)
  rescue
    DBConnection.OwnershipError ->
      Logger.debug("[TaskRouterWatcher] boot reconcile skipped: sandbox connection not owned")
      0
  catch
    :exit, _reason ->
      Logger.debug("[TaskRouterWatcher] boot reconcile skipped: Repo connection unavailable")
      0
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
    {started, stopped} = safe_reconcile()

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
      catch
        # Same sandbox-teardown "owner exited" :exit shape guarded in
        # resolve_runtime_for_task/1 and boot_reconcile/0 — the sweep's
        # Repo.all can hit it too. Catch it so the tick never crashes the
        # watcher (a sandbox-only condition; production sweeps normally).
        :exit, _reason ->
          %{scanned: 0, transitioned: 0, observed: 0}
      end

    # Gap 3 + Gap 4 (task 019f921d) — piggyback the same 5-min tick to
    # self-heal the two fire-and-forget stack-lifecycle gaps: commence any
    # `forming`-but-ready stack, and re-fire the rollup-PR open for any
    # stack stranded at `deploying` with no `rollup_pr`. Both are idempotent
    # and log-and-swallow; a failure here never crashes the watcher.
    lifecycle_result =
      try do
        Stacks.reconcile_stack_lifecycle()
      rescue
        e ->
          Logger.warning(
            "[TaskRouterWatcher] reconcile_stack_lifecycle raised: #{Exception.message(e)}"
          )

          %{commenced: 0, pr_reopened: 0}
      catch
        :exit, _reason ->
          %{commenced: 0, pr_reopened: 0}
      end

    Logger.info(
      "[TaskRouterWatcher] reconcile: started #{started}, stopped #{stopped}; " <>
        "in_review stall sweep: scanned=#{stall_result.scanned}, " <>
        "transitioned=#{stall_result.transitioned}, observed=#{stall_result.observed}; " <>
        "stack lifecycle: commenced=#{lifecycle_result.commenced}, " <>
        "pr_reopened=#{lifecycle_result.pr_reopened}"
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
      # In an `async: true` DataCase test the sandbox is in MANUAL mode
      # (`data_case.ex` calls `Sandbox.start_owner!(Repo, shared: not
      # tags[:async])`), so those broadcasts arrive on the watcher's own
      # process, which is NOT part of the sandbox owner chain — the
      # `Repo.get` above raises. Reporting a distinct error tag lets
      # `evaluate_task/1` short-circuit rather than crash the GenServer.
      #
      # Under `async: false` the sandbox is SHARED and the watcher can use
      # the connection, so this clause is unreachable there — that case is
      # the `catch` below, not this `rescue`. The mode qualifier is
      # load-bearing and is enforced by
      # test/platform/regression/boot_telemetry_handler_detach_audit_test.exs
      # (task 019f9d80 stage 4): the unconditional version of this claim
      # was measured false in stage 3.
      {:error, :sandbox_unowned}
  catch
    # Same singleton-vs-sandbox race, but the OTHER shape: when a test that
    # HAS allowed the watcher onto its shared connection exits while this
    # `Repo.get` is mid-flight, the sandbox connection is torn down and the
    # query fails as a `DBConnection.ConnectionError` delivered as an EXIT
    # ("owner #PID exited"), which the `rescue` above does not catch. These
    # task-board broadcasts fire on nearly every task insert/update across
    # the suite, so on an unlucky interleaving the watcher crashes several
    # times inside Platform.Supervisor's restart window and takes sibling
    # Platform.Repo down — the same cascade `boot_reconcile/0` guards.
    # "owner exited" is a sandbox-only condition (production has no sandbox
    # owner), and degrading to `{:error, ...}` just skips starting the router
    # this cycle — the next task event or reconcile tick retries — so
    # production behaviour is unchanged.
    :exit, _reason ->
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
    # Single source of truth: the sub-predicates hoisted into
    # `Platform.Tasks.Stacks` (TAIL-stall fix, 2026-07-22) are shared with
    # the event path (`Stacks.advance_member_to_deploying/1`). The sweep
    # keeps the granular observe-only telemetry reasons; the transition
    # itself routes through the same `advance_member_to_deploying/1` the
    # event path uses, so both walk the identical readiness gate.
    cond do
      not Stacks.member_has_merged_into_rollup_at?(task) ->
        emit_stall_telemetry(task, %{action: :observed_only, reason: :no_stamp_or_no_stack})
        %{acc | observed: acc.observed + 1}

      not Stacks.member_review_validations_all_passed?(task) ->
        # Validations still pending — the task is legitimately awaiting
        # something. Observation only.
        emit_stall_telemetry(task, %{
          action: :observed_only,
          reason: :validations_not_passed
        })

        %{acc | observed: acc.observed + 1}

      Stacks.member_pending_review_requests?(task) ->
        emit_stall_telemetry(task, %{action: :observed_only, reason: :pending_review_requests})
        %{acc | observed: acc.observed + 1}

      true ->
        auto_transition_stalled(task, acc)
    end
  end

  defp auto_transition_stalled(%Task{} = task, acc) do
    case Stacks.advance_member_to_deploying(task) do
      {:ok, _updated} ->
        Logger.info(
          "[TaskRouterWatcher] in_review stall auto-transitioned task #{task.id} " <>
            "-> deploying (updated_at was #{inspect(task.updated_at)})"
        )

        emit_stall_telemetry(task, %{action: :auto_transitioned_to_deploying})
        %{acc | transitioned: acc.transitioned + 1}

      :noop ->
        # The shared readiness gate declined (or the transition failed and
        # was log-and-swallowed inside advance_member_to_deploying/1). The
        # cond above already confirmed the observable preconditions, so this
        # is a transient/racing state — surface it as observe-only.
        Logger.warning(
          "[TaskRouterWatcher] in_review stall detected on task #{task.id} but " <>
            "advance_member_to_deploying/1 returned :noop"
        )

        emit_stall_telemetry(task, %{
          action: :observed_only,
          reason: :advance_noop
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
  rescue
    # `{:runtime_reconnected, _}` is broadcast on `tasks:board` (which the
    # watcher subscribes to) whenever a federation runtime channel joins, so
    # runtime-channel tests reach this handler. `list_should_run_tasks/0`
    # here is the same unguarded Repo.all as the other seams — guard it so a
    # sandbox-teardown error can't crash the watcher. Sandbox-only condition;
    # production redispatches normally.
    DBConnection.OwnershipError ->
      :ok
  catch
    :exit, _reason ->
      :ok
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

  # Guarded wrapper around reconcile/0 for the `:reconcile` handler. Its
  # `list_should_run_tasks/0` Repo.all can hit the same sandbox-teardown
  # errors as the other seams (OwnershipError raise or "owner exited" :exit)
  # when a tick is processed after the allowing test has exited. Degrade to
  # {0, 0} instead of crashing the watcher — a sandbox-only condition;
  # production reconciles normally. See boot_reconcile/0 for the cascade this
  # prevents.
  defp safe_reconcile do
    reconcile()
  rescue
    DBConnection.OwnershipError ->
      Logger.debug("[TaskRouterWatcher] reconcile skipped: sandbox connection not owned")
      {0, 0}
  catch
    :exit, _reason ->
      Logger.debug("[TaskRouterWatcher] reconcile skipped: Repo connection unavailable")
      {0, 0}
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
    # The autonomous reconcile tick fires `handle_info(:reconcile)`, whose
    # `reconcile/0` call (unlike the sweep beside it) is NOT rescued and does
    # Repo work. In test the watcher is a global singleton allow-listed into
    # whichever DataCase currently owns the sandbox (test/support/data_case.ex);
    # a tick that fires after that owning test has exited runs against a
    # torn-down connection and crashes the watcher — one more restart-count
    # push toward the cascade that `boot_reconcile/0` above guards against.
    #
    # The interval is 5 min, so this only actually fires during a slow full
    # run (e.g. CI in a slim container). Gate the self-timer off in test (the
    # flag defaults to `true`, so production still reconciles every 5 min).
    # The watcher's tests drive reconcile by sending `:reconcile` directly
    # inside their own sandbox (see task_router_watcher_test.exs), so
    # reconcile-logic coverage is unaffected — this only removes the
    # wall-clock self-trigger, mirroring how the other Repo-touching
    # singletons (SummarizerSweeper, SecuritySweeper, the purgers) are
    # disabled in config/test.exs and driven directly from their tests.
    if Application.get_env(:platform, :task_router_watcher_reconcile, true) do
      Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    end
  end
end
