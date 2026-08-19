defmodule Platform.Orchestration.TaskRouter do
  @moduledoc """
  Per-task orchestration process: event-driven dispatch, ack, and safety-net.

  One `TaskRouter` process runs per active task assignment. It subscribes to
  `tasks:board` PubSub events, dispatches on state transitions (plan approved,
  stage transitioned, plan completed), and arms per-dispatch liveness timers.

  ## Event-driven liveness (ADR 0025 amendment — task 019f640d)

  The historical fixed-cadence heartbeat + escalation ladder is gone. In its
  place:

  1. **Trigger**: `plan_updated approved`, `stage_transitioned running`,
     `plan_updated completed`, or a failed-stage bounce triggers
     `send(self(), :dispatch)`.
  2. **Dispatch**: `do_dispatch/2` composes context + prompt via
     `HeartbeatScheduler.dispatch_prompt/4` + `ContextAssembler.build/2` and
     broadcasts an `attention` event to the assignee runtime.
  3. **Arm timers**: on successful broadcast, the router calls
     `LeaseManager.record_dispatch/4` and arms one `:check_no_ack` timer
     (short — 5 min) and one `:check_safety_net` timer (stage-kind specific)
     via `Process.send_after/3`.
  4. **Ack extends**: an `execution.acked` runtime_event (emitted by the
     `task_ack` MCP tool in stage 5) is consumed by `apply_runtime_event/2`,
     which calls `LeaseManager.record_ack/1` to clear the no-ack countdown
     and extend the safety-net deadline.
  5. **Progress extends**: any `execution.heartbeat` / `execution.progress` /
     validation activity event calls `LeaseManager.record_progress/1`,
     pushing the safety-net deadline forward without touching the no-ack
     idempotency.
  6. **Silent drops**: on `:check_no_ack` firing with no ack, the router
     broadcasts a single `execution.no_ack_timeout` runtime_event, posts an
     `execution.blocked needs_human=true` message to the execution space,
     transitions to `:stalled`, and does NOT re-arm. On `:check_safety_net`
     firing past the safety-net deadline (no progress in the interval), the
     router broadcasts a single `execution.safety_net_fired` runtime_event
     and posts the same `execution.blocked needs_human=true` message. Both
     events are gated by `LeaseManager.mark_*_fired/1` so a spurious re-wake
     never re-fires.

  ## Dispatch coalescing (task 01a00587)

  `:dispatch` is a REQUEST TO RECONCILE, not a command to dispatch. Nine
  in-module senders each observe a genuine state change and each asks for a
  dispatch, so one change fans in as a burst — the 01a00571 trace recorded 12
  duplicate `:dispatch` messages inside 137ms from a single state change, each
  producing a full prompt payload.

  Receiving `:dispatch` therefore only schedules a `:dispatch_now` 50ms out,
  and drops the message if one is already scheduled. The window is chosen to
  absorb a fan-in burst while adding latency far below anything a human or
  agent perceives, and an order of magnitude below the 1s endpoint-not-ready
  retry inside `do_dispatch/2` (which deliberately still sends `:dispatch`, so
  the retry coalesces too).

  `:dispatch_now` carries no payload: it re-reads the task and plan at fire
  time, so the FINAL state wins rather than whichever message happened to
  arrive first.

  ## Assignee resolution (task 019fb977)

  `state.assignee` is a CACHE, refreshed from
  `Platform.Orchestration.PhaseRuntime.resolve/1` on every dispatch — never an
  immutable start argument. The router was previously phase-blind: it froze
  the runtime handed to `start_link/1` and dispatched there for its whole
  life, so a task with `phase_assignees` naming one agent for `planning` and
  another for `execution` sent every post-planning prompt to the planner.

  The router does NOT read `task.assignee_id` to decide where to dispatch.
  That flat pointer is what `TaskRouterWatcher`'s eligibility queries and the
  board read paths use, and it is what `PhaseRuntime` falls back to when a
  task has no entry for its current phase — but keeping it fresh (task
  019f42fd, and this ticket's single-write fold in
  `Tasks.transition_task_status/2`) is NOT what makes dispatch correct. The
  writer fix and the reader fix are independent, and stage 5's mutation
  controls measured the seam: with the reader mutated back to the flat
  pointer and the fold left in place, two of the three dispatch cases go
  green and only the one that forces the pointer stale at READ time still
  fails.

  Two refusals, not one policy: `{:error, :user_assignee}` SUPPRESSES the
  dispatch (a human-owned phase has no runtime, and falling back to the
  previously-held agent is the original bug wearing a different hat); every
  other atom FAILS OPEN to the held assignee. Collapsing the two is a
  measured regression, not a style question — see `refresh_assignee/2`.

  manual_approval stages get NO liveness timers (both `ack_ms` and
  `safety_net_ms` are `nil` in `LeaseManager.stage_kind_timeouts/0`); a daily
  digest surfaces long-pending review requests separately (out of scope for
  this task).

  All decisions remain deterministic — no LLM in the router.
  """

  use GenServer

  require Logger

  # Task 019fe1b7 stage 2 — `@design_step_timeout_ms` and its two accessors
  # USED TO LIVE HERE. Gone, not inlined: the wait they bounded happens inside
  # the lifecycle pipeline now, so `Lifecycle.step_timeout_ms/0` and
  # `edge_budget_ms/0` bound it — same 30 minutes, same
  # attribute-behind-`Application.get_env/3` shape, same absence of a
  # `config/test.exs` override, same `default_*` accessor for a guard to pin.
  # A replaced CONFIG LOOKUP, not a deleted magic number, and strictly wider:
  # one knob became two independent ones.

  alias Platform.Design.PreplanStep
  alias Platform.Execution.CredentialLease
  alias Platform.Federation
  alias Platform.Federation.AttentionDispatch

  alias Platform.Orchestration.{
    ContextAssembler,
    DispatchPhase,
    ExecutionSpace,
    HeartbeatScheduler,
    LeaseManager,
    PhaseRuntime,
    RuntimeSupervision
  }

  alias Platform.Lifecycle
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.Executor
  alias Platform.Tasks
  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.{DeployResolver, Plan, ReviewDisposition, ReviewRequests, Stage}

  # Task 01a00587. Dispatch coalescing window. Behind `Application.get_env/3`
  # so a test can inject a window instead of sleeping on the real one.
  @dispatch_debounce_ms 50

  defp dispatch_debounce_ms do
    Application.get_env(:platform, :task_router_dispatch_debounce_ms, @dispatch_debounce_ms)
  end

  # ── State ──────────────────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            task_id: String.t(),
            assignee: %{type: :federated, id: String.t()},
            execution_space_id: String.t() | nil,
            current_stage_id: String.t() | nil,
            stage_started_at: DateTime.t() | nil,
            last_evidence_at: DateTime.t() | nil,
            last_runtime_event_at: DateTime.t() | nil,
            last_dispatch_at: DateTime.t() | nil,
            dispatch_timer: reference() | nil,
            task_status: String.t() | nil,
            lease_status: String.t() | nil,
            deploy_lease: CredentialLease.t() | nil,
            design_run: {pid(), reference()} | nil,
            design_edge_ran?: boolean(),
            architecture_deadline_ref: reference() | nil,
            status:
              :dispatching | :running | :stalled | :complete | :waiting_human | :waiting_design
          }

    defstruct [
      :task_id,
      :assignee,
      :execution_space_id,
      :current_stage_id,
      :stage_started_at,
      :last_evidence_at,
      :last_runtime_event_at,
      :last_dispatch_at,
      # Task 01a00587. The pending debounce timer ref, or `nil` when no
      # `:dispatch_now` is scheduled. Deliberately NOT surfaced through
      # `current_status/1`: nothing outside the router should key off whether a
      # reconcile happens to be in flight.
      :dispatch_timer,
      :task_status,
      :lease_status,
      :deploy_lease,
      # The in-flight designer pipeline run: `{runner_pid, monitor_ref}`, or
      # `nil`. Task 019fe1b7 stage 2 — this REPLACED `:design_deadline_ref`,
      # and the replacement is the whole shape of the migration. The router
      # no longer owns a deadline for the design step; it owns a MONITOR on
      # the process running the edge, and the deadline belongs to the
      # pipeline's two budgets. Both halves die with this process, so the
      # hold still cannot outlive its holder.
      :design_run,
      # ADR-0046 member 5 stage 5. Held only so a re-arm can cancel the
      # previous one-shot instead of stacking duplicates; the timer is an
      # optimisation, never the correctness guarantee (see
      # `handle_info({:architecture_gate_deadline, _}, _)`).
      :architecture_deadline_ref,
      # Task 01a006e7 stage 2 — the unresolved-stage escalation counter.
      # `nil` when the last dispatch resolved; otherwise
      # `%{key: {task_id, task_status}, count: pos_integer, raised?: boolean}`.
      # See `note_unresolved_suppression/2`.
      :unresolved_suppression,
      status: :dispatching,
      # Task 019fe1b7 stage 2 — see `maybe_run_design_edge/2`. One designer
      # edge run per router process, whatever the run's fate.
      design_edge_ran?: false,
      # Task 019fb977. Provenance of `:assignee` as of the LAST dispatch:
      # `:resolved` means `PhaseRuntime.resolve/1` answered and the field was
      # overwritten with its answer; `:frozen_fallback` means resolution
      # failed and the dispatch went to whatever `start_link/1` was handed.
      # Surfaced through `current_status/1` so an operator can tell "the
      # router agrees with the DB" from "the router is coasting on its start
      # argument" without reading the log.
      assignee_source: :frozen_fallback
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────

  @doc "Start a TaskRouter for the given task assignment."
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    assignee = Keyword.fetch!(opts, :assignee)
    name = via(task_id)
    GenServer.start_link(__MODULE__, %{task_id: task_id, assignee: assignee}, name: name)
  end

  @doc "Stop the router for the given task."
  def stop(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :not_found}
    end
  end

  @doc "Return the current status of the router for the given task."
  def current_status(task_id) do
    GenServer.call(via(task_id), :current_status)
  end

  defp via(task_id) do
    {:via, Registry, {Platform.Orchestration.Registry, task_id}}
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(%{task_id: task_id, assignee: assignee}) do
    # Trap exits so `TaskRouterSupervisor.stop_assignment/1` cannot kill this
    # process mid-query (task 019fa06a).
    #
    # `stop_assignment/1` goes through `DynamicSupervisor.terminate_child/2`,
    # which sends a raw `:shutdown` EXIT signal. Without trapping, that signal
    # kills the router INSTANTLY — wherever it happens to be. Two consequences,
    # one production and one test:
    #
    #   * `terminate/2` never ran on supervisor-driven stops, so
    #     `clear_liveness/1`, `revoke_deploy_lease/1` (`CredentialLease.revoke`)
    #     and `ExecutionSpace.archive/1` were silently skipped on EVERY router
    #     stop. Deploy credential leases outliving their routers is a real
    #     production leak, not a test artifact.
    #
    #   * The router is reliably mid-Ecto-query when the signal lands (`init/1`
    #     schedules `send(self(), :dispatch)` and the dispatch path re-arms via
    #     `Process.send_after(self(), :dispatch, 1_000)`). A DBConnection client
    #     dying while holding a checked-out connection destroys that connection;
    #     under the Ecto sandbox the ownership process dies with it, the repo
    #     reverts from `{:shared, test_pid}` to `:manual`, and the TEST process
    #     raises `DBConnection.OwnershipError` on its very next Repo call.
    #
    # Trapping converts the signal into a mailbox message, so the in-flight
    # query finishes, `:gen_server` handles the parent EXIT, and `terminate/2`
    # runs before the process exits cleanly. The catch-all `handle_info/2`
    # already absorbs any other `{:EXIT, ...}`, and the router links to nothing
    # but its supervisor (`Tasks.subscribe_board/0` and the `:via` Registry
    # registration create no links), so the blast radius is this one flag.
    Process.flag(:trap_exit, true)

    Tasks.subscribe_board()
    ReviewRequests.subscribe_for_task(task_id)

    execution_space_id =
      case ExecutionSpace.find_or_create(task_id) do
        {:ok, space} ->
          space.id

        {:error, reason} ->
          Logger.warning(
            "[TaskRouter] failed to create execution space for #{task_id}: #{inspect(reason)}"
          )

          nil
      end

    # Hydrate task_status from DB so the dispatch path can check the phase
    # without a DB query on every event.
    initial_task_status =
      case Tasks.get_task_detail(task_id) do
        %{status: s} -> s
        _ -> nil
      end

    state =
      %State{
        task_id: task_id,
        assignee: assignee,
        execution_space_id: execution_space_id,
        task_status: initial_task_status
      }
      |> maybe_hydrate_from_lease()
      |> maybe_hydrate_current_stage()

    case state.lease_status do
      "active" ->
        cond do
          plan_awaiting_review?(task_id) ->
            # A plan is sitting with the human; do not re-prompt the agent.
            Logger.info(
              "[TaskRouter] init suppressed dispatch for task=#{task_id}: plan awaiting human review"
            )

            # Narrate the park in the EXECUTION SPACE once, at the start of the
            # suppression episode. The `:dispatch` handler's plan-gate log is
            # edge-triggered on `state.status != :waiting_human`, and every
            # production path into this branch (gateway restart,
            # `TaskRouterWatcher.boot_reconcile/0`, `force_dispatch/1`,
            # `redispatch_for_runtime/1`) parks the router HERE before any
            # dispatch lands — so that edge never occurred and the only trace
            # was the Logger line above, invisible to the human being asked to
            # approve the plan. Mirrors the `waiting_for_human_review?/1`
            # branch below, which already emits before delegating.
            #
            # ADR-0046 member 5 stage 5: WHO holds the slot decides the copy.
            # While the occupant is the ARCHITECT no human action is pending,
            # and the plan-review line sends the reader to a button they
            # should not press yet. Same episode discipline, third string.
            gate = architecture_gate_occupancy(task_id)

            maybe_log_heartbeat_suppressed(
              state,
              find_stage(Tasks.current_plan(task_id), state.current_stage_id),
              plan_gate_log_opts(gate)
            )

            {:ok, arm_architecture_gate_deadline(%{state | status: :waiting_human}, gate)}

          waiting_for_human_review?(state) ->
            # Deliberately NOT guarded on `state.status != :waiting_human`
            # (task 019f9b34): `init/1` IS episode start by definition, so
            # there is no prior episode to suppress against. This mirrors the
            # two plan-gate `init/1` emissions above and below, left unguarded
            # for the same reason.
            #
            # The explicit `:reason` is now load-bearing. This branch emits,
            # parks at `:waiting_human`, then delegates via
            # `send(self(), :dispatch)` (see the comment below). With the
            # stage-level handler now edge-triggered, it will correctly SKIP —
            # making this call the SOLE emitter for a boot-into-parked
            # episode. Without the reason it would fall through to the generic
            # "waiting for manual approval" copy, and boot-time stage-gate
            # episodes would be ungreppable by the stage-gate copy. Passing it
            # keeps exactly one consistent, greppable line per episode. No
            # string constant changes or is added — "awaiting_human_review"
            # already maps to existing copy.
            maybe_log_heartbeat_suppressed(
              state,
              find_stage(Tasks.current_plan(task_id), state.current_stage_id),
              reason: "awaiting_human_review"
            )

            # Deliberate delegation, not a contradiction: this send is
            # guaranteed to land in the `:dispatch` handler's stage-level
            # suppression branch. `waiting_for_human_review?/1` implies
            # `pending_review_request?/1` — both of its disjuncts require a
            # non-empty `ReviewRequests.list_pending_for_task/1`. Routing
            # through the handler keeps `clear_liveness/1`, `task_status`
            # hydration and the suppression log in ONE place instead of
            # duplicating them here. Only safe while the handler retains its
            # `pending_review_request?/1` branch.
            send(self(), :dispatch)
            {:ok, %{state | status: :waiting_human}}

          true ->
            {:ok, %{state | status: :running}}
        end

      "blocked" ->
        {:ok, %{state | status: :waiting_human}}

      _ ->
        if plan_awaiting_review?(task_id) do
          # A plan is sitting with the human; a fresh router (e.g. after a
          # gateway/deploy restart) must not act as an unguarded heartbeat.
          Logger.info(
            "[TaskRouter] init suppressed dispatch for task=#{task_id}: plan awaiting human review"
          )

          # Same episode-start emission as the lease-active branch above; see
          # the comment there for why the handler's edge trigger cannot cover
          # this shape, and for why the architect's occupancy gets its own
          # copy.
          gate = architecture_gate_occupancy(task_id)

          maybe_log_heartbeat_suppressed(
            state,
            find_stage(Tasks.current_plan(task_id), state.current_stage_id),
            plan_gate_log_opts(gate)
          )

          {:ok, arm_architecture_gate_deadline(%{state | status: :waiting_human}, gate)}
        else
          # Schedule initial dispatch on next tick
          send(self(), :dispatch)
          {:ok, state}
        end
    end
  end

  @impl true
  def handle_call(:current_status, _from, state) do
    reply = %{
      task_id: state.task_id,
      assignee: state.assignee,
      execution_space_id: state.execution_space_id,
      status: state.status,
      current_stage_id: state.current_stage_id,
      stage_started_at: state.stage_started_at,
      last_evidence_at: state.last_evidence_at,
      last_runtime_event_at: state.last_runtime_event_at,
      last_dispatch_at: state.last_dispatch_at,
      task_status: state.task_status,
      lease_status: state.lease_status,
      # Task 019fb977. `:assignee` alone cannot be audited — a runtime id is
      # only correct RELATIVE to the phase it was resolved for, and a caller
      # comparing it against the DB needs to know whether the router resolved
      # it or fell back. `nil` phase means the router has not observed a task
      # status yet (no dispatch since boot).
      phase: state.task_status && Tasks.current_phase(state.task_status),
      assignee_source: state.assignee_source
    }

    {:reply, reply, state}
  end

  # Task 01a00587. `:dispatch` is a REQUEST TO RECONCILE, not a command to
  # dispatch. Nine in-module senders each observe a real state change and each
  # correctly asks for a dispatch; a single change fans in as a burst. This
  # clause does no work beyond scheduling one `:dispatch_now`.
  #
  # If a timer is already armed the message is DROPPED — not cancelled, not
  # restarted, not extended. A restart-on-every-message debounce can be starved
  # indefinitely by a steady arrival stream; drop-if-scheduled bounds the delay
  # at one window.
  @impl true
  def handle_info(:dispatch, state) do
    if state.dispatch_timer do
      {:noreply, state}
    else
      ref = Process.send_after(self(), :dispatch_now, dispatch_debounce_ms())
      {:noreply, %{state | dispatch_timer: ref}}
    end
  end

  # The real dispatch decision. Carries NO payload: it re-reads
  # `Tasks.get_task_detail/1` (and `Tasks.current_plan/1` inside
  # `do_dispatch/2`) at FIRE time, so the dispatch reflects state as of the
  # moment it fires rather than the moment any one scheduling message arrived.
  def handle_info(:dispatch_now, state) do
    state = %{state | dispatch_timer: nil}

    # FIRE SITE for the designer lifecycle edge (ADR-0046 member 7 stage 5;
    # moved onto the pipeline frame by task 019fe1b7 stage 2).
    # Deliberately here and not on the `backlog -> planning` transition: that
    # transition has FOUR writers with four different gate sets
    # (`Tasks.transition_task/3`, `transition_task_status/2`,
    # `drop_task_to_column/3`, and the unguarded `update_task/3` that
    # `Stacks.promote/1` uses), and a fifth the day someone adds one. All five
    # funnel into a router, because `TaskRouterWatcher.should_run?/1` spawns one
    # for any task in `planning`. One chokepoint instead of five.
    task = Tasks.get_task_detail(state.task_id)
    state = maybe_run_design_edge(state, task)

    cond do
      task == nil ->
        Logger.warning("[TaskRouter] task #{state.task_id} not found, stopping")
        {:stop, :normal, state}

      plan_awaiting_review?(state.task_id) ->
        # Pre-dispatch guard, PLAN level (task 019f9ae5). `init/1` already
        # refuses to schedule a dispatch while the latest plan is
        # `pending_review`, but every OTHER `:dispatch` injector bypasses
        # `init/1` entirely and landed straight in `do_dispatch/2`:
        #
        #   * `TaskRouterWatcher.redispatch_for_runtime/1` — a raw
        #     `send(pid, :dispatch)` for every should-run task on each
        #     `{:runtime_reconnected, runtime_id}`. A `planning` task with no
        #     active lease is not filtered by `active_lease_present?/2`, so
        #     every runtime reconnect re-prompted the agent. This is the
        #     confirmed source of the 10-day re-dispatch loop on task 019f6779.
        #   * `TaskRouterWatcher.force_dispatch/1`.
        #   * The ~10 in-module `send(self(), :dispatch)` sites plus the
        #     `Process.send_after(self(), :dispatch, 1_000)` retry.
        #
        # One guard in the handler covers all of them; guarding per-caller
        # would not.
        #
        # This branch is deliberately ordered AHEAD of the stage-level
        # `pending_review_request?/1` clause below: the plan gate is the
        # coarser, earlier-in-lifecycle gate. While the latest plan is
        # `pending_review` the whole plan — and therefore any stage-level
        # review request hanging off it — is provisional, and the human's
        # actionable next step is to approve/reject the PLAN, not to
        # disposition a validation. When the plan is `approved`,
        # `plan_awaiting_review?/1` is false and control falls through to the
        # stage-level clause unchanged.
        #
        # Accepted semantics: `plan_awaiting_review?/1` keys off
        # `Tasks.latest_plan/1` (highest version regardless of status), so
        # submitting a v2 while v1 is approved and executing also suppresses
        # dispatch. That matches `init/1`'s existing behavior and is desired —
        # a plan sitting with the human outranks in-flight agent work.
        #
        # Logging is edge-triggered on the `:waiting_human` transition.
        # `maybe_log_heartbeat_suppressed/3` only elides its log when every
        # pending validation is a manual_approval linked to an OPEN review
        # request; in the plan-pending case there are no review requests, so
        # an unconditional call would post on every injected dispatch — the
        # exact execution-space pile-up task 019e00cb fixed.
        gate = architecture_gate_occupancy(state.task_id)

        if state.status != :waiting_human do
          maybe_log_heartbeat_suppressed(
            state,
            find_stage(Tasks.current_plan(state.task_id), state.current_stage_id),
            plan_gate_log_opts(gate)
          )
        end

        # Armed OUTSIDE the edge guard, deliberately. The edge guard exists to
        # keep NARRATION to one line per episode; the timer is not narration.
        # A router already parked at `:waiting_human` by a stage-level gate
        # when the architecture gate opens would otherwise never arm one, and
        # re-arming is free — `arm_architecture_gate_deadline/2` cancels the
        # previous ref and recomputes the delay from the PERSISTED deadline,
        # so an extra arm can only ever shorten it.
        state =
          state
          |> Map.put(:task_status, task.status)
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
          |> arm_architecture_gate_deadline(gate)

        {:noreply, state}

      pending_review_request?(state.task_id) ->
        # Pre-dispatch guard, STAGE level: a manual_approval review is open
        # against this task; suppress the dispatch entirely until a human
        # dispositions it.
        #
        # Invariant: `e2e_behavior` validations DO NOT suppress dispatch.
        # They are agent-driven (the review agent runs the script and
        # dispositions via validation_evaluate), not human-gated. Review
        # requests are reserved for `manual_approval` validations only — see
        # `pending_review_request?/1` and `ReviewRequests.list_pending_for_task/1`.
        plan = Tasks.current_plan(state.task_id)

        # Edge-triggered on the `:waiting_human` transition (task 019f9b34),
        # mirroring the plan-gate guard above. The 019e00cb predicate gate
        # inside `maybe_log_heartbeat_suppressed/3` cannot cover this on its
        # own: `HeartbeatScheduler.heartbeat_suppressible?/2` returns false
        # unless EVERY pending validation is a `manual_approval` linked to an
        # open review request, so a single co-pending `test_pass` on the same
        # stage makes the predicate false forever and the elision never
        # engages — the line then re-posted on every injected dispatch
        # (measured 1 -> 2 -> 3 -> 4 over three ticks). The predicate stays as
        # an independent second elision layer; this is an edge layer in front
        # of it, NOT a replacement.
        #
        # Accepted semantics: a genuinely NEW second review request opened
        # while the router is already parked will not emit a second line. The
        # episode is still ongoing and the review_request row is itself the
        # visible signal — same reasoning as the plan-gate precedent. The edge
        # re-arms on disposition, where `{:review_request_resolved, ...}` sets
        # `status: :running`.
        if state.status != :waiting_human do
          maybe_log_heartbeat_suppressed(
            state,
            find_stage(plan, state.current_stage_id),
            reason: "awaiting_human_review"
          )
        end

        state =
          state
          |> Map.put(:task_status, task.status)
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)

        {:noreply, state}

      design_hold?(state, task) ->
        # Pre-dispatch guard, DESIGN level (ADR-0046 member 7 stage 5).
        # "Design runs BEFORE planning" is only true if the planner actually
        # waits. Ordered AFTER `pending_review_request?/1` on purpose: a human
        # gate outranks a machine one.
        #
        # Ordered AHEAD of `completed_plan_no_work?/1` (below) at the ADR-0046
        # merge. The two are disjoint in practice — the design step fires
        # BEFORE a plan exists, so a task with an open design step cannot also
        # carry a `completed` plan — but if they ever did overlap, parking at
        # `:waiting_design` is the reading that keeps the design contract:
        # suppression would drop the hold on the floor.
        hold_for_design(state, task)

      completed_plan_no_work?(state.task_id) ->
        # Re-dispatch storm guard (task 019fa2fc stage 4). Production on
        # 2026-07-27 logged four `dispatched task_assigned` lines for the same
        # two tasks inside a 100 ms window at 09:47:12 — each a full prompt
        # payload to a runtime that correctly found nothing to do, and it only
        # stopped when the tasks were marked done by hand. Stages 1-3 removed
        # the cause (the task now advances synchronously off the plan-completion
        # path). This clause is the backstop: if that path ever regresses, the
        # task degrades into a STUCK task — visible on the board, and visible on
        # the `dispatch_suppressed` telemetry — instead of a token-burning loop.
        #
        # Ordered ahead of `settled_stack_member_no_work?/2` because it is the
        # stronger condition: a `completed` plan is terminal for every task,
        # stack member or not, so there is no reason to fall through to the
        # narrower stack-only clause first.
        #
        # WHY THE PREDICATE STAYS NARROW — this is the part that matters. The
        # `completed` PLAN STATUS is what makes suppression safe, because a
        # `completed` plan cannot have work left in it by construction (the
        # engine only writes that status once every stage is settled). Drop it
        # and lean on the shape `settled_stack_member_no_work?/2` uses — "no
        # running stage AND no open validation" — and this clause would also
        # match a task whose next stage is `pending` with zero validations. That
        # is an agent that has never been prompted and is the only thing that
        # can start the stage: suppressing it parks the task forever with no
        # log the operator would think to look for. The failure mode of a
        # dispatch guard is silent strangulation, so the guard is deliberately
        # the smallest one that covers the incident.
        Logger.info(
          "[TaskRouter] suppressed stale dispatch for task=#{state.task_id}: " <>
            "current plan is completed with no running stage"
        )

        emit_dispatch_suppressed_telemetry(state.task_id, :completed_plan_no_work)

        state =
          state
          |> Map.put(:task_status, task.status)
          |> clear_liveness()

        {:noreply, state}

      settled_stack_member_no_work?(task, state.task_id) ->
        # TAIL-stall fix (2026-07-22), direction (3): suppress dispatch for a
        # SETTLED stack member — one whose current plan has NO pending/running
        # validation AND NO running stage (a pending review request is already
        # handled by the clause above). There is nothing an executor could ack
        # or act on, so a prompt here is exactly the stale re-dispatch the
        # incident logged: a `manual_approval` review with every approval
        # already passed, and a `no_op_wait_for_rollup` deploy — both of which
        # return "no running stage" on `task_ack` and spin. Once stages 1-3
        # walk the member to `done` it leaves the active set and the router
        # stops on its own; this guard closes the residual race where the
        # member briefly settles before the tail transition fires. Non-stack
        # tasks are never suppressed. Observe-only telemetry keeps the
        # condition visible on dashboards without changing behavior for any
        # task with genuinely pending work.
        Logger.info(
          "[TaskRouter] suppressed stale dispatch for settled stack member " <>
            "task=#{state.task_id} (no pending validation, no running stage)"
        )

        emit_dispatch_suppressed_telemetry(state.task_id, :settled_stack_member)

        state =
          state
          |> Map.put(:task_status, task.status)
          |> clear_liveness()

        {:noreply, state}

      true ->
        do_dispatch(state, task)
    end
  end

  # New event-driven liveness handlers (task 019f640d stage 3).
  #
  # `:check_no_ack` — armed on each successful dispatch. If the executor / reviewer
  # never called `task_ack`, LeaseManager.get returns a lease with `ack_at: nil`;
  # we fire one loud `execution.no_ack_timeout` runtime_event + post
  # `execution.blocked needs_human=true` and transition to `:stalled`. No re-arm.
  # The idempotency guard `mark_no_ack_fired/1` prevents a spurious re-wake
  # (e.g. a stale timer sneaking through) from double-firing.
  #
  # Receiving this message means "a timer woke us", NOT "the deadline passed"
  # (task 019fa469 stage 6). `arm_liveness_timers/3` arms a `Process.send_after`
  # per dispatch and never cancels the previous one, so an orphan timer from an
  # earlier dispatch — or an earlier STAGE — lands mid-window against whatever
  # lease is current. Every fire path therefore goes through
  # `fire_or_reschedule_no_ack/3`, which re-checks `lease.no_ack_at` exactly as
  # `:check_safety_net` re-checks `safety_net_at`.
  def handle_info(:check_no_ack, %State{task_id: task_id} = state) do
    case LeaseManager.get(task_id) do
      nil ->
        # Lease was cleared (stage transition, human gate, termination) —
        # nothing to alert on.
        {:noreply, state}

      %{ack_at: %DateTime{}} ->
        # Ack landed before the check fired — silent.
        {:noreply, state}

      %{no_ack_fired?: true} ->
        # Already fired for this dispatch — idempotent noop. Note: silence
        # set AFTER the alarm already fired does NOT un-fire it; this clause
        # must remain ahead of the silence clause below so a late silence
        # doesn't accidentally re-arm.
        {:noreply, state}

      %{silenced_until: %DateTime{} = until} = lease ->
        # Operator silence installed via the `alarm_silence` MCP tool
        # (task 019f6791-c01b stage 3). While the silence is in effect we
        # reschedule `:check_no_ack` for `until + 1s` — the alarm re-arms
        # exactly when the silence lapses without firing, transitioning
        # to `:stalled`, or posting a blocker. If silence has already
        # lapsed by the time this check runs, fall through to the normal
        # fire path via `maybe_fire_no_ack/3`.
        now = DateTime.utc_now()

        cond do
          DateTime.compare(now, until) == :lt ->
            remaining_ms = DateTime.diff(until, now, :millisecond) + 1_000
            Process.send_after(self(), :check_no_ack, remaining_ms)

            Logger.info(
              "[TaskRouter] task #{state.task_id} no-ack alarm silenced until #{DateTime.to_iso8601(until)} — rescheduling check"
            )

            {:noreply, state}

          true ->
            fire_or_reschedule_no_ack(state, task_id, lease)
        end

      lease ->
        fire_or_reschedule_no_ack(state, task_id, lease)
    end
  end

  # The designer edge finished (task 019fe1b7 stage 2). This is the ONLY
  # release path for a design hold, and it fires for EVERY edge outcome —
  # `complete`, `not_applicable`, `failed`, `diverted`, `suppressed`. Design
  # fails open in every direction, so there is deliberately no branch here
  # that keeps holding.
  #
  # Matched on the RUNNER PID, so a message from a runner this router has
  # already given up on (a monitor that fired first, a runner belonging to a
  # previous hold) cannot release a later one.
  def handle_info({:design_edge_settled, pid, outcome}, %State{design_run: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    Logger.info(
      "[TaskRouter] designer edge settled for task=#{state.task_id} " <>
        "outcome=#{outcome} planning_step_outcome=#{Edges.run_outcome(outcome)} — " <>
        "releasing the planner"
    )

    send(self(), :dispatch)
    {:noreply, %{state | design_run: nil, status: :dispatching}}
  end

  def handle_info({:design_edge_settled, _pid, _outcome}, %State{} = state) do
    {:noreply, state}
  end

  # The runner died without reporting — killed, a raise outside the executor's
  # rescue, a node under memory pressure. FAIL OPEN: release the planner. A
  # crashed runner holding the planner forever is the one outcome the design
  # step is not allowed to have, and it is why the runner is monitored rather
  # than linked (a link would take this router down with it, stranding every
  # other thing this process dispatches).
  #
  # `maybe_run_design_edge/2` will not re-fire this router — `design_edge_ran?`
  # is already set, and it is set precisely because a crashed runner leaves no
  # persisted run row for the re-entry bound to count.
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{design_run: {pid, ref}} = state) do
    if reason != :normal do
      Logger.warning(
        "[TaskRouter] designer edge runner for task=#{state.task_id} went down " <>
          "(#{inspect(reason)}) — releasing the planner"
      )

      # The runner may have opened the cursor and died before it could close
      # it. Closing it here is the same fail-open write `run_design_edge/2`
      # makes on the normal path; without it the restart half of
      # `design_hold?/2` would hold every future router on this task.
      close_open_step(state.task_id)
    end

    send(self(), :dispatch)
    {:noreply, %{state | design_run: nil, status: :dispatching}}
  end

  # `:check_safety_net` — armed on each successful dispatch at the stage-kind's
  # safety-net interval. If progress extended the deadline (`record_progress/1`
  # or `record_ack/1` moved `safety_net_at` past `now`), reschedule to the new
  # deadline. Otherwise fire one loud `execution.safety_net_fired` runtime_event
  # + post `execution.blocked needs_human=true`. Also idempotency-gated.
  def handle_info(:check_safety_net, %State{task_id: task_id} = state) do
    case LeaseManager.get(task_id) do
      nil ->
        {:noreply, state}

      %{safety_net_fired?: true} ->
        {:noreply, state}

      %{safety_net_at: nil} ->
        # manual_approval (or otherwise disabled) — never fire.
        {:noreply, state}

      %{safety_net_at: %DateTime{} = deadline} = lease ->
        remaining_ms = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)

        if remaining_ms > 0 do
          # Progress or ack pushed the deadline out; reschedule to the new one.
          Process.send_after(self(), :check_safety_net, remaining_ms)
          {:noreply, state}
        else
          case LeaseManager.mark_safety_net_fired(task_id) do
            {:ok, :fired} ->
              # Task 019fbe9e stage 4. The safety net measures elapsed time
              # against a lease armed at dispatch; it does not re-read whether
              # there is still anything to be slow ABOUT. A plan that settled
              # after the lease was armed — no running stage, no
              # pending/running validation — has no work an executor could be
              # stuck on, so the alert can only be a false blocker asking a
              # human to investigate a finished task.
              #
              # `mark_safety_net_fired/1` above has ALREADY run, deliberately:
              # suppression must consume the one-shot, or the timer would find
              # the lease unfired and re-evaluate on every subsequent check.
              if plan_settled_no_open_work?(task_id) do
                Logger.info(
                  "[TaskRouter] task #{task_id} stage #{lease.stage_id} — safety-net window " <>
                    "elapsed but the current plan has no running stage and no open validation; " <>
                    "suppressing execution.safety_net_fired"
                )
              else
                # Task 01a01a4a stage 2. Second suppression, deliberately in
                # the SAME position and the SAME order as the one above: the
                # one-shot is already consumed, so a suppressed check cannot
                # be re-evaluated on the next timer wake.
                #
                # The plan here is NOT settled — there IS an open validation.
                # It is simply one no agent is allowed to pass: a `pr_merged`
                # on a `pr_merge` strategy with `auto_merge: false` waits on a
                # person clicking merge. "Check whether the agent is stuck" is
                # a false accusation, so this path emits a DISTINCT event and
                # leaves the task in `deploying`.
                case awaiting_human_gate(task_id) do
                  {:ok, pending_kinds} ->
                    note_awaiting_human_action(state, lease, pending_kinds)

                  nil ->
                    fire_safety_net_alert(state, lease)
                end
              end

              {:noreply, state}

            _ ->
              {:noreply, state}
          end
        end
    end
  end

  # Board PubSub: task updated for our task
  def handle_info({:task_updated, %{id: task_id} = task}, %State{task_id: task_id} = state) do
    task_status = Map.get(task, :status) || Map.get(task, "status")
    # Captured BEFORE the overwrite below — the stage-opening guard further
    # down needs the status the router last observed, not the incoming one.
    previous_task_status = state.task_status

    state =
      state
      |> Map.put(:last_evidence_at, DateTime.utc_now())
      |> then(fn s -> if task_status, do: Map.put(s, :task_status, task_status), else: s end)

    state =
      if waiting_for_human_review?(state) do
        # Another silent park site (task 019f9b34): `{:task_updated}` fires
        # from many places in `tasks.ex`, so this must stay edge-triggered or
        # it becomes the pile-up it is meant to prevent. Narrating here covers
        # the shape where the task transition — not a dispatch — is what first
        # observes the open review request.
        if state.status != :waiting_human do
          maybe_log_heartbeat_suppressed(
            state,
            find_stage(Tasks.current_plan(state.task_id), state.current_stage_id),
            reason: "awaiting_human_review"
          )
        end

        state |> clear_liveness() |> Map.put(:status, :waiting_human)
      else
        state
      end

    # LATE-PRECONDITION STAGE OPEN (task 019fbe9e stage 3). Until this call,
    # `ensure_execution_stage_started/2` was wired to exactly ONE edge — the
    # `{:plan_updated, "approved"}` branch — and it early-returns unless the
    # task is ALREADY `in_progress`. A stack member whose plan is approved
    # while it sits at `stack_pending` therefore crosses that edge in the one
    # state where the function declines to act, and when it is promoted to
    # `in_progress` later NOTHING re-evaluates the precondition: every stage
    # stays `pending` and the executor is prompted into a dead end where
    # `stage_complete` refuses the work with "Stage must be running".
    #
    # LEVEL, not edge: this reads the task status off the broadcast and
    # re-derives everything else from the DB, so it fires on whichever
    # `{:task_updated}` happens to carry `in_progress` — promotion, bounce, or
    # an unrelated write. Idempotency is `ensure_execution_stage_started/2`'s
    # own cond: the `current_running_stage(plan)` clause is tried first and
    # only re-dispatches, so repeat calls against a task with a running stage
    # start nothing. Deliberately NOT a second stage-start path.
    #
    # NARROWED to the case where a stage would actually be OPENED, and the
    # narrowing is load-bearing rather than tidiness. `{:task_updated}` fires
    # from many writers, and `ensure_execution_stage_started/2`'s first two
    # clauses each `send(self(), :dispatch)`. Calling it unconditionally on
    # every `in_progress` broadcast therefore amplifies dispatches:
    # `task_router_phase_assignee_test.exs:165` observed 3 attention
    # broadcasts where it asserts exactly 1, because plan approval already
    # walks the same path from the `{:plan_updated, "approved"}` branch. The
    # guard below fires only when there is NO running stage and a pending one
    # exists — precisely the state the defect strands — so it can never add a
    # dispatch to a task that already had a stage to be dispatched about.
    #
    # And EXCLUDED for `planning -> in_progress`, which is the one promotion
    # the approval edge already owns: `approve_plan/3` transitions the task
    # and broadcasts BOTH messages into this mailbox, `{:task_updated}` first.
    # Opening the stage here would leave `{:plan_updated, "approved"}` to land
    # on the now-running stage and emit a second, redundant prompt — measured
    # as 2 attention broadcasts where that test pins exactly 1. Every OTHER
    # entry into `in_progress` (`stack_pending`, `blocked`, `backlog`, or a
    # router that booted after the fact and has observed no prior status) is
    # exactly the set the approval edge cannot reach.
    state =
      if task_status == "in_progress" and previous_task_status != "planning" and
           stage_needs_opening?(task_id) do
        ensure_execution_stage_started(state, task_id)
      else
        state
      end

    # THE DESIGN WAKE-UP USED TO LIVE HERE (ADR-0046 member 7 stage 5): a
    # `release_design_hold_if_closed/1` call that re-read the row on every
    # `{:task_updated, _}` and re-dispatched if the cursor had closed.
    #
    # It is gone because the signal MOVED rather than disappeared.
    # `Platform.Design.PreplanLifecycleStep`'s watcher subscribes to this same
    # board topic and level-checks the same cursor, so a close is still seen at
    # broadcast latency; the release now arrives as `{:design_edge_settled, _,
    # _}`. Exactly one dispatch per hold still holds, for a stronger reason
    # than before: the RUN, not a router status flag, is the de-duplication
    # token.
    {:noreply, state}
  end

  def handle_info({:runtime_event, event}, %State{task_id: task_id} = state)
      when event.task_id == task_id do
    {:noreply, apply_runtime_event(state, event)}
  end

  # Board PubSub: stage transitioned
  def handle_info({:stage_transitioned, stage}, %State{} = state) do
    # Only react if this stage belongs to our task's current plan
    plan = Tasks.current_plan(state.task_id)

    if plan && stage.plan_id == plan.id do
      # Revoke deploy lease when a deploy stage completes (passed or failed)
      state =
        if stage.status in ["passed", "failed"] do
          revoke_deploy_lease(state)
        else
          state
        end

      # On a `passed` transition the broadcast payload is the just-completed
      # stage — its status is already `passed` and `find_stage(plan, id)` will
      # still resolve it, so keying `current_stage_id` off `stage.id` here
      # pins the router to a finished stage. `do_dispatch/2` then filters
      # that stage's validations to `["pending", "running"]` (empty) and
      # echoes "No validations are pending…" until the next broadcast lands.
      # Instead, resolve to the currently-running stage from the freshly
      # reloaded plan; fall back to `nil` when no stage is running yet (next
      # dispatch/hydrate will fill it in). Other statuses (`running`,
      # `failed`) still key off the transitioned stage as before — the
      # failure-bounce branch below expects `stage` to be the failing one,
      # and a `running` broadcast is exactly the stage we should track.
      # Capture the previous stage BEFORE the state overwrite so we know
      # which stage's leases to drop on the boundary crossing.
      previous_stage_id = state.current_stage_id

      next_stage_id =
        case stage.status do
          "passed" ->
            case current_running_stage(plan) do
              %Stage{id: id} -> id
              nil -> nil
            end

          _ ->
            stage.id
        end

      # A stage-boundary crossing invalidates the prior stage's liveness
      # bookkeeping — the next dispatch will call `record_dispatch/4` with a
      # fresh row. Clear here so a lingering `:check_no_ack` / `:check_safety_net`
      # doesn't fire against stale state before the new dispatch arrives.
      if next_stage_id != previous_stage_id do
        LeaseManager.clear(state.task_id)

        # Task 019f6791: unconditionally clean-slate the outgoing stage's
        # RuntimeSupervision leases too. Leftover `blocked` rows from the
        # prior stage were the direct source of the leak on task 019f6380
        # (router rehydrated into `:waiting_human` on any subsequent boot).
        if previous_stage_id do
          RuntimeSupervision.drop_leases_for_stage(state.task_id, previous_stage_id)
        end
      end

      # Rehydrate `lease_status` from the incoming stage's own lease row
      # (nil when the fresh stage has no lease yet — the intended state
      # before the next dispatch arms one). Never carry the prior stage's
      # `blocked` status forward into diagnostics / state-machine checks.
      rehydrated_lease_status =
        case next_stage_id do
          nil ->
            nil

          stage_id ->
            case RuntimeSupervision.current_lease_for_stage(state.task_id, stage_id) do
              %{status: status} -> status
              _ -> nil
            end
        end

      state =
        state
        |> Map.put(:current_stage_id, next_stage_id)
        |> Map.put(:stage_started_at, DateTime.utc_now())
        |> Map.put(:last_evidence_at, DateTime.utc_now())
        |> then(fn s ->
          # A stage boundary crossing invalidates the prior stage's
          # activity timestamp — the old blocker's runtime-event `at`
          # was masking `no_ack` alarms for the new stage.
          if next_stage_id != previous_stage_id do
            Map.put(s, :last_runtime_event_at, nil)
          else
            s
          end
        end)
        |> Map.put(:lease_status, rehydrated_lease_status)
        |> maybe_reset_stalled()
        |> maybe_reset_stale_waiting_human(next_stage_id, previous_stage_id)

      # If a review or deploy stage fails, bounce the task back to in_progress
      # (regression-critical — preserved byte-for-byte from the pre-redesign
      # state machine per task 019f640d stage 3 spec).
      state =
        if stage.status == "failed" do
          task = Tasks.get_task_detail(state.task_id)

          failure_outcome =
            cond do
              # Deploy stage failed — bounce deploying → in_progress
              task && task.status == "deploying" ->
                handle_deploy_stage_failure(state, task, stage)
                :bounced

              # Review stage failed — bounce in_review → in_progress, unless
              # this was the round that exhausts the bound (task 019ff788
              # stage 3), in which case the task goes back to PLANNING.
              task && task.status == "in_review" ->
                handle_review_stage_failure(state, task, stage)

              true ->
                :bounced
            end

          # Re-dispatch so the agent picks up the in_progress prompt. The
          # subsequent `do_dispatch/2` call will `record_dispatch/4` +
          # re-arm liveness timers automatically.
          if state.execution_space_id do
            log_line =
              case failure_outcome do
                :replanned ->
                  "Stage failure exhausted the review-round bound — task returned to planning | "

                _ ->
                  "Stage failure bounced task back to in_progress | "
              end

            ExecutionSpace.post_log(
              state.execution_space_id,
              log_line <> diagnostic_snapshot(state, task, stage_override: stage)
            )
          end

          # Same defect as the promotion path (task 019fbe9e stage 3). The
          # bounce puts the task back at `in_progress`, but the stage it
          # bounced off is `failed` and every execution stage is already
          # `passed` — so `send(self(), :dispatch)` alone prompts an agent at
          # a task with no stage it can complete. Re-open one here, AFTER the
          # transition (so the `!= "in_progress"` early return does not
          # swallow it) and BEFORE the dispatch. When no pending stage exists
          # this is a no-op and the withhold clause in `handle_info(:dispatch,
          # _)` catches the resulting dead end.
          #
          # A re-planned task is the one case that must NOT re-open an
          # execution stage: its plan has just been superseded and the next
          # dispatch is a PLANNING dispatch, so opening a stage on a dead
          # plan would hand the planner an executable stage it never wrote.
          state =
            if failure_outcome != :replanned and stage_needs_opening?(state.task_id) do
              ensure_execution_stage_started(state, state.task_id)
            else
              state
            end

          send(self(), :dispatch)
          %{state | status: :running}
        else
          # ADR 0029: the task must HOLD `in_review` while the review gate runs.
          # Ordering is load-bearing — `HeartbeatScheduler.dispatch_prompt/4`
          # selects its template off the task's status, so a write that lands
          # after `send(self(), :dispatch)` changes nothing observable and the
          # gate keeps rendering the implementation prompt.
          if stage.status == "running" do
            maybe_enter_in_review(state.task_id, stage)
          end

          if waiting_for_human_review?(state) do
            if stage.status == "running" do
              send(self(), :dispatch)
            end

            # Edge-triggered (task 019f9b34): stage broadcasts repeat for the
            # same running stage, and this call passes no `:reason` so it
            # emits the generic "waiting for manual approval" copy. Same bug
            # class as the `:dispatch` and `:review_request_pending` sites —
            # the 019e00cb predicate cannot elide it on a mixed-validation
            # stage, because `heartbeat_suppressible?/2` needs EVERY pending
            # validation to be a `manual_approval` with an open review request.
            if state.status != :waiting_human do
              maybe_log_heartbeat_suppressed(state, stage)
            end

            state |> clear_liveness() |> Map.put(:status, :waiting_human)
          else
            # When a new stage becomes running, re-dispatch so the agent gets
            # an updated prompt that describes the current stage. Timers arm
            # via `do_dispatch/2`.
            if stage.status == "running" do
              send(self(), :dispatch)
            end

            state
          end
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Board PubSub: plan completed for our task. LIVENESS ONLY — this clause
  # performs no task-status transition.
  #
  # The phase advance is owned by `Platform.Tasks.PlanCompletion`, called from
  # `PlanEngine.complete_plan/2` on the synchronous plan-completion path (task
  # 019fa2fc). That path runs in the same process and the same
  # `Repo.transaction/1` as the plan write, so it cannot be dropped the way a
  # broadcast to a router that is not alive can be — which is exactly how
  # tasks 019fa06a / 019fa209 / 019fa298 sat in `deploying` forever.
  #
  # The status-mapping arm that used to live here is deliberately NOT kept as
  # a redundant second path. It re-derived its target from the task's CURRENT
  # status, so once the advance is synchronous it reads post-advance state and
  # maps it forward again one broadcast later — a second state machine, not a
  # retry of the same decision. Concretely it re-advanced tasks that
  # `PlanCompletion` had deliberately declined to move (`:awaiting_rollup`,
  # `:stack_member`), undoing that protection, and it duplicated the 019f9b34
  # unsettled-deploy warning. Both are covered by
  # `task_router_plan_completed_test.exs`.
  def handle_info(
        {:plan_updated, %{task_id: task_id, status: "completed"}},
        %State{task_id: task_id} = state
      ) do
    # Phase boundary — clear the prior stage's liveness. Next dispatch will
    # arm fresh timers keyed off the new phase's first stage. Stays here (and
    # not on the plan-completion path) because the lease guards
    # `Process.send_after/3` timers living in THIS process: when no router is
    # alive there are no timers to invalidate, and when one is alive it is the
    # only process that can meaningfully cancel them.
    LeaseManager.clear(task_id)

    # Re-dispatch so the agent picks up the updated status prompt
    send(self(), :dispatch)
    {:noreply, state}
  end

  # Board PubSub: plan updated for our task
  def handle_info({:plan_updated, %{task_id: task_id} = plan}, %State{task_id: task_id} = state) do
    state =
      case plan.status do
        "pending_review" ->
          # A router that was `:running` when the plan got submitted parks
          # here, never reaching the `:dispatch` handler's edge-triggered
          # plan-gate log — so narrate the park at episode start, exactly as
          # `init/1` does for a router that boots into the same condition.
          # Guarded on the same edge the handler uses: if we are ALREADY
          # `:waiting_human` the episode has been narrated (or a stage-level
          # gate is already parked here), so stay silent rather than
          # double-posting on a re-broadcast.
          gate = architecture_gate_occupancy(task_id)

          if state.status != :waiting_human do
            maybe_log_heartbeat_suppressed(
              state,
              find_stage(Tasks.current_plan(task_id), state.current_stage_id),
              plan_gate_log_opts(gate)
            )
          end

          # Arm outside the edge guard — see the `:dispatch` handler's plan
          # branch for why.
          state
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
          |> arm_architecture_gate_deadline(gate)

        "approved" ->
          state
          |> Map.put(:status, :running)
          |> ensure_execution_stage_started(task_id)

        "rejected" ->
          state |> clear_liveness() |> Map.put(:status, :waiting_human)

        _other ->
          state
      end

    {:noreply, state}
  end

  # ── ADR-0046 member 5 stage 5: the architecture gate's deadline ────────
  #
  # THE EDGE, NOT THE GUARANTEE. `Tasks.architecture_gate/1` already reports a
  # past-deadline `pending` gate as `{:resolved, %{"state" => "expired"}}`
  # WITHOUT writing, so `approve_plan/3` stops blocking whether or not this
  # message is ever delivered. That level check is the correctness guarantee;
  # this timer is only the eager path, which additionally persists the verdict
  # and runs the deferred `settle_plan_submission/1` tail.
  #
  # Losing this message degrades to "resolved late", never to "stuck", and it
  # is genuinely lossy: `TaskRouterWatcher.should_run?/1` requires
  # `assignee_type == "agent"`, so a task assigned to a USER for planning has
  # NO router and never arms one, and a router that dies between the gate
  # opening and the deadline takes its timer with it. Two independent
  # fallbacks catch that, and they are not the same mechanism:
  #
  #   * NOTHING BLOCKS — `architecture_gate/1`'s projection reports the overdue
  #     gate as expired without writing, so `approve_plan/3` admits a human
  #     immediately, router or no router. This is the correctness guarantee.
  #   * IT STILL SETTLES — `architecture_gate_occupancy/1`'s `:overdue` answer
  #     re-fires this message at 0 ms the next time any router observes the
  #     task, so the verdict gets written and the deferred tail runs. Where no
  #     router will ever exist, that fallback does NOT apply and the plan waits
  #     for the human the projection has already unblocked. Saying which
  #     fallback covers which case matters: only the first one is universal.
  #
  # Built this way round on purpose. The 2026-07-26 journal records a live
  # incident where `deploying -> done` lived solely in an edge-triggered PubSub
  # handler with no level re-check, and a container restart between the
  # broadcast and the handler stranded a completed task at `deploying`
  # indefinitely while re-dispatching every ~90 minutes.
  #
  # Safe to fire late, twice, or against an already-resolved gate:
  # `record_architecture_verdict/3` arbitrates on the PERSISTED row inside a
  # guarded `UPDATE ... WHERE ->>'state' = 'pending'`, so a duplicate is
  # `{:error, :gate_already_resolved}` and an architect verdict that beat the
  # timer to the write genuinely wins.
  def handle_info({:architecture_gate_deadline, plan_id}, %State{} = state) do
    state = %{state | architecture_deadline_ref: nil}

    case Tasks.resolve_architecture_gate(plan_id, :expired) do
      {:ok, _resolved} ->
        Logger.info(
          "[TaskRouter] architecture gate expired for plan=#{plan_id} task=#{state.task_id}"
        )

      {:error, reason} ->
        # Expected on a duplicate fire, a gate an architect already closed, or
        # a plan superseded before the deadline landed. Not an error path.
        Logger.debug(
          "[TaskRouter] architecture gate deadline no-op for plan=#{plan_id}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  # Review-request PubSub: a manual_approval review is open against this task
  def handle_info(
        {:review_request_pending, %{task_id: tid}},
        %State{task_id: tid} = state
      ) do
    plan = Tasks.current_plan(state.task_id)
    stage = find_stage(plan, state.current_stage_id) || current_running_stage(plan)

    # Edge-triggered (task 019f9b34): a repeated `:review_request_pending`
    # broadcast must not re-log into an already-parked episode. The 019e00cb
    # predicate alone cannot elide it — `heartbeat_suppressible?/2` is false
    # whenever any pending validation on the stage is not a `manual_approval`
    # linked to an open review request, which is the common mixed-validation
    # shape.
    if state.status != :waiting_human do
      maybe_log_heartbeat_suppressed(state, stage, reason: "awaiting_human_review")
    end

    state =
      state
      |> clear_liveness()
      |> Map.put(:status, :waiting_human)

    {:noreply, state}
  end

  def handle_info({:review_request_pending, _}, state), do: {:noreply, state}

  # Review-request PubSub: a human dispositioned the gate; resume the agent
  def handle_info(
        {:review_request_resolved, %{task_id: tid, outcome: outcome}},
        %State{task_id: tid} = state
      ) do
    state = %{state | status: :running}

    if outcome == :failed do
      # ReviewRequests already posted the consolidated feedback to the
      # execution space; redispatch so the agent picks up the in_progress
      # prompt that includes that feedback. `do_dispatch/2` arms fresh
      # liveness timers.
      send(self(), :dispatch)
    end

    {:noreply, state}
  end

  def handle_info({:review_request_resolved, _}, state), do: {:noreply, state}

  # Ignore unrelated board events
  def handle_info({:plan_updated, _plan}, state), do: {:noreply, state}
  def handle_info({:task_updated, _task}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Terminal task statuses. Source: `Platform.Tasks.Task` `@statuses` and the
  # comment above it recording that `cancelled` has `[]` outbound transitions
  # in `@valid_task_transitions`; `done` is likewise a sink. Written out here
  # rather than derived so that ADDING a status to `Task` is a visible edit
  # against this list instead of a silent divergence.
  @terminal_task_statuses ~w(done cancelled)

  @impl true
  def terminate(reason, state) do
    clear_liveness(state)
    revoke_deploy_lease(state)

    # Archive execution space on shutdown (best-effort — DB may be unavailable)
    if state.execution_space_id do
      try do
        ExecutionSpace.post_log(
          state.execution_space_id,
          "Task router stopped for task #{state.task_id}"
        )

        maybe_archive_execution_space(state, reason)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Archiving is gated on the TASK, not on the shutdown. `terminate/2` fires on
  # normal completion, on `TaskRouterSupervisor.stop_assignment/1`, on a
  # supervisor restart, on a deploy and on node teardown; every one of those
  # paths delivers `:shutdown`, so `reason` cannot distinguish "the work
  # finished" from "the box went away". Archiving unconditionally tombstoned
  # execution spaces of live tasks, and the pin read path filters archived
  # spaces out, so the pin then persisted and could never render.
  #
  # A task row we cannot load is NOT archived: absence of evidence that the
  # task finished is not evidence that it did.
  defp maybe_archive_execution_space(state, reason) do
    case Tasks.get_task_detail(state.task_id) do
      %{status: status} when status in @terminal_task_statuses ->
        ExecutionSpace.archive(state.task_id)

      %{status: status} ->
        Logger.info(
          "TaskRouter terminate: skipping execution-space archive for task " <>
            "#{state.task_id} — status #{status} is not terminal (reason: #{inspect(reason)})"
        )

        :ok

      nil ->
        Logger.info(
          "TaskRouter terminate: skipping execution-space archive for task " <>
            "#{state.task_id} — no task row (reason: #{inspect(reason)})"
        )

        :ok
    end
  end

  # ── Dispatch helpers ───────────────────────────────────────────────────

  defp do_dispatch(state, task) do
    plan = Tasks.current_plan(state.task_id)
    stage = current_running_stage(plan)

    if unresolved_stage_dispatch?(task, plan, stage) do
      suppress_unresolved_stage_dispatch(state, task, plan)
    else
      # A dispatch that RESOLVED means a stage is open again: the escalation
      # counter is about a CONSECUTIVE run of suppressions, so clear it here.
      dispatch_resolved(%{state | unresolved_suppression: nil}, task, plan, stage)
    end
  end

  # Unresolved-stage guard (task 019fa469 stage 4). The task's own status claims
  # a stage-scoped phase, but the plan holds no stage this dispatch could be
  # ABOUT — not a running one, and not even a pending one. Every stage-shaped
  # field in the prompt would then be invented, which is precisely the
  # 2026-07-27 incident: an empty `stage_id` under a `Stage 1/7` label on tasks
  # nowhere near stage 1.
  #
  # ## Why the third conjunct exists (it is not in the approved plan)
  #
  # The plan specified `phase.requires_stage? and is_nil(stage)`. Those two
  # conjuncts alone also match an `in_progress` task whose next stage is
  # `pending` — the shape `task_router_dispatch_suppression_test.exs:109` exists
  # to protect, because that dispatch is the only thing that will ever get an
  # agent to call `stage_start`. Running the two-conjunct version turned that
  # sibling test red (recorded in this stage's evidence), which is the failure
  # mode its moduledoc calls worse than the one we are fixing: silent
  # strangulation.
  #
  # The principle the third conjunct encodes: DO NOT SEND A DISPATCH WHOSE
  # SUBJECT CANNOT BE NAMED. A pending stage is a nameable subject. No stage at
  # all is not. Deliberately NOT fixed here: a pending stage still receives a
  # `dispatch.fallback` body (stage 2 of this task) rather than being
  # auto-started — auto-starting from the dispatch path is a much larger blast
  # radius and belongs to whoever owns the `stage_start` gap.
  #
  # Disjoint from the two suppression clauses in `handle_info(:dispatch, …)`:
  # `completed_plan_no_work?/1` requires `plan.status == "completed"` and
  # `settled_stack_member_no_work?/2` requires a `stack_id`; both are evaluated
  # earlier and would have short-circuited before control ever reached here.
  # This clause covers the residue — a non-stack task whose plan is still
  # `approved` but exhausted, and a task with no plan row at all (which used to
  # log the especially absurd `Stage: 1/0`).
  #
  # Best-effort, mirroring its siblings: a lookup that raises yields `false`.
  # Failing open costs one redundant prompt; failing closed costs a stalled
  # task.
  defp unresolved_stage_dispatch?(task, plan, stage) do
    phase = DispatchPhase.resolve(task, plan, stage)

    phase.requires_stage? and is_nil(stage) and is_nil(first_pending_stage(plan))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp suppress_unresolved_stage_dispatch(state, task, plan) do
    stage_count = if plan, do: length(plan.stages || []), else: 0

    Logger.info(
      "[TaskRouter] suppressed stage-scoped dispatch for task=#{state.task_id}: " <>
        "task status #{task.status} implies a running stage but none resolved " <>
        "(0 running, 0 pending of #{stage_count})"
    )

    emit_dispatch_suppressed_telemetry(state.task_id, :unresolved_stage)

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Dispatch withheld: #{task.title} | Stage: -/#{stage_count} | " <>
          "no running or pending stage for a task at #{task.status}"
      )
    end

    {:noreply, note_unresolved_suppression(state, task, plan)}
  end

  # ── Unresolved-stage escalation (task 01a006e7 stage 2) ────────────────
  #
  # THE INVARIANT: a task at `in_progress` with an `approved` plan always has
  # at least one stage in `pending` or `running`. Violating it for more than
  # one dispatch interval is a real blocker, not a log line.
  #
  # Adopted as a SAFETY NET, not as a fix. The known route into this state is
  # the review bounce (`bounce_to_in_progress/4`, which stage 4 of this task
  # wired to `PlanEngine.open_remediation_stage/2` so the normal-bounce arm no
  # longer reaches this guard at all), but it is one of several:
  # `handle_deploy_stage_failure/2` lands in
  # the same shape, and so does a single-stage plan whose `manual_approval`
  # was REJECTED by a human (task `019ff6c9`). This guard fires on the STATE
  # rather than on any one cause, so it also catches the routes nobody has
  # enumerated yet. Until today that state emitted an INFO line and a
  # telemetry event and nothing red.
  #
  # DELIBERATELY NOT auto-repair. Instance 1 above is out of the auto-repair
  # path on purpose: an agent must not clear or reopen a human's rejection —
  # the ruling is the point. `PlanEngine.reopen_manual_approval/1` already
  # exists for the human/agent-triggered recovery. What that instance lacked
  # was NOTICE; this supplies the notice and nothing else.
  #
  # FIRES ONCE, NOT ON A LOOP. A blocker per dispatch tick is a new bug, not a
  # fix. The counter is keyed on `{task_id, task.status}` and lives on the
  # router `%State{}`; it resets when a dispatch resolves (a stage is open
  # again — see `do_dispatch/2`) and, by the key changing, when the task
  # leaves the status it was stuck at. `raised?` latches so subsequent ticks
  # in the same run stay quiet.
  defp note_unresolved_suppression(%State{} = state, task, plan) do
    key = {state.task_id, task.status}

    count =
      case state.unresolved_suppression do
        %{key: ^key, count: n} -> n + 1
        _ -> 1
      end

    raised? =
      case state.unresolved_suppression do
        %{key: ^key, raised?: true} -> true
        _ -> false
      end

    raised? =
      if not raised? and count >= 2 and task.status == "in_progress" do
        record_unresolved_stage_blocker(state, task, plan, count) == :ok
      else
        raised?
      end

    %{state | unresolved_suppression: %{key: key, count: count, raised?: raised?}}
  end

  # Same attrs shape as `record_review_unrunnable_blocker/4`, phase
  # `"execution"`, with a reason naming the task, the plan and the
  # stage-status census — the census is what tells a human whether they are
  # looking at a rejected approval, a failed deploy, or a bounced review.
  defp record_unresolved_stage_blocker(%State{} = state, task, plan, count) do
    census = stage_status_census(plan)

    attrs = %{
      "task_id" => task.id,
      "phase" => "execution",
      "runtime_id" => "task_router",
      "event_type" => "execution.blocked",
      "execution_space_id" => state.execution_space_id,
      "payload" => %{
        "stage_id" => nil,
        "description" =>
          "Task #{task.id} (#{task.title}) is at #{task.status} with " <>
            "#{if plan, do: "plan #{plan.id} (#{plan.status})", else: "no plan"} but NO stage " <>
            "is pending or running, so every dispatch is withheld " <>
            "(#{count} consecutive). Stage statuses: #{census}. Re-open the stage the work " <>
            "belongs in — a rejected manual_approval is re-opened with " <>
            "PlanEngine.reopen_manual_approval/1, never silently cleared.",
        "needs_human" => true,
        "reported_by" => "task_router"
      }
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        Logger.warning(
          "[TaskRouter] task #{task.id} has no open stage after #{count} consecutive " <>
            "withheld dispatches — blocker raised (#{census})"
        )

        :ok

      {:error, err} ->
        Logger.error(
          "[TaskRouter] failed to record unresolved-stage blocker for task #{task.id}: #{inspect(err)}"
        )

        :error
    end
  end

  defp stage_status_census(nil), do: "no plan"

  defp stage_status_census(plan) do
    case plan.stages || [] do
      [] ->
        "no stages"

      stages ->
        stages
        |> Enum.frequencies_by(& &1.status)
        |> Enum.map_join(", ", fn {status, n} -> "#{n} #{status}" end)
    end
  rescue
    _ -> "unavailable"
  end

  defp dispatch_resolved(state, task, plan, stage) do
    # Capture the INCOMING status before the unconditional
    # `Map.put(:status, :running)` below overwrites it. Both tail branches of
    # this function re-check `waiting_for_human_review?/1` and can park the
    # router at `:waiting_human`; those parks need an edge, and by then
    # `state.status` has already been clobbered to `:running`. See the
    # episode-start narration at those two sites (task 019f9b34).
    entry_status = state.status

    case refresh_assignee(state, task) do
      {:suppress, state} -> {:noreply, state}
      {:dispatch, state} -> do_dispatch_resolved(state, task, plan, stage, entry_status)
    end
  end

  # Task 019fb977. Re-resolve the dispatch runtime from the task's CURRENT
  # phase, using the fresh `%Task{}` `do_dispatch/2` already loaded, and
  # REPLACE `state.assignee` with the answer.
  #
  # Replacing the FIELD rather than shadowing a local is load-bearing:
  # `state.assignee` is also read by the `Assignee:` execution-space log line
  # and by `current_status/1`. A local would fix the broadcast target and
  # leave both readers disagreeing with it.
  #
  # MEASURED (stage 5 control M4): resolving correctly, dispatching to the
  # resolved runtime, but NOT writing it back fails exactly one assertion —
  # case 2's `current_status(task.id).assignee.id == runtime_b`. So the
  # write-back is load-bearing, but for `current_status/1`, not for
  # everything an earlier draft of this comment claimed.
  #
  # SPECIFICALLY RETRACTED: this comment used to also name
  # `maybe_hydrate_from_lease/1`'s foreign-lease comparison as a reader that
  # depends on the write-back. It is not. `maybe_hydrate_from_lease/1` has
  # exactly one call site (`init/1`, above), which runs strictly BEFORE any
  # dispatch, so the comparison there always reads the `start_link/1`
  # argument and the dispatch-time write-back cannot reach it. M4 confirms
  # it: all three foreign-lease tests stay GREEN under that mutation. If you
  # want the drift check to see a re-resolved assignee, you would have to
  # call it after a dispatch — nothing does today.
  defp refresh_assignee(state, task) do
    case PhaseRuntime.resolve(task) do
      {:ok, resolved} ->
        # Never a silent swap. A CHANGE of runtime is the exact event a human
        # debugging a "wrong agent picked up my task" report needs in the log,
        # and its absence is why the 2026-07-31 incident took a human staring
        # at a dirty worktree to diagnose. An unchanged resolution is the
        # common case and stays quiet.
        if resolved.id != state.assignee.id do
          Logger.info(
            "[TaskRouter] task #{state.task_id} phase=#{Tasks.current_phase(task)} " <>
              "reassigning dispatch from runtime #{state.assignee.id} to #{resolved.id}"
          )
        end

        {:dispatch, %{state | assignee: resolved, assignee_source: :resolved}}

      {:error, :user_assignee} ->
        {:suppress, suppress_user_phase_assignee(state, task)}

      {:error, reason} ->
        # FAIL OPEN, deliberately asymmetric with the clause above. A
        # transient resolution failure (`:no_runtime`, `:agent_not_found`,
        # `:sandbox_unowned`, `:no_assignee`) costs one dispatch to a
        # possibly-stale runtime; failing closed strands the task with no
        # prompt and no operator signal. Same policy as
        # `unresolved_stage_dispatch?/3`: "failing open costs one redundant
        # prompt; failing closed costs a stalled task."
        #
        # `:user_assignee` is NOT in this bucket and must never be folded into
        # it — there is no runtime behind a human, so falling back to the
        # previously-held agent is the phase-blind bug wearing a different hat.
        #
        # HOW MUCH OF THE SUITE RIDES ON THIS ARM (stage 5 control M8).
        # Making this clause suppress instead of dispatch fails exactly ONE
        # test in `task_router_phase_assignee_test.exs` — the one whose
        # fixture builds a real `Agent` row deliberately unlinked from any
        # runtime, so `:no_runtime` is the only answer available. That is the
        # discrimination the fixture was built for and it is clean.
        #
        # Across `test/platform/orchestration` + `tasks_test.exs`, though,
        # the same mutation fails 67 of 748. Those are NOT independent
        # evidence for the fail-open policy: they are older fixtures that
        # start a router with a synthetic `%{type: :federated, id:
        # "runtime-test-..."}` map against a task carrying no assignee at
        # all, so `PhaseRuntime.resolve/1` answers `:no_assignee` and this
        # arm is the only reason they dispatch. If you ever want to revisit
        # the fail-open policy, budget for rewriting those fixtures to wire a
        # real agent -> runtime link first; otherwise their redness will look
        # like a policy signal when it is a fixture artefact.
        Logger.warning(
          "[TaskRouter] task #{state.task_id} could not resolve a phase runtime " <>
            "(#{inspect(reason)}); dispatching to held assignee #{state.assignee.id}"
        )

        {:dispatch, %{state | assignee_source: :frozen_fallback}}
    end
  end

  # A phase owned by a HUMAN has no runtime to broadcast to. Mirrors the
  # `suppress_unresolved_stage_dispatch/2` shape above — log, telemetry,
  # execution-space line — and returns without arming any liveness timer,
  # because nothing was dispatched and there is no ack to wait for.
  defp suppress_user_phase_assignee(state, task) do
    phase = Tasks.current_phase(task)

    Logger.info(
      "[TaskRouter] suppressed dispatch for task=#{state.task_id}: " <>
        "the #{phase} phase is assigned to a user, not an agent runtime"
    )

    emit_dispatch_suppressed_telemetry(state.task_id, :user_phase_assignee)

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Dispatch withheld: #{task.title} | Phase: #{phase} | " <>
          "assigned to a user — no runtime to dispatch to"
      )
    end

    state
  end

  # ── Branch provisioning (task 01a001ac) ───────────────────────────────
  #
  # Two conditions, both necessary.
  #
  # EXECUTION PHASE ONLY. Gated on `DispatchPhase.resolve/3` — the same
  # resolver `unresolved_stage_dispatch?/3` uses — rather than on
  # `task.status`, for the reason that module's moduledoc gives: `task.status`
  # lags a dispatch cycle behind the plan engine. A planning dispatch has no
  # executor to constrain, and a review or deploy dispatch arrives after the
  # push it was supposed to precede.
  #
  # NOT STACK MEMBERS. A stack member ships through the rollup branch
  # (`Tasks.resolve_deploy_strategy/1` answers `no_op_wait_for_rollup`) and
  # `StackDeployer` owns its refs. The gate is `task.stack_id`, NOT the
  # `no_op_wait_for_rollup` strategy answer: that answer additionally requires
  # a non-empty `stack.rollup_branch` (`tasks.ex:1718`), so a member whose
  # rollup has not been cut yet would fall through it and get a solo task
  # branch provisioned underneath the stack. `stack_id` is the stricter gate
  # and the one that matches "skip stack members entirely".
  #
  # Best-effort, mirroring `unresolved_stage_dispatch?/3`: a resolver that
  # raises yields `false` and the dispatch proceeds unprovisioned.
  defp provision_branches?(task, plan, stage) do
    is_nil(task.stack_id) and execution_dispatch?(task, plan, stage)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # TWO slugs, not one — and the second is the load-bearing surprise.
  #
  # The plan said "gate on the resolved phase", meaning `dispatch.in_progress`.
  # That slug requires a RUNNING stage: `do_dispatch/2` resolves `stage` with
  # `current_running_stage/1` (`:1361`), so a task at `in_progress` whose next
  # stage is still `pending` resolves NO stage and `DispatchPhase.resolve/3`
  # falls to step 3, `dispatch.fallback`.
  #
  # That fallback dispatch is not an edge case — it is THE FIRST execution
  # dispatch of most tasks, and the comment on `unresolved_stage_dispatch?/3`
  # says so explicitly: it "is the only thing that will ever get an agent to
  # call `stage_start`". It is therefore the dispatch that most needs the
  # branch to already exist, since it is the one the executor runs
  # `git worktree add` from. Gating on `dispatch.in_progress` alone would have
  # skipped provisioning at exactly the moment it matters and provisioned only
  # on the redispatches after the executor had already invented a name.
  #
  # `dispatch.fallback` alone is not enough of a signal though — a task in a
  # stage-less status renders it too. Pairing it with
  # `Tasks.current_phase(task) == "execution"` narrows it to the shape above.
  defp execution_dispatch?(task, plan, stage) do
    case DispatchPhase.resolve(task, plan, stage).slug do
      "dispatch.in_progress" -> true
      "dispatch.fallback" -> Tasks.current_phase(task) == "execution"
      _ -> false
    end
  end

  defp maybe_provision_branches(state, task, plan, stage) do
    if provision_branches?(task, plan, stage) do
      provision_branches(state, task)
    else
      :ok
    end
  end

  # FAIL SOFT, LOG LOUD. A task that cannot reach GitHub still needs its
  # executor prompted — suppressing the dispatch would trade a missing branch
  # for a stalled task, which is strictly worse. So every failure path here
  # ends in a log line and `:ok`, never a raise and never an early return from
  # `do_dispatch_resolved/5`. Drift left behind by a failed provision is what
  # the reconciliation pass is for.
  defp provision_branches(state, task) do
    {:ok, %{branch: branch, results: results}} = BranchProvisioner.ensure_branches(task)

    Enum.each(results, fn
      %{result: {:ok, _}} ->
        :ok

      %{repo_url: repo_url, result: failure} ->
        report_provision_failure(state, task, branch, repo_url, failure)
    end)

    :ok
  rescue
    error -> report_provision_failure(state, task, provision_branch_name(task), nil, error)
  catch
    :exit, reason ->
      report_provision_failure(state, task, provision_branch_name(task), nil, {:exit, reason})
  end

  defp provision_branch_name(task) do
    BranchProvisioner.branch_for(task)
  rescue
    _ -> "task/#{task.id}"
  end

  defp report_provision_failure(state, task, branch, repo_url, reason) do
    where = if repo_url, do: " in #{repo_url}", else: ""

    Logger.warning(
      "[TaskRouter] task #{task.id} could not pre-create branch #{branch}#{where}: " <>
        "#{inspect(reason)}; dispatching anyway"
    )

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Branch not pre-created: #{branch}#{where} | #{inspect(reason)} | " <>
          "dispatching anyway — push to this exact branch name"
      )
    end

    :ok
  end

  defp do_dispatch_resolved(state, task, plan, stage, entry_status) do
    # Lease deploy credentials if this is a deploy stage
    state = maybe_lease_deploy_credentials(state, task, stage)

    # Create `task/<uuid>` BEFORE the executor is prompted (task 01a001ac).
    # Deliberately here and not in `PlanEngine.build_deploy_plan/1`: the
    # deploy plan is built after every implementation stage is done and the
    # executor has already pushed somewhere, so a branch created there cannot
    # constrain anything — that is detection dressed as prevention. The
    # executor needs the ref to exist before it runs `git worktree add`.
    maybe_provision_branches(state, task, plan, stage)

    context = ContextAssembler.build(state.task_id, state.deploy_lease)
    {agent, runtime} = Federation.lookup_assignment(state.assignee.id)
    previous_rejection_reason = context && Map.get(context, :previous_rejection_reason)
    # Only stack members receive `:parent_plans` in the assembled context; for
    # solo tasks the key is absent and this defaults to `[]` so the planning
    # dispatch template renders no upstream-plans section.
    parent_plans = (context && Map.get(context, :parent_plans, [])) || []

    prompt =
      HeartbeatScheduler.dispatch_prompt(task, plan, stage,
        agent: agent,
        runtime: runtime,
        previous_rejection_reason: previous_rejection_reason,
        parent_plans: parent_plans,
        # The execution space lives HERE, on the router's state — there is no
        # `execution_space_id` field on the task schema (task 019fa469 stage 3).
        # `dispatch.review_e2e` interpolates it, and without this opt the
        # accessor in `e2e_review_assigns/3` had nothing to read.
        execution_space_id: state.execution_space_id
      )

    case dispatch_attention(state.assignee, state.task_id, "task_assigned", context, prompt) do
      :ok ->
        # Post log message to execution space after successful runtime dispatch so
        # boot retries do not duplicate task-assigned chatter.
        if state.execution_space_id do
          stage_count = if plan, do: length(plan.stages || []), else: 0

          # NEVER `else: 1` (task 019fa469 stage 4). That default rendered
          # `Stage: 1/7` on tasks demonstrably past stage 1 all day on
          # 2026-07-27 — a fabrication of the one fact the log line exists to
          # report. When no stage resolved, say so.
          stage_pos = if stage, do: Integer.to_string(stage.position), else: "-"

          # A runtime id ALONE does not tell a human reading the execution
          # space which AGENT was chosen, nor for which phase — that opacity
          # is why the 2026-07-31 phase-blind dispatch took a human staring at
          # a dirty worktree to diagnose (task 019fb977). `agent` is the
          # `Federation.lookup_assignment/1` result a few lines up and is nil
          # for an unlinked runtime, so name it only when we have it.
          agent_log = if agent, do: " (agent #{agent.slug})", else: ""

          assignee_log =
            "Assignee: #{state.assignee.id}#{agent_log} | Phase: #{Tasks.current_phase(task)}"

          log_content =
            "Task assigned: #{task.title} | Stage: #{stage_pos}/#{stage_count} | #{assignee_log}"

          ExecutionSpace.post_log(state.execution_space_id, log_content)

          ExecutionSpace.post_engagement(state.execution_space_id, prompt,
            metadata: %{"reason" => "task_assigned"}
          )
        end

        # Event-driven liveness arm (task 019f640d stage 3). Record the
        # dispatch in LeaseManager and arm one-shot ack + safety-net timers
        # for this stage-instance. `arm_liveness_timers/2` no-ops on
        # manual_approval stage kinds (no timers armed at all).
        stage_kind = current_stage_type(%{state | current_stage_id: stage && stage.id})
        arm_liveness_timers(state.task_id, stage, stage_kind)

        state =
          state
          |> Map.put(:status, :running)
          |> Map.put(:last_dispatch_at, DateTime.utc_now())
          |> Map.put(:task_status, task.status)
          |> maybe_set_stage(stage)

        state =
          if waiting_for_human_review?(state) do
            # EPISODE START for the stage gate (task 019f9b34). This tail park
            # is silent on main, and it is the site that actually opens a
            # mid-task suppression episode: a review request created while the
            # router is running lands here (the `:dispatch` handler's
            # `pending_review_request?/1` branch was false on entry, which is
            # why control reached `do_dispatch/2` at all), parks at
            # `:waiting_human`, and every downstream narrating site then sees
            # an already-parked router and correctly skips. Without an
            # emission here the episode would be narrated ZERO times.
            #
            # Edge is `entry_status`, not `state.status`: the latter was set to
            # `:running` unconditionally a few lines above, so it would emit on
            # every dispatch — the 019e00cb pile-up regression.
            if entry_status != :waiting_human do
              maybe_log_heartbeat_suppressed(state, stage, reason: "awaiting_human_review")
            end

            state |> clear_liveness() |> Map.put(:status, :waiting_human)
          else
            state
          end

        {:noreply, state}

      {:error, :endpoint_not_ready} ->
        Logger.warning(
          "[TaskRouter] endpoint not ready for task #{state.task_id}; retrying dispatch"
        )

        Process.send_after(self(), :dispatch, 1_000)
        {:noreply, state}

      {:error, _reason} ->
        state =
          state
          |> Map.put(:status, :running)
          |> Map.put(:last_dispatch_at, DateTime.utc_now())
          |> Map.put(:task_status, task.status)
          |> maybe_set_stage(stage)

        state =
          if waiting_for_human_review?(state) do
            # Same episode-start narration as the `{:ok, ...}` tail above
            # (task 019f9b34); this branch parks identically on a failed
            # dispatch and must not leave the episode unnarrated.
            if entry_status != :waiting_human do
              maybe_log_heartbeat_suppressed(state, stage, reason: "awaiting_human_review")
            end

            state |> clear_liveness() |> Map.put(:status, :waiting_human)
          else
            state
          end

        {:noreply, state}
    end
  end

  # Goes through `Platform.Federation.AttentionDispatch`, which puts the
  # assignee in a writable posture in the task's execution space BEFORE the
  # signal leaves. This is a real behaviour change, not a refactor:
  # `Platform.Orchestration.ExecutionSpace.add_participant/2` had zero
  # production call sites, so a federated assignee was dispatched into an
  # execution space it had never been added to and only became able to write
  # there *incidentally*, when a router prompt happened to contain an
  # `@[slug]` token that `Chat.reinvite_and_pin_mentioned/1` picked up. That
  # function is deleted in the same change — its `attention_mode: "all"` now
  # lives in `DispatchMembership`'s per-kind policy, and two mechanisms saying
  # one thing is how they drift.
  #
  # The `:broadcast_failed` / `:endpoint_not_ready` split is preserved exactly,
  # because `handle_info(:dispatch, ...)` retries on the second and parks on
  # the first. Only the raw error term moved: the funnel logs it, so these
  # lines no longer restate it.
  defp dispatch_attention(%{type: :federated, id: runtime_id}, task_id, reason, context, prompt) do
    task_status = context[:task][:status] || context[:task]["status"]
    space_id = context[:execution_space_id]

    payload = %{
      signal: %{reason: reason, task_id: task_id, task_status: task_status, space_id: space_id},
      context: context,
      message: %{content: prompt, author: "TaskRouter"}
    }

    topic = AttentionDispatch.topic(runtime_id)

    # `Federation.lookup_assignment/1` is the resolution orchestration ALREADY
    # uses to turn a `%{type: :federated, id: runtime_id}` assignee into
    # `{agent, runtime}`. Reused rather than adding a second lookup path, and
    # the struct is handed to the funnel directly so DispatchMembership does not
    # repeat the query. An unresolvable runtime yields `nil`, which the funnel
    # reports as `:no_agent_named` and which never blocks the broadcast — the
    # signal is addressed by `runtime_id`, not by the agent row.
    {agent, _runtime} = Federation.lookup_assignment(runtime_id)

    case AttentionDispatch.broadcast(runtime_id, payload,
           space_id: space_id,
           agent_id: agent,
           source: :task_router
         ) do
      :ok ->
        Logger.info("[TaskRouter] dispatched #{reason} to #{topic} for task #{task_id}")
        :ok

      {:error, :endpoint_not_ready} ->
        Logger.warning(
          "[TaskRouter] endpoint not ready while dispatching #{reason} for task #{task_id}"
        )

        {:error, :endpoint_not_ready}

      {:error, :broadcast_failed} ->
        Logger.error("[TaskRouter] broadcast failed to #{topic}")
        {:error, :broadcast_failed}
    end
  end

  # ── Liveness (LeaseManager) helpers ────────────────────────────────────

  # Record the dispatch in LeaseManager and arm one-shot ack + safety-net
  # timers. Idempotent w.r.t. LeaseManager — `record_dispatch/4` overwrites
  # any prior lease for the task. Timer arming is a no-op on stage kinds
  # whose `stage_kind_timeouts()` entry has nil ack_ms / safety_net_ms
  # (manual_approval today; disabled/unknown kinds fall through the same
  # nil path).
  defp arm_liveness_timers(_task_id, nil, _stage_kind), do: :ok

  defp arm_liveness_timers(task_id, %Stage{} = stage, stage_kind) do
    :ok = LeaseManager.record_dispatch(task_id, stage.id, stage_kind, DateTime.utc_now())

    timeouts =
      LeaseManager.stage_kind_timeouts()
      |> Map.get(stage_kind, %{ack_ms: nil, safety_net_ms: nil})

    if timeouts.ack_ms do
      Process.send_after(self(), :check_no_ack, timeouts.ack_ms)
    end

    if timeouts.safety_net_ms do
      Process.send_after(self(), :check_safety_net, timeouts.safety_net_ms)
    end

    :ok
  end

  defp arm_liveness_timers(_task_id, _other, _stage_kind), do: :ok

  # Clear the LeaseManager row for the task. Pending `:check_no_ack` /
  # `:check_safety_net` timers may still fire later — their handlers
  # short-circuit on `LeaseManager.get/1 == nil`. Used on human-gate
  # transitions, phase boundaries, and router termination.
  defp clear_liveness(%State{task_id: task_id} = state) do
    LeaseManager.clear(task_id)
    state
  end

  # Reset the router from `:stalled` → `:running` when fresh runtime activity
  # arrives after a no-ack / safety-net alert. The stalled state is a signal
  # to a human, not a permanent lockout — if the runtime resumes, we resume.
  defp maybe_reset_stalled(%State{status: :stalled} = state), do: %{state | status: :running}
  defp maybe_reset_stalled(state), do: state

  # Stage-scoped blocker predicate (task 019f6791). A blocker "targets" the
  # current stage when either:
  #   * the payload has no `stage_id` at all (legacy caller — treat as
  #     current-stage to preserve pre-fix behaviour), OR
  #   * the payload's `stage_id` matches the router's `current_stage_id`.
  # Everything else is stale / cross-stage and must NOT flip the router
  # into `:waiting_human`.
  defp blocker_targets_current_stage?(payload, current_stage_id) do
    case get_in(payload, ["stage_id"]) || get_in(payload, [:stage_id]) do
      nil -> true
      stage_id -> stage_id == current_stage_id
    end
  end

  # DB-backed "does the current stage have a live blocker?" check
  # (task 019f6791). Used by the stage-transition handler to decide whether
  # a stale `:waiting_human` status should reset to `:dispatching` — if the
  # incoming stage has no live blocker of its own, the prior stage's
  # blocker must not gate its dispatch.
  defp stage_has_live_blocker?(%State{current_stage_id: nil}), do: false

  defp stage_has_live_blocker?(%State{task_id: task_id, current_stage_id: stage_id}) do
    case RuntimeSupervision.current_lease_for_stage(task_id, stage_id) do
      %{status: "blocked"} -> true
      _ -> false
    end
  end

  # On a stage boundary crossing, if the router was `:waiting_human` from a
  # prior-stage blocker and the incoming stage has neither a live blocker
  # nor a pending manual_approval review, reset to `:dispatching` so the
  # subsequent `:dispatch` handler re-arms the heartbeat via
  # `arm_liveness_timers/3` cleanly (task 019f6791).
  defp maybe_reset_stale_waiting_human(state, next_stage_id, previous_stage_id)
       when next_stage_id != previous_stage_id do
    cond do
      state.status != :waiting_human -> state
      stage_has_live_blocker?(state) -> state
      still_awaiting_human?(state) -> state
      true -> %{state | status: :dispatching}
    end
  end

  defp maybe_reset_stale_waiting_human(state, _next, _prev), do: state

  # Emit one loud runtime_event via `Tasks.broadcast_board/1` — the UI's
  # `tasks:board` subscribers pick it up. The event carries the same
  # top-level shape as a real RuntimeEvent (event_type, task_id, payload,
  # occurred_at) but is NOT persisted through `record_runtime_event/1` —
  # these are router-emitted alert events, not runtime lifecycle events.
  defp broadcast_router_event(event_type, task_id, stage_id, payload) do
    event = %{
      id: nil,
      event_type: event_type,
      task_id: task_id,
      stage_id: stage_id,
      payload: payload,
      occurred_at: DateTime.utc_now(),
      runtime_id: nil,
      phase: nil,
      lease: nil
    }

    Tasks.broadcast_board({:runtime_event, event})
  end

  # Level check for the no-ack deadline (task 019fa469 stage 6) — the exact
  # shape `handle_info(:check_safety_net, ...)` already applies to
  # `safety_net_at`, and the only reason the two handlers differed.
  #
  # Both `:check_no_ack` fire paths (default clause, and the silence-lapsed
  # fall-through) route through here rather than adding a clause to the
  # handler: a clause would have to sit after the silence branch to keep that
  # branch's ordering comments true, which would leave the silence-lapsed
  # fall-through firing without ever checking its deadline.
  #
  # `no_ack_at: nil` means the alarm is disabled for this lease's stage_kind
  # (`manual_approval`) — the router arms no timer for such stages, but an
  # orphan timer from a previous stage can still reach one. Never fire.
  # Mirrors `:check_safety_net`'s `%{safety_net_at: nil}` clause.
  #
  # Deliberately stateless: no timer refs in `%State{}`, so a router restart
  # cannot strand them. Cancelling the stale timer in `arm_liveness_timers/3`
  # would fix the same reproduction, but only while the router lives — the
  # same argument `:design_deadline` makes for preferring level checks over
  # timer bookkeeping.
  defp fire_or_reschedule_no_ack(%State{} = state, _task_id, %{no_ack_at: nil}) do
    {:noreply, state}
  end

  defp fire_or_reschedule_no_ack(
         %State{} = state,
         task_id,
         %{no_ack_at: %DateTime{} = deadline} = lease
       ) do
    remaining_ms = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)

    if remaining_ms > 0 do
      # Woken early by an orphan timer. Reschedule to the deadline this lease
      # actually carries and stay quiet.
      Process.send_after(self(), :check_no_ack, remaining_ms)
      {:noreply, state}
    else
      maybe_fire_no_ack(state, task_id, lease)
    end
  end

  # Idempotency-guarded fire path, reached only once
  # `fire_or_reschedule_no_ack/3` has confirmed the deadline actually elapsed.
  # `mark_no_ack_fired/1` flips the LeaseManager row's `no_ack_fired?`
  # atomically — if it returns anything other than `{:ok, :fired}`
  # (already-fired race), we swallow the check with no state change.
  # Durable-ack guard. The ETS lease row is the only place an ack lives at
  # runtime, and `clear_liveness/1` DELETES that row from ~15 call sites — so
  # any re-dispatch of a stage the executor already acked (opening a review
  # request is the reachable one) re-arms this alarm against an agent that DID
  # ack. `execution.acked` lives in Postgres and survives every clear, so we
  # consult it before firing and re-stamp the ETS row on a hit.
  #
  # ACCEPTED TRADE-OFF: this deliberately does NOT compare the ack's
  # `occurred_at` against `lease.dispatched_at`. Any time bound reintroduces
  # the false positive, because the re-dispatch happens AFTER the ack.
  # Consequence: a stage force-reassigned to a NEW runtime will not re-fire
  # no-ack on the old owner's ack — that case is covered by
  # `execution.safety_net_fired`, which is left untouched.
  #
  # Stage-scoped by construction: a lease with a nil/blank stage_id falls
  # through to the alarm (`stage_acked?/2` answers false), and an ack on stage
  # N never suppresses the alarm for stage N+1.
  # Best-effort stage label for the ack log line: the event payload is the
  # authority (the ack names its own stage), the router's current stage is
  # the fallback, and "unknown" when neither is set.
  defp acked_stage_id(event, %State{} = state) do
    payload_stage =
      case event do
        %{payload: %{"stage_id" => id}} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    payload_stage || state.current_stage_id || "unknown"
  end

  defp maybe_fire_no_ack(%State{} = state, task_id, lease) do
    if Platform.Orchestration.stage_acked?(task_id, lease.stage_id) do
      LeaseManager.record_ack(task_id)

      Logger.info(
        "[TaskRouter] task #{task_id} stage #{lease.stage_id} — no-ack alarm suppressed by a durable execution.acked event; re-stamping lease ack_at"
      )

      {:noreply, state}
    else
      do_fire_no_ack(state, task_id, lease)
    end
  end

  defp do_fire_no_ack(%State{} = state, task_id, lease) do
    case LeaseManager.mark_no_ack_fired(task_id) do
      {:ok, :fired} ->
        fire_no_ack_alert(state, lease)
        {:noreply, %{state | status: :stalled}}

      _ ->
        {:noreply, state}
    end
  end

  defp fire_no_ack_alert(%State{} = state, lease) do
    elapsed_ms =
      DateTime.diff(DateTime.utc_now(), lease.dispatched_at, :millisecond)

    Logger.warning(
      "[TaskRouter] task #{state.task_id} stage #{lease.stage_id} — no ack after #{div(elapsed_ms, 1_000)}s; firing execution.no_ack_timeout"
    )

    broadcast_router_event("execution.no_ack_timeout", state.task_id, lease.stage_id, %{
      task_id: state.task_id,
      stage_id: lease.stage_id,
      elapsed_ms_since_dispatch: elapsed_ms
    })

    sentence =
      "Executor never acked the dispatch. No `task_ack` runtime event received within " <>
        "#{div(elapsed_ms, 1_000)}s of dispatch — the runtime likely dropped before " <>
        "the agent spawned. Manual intervention required."

    stamp_blocked_reason(state.task_id, sentence)

    post_router_blocker(
      state,
      sentence,
      %{
        "reason" => "execution.no_ack_timeout",
        "stage_id" => lease.stage_id,
        "needs_human" => true,
        "elapsed_ms_since_dispatch" => elapsed_ms
      }
    )
  end

  defp fire_safety_net_alert(%State{} = state, lease) do
    elapsed_ms =
      DateTime.diff(DateTime.utc_now(), lease.dispatched_at, :millisecond)

    Logger.warning(
      "[TaskRouter] task #{state.task_id} stage #{lease.stage_id} (#{lease.stage_kind}) — safety-net fired after #{div(elapsed_ms, 60_000)}m; firing execution.safety_net_fired"
    )

    broadcast_router_event("execution.safety_net_fired", state.task_id, lease.stage_id, %{
      task_id: state.task_id,
      stage_id: lease.stage_id,
      stage_kind: lease.stage_kind,
      elapsed_ms: elapsed_ms,
      ack_at: lease.ack_at,
      last_validation_pass_at: lease.last_progress_at
    })

    sentence =
      "Stage safety-net exceeded (#{div(elapsed_ms, 60_000)}m elapsed for #{lease.stage_kind}). " <>
        "The executor acked but has not produced validation progress within the stage's safety-net window. " <>
        "Check whether the agent is stuck; manual intervention may be required."

    stamp_blocked_reason(state.task_id, sentence)

    post_router_blocker(
      state,
      sentence,
      %{
        "reason" => "execution.safety_net_fired",
        "stage_id" => lease.stage_id,
        "stage_kind" => lease.stage_kind,
        "needs_human" => true,
        "elapsed_ms" => elapsed_ms
      }
    )
  end

  # Give the escalation sentence a durable per-task home
  # (`metadata["blocked_reason"]`) alongside the transient chat post, using
  # the SAME string so the two can never disagree. This is a failure path:
  # it logs and continues on error rather than crashing the router.
  defp stamp_blocked_reason(task_id, sentence) do
    case Tasks.stamp_blocked_reason(task_id, sentence) do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[TaskRouter] task #{task_id} — could not stamp blocked_reason: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[TaskRouter] task #{task_id} — blocked_reason stamp raised: #{Exception.message(error)}"
      )

      :ok
  end

  # Post the human-facing blocker message to the execution space so a
  # reviewer sees it inline on the task view. Uses `post_engagement/3` so
  # the message surfaces as an attention-grabbing event, not a plain log
  # line lost in the diagnostic scroll.
  defp post_router_blocker(%State{execution_space_id: nil}, _description, _metadata), do: :ok

  defp post_router_blocker(%State{execution_space_id: space_id}, description, metadata) do
    ExecutionSpace.post_engagement(
      space_id,
      "Blocker reported: " <> description,
      metadata: metadata
    )

    :ok
  end

  # Informational sibling of `post_router_blocker/3` (task 01a01a4a stage 2).
  # A separate function rather than a flag on the blocker path because the
  # blocker path is SHARED by every other router alarm: parameterising its
  # "Blocker reported: " prefix would put a way to un-blocker those alarms
  # one wrong argument away. This one cannot post a blocker at all.
  defp post_router_notice(%State{execution_space_id: nil}, _description, _metadata), do: :ok

  defp post_router_notice(%State{execution_space_id: space_id}, description, metadata) do
    ExecutionSpace.post_engagement(space_id, description, metadata: metadata)
    :ok
  end

  # Boot rehydration — stage-scoped when a stage is already running (task
  # 019f6791). Leases whose `stage_id` matches a `passed` stage are
  # historical and MUST NOT rehydrate into `state.lease_status`; carrying a
  # stale `blocked` row into `state.status = :waiting_human` was the
  # direct cause of the boot-time leak Rowan observed on task 019f6380.
  defp maybe_hydrate_from_lease(%State{} = state) do
    plan = Tasks.current_plan(state.task_id)
    running_stage = current_running_stage(plan)

    lease =
      case running_stage do
        %Stage{id: stage_id} ->
          case RuntimeSupervision.current_lease_for_stage(state.task_id, stage_id) do
            %{} = live ->
              live

            nil ->
              # Fallback for legacy callers whose runtime events don't
              # carry `stage_id` in the payload (lease row is written
              # with `stage_id: nil`). We still want to hydrate from
              # such rows, but never from a lease whose `stage_id`
              # references a `passed` stage — that's the leak.
              case RuntimeSupervision.current_lease_for_task(state.task_id) do
                nil ->
                  nil

                candidate ->
                  if lease_targets_passed_stage?(candidate, plan),
                    do: nil,
                    else: candidate
              end
          end

        nil ->
          # No stage running — legacy path. Fall back to the newest
          # cross-stage lease but drop any row that references a stage
          # already in `passed` (a leaked historical blocker).
          case RuntimeSupervision.current_lease_for_task(state.task_id) do
            nil ->
              nil

            candidate ->
              if lease_targets_passed_stage?(candidate, plan), do: nil, else: candidate
          end
      end

    case lease do
      %{runtime_id: runtime_id} = lease when runtime_id == state.assignee.id ->
        last_runtime_event_at =
          lease.last_progress_at || lease.last_heartbeat_at || lease.started_at

        %{
          state
          | last_runtime_event_at: last_runtime_event_at,
            lease_status: lease.status
        }

      # A live lease whose holder is NOT the runtime this router intends to
      # dispatch to. Before task 019fb977 this fell through the bare `_`
      # clause below and was discarded silently — despite being the single
      # most diagnostic fact available at boot: the current stage's liveness
      # is anchored to a runtime nobody means to talk to.
      #
      # Still NOT hydrated. `last_runtime_event_at` / `lease_status` from a
      # foreign lease would credit this router's assignee with another
      # runtime's activity; the whole point is that the two disagree.
      %{runtime_id: _} = foreign ->
        note_foreign_lease(state, foreign)
        state

      _ ->
        state
    end
  end

  # Surface + clear a lease held by the wrong runtime (task 019fb977 stage 3).
  #
  # Reached only from `maybe_hydrate_from_lease/1`'s foreign-lease clause, and
  # only for a lease that already survived `lease_targets_passed_stage?/2` —
  # a lease pointing at a `passed` stage is historical and is dropped before
  # this code sees it, otherwise every router boot would re-emit drift for
  # leases the task has long moved past.
  #
  # SERVER-SIDE HALF OF A PAIR. Task 019fb949's stage 3 adds a
  # `git ls-remote origin 'task/<slug>*'` preflight to the dispatch prompt
  # renderers in `heartbeat_scheduler.ex` — the git-side half, which catches a
  # branch another agent already pushed. This is the server-side half: that
  # plan's reasoning says the platform cannot detect an occupied worktree
  # without a worktree registry, but it has one — `execution_leases.runtime_id`
  # names the runtime currently holding the stage. Neither half subsumes the
  # other (a lease exists before any branch does; a branch outlives its lease),
  # and each lives in the other ticket's file. Do not fold them together.
  #
  # IDEMPOTENCY IS THE STATE CHANGE, not a seen-set.
  # `abandon_current_lease_for_task/2` sets `status: "abandoned"` and
  # `expires_at: now`, while `current_lease_for_stage/2` and
  # `current_lease_for_task/1` both filter on `status in ~w(active blocked)`
  # AND `expires_at > now`. The next hydrate therefore finds no lease at all
  # and cannot reach this function a second time. A bookkeeping set would add
  # a second source of truth that a router restart wipes anyway.
  defp note_foreign_lease(
         %State{assignee: %{id: expected}} = state,
         %{runtime_id: actual} = lease
       )
       when is_binary(expected) and is_binary(actual) and expected != actual do
    Logger.warning(
      "[TaskRouter] task #{state.task_id} stage #{lease.stage_id} — assignee drift: " <>
        "lease held by runtime #{actual} but this router dispatches to #{expected} " <>
        "(phase #{lease.phase}); abandoning the foreign lease"
    )

    broadcast_router_event("execution.assignee_drift", state.task_id, lease.stage_id, %{
      "task_id" => state.task_id,
      "stage_id" => lease.stage_id,
      "expected_runtime_id" => expected,
      "actual_runtime_id" => actual,
      "phase" => lease.phase,
      "lease_id" => lease.id
    })

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Assignee drift detected on the #{lease.phase} phase: the live execution lease is " <>
          "held by runtime `#{actual}`, but this task's #{lease.phase} phase resolves to " <>
          "runtime `#{expected}`. Abandoning the foreign lease so the stage's liveness is " <>
          "no longer anchored to a runtime this task will not dispatch to."
      )
    end

    # The recoverability half: with no live lease, the wrong agent's next
    # `task_ack` / heartbeat has nothing to extend.
    RuntimeSupervision.abandon_current_lease_for_task(state.task_id, lease.phase)

    :ok
  end

  defp note_foreign_lease(_state, _lease), do: :ok

  defp lease_targets_passed_stage?(%{stage_id: nil}, _plan), do: false
  defp lease_targets_passed_stage?(_lease, nil), do: false

  defp lease_targets_passed_stage?(%{stage_id: stage_id}, plan) do
    case find_stage(plan, stage_id) do
      %{status: "passed"} -> true
      _ -> false
    end
  end

  defp maybe_hydrate_current_stage(%State{} = state) do
    plan = Tasks.current_plan(state.task_id)
    running_stage = current_running_stage(plan)

    maybe_set_stage(state, running_stage)
  end

  # Router-emitted alerts (`execution.no_ack_timeout`, `execution.safety_net_fired`)
  # are broadcast on `tasks:board` — which the router is subscribed to — so we
  # receive our own alerts back. They must NOT re-enter the state machine
  # (specifically, they must not `maybe_reset_stalled/1` and flip us out of
  # `:stalled` immediately after firing the no-ack alert). Explicit noop for
  # our own event types keeps the state machine hermetic.
  defp apply_runtime_event(state, %{event_type: "execution.no_ack_timeout"}), do: state
  defp apply_runtime_event(state, %{event_type: "execution.safety_net_fired"}), do: state

  # Same hermeticism, and load-bearing for task 019fb977 stage 3's stated
  # invariant. `note_foreign_lease/2` fires during `init/1`, AFTER
  # `Tasks.subscribe_board/0`, so the router receives its own drift alert one
  # message later. Without this clause the generic arm below would stamp
  # `last_runtime_event_at` from it — hydrating, by the back door, exactly the
  # liveness the foreign-lease clause deliberately refuses to hydrate.
  defp apply_runtime_event(state, %{event_type: "execution.assignee_drift"}), do: state

  defp apply_runtime_event(state, event) do
    event_time = event.occurred_at || DateTime.utc_now()
    lease_status = event.lease && event.lease.status

    base_state =
      state
      |> Map.put(:last_runtime_event_at, event_time)
      |> Map.put(:lease_status, lease_status || state.lease_status)
      |> maybe_reset_stalled()

    case event.event_type do
      "execution.acked" ->
        # `task_ack` MCP tool (stage 5) landed — extend the lease.
        # `LeaseManager.record_ack/1` clears the no-ack countdown and
        # extends the safety-net deadline; the next `:check_safety_net`
        # tick will see the extended deadline and reschedule accordingly.
        # Task 01a007bf stage 4: match on the return. Unlike the
        # tool_surface site, a `:not_found` HERE is not the dispatch race —
        # the durable ack already landed, so a missing ETS row means the
        # lease was cleared out from under an acked stage.
        case LeaseManager.record_ack(state.task_id) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Logger.warning(
              "[TaskRouter] task #{state.task_id} stage #{acked_stage_id(event, state)} — LeaseManager.record_ack/1 returned :not_found on execution.acked: ETS lease row missing for an acked stage — the lease was cleared between dispatch and ack. The no-ack countdown is no longer tracked for this stage; check for a stage transition or a LeaseManager restart in between."
            )
        end

        if still_awaiting_human?(base_state) do
          base_state
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
        else
          %{base_state | status: :running}
        end

      type
      when type in [
             "assignment.accepted",
             "execution.started",
             "execution.heartbeat",
             "execution.progress",
             "execution.unblocked"
           ] ->
        # Any runtime-liveness signal is progress — extends the safety-net
        # window so long-running stages don't false-alarm.
        _ = LeaseManager.record_progress(state.task_id)

        if still_awaiting_human?(base_state) do
          # A manual-review gate is still pending; runtime activity must not
          # flip us out of the suppressed state.
          base_state
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
        else
          %{base_state | status: :running}
        end

      "execution.blocked" ->
        # Stage-scoped blocker handling (task 019f6791). A blocker whose payload
        # names a different stage than the router's current stage must NOT flip
        # the state machine — it's a leftover from a prior stage (or from a
        # subagent that got its `stage_id` param wrong) and must not gate the
        # currently-running stage's dispatch/heartbeat. Legacy callers with no
        # payload stage_id fall through to today's behaviour so we don't regress
        # solo tools that never learned to include the field.
        if blocker_targets_current_stage?(event.payload, base_state.current_stage_id) do
          task = Tasks.get_task_detail(state.task_id)

          if base_state.execution_space_id && task do
            ExecutionSpace.post_log(
              base_state.execution_space_id,
              "Heartbeat suppressed: runtime reported blocker | " <>
                runtime_event_summary(event) <> " | " <> diagnostic_snapshot(base_state, task)
            )
          end

          base_state
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
        else
          blocked_stage_id =
            get_in(event.payload, ["stage_id"]) || get_in(event.payload, [:stage_id])

          Logger.info(
            "[TaskRouter] ignoring stale blocker on stage=#{inspect(blocked_stage_id)} (current=#{inspect(base_state.current_stage_id)}) for task=#{state.task_id}"
          )

          base_state
        end

      "execution.finished" ->
        if still_awaiting_human?(base_state) do
          base_state
          |> clear_liveness()
          |> Map.put(:status, :waiting_human)
        else
          base_state
          |> clear_liveness()
          |> Map.put(:status, :running)
        end

      type when type in ["execution.failed", "execution.abandoned", "assignment.rejected"] ->
        task = Tasks.get_task_detail(state.task_id)

        if base_state.execution_space_id && task do
          ExecutionSpace.post_log(
            base_state.execution_space_id,
            "Runtime failure detected | event=#{type} | " <>
              runtime_event_summary(event) <> " | " <> diagnostic_snapshot(base_state, task)
          )
        end

        base_state
        |> clear_liveness()
        |> Map.put(:status, :stalled)

      _ ->
        base_state
    end
  end

  defp maybe_log_heartbeat_suppressed(state, stage, opts \\ [])

  defp maybe_log_heartbeat_suppressed(%State{execution_space_id: nil}, _stage, _opts), do: :ok

  defp maybe_log_heartbeat_suppressed(%State{} = state, stage, opts) do
    # Predicate gate (task 019e00cb stage 2): when every pending validation on
    # this stage is a manual_approval already linked to an open review_request,
    # the suppression is "expected" and we don't post a per-dispatch log. The
    # review_request itself is the visible signal a human needs. Posting the
    # same "Dispatch suppressed" line on every dispatch was the message
    # pile-up Rowan reported.
    #
    # Some call sites pass `stage = nil` when `current_stage_id` is unset
    # (early dispatch, pre-stage_transitioned). Fall back to the running stage
    # in that case so the predicate has the data it needs.
    resolved_stage =
      stage ||
        state.task_id |> Tasks.current_plan() |> current_running_stage()

    if heartbeat_suppressible_for_task?(state.task_id, resolved_stage) do
      :ok
    else
      do_log_heartbeat_suppressed(state, stage, opts)
    end
  end

  defp do_log_heartbeat_suppressed(%State{} = state, stage, opts) do
    task = Tasks.get_task_detail(state.task_id)

    if task do
      reason = Keyword.get(opts, :reason, "manual_approval")

      message =
        case reason do
          "awaiting_plan_review" ->
            "Dispatch suppressed: plan is awaiting human review — approve or reject the plan to resume"

          # ADR-0046 member 5 stage 5. A THIRD string, not an edit to the two
          # above: `70fc30fe` deliberately made "awaiting_plan_review"
          # separately greppable from "awaiting_human_review" and shipped six
          # tests against the resulting copy. Both survive byte-identical.
          #
          # It must NOT tell the reader to approve or reject — no human action
          # is pending while the architect holds the slot — and it must name
          # the deadline, because "wait" without an end is indistinguishable
          # from "hung".
          "awaiting_architecture_review" ->
            "Dispatch suppressed: plan is with the architect for review — no human action needed yet; the architecture gate falls open on its own at " <>
              (Keyword.get(opts, :gate_deadline_at) || "its deadline") <>
              " and the plan proceeds from there"

          "awaiting_human_review" ->
            "Dispatch suppressed: awaiting human review on a manual_approval validation"

          _ ->
            "Heartbeat suppressed: waiting for manual approval before more agent work"
        end

      ExecutionSpace.post_log(
        state.execution_space_id,
        message <> " | " <> diagnostic_snapshot(state, task, stage_override: stage)
      )
    end
  end

  defp diagnostic_snapshot(%State{} = state, task, opts \\ []) do
    plan = Tasks.current_plan(state.task_id)

    stage =
      Keyword.get(opts, :stage_override) ||
        find_stage(plan, state.current_stage_id) || current_running_stage(plan) ||
        first_pending_stage(plan)

    phase = runtime_phase_for_task(task)
    lease = RuntimeSupervision.latest_lease_for_task(state.task_id, phase)

    [
      "task_status=#{task.status}",
      stage_diagnostic(stage),
      deploy_diagnostic(task, stage),
      validation_diagnostic(stage),
      lease_diagnostic(lease),
      liveness_diagnostic(state, stage)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" | ")
  end

  defp runtime_event_summary(event) do
    payload = event.payload || %{}

    [
      payload["description"] || payload[:description],
      payload["error"] || payload[:error],
      payload["summary"] || payload[:summary],
      payload["block_reason"] || payload[:block_reason]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
    |> case do
      "" -> "no extra runtime details"
      details -> details
    end
  end

  defp stage_diagnostic(nil), do: "stage=unknown"

  defp stage_diagnostic(stage) do
    "stage=#{stage.name || "unknown"}(#{stage.id}) status=#{stage.status}"
  end

  defp validation_diagnostic(nil), do: "validations=unknown"

  defp validation_diagnostic(stage) do
    validations = stage_validations(stage)

    cond do
      validations == [] ->
        "validations=none"

      true ->
        pending =
          validations
          |> Enum.filter(&(&1.status in ["pending", "running", "failed"]))
          |> Enum.map_join(", ", fn validation ->
            "#{validation.kind}:#{validation.status}"
          end)

        if pending == "", do: "pending_validations=none", else: "pending_validations=#{pending}"
    end
  end

  defp deploy_diagnostic(task, stage) do
    name = String.downcase((stage && stage.name) || task.title || "")
    requested = task.deploy_target
    targets = available_deploy_targets(task)

    cond do
      not String.contains?(name, "deploy") and is_nil(requested) and targets == [] ->
        nil

      is_nil(requested) and targets == [] ->
        "deploy_target=missing(task.deploy_target unset; project has no deploy_targets)"

      is_nil(requested) ->
        "deploy_target=unresolved(task.deploy_target unset; available=#{Enum.join(targets, ",")})"

      match?(%{project: %{}}, task) ->
        case DeployResolver.resolve(task.project, requested) do
          {:ok, _target} ->
            "deploy_target=#{requested}"

          {:error, reason} ->
            "deploy_target=unresolved(requested=#{requested}; error=#{inspect(reason)}; available=#{Enum.join(targets, ",")})"
        end

      true ->
        "deploy_target=#{requested}"
    end
  end

  defp available_deploy_targets(task) do
    deploy_config =
      case task.project do
        %{deploy_config: config} when is_map(config) -> config
        _ -> %{}
      end

    case Map.get(deploy_config, "deploy_targets") || Map.get(deploy_config, :deploy_targets) do
      targets when is_list(targets) ->
        # MATCH ON THE SHAPE FIRST. This was `target["name"] || inspect(target)`,
        # whose `||` branch was clearly written for a target that is not a map —
        # and could never run, because `target["name"]` is `Access.get/3` and
        # binaries do not implement Access. A project whose deploy_targets are
        # plain strings (`["staging"]` rather than `[%{"name" => "staging"}]`)
        # therefore raised FunctionClauseError instead of falling back.
        #
        # That mattered far out of proportion to the line. This runs inside
        # do_log_heartbeat_suppressed/3 — a DIAGNOSTIC path, reached only for a
        # task whose dispatch is suppressed — so the crash killed that task's
        # TaskRouter, and with it every other task's router in the same
        # supervision tree. One project with string-shaped deploy_targets plus
        # one task awaiting plan review cycled the whole orchestration layer:
        # restart, re-dispatch everything, crash, repeat. Observed 2026-08-17.
        #
        # A function that only builds a log line must never be able to take the
        # process down; the fallback is now reachable for exactly the input it
        # was written for.
        Enum.map(targets, fn
          target when is_map(target) -> target["name"] || inspect(target)
          target -> inspect(target)
        end)

      _ ->
        []
    end
  end

  defp lease_diagnostic(nil), do: "lease=none"

  defp lease_diagnostic(lease) do
    worker = if lease.runtime_worker_ref, do: " worker=#{lease.runtime_worker_ref}", else: ""

    reason =
      if lease.block_reason do
        " reason=#{lease.block_reason}"
      else
        ""
      end

    expires =
      case lease.expires_at do
        %DateTime{} = expires_at -> " expires_at=#{DateTime.to_iso8601(expires_at)}"
        _ -> ""
      end

    "lease=#{lease.status}#{worker}#{reason}#{expires}"
  end

  defp liveness_diagnostic(%State{} = state, stage) do
    cond do
      manual_approval_stage?(stage) and pending_review_request?(state.task_id) ->
        "liveness=suppressed_waiting_human"

      pending_review_request?(state.task_id) ->
        "liveness=awaiting_human_review"

      state.status == :waiting_human ->
        "liveness=waiting_human"

      true ->
        case LeaseManager.get(state.task_id) do
          nil ->
            "liveness=#{state.status}"

          lease ->
            ack = if lease.ack_at, do: "acked", else: "unacked"

            "liveness=#{state.status}:#{ack}:no_ack_fired=#{lease.no_ack_fired?}:safety_net_fired=#{lease.safety_net_fired?}"
        end
    end
  end

  defp manual_approval_stage?(nil), do: false

  defp manual_approval_stage?(stage) do
    pending_validations =
      stage_validations(stage)
      |> Enum.filter(&(&1.status == "pending"))

    pending_validations != [] &&
      Enum.all?(pending_validations, &(&1.kind == "manual_approval"))
  end

  defp stage_validations(nil), do: []

  defp stage_validations(stage) do
    case Map.get(stage, :validations) do
      validations when is_list(validations) -> validations
      %Ecto.Association.NotLoaded{} -> Tasks.list_validations(stage.id)
      _ -> []
    end
  end

  # A stage is the task-level review gate when it hosts at least one
  # `e2e_behavior` validation. Deliberately structural rather than a name match
  # on "Task-level review": `PlanEngine.attach_e2e_validations_to_review_stage/2`
  # REUSES a planner-authored stage whose name merely contains "review" or
  # "validation", so a name-equality check would miss every reused-stage plan.
  defp review_gate_stage?(stage) do
    stage
    |> stage_validations()
    |> Enum.any?(fn validation -> Map.get(validation, :kind) == "e2e_behavior" end)
  end

  # Move the task to `in_review` when its review gate starts running. Guarded on
  # `in_progress` so a re-broadcast for the same stage, or a task already past
  # the gate, is a no-op. Never crashes the router: a rejected transition is
  # logged and execution continues (the stage still dispatches, just with the
  # implementation prompt — the pre-change behaviour).
  defp maybe_enter_in_review(task_id, stage) do
    with true <- review_gate_stage?(stage),
         %{status: "in_progress"} = task <- Tasks.get_task_detail(task_id) do
      case Tasks.transition_task(task, "in_review") do
        {:ok, _updated} ->
          Logger.info(
            "[TaskRouter] review gate stage #{stage.id} running — task #{task_id} moved to in_review"
          )

        {:error, reason} ->
          Logger.warning(
            "[TaskRouter] failed to move task #{task_id} to in_review at the review gate: #{inspect(reason)}"
          )
      end
    else
      _ -> :ok
    end
  end

  defp runtime_phase_for_task(%{status: "planning"}), do: "planning"
  defp runtime_phase_for_task(%{status: "in_review"}), do: "review"
  defp runtime_phase_for_task(%{status: "deploying"}), do: "deploying"
  defp runtime_phase_for_task(_task), do: "execution"

  # ── Stage helpers ──────────────────────────────────────────────────────

  defp maybe_set_stage(state, nil), do: state

  defp maybe_set_stage(state, stage) do
    %{
      state
      | current_stage_id: stage.id,
        stage_started_at: stage.started_at || DateTime.utc_now()
    }
  end

  defp ensure_execution_stage_started(state, task_id) do
    task = Tasks.get_task_detail(task_id)
    plan = Tasks.current_plan(task_id)

    cond do
      task == nil or task.status != "in_progress" or is_nil(plan) ->
        state

      running_stage = current_running_stage(plan) ->
        send(self(), :dispatch)
        maybe_set_stage(state, running_stage)

      pending_stage = first_pending_stage(plan) ->
        case Platform.Tasks.PlanEngine.start_stage(pending_stage.id) do
          {:ok, started_stage} ->
            maybe_set_stage(state, started_stage)

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to start first execution stage for task #{task_id}: #{inspect(reason)}"
            )

            state
        end

      true ->
        send(self(), :dispatch)
        state
    end
  end

  defp current_running_stage(nil), do: nil

  defp current_running_stage(plan) do
    (plan.stages || [])
    |> Enum.find(&(&1.status == "running"))
  end

  # ── Pre-plan design hold (ADR-0046 member 7 stage 5) ───────────────────
  #
  # ## How the hold cannot outlive its holder
  #
  # The holder is this router process. The hold is NOT persisted anywhere: it
  # is a router status plus a `Process.send_after/3` reference, both of which
  # die with the process. Everything that decides whether to hold is re-derived
  # from the task row on every dispatch tick. So:
  #
  #   * Router dies mid-hold -> the hold dies with it. The next boot runs
  #     `init/1` -> `send(self(), :dispatch)` -> this same level check, which
  #     either re-holds (step genuinely still open) or dispatches. This is the
  #     precise failure mode journalled on 2026-07-26, where `deploying -> done`
  #     lived solely in an edge-triggered PubSub handler with no level re-check
  #     and a container restart between the broadcast and the handler stranded
  #     the task indefinitely. There is no equivalent here because there is no
  #     edge to miss.
  #   * Timer lost, cancelled, or never armed -> `design_hold_expired?/2` still
  #     reads `true` on the next tick and expires the step inline. The timer is
  #     an optimisation for the case where nothing else pokes the router.
  #   * Expiry write itself fails -> `handle_design_hold/2` falls through to
  #     `do_dispatch/2` REGARDLESS of what `expire/2` returned. Stage 2's
  #     posture for this whole member is that design fails open in every
  #     direction; a persistence fault must not be the one thing that blocks.
  #
  # The deadline is derived from `task.updated_at`, not from a wall clock
  # captured when the hold began, so a restart does not reset it: two routers
  # reading the same row at the same instant reach the same verdict.

  # The hold predicate. `task.planning_step` IS the state — `PreplanStep.open?/1`
  # reads the same field, so there is no second source of truth to drift.
  #
  # The plan check is NOT redundant with the cursor. The stage brief defined
  # this predicate as status + cursor only, and separately demanded a guard that
  # "a task already carrying a plan is never held, even with the cursor at
  # designing". Those contradict: with status + cursor alone, such a task IS
  # held. Resolved in favour of the guard, which is protecting the real
  # property — a re-planning or executing task must never be stranded behind a
  # stale cursor. It also makes the hold a strict subset of the start-site
  # condition, so the router only ever holds where it would also have re-run
  # `PreplanStep.start/1`.
  defp design_step_open?(nil), do: false

  defp design_step_open?(task) do
    Map.get(task, :status) == "planning" and
      Map.get(task, :planning_step) == "designing" and
      Tasks.latest_plan(task.id) == nil
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # THE HOLD PREDICATE, and it is a disjunction for a reason.
  #
  #   * A run this router started is still in flight — the authoritative half.
  #     It covers the window between spawning the runner and the cursor
  #     reaching `"designing"`, which the cursor alone cannot see: the fire
  #     happens in another process now, so a cursor-only hold would dispatch
  #     the planner straight into the step this branch waits for.
  #   * The cursor says `"designing"` with no run in flight — the RESTART
  #     half, and the same level check the pre-migration hold used. The hold
  #     must be re-derivable from the row by a process that was not there when
  #     it began.
  defp design_hold?(%State{design_run: {_pid, _ref}}, _task), do: true
  defp design_hold?(%State{}, task), do: design_step_open?(task)

  defp hold_for_design(state, task) do
    # Edge-triggered narration only — one line per hold episode, not one per
    # tick. Deliberately a plain `Logger.info` rather than
    # `maybe_log_heartbeat_suppressed/3`: that helper's reason table is the
    # human-review vocabulary, and a design hold is a machine gate.
    if state.status != :waiting_design do
      Logger.info(
        "[TaskRouter] suppressed planner dispatch for task=#{state.task_id}: " <>
          "pre-plan design step open (planning_step=designing)"
      )
    end

    state =
      state
      |> Map.put(:task_status, task.status)
      |> Map.put(:status, :waiting_design)

    # NOT optional, and gated on the CURSOR rather than on the hold. Leaving
    # the ack timer armed would fire `execution.no_ack_timeout` five minutes
    # into a LEGITIMATELY held design step — the same liveness-signal
    # miscalibration journalled for screenshot-driven UI stages, where the
    # router alerted on a stage that was working exactly as designed.
    #
    # The gate is what keeps this specific to a real hold. A task whose design
    # step will resolve to `not_applicable` passes through `design_hold?/2`
    # for as long as its runner takes to answer, and clearing the lease of a
    # task that was never held would make the clear a property of the tick
    # rather than of the hold.
    state = if design_step_open?(task), do: clear_liveness(state), else: state

    {:noreply, state}
  end

  # ── the designer lifecycle edge (task 019fe1b7 stage 2) ────────────────
  #
  # The router owns exactly two things now: WHEN the edge fires, and whether
  # to hold while it runs. Ordering, settlement, both budgets and the run rows
  # belong to `Platform.Lifecycle.Executor`.
  #
  # SPAWNED and MONITORED, never inline: the executor blocks its caller while
  # awaiting an async step, and this router is the dispatcher for every agent
  # in flight on this task — a thirty-minute block here would stall acks,
  # safety nets and stage transitions. Monitored rather than linked so a
  # runner crash releases the planner instead of killing the dispatcher.

  # AT MOST ONE DESIGNER EDGE RUN PER ROUTER PROCESS, and the flag is the
  # load-bearing half of that — not the window, and not the re-entry bound.
  #
  # The bound counts PERSISTED RUN ROWS, so it cannot see a run that died
  # before the executor wrote one. A runner that crashes early (the registry
  # is down, the node is out of memory) leaves the window as it found it, and
  # a window-only guard re-fires on the release the crash itself triggered: an
  # unbounded dispatch loop at the speed of process spawning. Measured, not
  # hypothesised — it is what this stage's first router-suite run did.
  #
  # A restart is still covered: the flag dies with the process. The
  # recorded-outcome conjunct in `design_edge_window?/1` is the second,
  # independent guard, and it is what stops a REPLACEMENT router re-firing an
  # edge whose outcome is already on the task.
  defp maybe_run_design_edge(%State{design_run: {_pid, _ref}} = state, _task), do: state

  defp maybe_run_design_edge(%State{design_edge_ran?: true} = state, _task), do: state

  defp maybe_run_design_edge(%State{} = state, task) do
    if design_edge_window?(task) do
      router = self()
      {pid, ref} = spawn_monitor(fn -> run_design_edge(router, task) end)
      %{state | design_run: {pid, ref}, design_edge_ran?: true}
    else
      state
    end
  end

  # The pre-plan window: `planning`, no plan of any status yet, and no design
  # outcome already recorded. A strict subset of the old start-site condition
  # — `PreplanStep.start/1` is still idempotent on both cursor and outcome, so
  # the extra conjunct costs nothing and buys the bound above.
  defp design_edge_window?(nil), do: false

  defp design_edge_window?(task) do
    Map.get(task, :status) == "planning" and
      not design_outcome_recorded?(task) and
      Tasks.latest_plan(task.id) == nil
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp design_outcome_recorded?(task) do
    case Map.get(task, :planning_step_outcomes) do
      %{"design" => _entry} -> true
      _ -> false
    end
  end

  # Runs in the spawned process. Two jobs, in order.
  defp run_design_edge(router, task) do
    edge = Edges.designer_edge()

    {outcome, _summary} =
      Executor.run_edge(task, edge,
        steps: Edges.default_steps(edge),
        step_timeout_ms: Lifecycle.step_timeout_ms(),
        edge_budget_ms: Lifecycle.edge_budget_ms()
      )

    # DESIGN FAILS OPEN IN EVERY DIRECTION — the posture this member inherited
    # and the one thing that must not change. The executor bounds the WAIT,
    # but a bounded wait still leaves the cursor at `"designing"`, and a task
    # stuck there is held forever by the restart half of `design_hold?/2`. So
    # whatever the edge answered, a step still open when the edge is over is
    # expired here.
    #
    # This is where `expire_design_step/1` went: the same `PreplanStep.expire/2`
    # call, off the dispatch tick and onto the process that knows the edge is
    # over, now covering `:suppressed` and `:diverted` as well as the timeout.
    close_open_step(task.id)

    send(router, {:design_edge_settled, self(), outcome})
  end

  defp close_open_step(task_id) do
    case Tasks.get_task_detail(task_id) do
      nil ->
        :ok

      task ->
        if PreplanStep.open?(task) do
          PreplanStep.expire(task, Lifecycle.step_timeout_ms())
        end
    end
  rescue
    e ->
      Logger.warning("[TaskRouter] design edge close raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[TaskRouter] design edge close exited: #{inspect(reason)}")
      :ok
  end

  # TAIL-stall fix (2026-07-22), direction (3): a settled stack member has an
  # approved plan with NO running stage and NO open (pending/running)
  # validation — nothing an executor could ack or act on. Only stack members
  # are eligible for suppression (the incident was a stack-tail deadlock);
  # non-stack tasks always fall through to normal dispatch. Requires a
  # non-nil current plan so a planning-phase member (no approved plan yet)
  # is never suppressed — it still needs a dispatch to author its plan.
  # Best-effort: any lookup error yields `false` (never suppress on error).
  defp settled_stack_member_no_work?(task, task_id) do
    if is_binary(Map.get(task, :stack_id)) do
      case Tasks.current_plan(task_id) do
        nil -> false
        plan -> current_running_stage(plan) == nil and not any_open_validation?(plan)
      end
    else
      false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Task 019fbe9e stage 4 — the safety-net suppression predicate.
  #
  # Deliberately NOT `settled_stack_member_no_work?/2` and deliberately not a
  # second copy of `any_open_validation?/1`. It shares the "nothing open"
  # half with the dispatch-suppression clause and drops the `stack_id` half:
  # a false safety-net alert on a settled plan is equally wrong for a solo
  # task, whereas WITHHOLDING A DISPATCH from a solo task would strand it.
  # Different blast radius, so the stack guard stays where it is.
  #
  # Best-effort in the same shape as its sibling: any lookup failure yields
  # `false`, i.e. fire the alert. A safety net that goes quiet when it cannot
  # read the plan is worse than one that cries wolf.
  defp plan_settled_no_open_work?(task_id) do
    case Tasks.current_plan(task_id) do
      nil -> false
      plan -> current_running_stage(plan) == nil and not any_open_validation?(plan)
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Task 01a01a4a stage 2 — the human-gate suppression predicate.
  #
  # Returns `{:ok, pending_kinds}` when every open validation on the CURRENTLY
  # RUNNING stage is one an agent is structurally unable to pass, and `nil`
  # otherwise. `nil` means "fire the alert" — the same polarity its sibling
  # `plan_settled_no_open_work?/1` uses for its own false.
  #
  # Scoped to the running stage on purpose, which is where it diverges from
  # `any_open_validation?/1`: a `pr_merged` left pending on some LATER stage
  # says nothing about whether the stage we are timing is parked on a human.
  #
  # Best-effort in the same shape as its siblings: any lookup failure yields
  # `nil`, i.e. fire the alert. A safety net that goes quiet when it cannot
  # read the plan is worse than one that cries wolf.
  defp awaiting_human_gate(task_id) do
    with plan when not is_nil(plan) <- Tasks.current_plan(task_id),
         %Stage{} = stage <- current_running_stage(plan),
         task when not is_nil(task) <- Tasks.get_task_record(task_id) do
      pending_kinds = open_validation_kinds(stage)
      strategy = Tasks.resolve_deploy_strategy(task)

      if DispatchPhase.human_gated_pending?(pending_kinds, strategy || %{}) do
        {:ok, pending_kinds}
      else
        nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The `kind`s of the stage's own open validations. Shares the flat-map
  # shape of `any_open_validation?/1` and none of its plan-wide scope.
  defp open_validation_kinds(stage) do
    case stage.validations do
      vs when is_list(vs) -> vs
      _ -> []
    end
    |> Enum.filter(&(&1.status in ["pending", "running"]))
    |> Enum.map(& &1.kind)
  end

  # The suppressed counterpart of `fire_safety_net_alert/2`. Everything that
  # accuses somebody is removed: no `execution.safety_net_fired`, no
  # `needs_human => true` blocker, and above all no `stamp_blocked_reason/2`
  # — that helper routes through `Tasks.ensure_blocked/1`, which is the exact
  # line that dropped a parked task into `blocked`. The task stays `deploying`.
  defp note_awaiting_human_action(%State{} = state, lease, pending_kinds) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), lease.dispatched_at, :millisecond)

    Logger.info(
      "[TaskRouter] task #{state.task_id} stage #{lease.stage_id} (#{lease.stage_kind}) — " <>
        "safety-net window elapsed after #{div(elapsed_ms, 60_000)}m, but the only open " <>
        "validation(s) #{inspect(pending_kinds)} require a human; emitting " <>
        "execution.awaiting_human_action instead of execution.safety_net_fired"
    )

    broadcast_router_event("execution.awaiting_human_action", state.task_id, lease.stage_id, %{
      task_id: state.task_id,
      stage_id: lease.stage_id,
      stage_kind: lease.stage_kind,
      elapsed_ms: elapsed_ms,
      pending_kinds: pending_kinds,
      gate: "pr_merge_auto_merge_false"
    })

    stamp_awaiting_human_action(state.task_id)

    post_router_notice(
      state,
      "Waiting on a human merge — the deploy PR is open and correct; the outstanding " <>
        "validation (#{Enum.join(pending_kinds, ", ")}) can only pass when a person merges. " <>
        "Nothing is stuck.",
      %{
        "reason" => "execution.awaiting_human_action",
        "stage_id" => lease.stage_id,
        "stage_kind" => lease.stage_kind,
        "needs_human" => false,
        "pending_kinds" => pending_kinds,
        "elapsed_ms" => elapsed_ms
      }
    )
  end

  # Durable per-task home for the park, with NO status transition. Failure
  # path in the same shape as `stamp_blocked_reason/2`: log and continue.
  defp stamp_awaiting_human_action(task_id) do
    case Tasks.stamp_awaiting_human_action(task_id, "merge") do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[TaskRouter] task #{task_id} — could not stamp awaiting_human_action: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[TaskRouter] task #{task_id} — awaiting_human_action stamp raised: #{Exception.message(error)}"
      )

      :ok
  end

  defp any_open_validation?(nil), do: false

  defp any_open_validation?(plan) do
    (plan.stages || [])
    |> Enum.flat_map(fn stage ->
      case stage.validations do
        vs when is_list(vs) -> vs
        _ -> []
      end
    end)
    |> Enum.any?(&(&1.status in ["pending", "running"]))
  end

  # Re-dispatch storm guard (task 019fa2fc stage 4). The current plan is
  # `completed` and holds no running stage — terminal by construction, so a
  # prompt here can only be the stale re-dispatch the 2026-07-27 incident
  # logged. See the clause in `handle_info(:dispatch, ...)` for why the
  # `completed` plan status (rather than the weaker "nothing open" shape) is
  # the load-bearing half of this predicate.
  #
  # Best-effort, mirroring `settled_stack_member_no_work?/2`: any lookup error
  # yields `false`. A predicate that raises must never take down dispatch —
  # failing open costs one redundant prompt, failing closed costs a stalled
  # task.
  defp completed_plan_no_work?(task_id) do
    case Tasks.current_plan(task_id) do
      %Plan{status: "completed"} = plan -> current_running_stage(plan) == nil
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Reason is supplied by the call site rather than re-derived here, so the
  # metadata says WHICH guard fired. Event name and the `%{task_id:, reason:}`
  # metadata shape are unchanged from the single-reason version — existing
  # dashboards keep working, they just see a second `reason` value.
  defp emit_dispatch_suppressed_telemetry(task_id, reason) do
    :telemetry.execute(
      [:platform, :orchestration, :dispatch_suppressed],
      %{count: 1},
      %{task_id: task_id, reason: reason}
    )

    :ok
  end

  # Task 019fbe9e stage 3. True only for the stranded shape: a current plan
  # with no running stage and at least one pending stage. Rescues to `false`
  # like its sibling predicates — a failing lookup must not open a stage.
  defp stage_needs_opening?(task_id) do
    case Tasks.current_plan(task_id) do
      nil -> false
      plan -> current_running_stage(plan) == nil and first_pending_stage(plan) != nil
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp first_pending_stage(nil), do: nil

  # Returns the LOWEST-position pending stage, not whatever Ecto's preload
  # happened to surface first. `Platform.Tasks.Plan` declares
  # `has_many(:stages, …)` without a default preload order, so preloaded
  # stages come back in incidental DB order — usually insertion order, but
  # plan_create can insert out of position when stages are written
  # individually. Without the sort here the engine would dispatch a higher-
  # position stage while lower-position ones are still pending (observed on
  # task 019edb16: engine dispatched stage 3, then 4, while 1 and 2 stayed
  # `pending`). Sorting explicitly makes the dispatch order deterministic
  # regardless of how the stages were preloaded.
  defp first_pending_stage(plan) do
    (plan.stages || [])
    |> Enum.sort_by(& &1.position)
    |> Enum.find(&(&1.status == "pending"))
  end

  defp waiting_for_human_review?(%State{task_id: task_id} = state) do
    (current_stage_type(state) == "manual_approval" and pending_review_request?(task_id)) or
      manual_approval_gate_pending?(task_id)
  end

  # True when the task has a pending review_request whose validation belongs to
  # the currently-running stage — even if that stage's *type* (per
  # `current_stage_type/1`) is "coding"/"review"/etc. This covers the case
  # where a code stage carries a manual_approval validation alongside
  # automated checks: as soon as a review request is open, the agent must be
  # paused regardless of whether the dominant stage type is "manual_approval".
  defp manual_approval_gate_pending?(task_id) do
    pending = ReviewRequests.list_pending_for_task(task_id)

    case pending do
      [] ->
        false

      requests ->
        plan = Tasks.current_plan(task_id)
        stage = current_running_stage(plan)

        cond do
          # Anything pending against this task is a gate.
          stage == nil -> true
          true -> Enum.any?(requests, &review_request_attached_to_stage?(&1, stage))
        end
    end
  end

  defp review_request_attached_to_stage?(request, stage) do
    validation_id = Map.get(request, :validation_id)
    stage_validations = stage_validations(stage)

    Enum.any?(stage_validations, &(&1.id == validation_id))
  end

  defp still_awaiting_human?(%State{task_id: task_id}) do
    pending_review_request?(task_id)
  end

  # Plan-level "human is sitting with the latest plan" check. Distinct from
  # `waiting_for_human_review?/1`, which is stage-level (manual_approval stage
  # within an approved plan).
  defp plan_awaiting_review?(task_id) do
    case Tasks.latest_plan(task_id) do
      %{status: "pending_review"} -> true
      _ -> false
    end
  end

  defp pending_review_request?(task_id) do
    ReviewRequests.list_pending_for_task(task_id) != []
  end

  # ── ADR-0046 member 5 stage 5: who is holding the plan slot ───────────
  #
  # NO SECOND HOLD MECHANISM. A gated plan simply stays `pending_review`,
  # which is exactly the condition `plan_awaiting_review?/1` above already
  # suppresses across all ~13 dispatch injectors. This pair of helpers only
  # answers "who is the occupant" — for the copy and for the deadline — and
  # never decides whether to suppress.
  #
  # Three answers, and the third one is the whole reason this is a `case` and
  # not a boolean:
  #
  #   * `{:open, plan_id, verdict}` — the architect genuinely holds the slot.
  #   * `{:overdue, plan_id}` — the PERSISTED row still says `"pending"` but
  #     the deadline has passed. `architecture_gate/1` has already stopped
  #     blocking on it, but nobody wrote the verdict or ran the deferred
  #     `settle_plan_submission/1` tail.
  #   * `nil` — no gate, or one already resolved in the row.
  #
  # THE `:overdue` CASE IS THE LEVEL RE-CHECK ON REHYDRATE, and it is not
  # theoretical. Without it a router that reboots AFTER the deadline (the
  # `TaskRouterWatcher` restarts routers on every runtime reconnect and every
  # 5-minute reconcile, so reboots are the norm) would arm no timer at all and
  # park — leaving a plan whose gate fell open sitting at `pending_review`
  # forever, waiting on a human, with a `"pending"` verdict nobody will ever
  # close. That is precisely the `deploying -> done` incident shape the
  # 2026-07-26 journal records, and "add a level-triggered re-check on
  # init/rehydrate" is the fix it recommends. It is applied here at the one
  # point where the same shape could recur.
  #
  # `Tasks.latest_plan/1` is a fresh query, so the `"pending"` match is on the
  # persisted row and not on a struct somebody loaded earlier; the
  # `architecture_gate/1` call re-reads again and owns the expiry rule, so
  # "when is it overdue" is defined in exactly one place.
  defp architecture_gate_occupancy(task_id) do
    case Tasks.latest_plan(task_id) do
      %{architecture_verdict: %{"state" => "pending"}} = plan ->
        case Tasks.architecture_gate(plan) do
          {:open, verdict} -> {:open, plan.id, verdict}
          _past_deadline -> {:overdue, plan.id}
        end

      _no_open_gate ->
        nil
    end
  end

  # An overdue gate takes the HUMAN copy, not the architect's: its window has
  # closed, `approve_plan/3` no longer refuses, and telling a reader to keep
  # waiting on an architect who is out of time would be false.
  defp plan_gate_log_opts({:open, _plan_id, verdict}) do
    [reason: "awaiting_architecture_review", gate_deadline_at: verdict["deadline_at"]]
  end

  defp plan_gate_log_opts(_not_open), do: [reason: "awaiting_plan_review"]

  defp arm_architecture_gate_deadline(%State{} = state, nil), do: state

  defp arm_architecture_gate_deadline(%State{} = state, occupancy) do
    _ = cancel_architecture_gate_deadline(state.architecture_deadline_ref)

    {plan_id, delay_ms} =
      case occupancy do
        {:open, plan_id, verdict} -> {plan_id, architecture_gate_remaining_ms(verdict)}
        # Already past due — settle it now, through the SAME one message, so
        # there is a single path from "the deadline is up" to "the gate is
        # closed and the deferred tail has run".
        {:overdue, plan_id} -> {plan_id, 0}
      end

    ref = Process.send_after(self(), {:architecture_gate_deadline, plan_id}, delay_ms)

    %{state | architecture_deadline_ref: ref}
  end

  defp cancel_architecture_gate_deadline(nil), do: :ok

  defp cancel_architecture_gate_deadline(ref) when is_reference(ref),
    do: Process.cancel_timer(ref)

  # From the PERSISTED `deadline_at` minus now, clamped at 0 — NEVER a fresh
  # window. `TaskRouterWatcher` restarts routers on every runtime reconnect
  # and every 5-minute reconcile, so a full window here would let a restart
  # loop renew the deadline indefinitely: the same defect shape as a lease
  # that re-arms on every touch. Because the delay is a pure function of a row
  # nobody rewrites, re-arming N times can only ever shorten it.
  defp architecture_gate_remaining_ms(%{"deadline_at" => deadline}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, at, _offset} -> at |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0)
      {:error, _reason} -> 0
    end
  end

  defp architecture_gate_remaining_ms(_verdict), do: 0

  defp heartbeat_suppressible_for_task?(_task_id, nil), do: false

  defp heartbeat_suppressible_for_task?(task_id, stage) do
    pending_requests = ReviewRequests.list_pending_for_task(task_id)
    HeartbeatScheduler.heartbeat_suppressible?(stage, pending_requests)
  end

  defp current_stage_type(%State{current_stage_id: nil}), do: "coding"

  defp current_stage_type(%State{task_id: task_id, current_stage_id: stage_id}) do
    plan = Tasks.current_plan(task_id)
    stage = find_stage(plan, stage_id)

    if stage do
      # Check if all remaining (pending) validations on this stage are manual_approval.
      # If so, treat the stage as a human gate — no liveness timers should fire.
      #
      # `e2e_behavior` is intentionally NOT included here: it is agent-driven
      # (review agent executes the script and dispositions), so dispatch must
      # not be suppressed. Stages whose only pending validation is
      # `e2e_behavior` fall through to `infer_stage_type/1` and are treated as
      # a normal "review" stage for liveness purposes.
      pending_validations =
        (stage.validations || [])
        |> Enum.filter(&(&1.status == "pending"))

      if pending_validations != [] &&
           Enum.all?(pending_validations, &(&1.kind == "manual_approval")) do
        "manual_approval"
      else
        infer_stage_type(stage.name)
      end
    else
      "coding"
    end
  end

  # Map human-readable stage names to stage-kind keys used by
  # `LeaseManager.stage_kind_timeouts/0`. Falls back to "coding" for
  # unrecognized names.
  defp infer_stage_type(name) do
    name_lower = String.downcase(name || "")

    cond do
      String.contains?(name_lower, "planning") -> "planning"
      String.contains?(name_lower, "review") -> "review"
      String.contains?(name_lower, "deploy") -> "deploying"
      String.contains?(name_lower, "ci") -> "ci_check"
      String.contains?(name_lower, "manual_approval") -> "manual_approval"
      true -> "coding"
    end
  end

  defp find_stage(nil, _stage_id), do: nil

  defp find_stage(plan, stage_id) do
    Enum.find(plan.stages || [], &(&1.id == stage_id))
  end

  # ── Deploy credential leasing ──────────────────────────────────────────

  # Deploy stall threshold — 15 minutes TTL for deploy leases
  @deploy_lease_ttl_seconds 900

  defp maybe_lease_deploy_credentials(%State{deploy_lease: existing} = state, _task, _stage)
       when not is_nil(existing) do
    # Already have an active lease — check validity
    if CredentialLease.valid?(existing) do
      state
    else
      # Lease expired — try to re-lease
      %{state | deploy_lease: nil}
      |> maybe_lease_deploy_credentials(Tasks.get_task_detail(state.task_id), nil)
    end
  end

  defp maybe_lease_deploy_credentials(%State{} = state, task, stage) do
    if deploy_stage?(stage) do
      lease_deploy_credentials(state, task, stage)
    else
      state
    end
  end

  defp lease_deploy_credentials(%State{} = state, task, stage) do
    task = Tasks.ensure_project_loaded(task)
    project = task.project

    if project do
      strategy = Tasks.resolve_deploy_strategy(task)
      target_name = get_in(strategy, ["config", "target"])

      if target_name do
        run_id = "#{state.task_id}:#{stage && stage.id}"

        case DeployResolver.resolve(project, target_name) do
          {:ok, target} ->
            case DeployResolver.lease_for_target(target, run_id, ttl: @deploy_lease_ttl_seconds) do
              {:ok, lease} ->
                Logger.info(
                  "[TaskRouter] leased deploy credentials for task #{state.task_id}, " <>
                    "target: #{target_name}, TTL: #{@deploy_lease_ttl_seconds}s"
                )

                if state.execution_space_id do
                  ExecutionSpace.post_log(
                    state.execution_space_id,
                    "Deploy credentials leased for target '#{target_name}' (TTL: #{div(@deploy_lease_ttl_seconds, 60)}min)"
                  )
                end

                %{state | deploy_lease: lease}

              {:error, reason} ->
                Logger.warning(
                  "[TaskRouter] failed to lease deploy credentials for task #{state.task_id}: #{inspect(reason)}"
                )

                state
            end

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to resolve deploy target '#{target_name}' for task #{state.task_id}: #{inspect(reason)}"
            )

            state
        end
      else
        # No target configured — deploy without credentials (agent uses its own)
        state
      end
    else
      state
    end
  end

  defp revoke_deploy_lease(%State{deploy_lease: nil} = state), do: state

  defp revoke_deploy_lease(%State{deploy_lease: lease} = state) do
    case CredentialLease.revoke(lease) do
      {:ok, _revoked} ->
        Logger.info("[TaskRouter] revoked deploy lease #{lease.id} for task #{state.task_id}")

        if state.execution_space_id do
          ExecutionSpace.post_log(
            state.execution_space_id,
            "Deploy credentials revoked (lease #{lease.id})"
          )
        end

      _ ->
        :ok
    end

    %{state | deploy_lease: nil}
  end

  defp deploy_stage?(nil), do: false

  defp deploy_stage?(stage) do
    name = String.downcase(stage.name || "")
    String.starts_with?(name, "deploy:")
  end

  # `deploy_stage_settled?/1`, `unsettled_deploy_statuses/1` and
  # `deploy_stages/1` used to live here. They moved to
  # `Platform.Tasks.PlanCompletion` (task 019fa2fc stage 1) with the deploy
  # guard they exist to serve. The router-private `deploy_stage?/1` above stays
  # — `maybe_lease_deploy_credentials/3` still uses it.

  # ── Deploy failure handling ────────────────────────────────────────────

  # ── Bounded review loop (task 019ff788 stage 3) ───────────────────────────
  #
  # Returns `:bounced` (task is back at `in_progress`) or `:replanned` (the
  # bound is exhausted; the plan is superseded and the task is at
  # `planning`). The caller uses the distinction to decide whether to
  # re-open an execution stage.
  #
  # THE LOAD-BEARING BRANCH is the first one. A gate that COULD NOT BE RUN —
  # dev server will not boot, a fixture that cannot be built, a known flake —
  # raises a blocker and spends NO round. Without it a broken environment
  # burns three rounds and re-plans a feature that was never wrong. The
  # reviewer expresses that through `Platform.Tasks.ReviewDisposition`, which
  # is also the seam the `dispatch.review_e2e` prompt quotes; see its
  # moduledoc for why the marker rides in `evidence` rather than in a third
  # validation status.
  defp handle_review_stage_failure(%State{} = state, task, stage) do
    failed = failed_validations_for_stage(stage)

    case ReviewDisposition.classify_all(failed) do
      {:could_not_evaluate, reason} ->
        record_review_unrunnable_blocker(state, task, stage, reason)

        Logger.warning(
          "[TaskRouter] review gate could not be evaluated for task #{state.task_id} — " <>
            "blocker raised, review round NOT spent (count stays " <>
            "#{task.review_round_count || 0}): #{reason}"
        )

        # ARM DECISION (task 01a006e7 stage 4): NO remediation stage here.
        # This arm means the gate could not be RUN — the dev server would not
        # boot, a fixture could not be built. Nothing was shown to be wrong
        # with the code, so synthesizing "Address the failed behavioural gate"
        # would dispatch an executor to fix a defect no one observed, and
        # would archive a gate ruling that was never a ruling. The arm already
        # raises a `needs_human` blocker via
        # `record_review_unrunnable_blocker/4` — a human fixing the
        # environment is the correct next actor — and stage 2's
        # suppressed-dispatch guard is the backstop if that human never
        # arrives.
        bounce_to_in_progress(state, task, "review gate could not be evaluated", nil)

      classification ->
        if classification == :malformed do
          # A `could_not_evaluate` marker with no reason is not a free pass:
          # treated as a genuine verdict so the cheap path stays the honest
          # one, and logged so the reviewer's omission is visible.
          Logger.warning(
            "[TaskRouter] review evidence for task #{state.task_id} claimed " <>
              "#{ReviewDisposition.marker()} without a #{ReviewDisposition.reason_key()} — " <>
              "counted as a genuine failure"
          )
        end

        spend_round_and_route(state, task, stage)
    end
  end

  defp spend_round_and_route(%State{} = state, task, gate_stage) do
    case Tasks.spend_review_round(task) do
      {:ok, updated, count} ->
        if count >= Tasks.max_review_rounds() do
          # `gate_stage` is deliberately NOT forwarded — see
          # `replan_after_exhausted_rounds/3`.
          replan_after_exhausted_rounds(state, updated, count)
        else
          # ARM DECISION: the normal bounce DOES open a remediation stage.
          # This is the instance the task exists for — a genuine behavioural
          # verdict, a round spent, and an executor expected to land a fix.
          bounce_to_in_progress(
            state,
            task,
            "review round #{count}/#{Tasks.max_review_rounds()}",
            gate_stage
          )
        end

      {:error, reason} ->
        # The counter is bookkeeping; failing to write it must never strand
        # a failed review. Bounce anyway and say so.
        Logger.warning(
          "[TaskRouter] could not spend a review round for task #{state.task_id}: #{inspect(reason)}"
        )

        # ARM DECISION: treated exactly as the normal bounce. The counter is
        # bookkeeping; a failed write must never cost the task its stage.
        bounce_to_in_progress(state, task, "review round counter unwritten", gate_stage)
    end
  end

  # Arity 3, not 4 (task 01a01041 stage 2). This function used to take the
  # failed `gate_stage` and ignore it, which the compiler flagged as an unused
  # parameter. The ignoring is INTENTIONAL, not a guard failing open: BOTH arms
  # below deliberately open no remediation stage, and the fallback arm's ARM
  # DECISION comment says so explicitly and extends the same reasoning to the
  # `:replanned` success path — on the success path the task goes to
  # `planning` and a planner is dispatched, so the "must have an open stage"
  # invariant does not apply; on the failure path the plan is already dying and
  # stacking a synthesized stage onto it would hand the next planner an
  # executable stage it never wrote. Neither arm has anywhere to put a
  # `gate_stage`, so the parameter was vestigial and the arity shrank rather
  # than the body growing a use for it. The review-round BOUND itself
  # (`count >= Tasks.max_review_rounds()`, decided in
  # `spend_round_and_route/3`) is untouched: nothing about the bound consults
  # the gate stage.
  defp replan_after_exhausted_rounds(%State{} = state, task, count) do
    reason =
      "Behavioural review failed #{count} times (bound: #{Tasks.max_review_rounds()}). " <>
        "Returning the task to planning rather than bouncing it to implementation again."

    case Tasks.supersede_current_plan(task.id, reason, "task_router") do
      {:ok, _replanning_task} ->
        Logger.warning(
          "[TaskRouter] review-round bound exhausted for task #{state.task_id} " <>
            "(#{count}/#{Tasks.max_review_rounds()}) — plan superseded, task returned to planning"
        )

        :replanned

      {:error, err} ->
        Logger.warning(
          "[TaskRouter] review-round bound exhausted for task #{state.task_id} but " <>
            "re-planning failed (#{inspect(err)}) — falling back to in_progress"
        )

        # ARM DECISION: NO remediation stage. The plan here is either already
        # superseded or on its way out; stacking a synthesized stage onto a
        # dying plan hands the next planner an executable stage it never
        # wrote. The `:replanned` success path above is untouched for the same
        # reason — the task goes to `planning` and a planner is dispatched, so
        # the "must have an open stage" invariant does not apply to it.
        bounce_to_in_progress(state, task, "re-plan failed", nil)
    end
  end

  # `gate_stage` is the failed review stage to open a remediation stage in
  # front of, or `nil` for the arms that deliberately open none (see the
  # per-arm comments above). Task 01a006e7 stage 4.
  #
  # DELIBERATE OMISSION: `handle_deploy_stage_failure/2` is NOT wired to this.
  # A deploy bounce has its own retry semantics and its own reason for going
  # back to `in_progress`; stage 2's suppressed-dispatch guard covers its
  # silence, and giving it a behavioural remediation stage would misdescribe
  # what failed.
  defp bounce_to_in_progress(%State{} = state, task, why, gate_stage) do
    case Tasks.transition_task(task, "in_progress") do
      {:ok, _updated} ->
        Logger.info(
          "[TaskRouter] review stage failed — bounced task #{state.task_id} back to in_progress (#{why})"
        )

        # AFTER the transition, so a failed transition never leaves a
        # synthesized stage on a task that did not actually bounce. The
        # newly `pending` stage is what makes the task a nameable dispatch
        # subject: `unresolved_stage_dispatch?/3` withholds only when there
        # is no running stage AND `first_pending_stage/1` is nil.
        maybe_open_remediation_stage(state, gate_stage)

      {:error, reason} ->
        Logger.warning(
          "[TaskRouter] failed to bounce task #{state.task_id} to in_progress: #{inspect(reason)}"
        )
    end

    :bounced
  end

  defp maybe_open_remediation_stage(_state, nil), do: :ok

  defp maybe_open_remediation_stage(%State{} = state, gate_stage) do
    stage_id = Map.get(gate_stage, :id) || Map.get(gate_stage, "id")

    if is_binary(stage_id) do
      case Platform.Tasks.PlanEngine.open_remediation_stage(stage_id) do
        {:ok, stage} ->
          Logger.info(
            "[TaskRouter] opened remediation stage #{stage.id} (position #{stage.position}) " <>
              "for bounced task #{state.task_id}"
          )

        {:error, reason} ->
          # Never crash the router on the failure path. `stage_needs_opening?/1`
          # plus stage 2's suppressed-dispatch guard remain the backstop.
          Logger.warning(
            "[TaskRouter] could not open a remediation stage for task #{state.task_id}: " <>
              inspect(reason)
          )
      end
    end

    :ok
  end

  # Read the stage's failed validations FROM THE DATABASE rather than off the
  # broadcast `%Stage{}`: the transition message carries whatever association
  # state the writer happened to hold, so `stage.validations` can be an
  # `Ecto.Association.NotLoaded{}` here and any `Enum` over it would raise on
  # the failure path — the one path that must not crash the router.
  defp failed_validations_for_stage(stage) do
    stage_id = Map.get(stage, :id) || Map.get(stage, "id")

    if is_binary(stage_id) do
      stage_id
      |> Tasks.list_validations()
      |> Enum.filter(&(&1.status == "failed"))
    else
      []
    end
  end

  defp record_review_unrunnable_blocker(%State{} = state, task, stage, reason) do
    attrs = %{
      "task_id" => task.id,
      "phase" => "review",
      "runtime_id" => "task_router",
      "event_type" => "execution.blocked",
      "execution_space_id" => state.execution_space_id,
      "payload" => %{
        "stage_id" => Map.get(stage, :id) || Map.get(stage, "id"),
        "description" =>
          "Behavioural review could not be evaluated: #{reason}. No review round was " <>
            "spent — fix the environment and re-run the gate.",
        "needs_human" => true,
        "reported_by" => "task_router"
      }
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, err} ->
        Logger.error(
          "[TaskRouter] failed to record un-runnable-review blocker for task #{task.id}: #{inspect(err)}"
        )

        :error
    end
  end

  defp handle_deploy_stage_failure(%State{} = state, task, stage) do
    # Extract failure evidence from the stage's failed validations
    failed_validations = extract_failed_validations(stage)

    evidence_summary =
      failed_validations
      |> Enum.map(fn {kind, evidence} -> "#{kind}: #{summarize_evidence(evidence)}" end)
      |> Enum.join("; ")

    # Extract merge SHA for potential revert tracking
    merge_sha =
      failed_validations
      |> Enum.find_value(fn {_kind, evidence} ->
        Map.get(evidence, "sha") || Map.get(evidence, "merge_sha")
      end)

    # Transition task back to in_progress
    case Tasks.transition_task(task, "in_progress") do
      {:ok, _updated} ->
        Logger.info(
          "[TaskRouter] deploy stage failed — bounced task #{state.task_id} back to in_progress" <>
            if(merge_sha, do: " (merge SHA: #{merge_sha})", else: "")
        )

      {:error, reason} ->
        Logger.warning(
          "[TaskRouter] failed to bounce task #{state.task_id} to in_progress after deploy failure: #{inspect(reason)}"
        )
    end

    # Log to execution space with failure details
    if state.execution_space_id do
      log_parts = [
        "Deploy stage failed: #{evidence_summary}.",
        "Task returned to in_progress for retry.",
        if(merge_sha, do: "Merge SHA for potential revert: #{merge_sha}", else: nil)
      ]

      log_content = log_parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      ExecutionSpace.post_log(state.execution_space_id, log_content)
    end

    state
  end

  defp extract_failed_validations(stage) do
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    validations
    |> Enum.filter(fn v ->
      status = Map.get(v, :status) || Map.get(v, "status")
      status == "failed"
    end)
    |> Enum.map(fn v ->
      kind = Map.get(v, :kind) || Map.get(v, "kind") || "unknown"
      evidence = Map.get(v, :evidence) || Map.get(v, "evidence") || %{}
      {kind, evidence}
    end)
  end

  defp summarize_evidence(evidence) when is_map(evidence) do
    case Map.get(evidence, "conclusion") || Map.get(evidence, "reason") do
      nil ->
        case map_size(evidence) do
          0 -> "no details"
          _ -> inspect(evidence) |> String.slice(0, 200)
        end

      summary ->
        to_string(summary)
    end
  end

  defp summarize_evidence(_), do: "no details"
end
