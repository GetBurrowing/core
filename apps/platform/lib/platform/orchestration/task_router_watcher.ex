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

  ## The sandbox precondition (invariant)

  **No handler may touch `Platform.Orchestration.Registry`,
  `TaskRouterSupervisor`, or the `:orchestration_lease_manager` ETS table
  before the sandbox precondition in `handle_task_event/2` has passed.**

  This watcher is a globally-supervised singleton that `Platform.DataCase`
  allow-lists into *every* test, and `Sandbox.allow/3` binds it to whichever
  test won the race. So a broadcast raised by test A routinely arrives while
  the watcher is sitting on test B's connection. The state it then mutates —
  Registry entries, supervised router processes, lease rows in a
  `:named_table, :public` ETS table — is **global and non-transactional**, so
  the end-of-test sandbox rollback does not undo any of it.

  A return-value check cannot enforce that. The stop branch of
  `evaluate_task/1` performs **zero Repo calls**, so no Repo-derived
  `:sandbox_unowned` signal ever reaches the code that terminates a router and
  clears its lease. The guard therefore has to be a *precondition on handling
  the broadcast at all*. See `Platform.Orchestration.SandboxGuard` and
  `notes/2026-07-06-datacase-cascade-rootcause.md`.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Platform.Agents.AgentRuntime

  alias Platform.Orchestration.{
    PhaseRuntime,
    RuntimeSupervision,
    SandboxGuard,
    TaskRouterSupervisor
  }

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stacks, Task}

  @reconcile_interval_ms 5 * 60 * 1_000

  @active_statuses ~w(planning in_progress in_review deploying)

  @doc """
  The task statuses the dispatcher treats as live — the set `stack_get`'s
  `executable_now` reuses so "runnable now" on the MCP surface is the
  dispatcher's own notion, not a parallel one (task 01a05394-8300 stage 2).
  """
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

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

  # Task 019fa605: architecture-gate expiry sweep. See
  # `sweep_expired_architecture_gates/0` for the argument.
  @gate_expiry_sweep_cap 25

  # A healthy router arms its own `{:architecture_gate_deadline, plan_id}`
  # timer and settles the gate the instant it fires. The grace keeps that
  # the PRIMARY settler and this sweep a backstop, so the two are not
  # routinely racing over the same row. Correctness does not depend on it:
  # `record_architecture_verdict/3`'s guarded `UPDATE ... WHERE
  # ->>'state' = 'pending'` already makes the race deterministic — the
  # loser gets `{:error, :gate_already_resolved}` and counts as observed.
  @gate_expiry_sweep_grace_minutes 2

  # THE DEPLOY-DAY GUARD. Without it the first production tick after this
  # ships settles every historical overdue gate at once and can auto-approve
  # plans abandoned weeks ago. Ancient rows get surfaced as telemetry, not
  # acted on.
  @gate_expiry_sweep_max_age_days 7

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Block until the watcher has drained every message enqueued before this call.

  A `GenServer.call/3` is answered strictly after every message already in the
  watcher's mailbox has been handled, so `sync/0` returning proves the
  broadcasts a test raised before it have been fully processed — including
  their Registry / supervisor / ETS side effects.

  This exists so tests stop synchronising with a fixed `Process.sleep/1`. A
  sleep is a guess in both directions: too short and the assertion races the
  watcher, too long and it hides a real regression behind wall-clock padding.
  Mirrors the `:__drain__` call `Platform.DataCase` already makes against
  `Platform.Chat.AttentionRouter`.
  """
  @spec sync(timeout()) :: :ok
  def sync(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :sync, timeout)
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
    handle_task_event(event, task)
    {:noreply, state}
  end

  def handle_info({:runtime_reconnected, runtime_id}, state) do
    handle_runtime_reconnected(runtime_id)
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

          %{commenced: 0, pr_reopened: 0, promoted: 0}
      catch
        :exit, _reason ->
          %{commenced: 0, pr_reopened: 0, promoted: 0}
      end

    # Task 019fa605 — the same 5-min tick is also the deadline timer for
    # every plan whose task has no router. Identical envelope: the sweep's
    # `Repo.all` can hit the sandbox-teardown "owner exited" `:exit` shape
    # guarded at `resolve_runtime_for_task/1` and `boot_reconcile/0`, and a
    # failure here must never crash the watcher.
    gate_result =
      try do
        sweep_expired_architecture_gates()
      rescue
        e ->
          Logger.warning(
            "[TaskRouterWatcher] sweep_expired_architecture_gates raised: #{Exception.message(e)}"
          )

          %{scanned: 0, settled: 0, observed: 0}
      catch
        :exit, _reason ->
          %{scanned: 0, settled: 0, observed: 0}
      end

    # Task 019fa605 stage 3 — one step further down the same failure: a gate
    # already resolved terminally whose deferred approval tail was lost.
    # Ordered AFTER the expiry sweep deliberately, so a gate settled by this
    # very tick gets its tail run by the NEXT one rather than being raced
    # here; the 15-minute debounce enforces that regardless of order.
    retry_result =
      try do
        sweep_unsettled_auto_approvals()
      rescue
        e ->
          Logger.warning(
            "[TaskRouterWatcher] sweep_unsettled_auto_approvals raised: #{Exception.message(e)}"
          )

          %{scanned: 0, reapproved: 0, observed: 0}
      catch
        :exit, _reason ->
          %{scanned: 0, reapproved: 0, observed: 0}
      end

    Logger.info(
      "[TaskRouterWatcher] reconcile: started #{started}, stopped #{stopped}; " <>
        "in_review stall sweep: scanned=#{stall_result.scanned}, " <>
        "transitioned=#{stall_result.transitioned}, observed=#{stall_result.observed}; " <>
        "stack lifecycle: commenced=#{lifecycle_result.commenced}, " <>
        "pr_reopened=#{lifecycle_result.pr_reopened}, " <>
        "promoted=#{lifecycle_result.promoted}; " <>
        "arch gate sweep: scanned=#{gate_result.scanned}, " <>
        "settled=#{gate_result.settled}, observed=#{gate_result.observed}; " <>
        "auto-approval retry sweep: scanned=#{retry_result.scanned}, " <>
        "reapproved=#{retry_result.reapproved}, observed=#{retry_result.observed}"
    )

    schedule_reconcile()
    {:noreply, state}
  end

  # Ignore other PubSub events (plan_updated, stage_transitioned, etc.)
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  # ── Broadcast boundary: the sandbox precondition ───────────────────────
  #
  # Everything below the two `handle_task_event/2` preconditions mutates
  # global, non-transactional state: the Registry, supervised TaskRouter
  # processes, and the `:orchestration_lease_manager` ETS table. So the guard
  # has to sit HERE, before any of it, rather than downstream:
  #
  #   * `should_run?/1` is pure struct reads and `router_running?/1` is a bare
  #     `Registry.lookup` — neither touches Repo, so neither has an error to
  #     short-circuit on.
  #   * `evaluate_task/1`'s STOP branch reaches `terminate_child` (and through
  #     its terminate, `LeaseManager.clear/1`) with ZERO Repo calls. There is
  #     no return value anywhere on that path that could carry an ownership
  #     signal.
  #
  # PRECONDITION A runs in every environment. Under the production pool
  # `Repo.checkout/1` always succeeds (`SandboxGuard.connection_owned?/0`
  # short-circuits to `true` off the sandbox pool precisely so a transient
  # pool timeout can never be read as "not owned"), so it is inert in
  # production by construction rather than by convention.
  #
  # PRECONDITION B is gated on `SandboxGuard.sandbox_pool?/0` and therefore
  # cannot run in production at all. That gate is deliberately cheaper than
  # the alternative — auditing all eleven `broadcast_board/1` call sites to
  # prove none of them can fire before its transaction commits, and re-auditing
  # on every new one.
  defp handle_task_event(event, task) do
    cond do
      not SandboxGuard.connection_owned?() ->
        drop(:connection_unowned, %{event: event, task_id: id_of(task)})

      not task_row_visible?(task) ->
        drop(:foreign_connection, %{event: event, task_id: id_of(task)})

      true ->
        # Defence in depth for the window between the probe above and the work
        # below: the connection can still be torn down mid-flight if the test
        # that allowed us onto it exits right here. Everything Repo-touching
        # downstream already carries its own rescue, so this envelope is not
        # what makes today's paths safe — it is what makes the NEXT handler
        # added below this line safe by default.
        SandboxGuard.guarded(fn -> evaluate_task(task) end, :ok, caller: __MODULE__)
    end
  end

  defp handle_runtime_reconnected(runtime_id) do
    # `redispatch_for_runtime/1` rescues its own Repo work, but its
    # `send(pid, :dispatch)` to a live router is global-state mutation
    # reachable from a foreign broadcast — so the same precondition applies.
    cond do
      not SandboxGuard.connection_owned?() ->
        drop(:connection_unowned, %{event: :runtime_reconnected, runtime_id: runtime_id})

      not runtime_row_visible?(runtime_id) ->
        drop(:foreign_connection, %{event: :runtime_reconnected, runtime_id: runtime_id})

      true ->
        SandboxGuard.guarded(fn -> redispatch_for_runtime(runtime_id) end, :ok,
          caller: __MODULE__
        )
    end
  end

  defp task_row_visible?(task) do
    not SandboxGuard.sandbox_pool?() or SandboxGuard.row_visible?(Task, id_of(task))
  end

  # The runtime equivalent of `row_visible?/2`. `AgentRuntime` is keyed in
  # broadcasts by its string `runtime_id`, not its primary key, so it needs
  # its own predicate rather than the shared id-based one.
  defp runtime_row_visible?(runtime_id) do
    not SandboxGuard.sandbox_pool?() or
      SandboxGuard.guarded(
        fn -> Repo.exists?(from(r in AgentRuntime, where: r.runtime_id == ^runtime_id)) end,
        false,
        caller: __MODULE__
      )
  end

  defp id_of(task), do: Map.get(task, :id)

  defp drop(reason, metadata) do
    # `:debug`, not `:warning`. Under the sandbox this fires on a large
    # fraction of board broadcasts by design — a foreign-connection drop is
    # the guard working, not an anomaly — and at `:warning` it would bury the
    # log a real problem needs. The telemetry event beside it is the channel
    # a test or a metric should watch.
    Logger.debug(
      "[TaskRouterWatcher] dropped broadcast (#{reason}): #{inspect(metadata)} — " <>
        "the sandbox precondition did not pass, so no global state was touched"
    )

    SandboxGuard.record_drop(reason, __MODULE__, metadata)
  end

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
  Resolve the agent runtime that owns this task's CURRENT phase.

  Delegates to `Platform.Orchestration.PhaseRuntime.resolve/1`, which looks
  up `phase_assignees[current_phase(task)]` (falling back to the flat
  `assignee_id` pointer), follows the agent's FK to its `AgentRuntime`, and
  returns `{:ok, %{type: :federated, id: runtime_id}}`.

  Returns `{:error, reason}` if the agent or runtime cannot be resolved; see
  `PhaseRuntime`'s moduledoc for the five distinct reasons. The
  `%{assignee_id: nil}` shape still yields `{:error, :no_assignee}`, now via
  that module's `{nil, _}` clause rather than a head here.

  Kept as a public function with its original name and `@spec` because
  `resolve_and_start/1`, `redispatch_for_runtime/1`,
  `Platform.Orchestration.resolve_runtime_for_task/1` and
  `task_router_watcher_test.exs` all call it. Moving the BODY (task 019fb977)
  is what removes the split-brain: before, the watcher decided eligibility
  and redispatch from the flat pointer while `TaskRouter` dispatched to a
  frozen copy, so `redispatch_for_runtime/1` could poke a router on behalf of
  runtime B and watch it send to runtime A. Both sides now ask one function.
  """
  @spec resolve_runtime_for_task(map()) :: {:ok, map()} | {:error, atom()}
  def resolve_runtime_for_task(task), do: PhaseRuntime.resolve(task)

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

  # ── Task 019fa605: architecture-gate expiry sweep ─────────────────────

  @doc """
  Settle architecture gates whose deadline has passed on tasks that have no
  router. **This is the deadline timer for tasks nothing else times.**

  ## The defect

  `should_run?/1` requires `assignee_type == "agent"`, so a task whose
  PLANNING assignee is a USER never gets a `TaskRouter`, never arms
  `{:architecture_gate_deadline, plan_id}`, and therefore never has anything
  that calls `Tasks.resolve_architecture_gate(plan, :expired)`.

  `Tasks.architecture_gate/1` still PROJECTS the overdue gate as
  `{:resolved, %{"state" => "expired", "source" => "deadline"}}` — the level
  guarantee that a gate can never block forever — but that projection is a
  READ. Nothing downstream of it re-enters `settle_plan_submission/1 ->
  maybe_auto_approve/1`, so a task carrying `auto_approve_plan: true` (or a
  stack member under `auto_accept_plan: true`, which `maybe_auto_approve/1`
  reads through the same branch) sits at `pending_review` forever on a plan
  configured to approve itself.

  ## What this calls, and what it deliberately does not

  `Tasks.resolve_architecture_gate/3` is the ONLY thing this sweep calls,
  and that is the whole design: it is the identical single call
  `TaskRouter.handle_info({:architecture_gate_deadline, plan_id}, _)` makes.
  NO NEW SETTLEMENT CODE lives here. The verdict write, the cursor return to
  `:planning`, `record_architecture_planning_step(task, {:error, :expired})`
  and the deferred `settle_plan_submission/1 -> maybe_auto_approve/1` tail
  all come from the existing `settle_resolved_architecture_gate(plan,
  :expired)` clause in `Platform.Tasks`.

  Consequently approving does NOT erase the record that nobody reviewed the
  plan: the settled verdict still reads `state: "expired"` / `source:
  "deadline"` and `Tasks.planning_gate_failed?/1` is still true. A fix that
  bought liveness by quietly marking the gate passed would be worse than the
  stall it replaced.

  ## Which side of the projection this is on

  `Tasks.architecture_gate/1` OWNS the overdue rule and this function never
  re-derives it. The SQL predicate matches the raw column (`->>'state' =
  'pending'`) purely to bound the candidate set — the writer arbitrating a
  race wants the row — and then every candidate is re-asked through
  `architecture_gate/1`, whose answer is the authority for whether to act.
  The only thing measured locally is the MAGNITUDE of the overdue interval,
  for the grace and max-age bands; the overdue/not-overdue decision itself is
  never made here.

  ## Why the sweep and not the three alternatives

    1. **Extending `should_run?/1` to user-assigned tasks does not work as
       stated.** `evaluate_task/1` starts a router via `resolve_and_start/1
       -> resolve_runtime_for_task/1`, which does `Repo.get(Agents.Agent,
       assignee_id)` and returns `{:error, :agent_not_found}` for a user id.
       The router never starts and the watcher logs a warning every five
       minutes. Making it work needs a second router flavour with no runtime,
       inside a GenServer whose entire dispatch loop assumes one.

    2. **A deferred continuation after the admission commits cannot fix this
       bug at all.** `architecture_gate_admission/2` has exactly one caller —
       `approve_plan/3` — and every branch except `:refuse` proceeds to
       `do_approve_plan/3`. By the time any continuation fired, the plan
       would already be approved by whoever called. The stall is precisely
       the case where NOBODY calls `approve_plan/3`. Refuted on the facts,
       not on blast radius.

    3. **Refusing the combination at write time is refuted too.**
       `auto_approve_plan: true` with a user planning assignee works whenever
       the architect answers, because the architect is dispatched through
       `Platform.Responsibilities.fire/2` to its OWN runtime and its verdict
       arrives via the MCP tool calling `resolve_architecture_gate(:pass)`,
       never through the task's router. It also works when nobody holds
       `architecture.review_plan`: `submit_plan_for_review/1` takes the
       `:not_applicable` branch into `settle_ungated_plan_submission/1` and
       auto-approves inline. Only the silent-architect corner stalls, so
       refusing would reject configurations that demonstrably make progress.

  THE ROUTER IS AN OPTIMISATION; THIS SWEEP IS THE GUARANTEE — the same shape
  as `architecture_gate/1`'s projection being the guarantee and the router's
  deadline timer the edge.

  Returns `%{scanned: n, settled: s, observed: o}` for the reconcile log line.
  """
  @spec sweep_expired_architecture_gates() :: %{
          scanned: non_neg_integer(),
          settled: non_neg_integer(),
          observed: non_neg_integer()
        }
  def sweep_expired_architecture_gates do
    candidates = list_expired_architecture_gate_candidates()

    if length(candidates) >= @gate_expiry_sweep_cap do
      Logger.warning(
        "[TaskRouterWatcher] architecture gate expiry sweep hit the " <>
          "#{@gate_expiry_sweep_cap}-row LIMIT — indicates a broader stall " <>
          "condition; expect follow-up ticks to drain."
      )
    end

    Enum.reduce(candidates, %{scanned: 0, settled: 0, observed: 0}, fn plan, acc ->
      acc = %{acc | scanned: acc.scanned + 1}
      handle_gate_expiry_candidate(plan, acc)
    end)
  end

  # `p.status == "pending_review"` is load-bearing, not incidental. A `draft`
  # or superseded (`rejected`) version can still carry a stale `"pending"`
  # verdict, and settling one would drive `approve_plan/3` on a
  # non-`pending_review` plan, get `{:error, :invalid_transition}`, and log a
  # `maybe_auto_approve` warning on every tick forever.
  defp list_expired_architecture_gate_candidates do
    from(p in Plan,
      join: t in Task,
      on: t.id == p.task_id,
      where:
        p.status == "pending_review" and
          fragment("?->>'state' = 'pending'", p.architecture_verdict) and
          is_nil(t.deleted_at),
      order_by: [asc: p.updated_at],
      limit: @gate_expiry_sweep_cap
    )
    |> Repo.all()
  end

  defp handle_gate_expiry_candidate(%Plan{} = plan, acc) do
    case Tasks.architecture_gate(plan.id) do
      {:open, _verdict} ->
        observe_gate_candidate(plan, :not_overdue, acc)

      {:resolved, %{"state" => "expired"} = verdict} ->
        classify_expired_gate_candidate(plan, verdict, acc)

      {:resolved, _other_terminal} ->
        # A real writer beat us between the candidate query and this
        # re-read. The gate is no longer ours to close; healing a plan whose
        # verdict is ALREADY terminal is a different shape with different
        # refusals (an architect-rejected plan must never be auto-approved).
        observe_gate_candidate(plan, :already_resolved, acc)

      :none ->
        # Defensive: the query filters on a `"pending"` verdict, so the gate
        # having vanished means the row moved under us.
        observe_gate_candidate(plan, :no_gate, acc)
    end
  end

  defp classify_expired_gate_candidate(%Plan{} = plan, verdict, acc) do
    grace_seconds = @gate_expiry_sweep_grace_minutes * 60
    max_age_seconds = @gate_expiry_sweep_max_age_days * 24 * 60 * 60

    case gate_overdue_seconds(verdict) do
      nil ->
        # `architecture_gate/1` projects a missing or unparseable
        # `deadline_at` as expired (deliberately — a gate with no falsifiable
        # end is the failure it rules out). But its AGE is then unknown, so
        # the max-age guard cannot be applied and we surface rather than act.
        observe_gate_candidate(plan, :undatable_deadline, acc)

      seconds when seconds < grace_seconds ->
        observe_gate_candidate(plan, :within_grace, acc)

      seconds when seconds > max_age_seconds ->
        observe_gate_candidate(plan, :too_old, acc)

      _settleable ->
        settle_expired_gate(plan, acc)
    end
  end

  # Magnitude only — see the @doc. `architecture_gate/1` has already decided
  # this gate is overdue; this just measures by how much.
  defp gate_overdue_seconds(%{"deadline_at" => deadline}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, at, _offset} -> DateTime.diff(DateTime.utc_now(), at, :second)
      {:error, _reason} -> nil
    end
  end

  defp gate_overdue_seconds(_verdict), do: nil

  defp settle_expired_gate(%Plan{} = plan, acc) do
    case Tasks.resolve_architecture_gate(plan.id, :expired) do
      {:ok, _settled} ->
        Logger.info(
          "[TaskRouterWatcher] architecture gate expiry swept plan=#{plan.id} " <>
            "task=#{plan.task_id} (no router; settled :expired)"
        )

        emit_gate_sweep_telemetry(plan, %{action: :settled, reason: :expired})
        %{acc | settled: acc.settled + 1}

      {:error, :gate_already_resolved} ->
        # Expected: a router (or a late architect verdict) beat us to the
        # guarded UPDATE. Not a fault.
        Logger.debug(
          "[TaskRouterWatcher] architecture gate expiry sweep lost the race on " <>
            "plan=#{plan.id} — already resolved"
        )

        emit_gate_sweep_telemetry(plan, %{
          action: :observed_only,
          reason: :gate_already_resolved
        })

        %{acc | observed: acc.observed + 1}

      {:error, reason} ->
        Logger.warning(
          "[TaskRouterWatcher] architecture gate expiry sweep failed to settle " <>
            "plan=#{plan.id} task=#{plan.task_id} reason=#{inspect(reason)}"
        )

        emit_gate_sweep_telemetry(plan, %{action: :observed_only, reason: :settle_failed})
        %{acc | observed: acc.observed + 1}
    end
  end

  # ── task 019fa605 stage 3: the lost deferred tail ─────────────────────

  # A plan settled thirty seconds ago may still be mid-tail in another
  # process. Mirrors `@in_review_stall_debounce_minutes` for the same reason:
  # normal settlement latency must stay invisible to the sweep.
  @unsettled_auto_approval_debounce_minutes 15

  @doc """
  Re-run the auto-approval tail for plans whose gate resolved terminally but
  which never left `pending_review`.

  The sibling of `sweep_expired_architecture_gates/0`, one step further down
  the same failure: that sweep heals a verdict ROW still reading `"pending"`,
  this one heals a verdict already written `"expired"` / `"dispatch_failed"`
  whose deferred `settle_plan_submission/1` tail was lost. The 07-27
  production audit found rows in exactly that shape.

  **This arm holds no policy.** Every refusal — the architect-rejected plan
  that must never be auto-approved, the human override, the passed gate, the
  unarmed task, the failed precondition — lives in `Tasks.retry_auto_approval/1`,
  and the candidate query is built from `Tasks.retryable_auto_approval_states/0`
  so the scan and the refusal cannot name different sets. A future caller must
  not be able to get a different answer than this one.

  Returns `%{scanned: n, reapproved: r, observed: o}` for the reconcile log.
  """
  @spec sweep_unsettled_auto_approvals() :: %{
          scanned: non_neg_integer(),
          reapproved: non_neg_integer(),
          observed: non_neg_integer()
        }
  def sweep_unsettled_auto_approvals do
    candidates = list_unsettled_auto_approval_candidates()

    if length(candidates) >= @gate_expiry_sweep_cap do
      Logger.warning(
        "[TaskRouterWatcher] unsettled auto-approval sweep hit the " <>
          "#{@gate_expiry_sweep_cap}-row LIMIT — indicates a broader stall " <>
          "condition; expect follow-up ticks to drain."
      )
    end

    Enum.reduce(candidates, %{scanned: 0, reapproved: 0, observed: 0}, fn plan, acc ->
      acc = %{acc | scanned: acc.scanned + 1}
      handle_unsettled_auto_approval_candidate(plan, acc)
    end)
  end

  # THE MAX-AGE GUARD IS IN SQL HERE, AND IN ELIXIR IN THE SIBLING SWEEP.
  # That difference is deliberate. `sweep_expired_architecture_gates/0`'s
  # candidates SELF-CLEAR — settling one flips its verdict off `"pending"`
  # and it leaves the candidate set — so surfacing `:too_old` as telemetry
  # costs nothing. This sweep's refused candidates NEVER change: an unarmed
  # task's `expired` plan sits at `pending_review` forever and its
  # `updated_at` never moves. Classifying age in Elixir would let those
  # permanent residents accumulate at the head of an oldest-first, 25-row
  # capped query and starve every genuinely healable row behind them.
  # Filtering in SQL keeps the cap spent on rows inside the window.
  defp list_unsettled_auto_approval_candidates do
    now = DateTime.utc_now()
    debounce_cutoff = DateTime.add(now, -@unsettled_auto_approval_debounce_minutes * 60, :second)
    max_age_cutoff = DateTime.add(now, -@gate_expiry_sweep_max_age_days * 24 * 60 * 60, :second)
    states = Tasks.retryable_auto_approval_states()

    from(p in Plan,
      join: t in Task,
      on: t.id == p.task_id,
      where:
        p.status == "pending_review" and
          fragment("?->>'state'", p.architecture_verdict) in ^states and
          is_nil(t.deleted_at) and
          p.updated_at < ^debounce_cutoff and
          p.updated_at > ^max_age_cutoff,
      order_by: [asc: p.updated_at],
      limit: @gate_expiry_sweep_cap
    )
    |> Repo.all()
  end

  defp handle_unsettled_auto_approval_candidate(%Plan{} = plan, acc) do
    case Tasks.retry_auto_approval(plan.id) do
      {:ok, :approved} ->
        Logger.info(
          "[TaskRouterWatcher] lost auto-approval tail re-run plan=#{plan.id} " <>
            "task=#{plan.task_id} (no router; approved)"
        )

        emit_gate_sweep_telemetry(plan, %{action: :reapproved, reason: :tail_reran})
        %{acc | reapproved: acc.reapproved + 1}

      {:ok, :noop, reason} ->
        # Every governance refusal lands here — including the architect-
        # rejected plan. Observed, never acted on.
        emit_gate_sweep_telemetry(plan, %{action: :observed_only, reason: reason})
        %{acc | observed: acc.observed + 1}

      {:error, reason} ->
        Logger.warning(
          "[TaskRouterWatcher] unsettled auto-approval sweep failed plan=#{plan.id} " <>
            "task=#{plan.task_id} reason=#{inspect(reason)}"
        )

        emit_gate_sweep_telemetry(plan, %{action: :observed_only, reason: :retry_failed})
        %{acc | observed: acc.observed + 1}
    end
  end

  defp observe_gate_candidate(%Plan{} = plan, reason, acc) do
    emit_gate_sweep_telemetry(plan, %{action: :observed_only, reason: reason})
    %{acc | observed: acc.observed + 1}
  end

  defp emit_gate_sweep_telemetry(%Plan{id: plan_id, task_id: task_id}, metadata) do
    :telemetry.execute(
      [:platform, :orchestration, :architecture_gate_swept],
      %{count: 1},
      metadata
      |> Map.put(:plan_id, plan_id)
      |> Map.put(:task_id, task_id)
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
      %{expires_at: %DateTime{} = expires_at} = lease ->
        # A `needs_human` hold is present however old its `expires_at` is —
        # that column is informational for such a lease (task 01a0665e
        # stage 2). Checked FIRST: the clock clause below used to win for
        # every lease, so a 13-hour-old hold read as "no lease" and this
        # reconnect re-sent the whole dispatch the executor had refused.
        RuntimeSupervision.needs_human_hold?(lease) or
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
