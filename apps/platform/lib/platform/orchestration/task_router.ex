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

  ## The `needs_human` hold (task 01a04a8c)

  `report_blocker(needs_human: true)` is not a liveness statement — it says
  the next move belongs to a PERSON. Such a blocker parks the router the way
  the two review gates do, and the stage is NOT re-dispatched while it
  stands. The hold is level-triggered off the durable `execution_leases` row
  (`RuntimeSupervision.needs_human_hold/3`), so it survives a router restart.
  A `{:awaiting_human_reminder, lease_id}` tick re-announces the wait on an
  hourly cadence with escalating wording, so a held stage is loud rather than
  merely quiet — a silent hold is task 01a04333's defect, not a fix for this
  one. `needs_human: false` is untouched: it stays a liveness statement,
  expires on the phase TTL, and re-dispatches.

  The hold is NOT bounded by a clock (task 01a0665e stage 2, REVERSING the
  bounded-horizon decision of 01a04a8c/01a04333). 01a04a8c gave the lease a
  12-hour `expires_at` so a forgotten hold would "self-heal"; what the
  horizon measurably did (01a04fbc-1e71, 01a03f4e-78b1) was re-dispatch a
  stage the executor had already refused, which it refused again within
  70 s, after which `:check_no_ack` transitioned the task to `blocked`
  carrying the false sentence "Executor never acked" — the silent park
  01a04333 wanted to prevent, with an untruth on top. The hourly reminder is
  the anti-silence mechanism; the clock never was. A stage-scoped
  `needs_human` lease now ends in exactly three ways: the runtime reports
  `execution.unblocked`, the stage moves on, or a PERSON transitions the task
  (`Platform.Tasks.transition_task/3` / `drop_task_to_column/3` ->
  `RuntimeSupervision.release_needs_human_holds/2`). `:system` and agent
  transitions never release it. The human release is also what WAKES this
  router (task 01a0665e stage 4): `Tasks.maybe_release_needs_human_holds/3`
  calls `TaskRouterWatcher.force_dispatch/1` when it actually released a
  row, because nothing else does — `{:task_updated, _}` records a status,
  the reminder is hourly, and a reconnect is somebody else's event. The
  re-dispatch then has to get past the live-acked-executor guard, which
  treats a release newer than the ack like an `execution.finished`
  (`human_released_since?/3`).

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
  alias Platform.Federation.RuntimePresence

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

  # Task 01a04a8c. Cadence of the `needs_human` hold reminder.
  #
  # A hold that re-dispatches is churn; a hold that says nothing is a task
  # sitting still while looking healthy, which is its own open ticket
  # (01a04333). This is the third option: the stage is NOT re-prompted, and
  # the wait is re-announced on a cadence a human reads as an escalation
  # rather than as a loop. An hour is deliberately two orders of magnitude
  # slower than the 2-second re-announcement task 01a048fe was filed for, and
  # every notice differs from the last — it names a longer elapsed time and,
  # past the thresholds in `awaiting_human_notice/2`, a louder word.
  @awaiting_human_reminder_ms 60 * 60_000

  defp awaiting_human_reminder_ms do
    Application.get_env(
      :platform,
      :task_router_awaiting_human_reminder_ms,
      @awaiting_human_reminder_ms
    )
  end

  # Task 01a0a5fa stage 2. How long a dispatch that resolved NO stage is given
  # to be answered before the router records that it was not.
  #
  # The expected answer to a no-stage dispatch is a STATE CHANGE — a plan
  # submitted, a `task_update`, a stage opening — not an ack. That is slower
  # than the 300s ack budget (which does not apply here: no lease, no ack) and
  # far faster than the 90-minute stage safety net (which also does not apply
  # here: no stage). Fifteen minutes sits between the two and is long enough
  # that a recipient doing real planning work is not reported as silent.
  #
  # DELIBERATELY NOT sourced from `LeaseManager.stage_kind_timeouts/0`. That
  # matrix is keyed by STAGE KIND and this path has no stage; borrowing one of
  # its numbers would make two unrelated clocks look linked, so that a later
  # edit to a stage's budget would silently move a task-level window.
  #
  # Behind `Application.get_env/3` so a test can inject a short window instead
  # of sleeping on the real one — the same shape as `@dispatch_debounce_ms`
  # and `@awaiting_human_reminder_ms` above.
  @stageless_watchdog_ms 15 * 60_000

  defp stageless_watchdog_ms do
    Application.get_env(:platform, :task_router_stageless_watchdog_ms, @stageless_watchdog_ms)
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
            stageless_dispatch_at: DateTime.t() | nil,
            stageless_dispatch_token: integer(),
            stageless_dispatch_delivered_online: boolean() | nil,
            last_dispatch_at: DateTime.t() | nil,
            dispatch_timer: reference() | nil,
            task_status: String.t() | nil,
            lease_status: String.t() | nil,
            deploy_lease: CredentialLease.t() | nil,
            design_run: {pid(), reference()} | nil,
            design_edge_ran?: boolean(),
            boot_dispatch?: boolean(),
            architecture_deadline_ref: reference() | nil,
            awaiting_human_timer: reference() | nil,
            awaiting_human_key: {String.t(), String.t()} | nil,
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
      # Task 01a0a5fa stage 2. When the most recent NO-STAGE dispatch went out,
      # or `nil` when there is no unanswered one outstanding. Cleared the
      # moment the watchdog fires, which is what makes a second fire for the
      # same dispatch structurally impossible rather than merely guarded.
      :stageless_dispatch_at,
      # Whether the runtime the stageless dispatch was addressed to was
      # connected when the frame went out. Carried on state only so the
      # watchdog's payload can repeat it — a reader comparing an unanswered
      # dispatch against a delivery failure needs both in one row, and the
      # timer message deliberately carries nothing but the token.
      :stageless_dispatch_delivered_online,
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
      # Task 01a04a8c — the `needs_human` hold. `awaiting_human_key` is
      # `{stage_id, lease_id}` of the blocker currently holding this router,
      # or `nil`. It is a NARRATION KEY, not the hold itself: the hold lives
      # on the durable `execution_leases` row and is re-derived on every
      # dispatch, so a router restart re-acquires it. The key exists so one
      # hold produces ONE entry notice rather than one per dispatch injector
      # (the 01a048fe failure mode), and so an orphan reminder timer from a
      # previous hold is discarded instead of narrating a hold that is over.
      :awaiting_human_timer,
      :awaiting_human_key,
      # Task 01a0665e stage 1 — narration key for the delivered-but-open
      # hold: the stamp's `delivered_but_open_at` value the router last
      # announced, or `nil`. Same contract as `awaiting_human_key`: the hold
      # itself is the durable `metadata["delivered_but_open"]` stamp and is
      # re-read on every dispatch; the key only keeps N injectors from
      # producing N identical notices. A re-stamp (new `_at`) re-arms it.
      :delivered_but_open_key,
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
      assignee_source: :frozen_fallback,
      # Task 01a03ed3 stage 2. True only while the dispatch currently being
      # coalesced was scheduled by `init/1`'s tail `send(self(), :dispatch_boot)`
      # and NOTHING else has asked for a dispatch since. This is the MAILBOX
      # ACCUMULATOR, not the decision: `handle_info(:dispatch_now, …)` reads it
      # into a local and resets it to `false` before any dispatch work runs, so
      # it can never survive into a later dispatch.
      #
      # It fails OPEN by construction. Every non-boot `:dispatch` injector
      # clears it — including the one the debounce DROPS — so a reconnect that
      # lands inside the boot window makes the coalesced dispatch a real one.
      # Nothing reads it to withhold a prompt in this stage.
      boot_dispatch?: false,
      # Task 01a0a5fa stage 2. Monotonic counter bumped on every stageless
      # dispatch. A `{:check_stageless_dispatch, token}` message whose token is
      # not the current one is an ORPHAN from an earlier dispatch and is
      # ignored: a timer message means "a timer woke us", never "the deadline
      # passed".
      stageless_dispatch_token: 0
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
          # Schedule initial dispatch on next tick.
          #
          # Task 01a03ed3 stage 2: `:dispatch_boot`, not `:dispatch`. This send
          # is the one a RESTARTED process runs — `TaskRouterWatcher`'s
          # `boot_reconcile/0` and its 5-minute `:reconcile` tick both reach
          # here through `resolve_and_start/1`, and each fresh process repeats
          # the engagement. Marking the provenance lets a later stage tell "the
          # supervisor restarted me" from "something happened". The sibling send
          # in the `waiting_for_human_review?/1` branch above is deliberately
          # left as `:dispatch`.
          send(self(), :dispatch_boot)
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
      # Task 01a0a5fa stage 2 — observable so a test (and `router_state`-style
      # introspection) can see an outstanding unanswered stageless dispatch
      # without reaching into process state.
      stageless_dispatch_at: state.stageless_dispatch_at,
      stageless_dispatch_token: state.stageless_dispatch_token,
      stageless_dispatch_delivered_online: state.stageless_dispatch_delivered_online,
      last_dispatch_at: state.last_dispatch_at,
      task_status: state.task_status,
      lease_status: state.lease_status,
      # Task 019fb977. `:assignee` alone cannot be audited — a runtime id is
      # only correct RELATIVE to the phase it was resolved for, and a caller
      # comparing it against the DB needs to know whether the router resolved
      # it or fell back. `nil` phase means the router has not observed a task
      # status yet (no dispatch since boot).
      phase: state.task_status && Tasks.current_phase(state.task_status),
      assignee_source: state.assignee_source,
      # Task 01a03ed3 stage 2. Observable so a test can assert the flag without
      # reaching into process state. Reflects the ACCUMULATOR, which is false
      # everywhere except inside an un-disturbed boot debounce window.
      boot_dispatch?: state.boot_dispatch?
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
    # Task 01a03ed3 stage 2. Cleared in BOTH branches, and the DROP branch is
    # the load-bearing one: a reconnect-driven `:dispatch` arriving inside the
    # boot debounce window is discarded by the timer check, and if it did not
    # clear the flag on its way out then the one signal proving the runtime is
    # live would never reach the dispatch decision. Clearing in both is the
    # direction that fails OPEN.
    {:noreply, arm_dispatch_debounce(%{state | boot_dispatch?: false})}
  end

  # Task 01a03ed3 stage 2. `init/1`'s tail send. Identical arming to
  # `:dispatch` — same drop-if-already-armed semantics — differing only in the
  # provenance it records.
  def handle_info(:dispatch_boot, state) do
    {:noreply, arm_dispatch_debounce(%{state | boot_dispatch?: true})}
  end

  # The real dispatch decision. Carries NO payload: it re-reads
  # `Tasks.get_task_detail/1` (and `Tasks.current_plan/1` inside
  # `do_dispatch/2`) at FIRE time, so the dispatch reflects state as of the
  # moment it fires rather than the moment any one scheduling message arrived.
  def handle_info(:dispatch_now, state) do
    # Task 01a03ed3 stage 2. Capture the accumulator into a local and reset the
    # field FIRST, before anything else runs, so no path can leak this
    # dispatch's provenance into a later one. Everything downstream threads the
    # local: the field is the mailbox accumulator, `boot_dispatch?` the local is
    # the decision.
    boot_dispatch? = state.boot_dispatch?
    state = %{state | dispatch_timer: nil, boot_dispatch?: false}

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

    # Task 01a04a8c. Read ONCE per dispatch and threaded into both branches:
    # a second call would be a second query, and — worse — could observe a
    # different answer than the one the cond below acted on.
    human_hold = task && needs_human_blocker_hold(state)

    # Release is level-triggered on the SAME read. The hold ends when the
    # runtime reports `execution.unblocked` (the lease flips back to
    # `active`), when the stage moves on, or when a PERSON transitions the
    # task (`RuntimeSupervision.release_needs_human_holds/2`); there is no
    # clock (task 01a0665e stage 2). None of those notify this router, so
    # "is it still held?" has to be re-asked, never remembered.
    state = if is_nil(human_hold), do: release_awaiting_human(state), else: state

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

      human_hold != nil ->
        # Pre-dispatch guard, BLOCKER level (task 01a04a8c). The executor this
        # dispatch is addressed to has already said, durably, that it cannot
        # proceed without a person. Re-sending the payload does not make the
        # person appear; it produces a fresh prompt that the agent must either
        # ignore or answer by re-filing the same blocker, which is the
        # ~15-minute loop this ticket was filed from.
        #
        # Ordered directly after the two review gates and before
        # `design_hold?/2` for the reason those two are ordered as they are: a
        # gate held by a HUMAN outranks every machine gate below it.
        hold_for_needs_human_blocker(state, task, human_hold)

      delivered_but_open?(task) ->
        # Pre-dispatch guard, DELIVERED level (task 01a0665e stage 1). A PR
        # for this task has MERGED and no plan gate absorbed it — the task is
        # shipped but still open. Any prompt sent now is a request to do
        # again work that is already on main (01a0554f took five planning
        # dispatches for PR #883, merged three days earlier). Only a person
        # can close the record, so this is a human hold and sits directly
        # after the blocker hold, ahead of every machine gate below.
        hold_for_delivered_but_open(state, task)

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
        do_dispatch(state, task, boot_dispatch?)
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

  # Statuses in which a task-level dispatch is still expecting an answer.
  # Everything else in `Task.statuses/0` (`backlog`, `blocked`, `done`,
  # `cancelled`, `stack_pending`) is either terminal or parked, and reporting a
  # dispatch there as unanswered would be reporting a state nobody is in.
  @stageless_answer_expected_statuses ~w(planning in_progress in_review deploying)

  # Task 01a0a5fa stage 2 — the stageless unanswered watchdog.
  #
  # Mirrors the defensive structure of `handle_info(:check_no_ack, ...)` above:
  # a timer message means "A TIMER WOKE US", not "the deadline passed". Every
  # reason the fire would be wrong is checked here, at fire time, against live
  # state — never assumed from the fact that the message arrived.
  #
  # This is an OBSERVABILITY FLOOR, not an alarm. It records one runtime_event
  # and posts one execution-space line. It sets no `needs_human`, does not move
  # the router to `:stalled`, and does not block the task. It arms no lease and
  # re-arms no timer: `stageless_dispatch_at` is cleared as it fires, so a
  # second fire for the same dispatch is structurally impossible rather than
  # merely guarded.
  def handle_info({:check_stageless_dispatch, token}, %State{} = state) do
    cond do
      token != state.stageless_dispatch_token ->
        # ORPHAN. A later stageless dispatch bumped the token; this timer
        # belongs to a dispatch that has been superseded. Timers are never
        # cancelled here, so an orphan firing is the NORMAL case, not an edge.
        {:noreply, state}

      is_nil(state.stageless_dispatch_at) ->
        # Already fired (or never armed) for this token — nothing outstanding.
        {:noreply, state}

      not is_nil(state.current_stage_id) ->
        # A stage opened after the dispatch: the thing the dispatch was asking
        # for happened. Silent.
        {:noreply, clear_stageless_dispatch(state)}

      runtime_event_since_stageless_dispatch?(state) ->
        # Something came back for this task inside the window. Silent — a
        # watchdog that fires on answered dispatches trains readers to ignore
        # it, which is worse than no watchdog.
        {:noreply, clear_stageless_dispatch(state)}

      true ->
        case Tasks.get_task_detail(state.task_id) do
          %{status: status} = task when status in @stageless_answer_expected_statuses ->
            {:noreply, fire_stageless_unanswered(state, task)}

          _ ->
            # Terminal, parked, or gone: nobody is waiting on an answer.
            {:noreply, clear_stageless_dispatch(state)}
        end
    end
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

  # `{:awaiting_human_reminder, lease_id}` — the escalation tick for an open
  # `needs_human` hold (task 01a04a8c).
  #
  # Matched on the lease id held in `awaiting_human_key` so a timer left over
  # from a previous hold cannot narrate the current one, and re-reads the
  # durable lease before saying anything: "a timer woke us" is not "the hold
  # still stands", the same distinction `:check_no_ack` documents.
  #
  # This handler is the ONLY thing that turns a suppressed dispatch back into
  # a live one without a fresh injector. It fires `:dispatch` the moment the
  # hold is gone — released by a person transitioning the task, by the
  # runtime's `execution.unblocked`, or by the stage moving on — so the
  # suppression can never outlive its cause. It does NOT release on a clock:
  # the 12-hour horizon of 01a04a8c is gone (task 01a0665e stage 2), and a
  # hold whose lease still reads `blocked` is re-narrated, however old.
  def handle_info(
        {:awaiting_human_reminder, lease_id},
        %State{awaiting_human_key: {_stage_id, lease_id}} = state
      ) do
    case needs_human_blocker_hold(state) do
      %{id: ^lease_id} = hold ->
        elapsed_ms = DateTime.diff(DateTime.utc_now(), hold.started_at, :millisecond)

        broadcast_router_event(
          "execution.awaiting_human_blocker",
          state.task_id,
          hold.stage_id,
          %{
            task_id: state.task_id,
            stage_id: hold.stage_id,
            elapsed_ms: elapsed_ms,
            expires_at: hold.expires_at
          }
        )

        post_router_notice(state, awaiting_human_notice(hold, elapsed_ms), %{
          "reason" => "execution.awaiting_human_blocker",
          "stage_id" => hold.stage_id,
          "needs_human" => true,
          "elapsed_ms" => elapsed_ms
        })

        {:noreply, arm_awaiting_human_reminder(state, lease_id)}

      _ ->
        send(self(), :dispatch)
        {:noreply, release_awaiting_human(state)}
    end
  end

  # An orphan tick: the hold it belongs to has already been released, or a
  # different one has replaced it. Silent by design — see the header above.
  def handle_info({:awaiting_human_reminder, _lease_id}, %State{} = state) do
    {:noreply, state}
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
        |> then(fn s ->
          # Task 01a04a8c. The hold is stage-scoped, and the boundary crossing
          # above has already abandoned the outgoing stage's leases — so the
          # blocker that was holding this router no longer exists. Drop the
          # narration key and the board stamp with it rather than waiting for
          # the next reminder to notice.
          if next_stage_id != previous_stage_id, do: release_awaiting_human(s), else: s
        end)

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

  # The one arming site for both `:dispatch` and `:dispatch_boot` call. If a timer is already armed the
  # message is DROPPED — not cancelled, not restarted, not extended.
  defp arm_dispatch_debounce(%State{dispatch_timer: nil} = state) do
    ref = Process.send_after(self(), :dispatch_now, dispatch_debounce_ms())
    %{state | dispatch_timer: ref}
  end

  defp arm_dispatch_debounce(%State{} = state), do: state

  defp do_dispatch(state, task, boot_dispatch?) do
    plan = Tasks.current_plan(state.task_id)
    stage = current_running_stage(plan)

    cond do
      unresolved_stage_dispatch?(task, plan, stage) ->
        suppress_unresolved_stage_dispatch(state, task, plan)

      no_unmet_gate_dispatch?(task, plan, stage) ->
        suppress_no_unmet_gate_dispatch(state, task, plan, stage)

      true ->
        # A dispatch that RESOLVED means a stage is open again: the escalation
        # counter is about a CONSECUTIVE run of suppressions, so clear it here.
        dispatch_resolved(
          %{state | unresolved_suppression: nil},
          task,
          plan,
          stage,
          boot_dispatch?
        )
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

  # ── No-unmet-gate guard (task 01a01b00 stage 3) ────────────────────────
  #
  # THE SHAPE: a stage DID resolve — so `unresolved_stage_dispatch?/3` above
  # declines — but it owes no unmet validation, while `task.status` still
  # reads a review phase. The last-resort `task.status` mapping in
  # `DispatchPhase` then summoned a reviewer to judge a gate that does not
  # exist. Observed on stage 01a0180b of task 01a01796, four times: the
  # reviewer was handed the UI-judgment body for a stage carrying no
  # `manual_approval` validation at all.
  #
  # `DispatchPhase.review_status_without_unmet_gate?/2` (stage 3, same task)
  # already stops `resolve/3` ANSWERING a review slug for that shape. This
  # clause is the other half: with nothing owed anywhere in the plan there is
  # no subject for a prompt of any kind, so withhold rather than send the
  # generic body and let the next tick re-derive once the engine advances.
  #
  # ## The conjuncts, and the one this stage tried and REMOVED
  #
  # Mirrors `unresolved_stage_dispatch?/3` deliberately, for the same reason:
  # the failure mode of a dispatch guard is SILENT STRANGULATION, so the guard
  # must be the smallest one that covers the incident.
  #
  #   1. `review_status_without_unmet_gate?/2` — the status/stage
  #      disagreement, judged in ONE place (the resolver) so the router and
  #      the resolver cannot drift into disagreeing about it. It carries its
  #      own carve-out for an UNGATED stage; read its docstring before
  #      touching it, because that carve-out is what keeps this guard off a
  #      stage only `stage_complete` can ever advance.
  #   2. no PENDING stage — the strangulation guard, and the one
  #      `HeartbeatScheduler.select_review_template/3`'s moduledoc warns about
  #      by name: `select_review_template([], _, _)` deliberately returns
  #      `dispatch.in_review` to cover the transient window where every
  #      validation is evaluated but the stage has not yet auto-advanced.
  #      A pending next stage IS that window, and the dispatch is the only
  #      thing that will get an agent to call `stage_start`. Withholding it
  #      parks the task forever with no signal an operator would look for.
  #
  # A THIRD conjunct — "no OTHER running stage owes a gate" — was written,
  # probed and DELETED, and this note exists so it is not re-added on the same
  # reasoning. It was meant to cover `current_running_stage/1` returning the
  # FIRST running stage while a second one still owed work. Deleting it fails
  # NOTHING in `test/platform/orchestration/` (1039 tests, 0 failures), and
  # that is not a coverage gap:
  #
  #   * `PlanEngine` resolves the running stage the same way
  #     (`Enum.find(stages, &(&1.status == "running"))`, plan_engine.ex:1355),
  #     so a plan with two running stages is not a shape the engine produces,
  #     and if one existed the engine would be as confused as the router.
  #   * `do_dispatch/2` passes the SAME `stage` to this predicate and to
  #     `dispatch_resolved/4`, so conjunct 1 is already judging exactly the
  #     stage the withheld dispatch would have named.
  #   * The fail-open on an unloaded `:validations` preload, which was the
  #     other reason for it, is already handled inside
  #     `review_status_without_unmet_gate?/2`: an unloaded association reads
  #     as ZERO gates, and zero gates answers `false` there.
  #
  # An unkillable conjunct duplicating a killable one is dead code, not
  # defence in depth.
  #
  # ## Why the status half stays scoped to REVIEW
  #
  # Measured, not assumed. Dropping ONLY the `status_phase(task) in
  # @review_phases` half of conjunct 1 — keeping "every gate met" intact —
  # reds two tests: `task_router_no_unmet_gate_suppression_test.exs` "an
  # in_progress task with an all-met running stage and no pending stage still
  # dispatches", and `dispatch_phase_test.exs` "a stage whose validations all
  # passed falls back to task.status". Replacing conjunct 1 wholesale with
  # "a stage resolved" reds nine, including the sibling
  # `task_router_dispatch_suppression_test.exs` control "a task whose current
  # plan is approved with a RUNNING stage still dispatches" — a task at
  # `deploying` whose only stage is `running` with ZERO validations.
  #
  # It is the right scope on the merits too: a redundant
  # `dispatch.in_progress` nudges an agent that is already working, whereas a
  # redundant `dispatch.in_review` MANUFACTURES a review round out of a stale
  # status field.
  #
  # Best-effort like every sibling predicate: a lookup that raises yields
  # `false`. Failing open costs one redundant prompt; failing closed costs a
  # stalled task.
  defp no_unmet_gate_dispatch?(task, plan, stage) do
    DispatchPhase.review_status_without_unmet_gate?(task, stage) and
      is_nil(first_pending_stage(plan))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp suppress_no_unmet_gate_dispatch(state, task, plan, stage) do
    stage_count = if plan, do: length(plan.stages || []), else: 0
    position = if stage, do: stage.position, else: "-"

    Logger.info(
      "[TaskRouter] suppressed review dispatch for task=#{state.task_id}: " <>
        "stage #{position} owes no unmet gate and no stage is pending, but the task " <>
        "still reads #{task.status}"
    )

    emit_dispatch_suppressed_telemetry(state.task_id, :no_unmet_gate)

    if state.execution_space_id do
      ExecutionSpace.post_log(
        state.execution_space_id,
        "Dispatch withheld: #{task.title} | Stage: #{position}/#{stage_count} | " <>
          "every gate on the running stage is met — no review is owed"
      )
    end

    # `unresolved_suppression` is deliberately left untouched. That counter
    # tracks a CONSECUTIVE run of `:unresolved_stage` suppressions and
    # escalates to a blocker at two; this is a different condition with a
    # different key, and neither clearing it (which would pretend a dispatch
    # resolved) nor incrementing it (which would raise the wrong blocker) is
    # true. Liveness is cleared for the same reason the sibling clauses clear
    # it: no dispatch went out, so there is no ack to wait for.
    {:noreply, clear_liveness(%{state | task_status: task.status})}
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
      "runtime_id" => RuntimeSupervision.self_filed_runtime_id(),
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

  # Task 01a0a5fa stage 1 — record that a dispatch which resolved NO stage was
  # sent. Before this, the only durable trace was the ExecutionSpace engagement
  # row, which is a chat message: `runtime_event_list` does not return it, which
  # is why the 2026-09-15 instance on task 01a09de9 had to be dug out of the
  # gateway journal.
  #
  # Same attrs shape as `record_unresolved_stage_blocker/4`, and the same
  # `{:error, _}` discipline: a failed emit logs and returns `:error`, it NEVER
  # crashes the dispatch that just succeeded.
  #
  # Arity 4, not 3: `stage` is the discriminator and it is not yet on `state` at
  # the call site (`maybe_set_stage/2` runs after), so it has to be passed.
  #
  # `execution.dispatch_stageless` is registered with a nil status in
  # `RuntimeSupervision.@event_statuses`, so this mints no execution_lease row.
  #
  # Task 01a0a5fa stage 2: this now RETURNS STATE and is threaded at the call
  # site, because arming the unanswered watchdog means stamping two fields. The
  # process dictionary would have been the shortcut and is deliberately not
  # used — router state is the thing `current_status/1` reports, and a timer
  # whose guard token lived outside that state could not be asserted on.
  defp maybe_record_stageless_dispatch(%State{} = state, _task, %Stage{}, _delivered_online),
    do: state

  defp maybe_record_stageless_dispatch(%State{} = state, task, nil, delivered_online) do
    attrs = %{
      "task_id" => task.id,
      "phase" => Tasks.current_phase(task),
      "runtime_id" => RuntimeSupervision.self_filed_runtime_id(),
      "event_type" => "execution.dispatch_stageless",
      "execution_space_id" => state.execution_space_id,
      "payload" => %{
        "stage_id" => nil,
        "task_status" => task.status,
        "dispatch_runtime_id" => state.assignee.id,
        "delivered_online" => delivered_online,
        "reported_by" => "task_router",
        "description" =>
          "Task #{task.id} (#{task.title}) was dispatched at #{task.status} but the " <>
            "dispatch resolved NO stage, so no execution_lease row was minted and no " <>
            "liveness timer was armed. This event records that the frame was sent."
      }
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        arm_stageless_watchdog(state, delivered_online)

      {:error, err} ->
        Logger.error(
          "[TaskRouter] failed to record stageless dispatch for task #{task.id}: #{inspect(err)}"
        )

        # No trace was recorded, so there is nothing for a watchdog to find
        # unanswered. Arming one here would produce an "unanswered" event with
        # no corresponding "sent" event to read it against.
        state
    end
  end

  defp maybe_record_stageless_dispatch(%State{} = state, _task, _other, _delivered_online),
    do: state

  # Arm the ONE-SHOT unanswered watchdog for the dispatch just recorded.
  #
  # This arms NO lease and touches NO stage timer: `arm_liveness_timers/3`,
  # `clear_liveness/1`, `:check_no_ack` and `:check_safety_net` are all
  # untouched by this stage. The token is what makes a second stageless
  # dispatch retire the first dispatch's timer without cancelling it — the
  # orphan still fires, and `handle_info({:check_stageless_dispatch, token}, _)`
  # drops it on the token mismatch.
  defp arm_stageless_watchdog(%State{} = state, delivered_online) do
    token = state.stageless_dispatch_token + 1

    Process.send_after(
      self(),
      {:check_stageless_dispatch, token},
      stageless_watchdog_ms()
    )

    %{
      state
      | stageless_dispatch_at: DateTime.utc_now(),
        stageless_dispatch_token: token,
        stageless_dispatch_delivered_online: delivered_online
    }
  end

  defp clear_stageless_dispatch(%State{} = state) do
    %{state | stageless_dispatch_at: nil}
  end

  defp runtime_event_since_stageless_dispatch?(%State{last_runtime_event_at: nil}), do: false

  defp runtime_event_since_stageless_dispatch?(%State{} = state) do
    DateTime.compare(state.last_runtime_event_at, state.stageless_dispatch_at) != :lt
  end

  defp fire_stageless_unanswered(%State{} = state, task) do
    dispatched_at = state.stageless_dispatch_at
    elapsed_ms = DateTime.diff(DateTime.utc_now(), dispatched_at, :millisecond)

    description =
      "Task #{task.id} (#{task.title}) was dispatched at #{task.status} with NO stage open " <>
        "#{div(elapsed_ms, 1_000)}s ago and nothing has come back: no runtime event, no stage " <>
        "opened, no status change. No lease was minted for this dispatch, so no ack or " <>
        "safety-net timer covers it. This is a record, not a block — the task is not held " <>
        "and no human intervention has been requested."

    attrs = %{
      "task_id" => task.id,
      "phase" => Tasks.current_phase(task),
      "runtime_id" => RuntimeSupervision.self_filed_runtime_id(),
      "event_type" => "execution.dispatch_unanswered",
      "execution_space_id" => state.execution_space_id,
      "payload" => %{
        "stage_id" => nil,
        "dispatched_at" => DateTime.to_iso8601(dispatched_at),
        "elapsed_ms" => elapsed_ms,
        "task_status" => task.status,
        "dispatch_runtime_id" => state.assignee.id,
        "delivered_online" => state.stageless_dispatch_delivered_online,
        "reported_by" => "task_router",
        "description" => description
      }
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, err} ->
        Logger.error(
          "[TaskRouter] failed to record unanswered stageless dispatch for task #{task.id}: #{inspect(err)}"
        )
    end

    if state.execution_space_id do
      ExecutionSpace.post_log(state.execution_space_id, description)
    end

    # Cleared whatever the emit did. A failed emit is a lost record, not a
    # reason to try again later under a different elapsed time.
    clear_stageless_dispatch(state)
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

  defp dispatch_resolved(state, task, plan, stage, boot_dispatch?) do
    # Capture the INCOMING status before the unconditional
    # `Map.put(:status, :running)` below overwrites it. Both tail branches of
    # this function re-check `waiting_for_human_review?/1` and can park the
    # router at `:waiting_human`; those parks need an edge, and by then
    # `state.status` has already been clobbered to `:running`. See the
    # episode-start narration at those two sites (task 019f9b34).
    entry_status = state.status

    case refresh_assignee(state, task) do
      {:suppress, state} ->
        {:noreply, state}

      {:dispatch, state} ->
        do_dispatch_resolved(state, task, plan, stage, entry_status, boot_dispatch?)
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
  #
  # SCOPE (task 01a0a5fa stage 3): the `execution.dispatch_stageless` event added
  # by stage 1 covers dispatches that WERE SENT with no stage open. This path
  # sends no frame, so it emits no such event — correctly. Suppression and a
  # stageless send are different facts and are recorded differently.
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

  defp do_dispatch_resolved(state, task, plan, stage, entry_status, boot_dispatch?) do
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

    # READ ONCE, AND BEFORE THE BROADCAST. `dispatch_attention/5` publishes to
    # `runtime:<id>` and returns `:ok` whether or not anything is subscribed
    # (`AttentionDispatch.broadcast/3` over a subscriber-less PubSub topic is a
    # successful no-op), so this flag is the only record of whether the signal
    # had a listener. Reading it AFTER the broadcast would race the runtime's
    # own reconnect and stamp `true` on precisely the dispatch that fell on the
    # floor, which is the case the field exists to identify.
    #
    # `state.assignee` is the post-`refresh_assignee/2` value — `do_dispatch/2`
    # replaced the field before calling here — so this is presence for the
    # runtime the broadcast is actually addressed to, not the one the router
    # was started with.
    # Task 01a03ed3 stage 3. Placement is load-bearing: this sits AFTER the
    # prompt is rendered and BEFORE `dispatch_attention/5`, because
    # `dispatch_attention/5` is what actually wakes the agent — it puts the
    # whole prompt on the wire as `message.content`. A guard wrapped around
    # `post_engagement/3` instead would remove the execution-space message
    # and still wake the runtime, which is the opposite of the fix.
    cond do
      # Task 01a04135 / 01a00915. Checked BEFORE the boot-engagement guard
      # because it is the more general condition: that guard only ever fires
      # for a planning dispatch with no resolved stage, and this one only ever
      # fires for a resolved stage, so the two are disjoint and the order is
      # documentation rather than precedence.
      live_acked_executor?(state, stage) ->
        suppress_live_acked_executor(state, task, stage)

      unchanged_boot_engagement?(state, task, stage, prompt, boot_dispatch?) ->
        suppress_unchanged_boot_engagement(state, task)

      true ->
        delivered_online = RuntimePresence.online?(state.assignee.id)

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

              # SCOPE OF THIS ROW (corrected, task 01a0a5fa stage 3). The
              # engagement row covers the HUMAN-READABLE side of a dispatch that
              # resolved no stage: the full prompt text, in the execution space,
              # where a person reading the task's history sees what was actually
              # said and to whom. Stamping who it was addressed to and whether
              # that runtime was connected is what lets a later reader tell a
              # repeat that was never delivered from one that was.
              #
              # It is no longer the only durable trace. Stage 1 of task 01a0a5fa
              # added an `execution.dispatch_stageless` runtime_event covering the
              # MACHINE-READABLE side: queryable over MCP via `runtime_event_list`,
              # which does not return chat messages. Two rows because there are two
              # readers, not because one is a fallback for the other.
              #
              # What has NOT changed: the nil-stage clause of
              # `arm_liveness_timers/3` remains a deliberate no-op, and
              # `unchanged_boot_engagement?/5` depends on that no-op for its
              # suppression to be safe. The new event records a send; it arms
              # nothing and mints no lease.
              ExecutionSpace.post_engagement(state.execution_space_id, prompt,
                metadata: %{
                  "reason" => "task_assigned",
                  "dispatch_runtime_id" => state.assignee.id,
                  "delivered_online" => delivered_online
                }
              )
            end

            # Task 01a0a5fa stage 1. OUTSIDE the `if state.execution_space_id`
            # block above ON PURPOSE: a task with no execution space is exactly
            # the case where the engagement row does not exist either, so gating
            # this on it would reproduce the blind spot it exists to close.
            #
            # This is NOT a replacement for arming a liveness timer, and it does
            # not change what `arm_liveness_timers/3` does below. The nil-stage
            # clause of that function remains a deliberate no-op which
            # `unchanged_boot_engagement?/5` depends on (see the comment at the
            # boot-suppression site). What is recorded here is only that the
            # frame WAS SENT.
            state = maybe_record_stageless_dispatch(state, task, stage, delivered_online)

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
  end

  # ── Live-acked-executor guard (tasks 01a04135, 01a00915) ──────────────
  #
  # Do not re-prompt a stage that already has an executor working it.
  #
  # Nothing in the dispatch path used to ask whether the stage had been
  # staffed. `LeaseManager` learned (task 019fa469 stage 6) to stop a
  # re-dispatch DESTROYING an ack, but its moduledoc puts suppressing the
  # redundant dispatch itself explicitly out of scope. So the router kept
  # re-sending, and because every dispatch body opens with "spawn the subagent
  # FIRST, then ack with its id", a recipient following the text literally
  # staffs the same stage twice: two executors in one worktree on task
  # `01a00108`, and three deploy agents racing to open one PR on `019f9cb7`.
  #
  # ## Why the ack has to come from Postgres
  #
  # The obvious source — `LeaseManager.get/1`'s `ack_at` and `safety_net_at` —
  # is empty in the case that matters. `terminate/2` calls `clear_liveness/1`,
  # which deletes the entire ETS row, so a router that stops and restarts reads
  # back nothing while its executor is still running. That IS the reported
  # incident: ack at 02:09 with a 03:39 safety net, "Task router stopped", and
  # the same stage re-dispatched at 02:17. A guard reading the lease would have
  # suppressed nothing on the one occasion it was needed most.
  #
  # `Platform.Orchestration.last_stage_ack_at/2` reads `runtime_events`, which
  # survives `clear_liveness/1`, a `LeaseManager` restart and a node restart —
  # the same durability argument ADR 0051 makes for `stage_acked?/2` on the
  # alarm path.
  #
  # ## Why the window, and not simply "has it ever acked"
  #
  # An ack is not a permanent claim on a stage. `stage_acked?/2` stays true
  # forever, so suppressing on it alone would park a stage whose executor died
  # after acking, with nothing left to re-dispatch it — the failure this system
  # is least able to notice. Bounding the suppression by the stage kind's own
  # `safety_net_ms` makes the guard self-healing: while the executor is inside
  # its safety net it is presumed alive and is not disturbed; once the net
  # lapses this guard stops suppressing, so the next `:dispatch` to arrive is
  # delivered rather than withheld, on exactly the deadline the safety-net
  # alarm already fires on. Note what that does NOT say: the lapse itself
  # sends no `:dispatch`. `handle_info(:check_safety_net, ...)` only logs,
  # notes an awaiting-human gate, or fires the `needs_human` blocker; the
  # stage moves again when something else asks the router to reconcile.
  #
  # `manual_approval` has `safety_net_ms: nil` and is therefore never
  # suppressed. That is deliberate: those stages park on a human, arm no
  # timers, and withholding their dispatch has no deadline that would ever
  # release it.
  #
  # Fails OPEN on anything unexpected, like every sibling predicate here — a
  # redundant prompt costs tokens, a wrongly withheld one costs a stalled task.
  defp live_acked_executor?(%State{} = state, %Stage{} = stage) do
    stage_kind = current_stage_type(%{state | current_stage_id: stage.id})

    timeouts =
      LeaseManager.stage_kind_timeouts()
      |> Map.get(stage_kind, %{ack_ms: nil, safety_net_ms: nil})

    case {timeouts.safety_net_ms,
          Platform.Orchestration.last_stage_ack_at(state.task_id, stage.id)} do
      {safety_net_ms, %DateTime{} = acked_at} when is_integer(safety_net_ms) ->
        DateTime.diff(DateTime.utc_now(), acked_at, :millisecond) < safety_net_ms and
          not finished_since?(state.task_id, stage.id, acked_at) and
          not human_released_since?(state.task_id, stage.id, acked_at)

      _ ->
        false
    end
  rescue
    error -> live_ack_fail_open(state.task_id, error)
  catch
    kind, reason -> live_ack_fail_open(state.task_id, {kind, reason})
  end

  # No resolved stage (the planning dispatch) can have a stage-scoped ack, so
  # there is nothing to suppress against.
  defp live_acked_executor?(_state, _stage), do: false

  # Same reasoning as `fail_open/2`: falling open here reproduces the exact
  # pre-fix behaviour, so a predicate that raised on every call would look
  # identical to one that was never added. This line is the only way to tell a
  # live guard from a dead one. `Logger.warning`, not `info`, because the test
  # env pins the logger at `:warning`.
  defp live_ack_fail_open(task_id, error) do
    Logger.warning(
      "[TaskRouter] live-acked-executor guard failed open for task=#{task_id}: " <>
        "#{inspect(error)}; dispatching anyway"
    )

    :telemetry.execute(
      [:platform, :orchestration, :live_ack_guard, :failed_open],
      %{count: 1},
      %{task_id: task_id, error: inspect(error)}
    )

    false
  end

  # An `execution.finished` newer than the ack means the subagent that acked has
  # already exited. The ack is then a record of something that HAPPENED, not
  # evidence of something still running, so re-dispatching the stage is the
  # correct recovery rather than a duplicate. Without this the finished-executor
  # path would sit out the rest of its safety-net window before anything moved —
  # a regression against `task_router_acked_stage_no_ack_test.exs`'s REPRO B,
  # which drives exactly that sequence.
  defp finished_since?(task_id, stage_id, %DateTime{} = acked_at) do
    case Platform.Orchestration.last_stage_event_at(task_id, stage_id, "execution.finished") do
      %DateTime{} = finished_at -> DateTime.compare(finished_at, acked_at) != :lt
      _ -> false
    end
  end

  # A `needs_human` hold released by a PERSON after the ack is the same shape
  # (task 01a0665e stage 4). The dispatch text tells every runtime to ack
  # first, so an executor that then files `report_blocker(needs_human: true)`
  # leaves an ack inside the safety net with nobody working the stage; the
  # hold clause in `handle_info(:dispatch_now)` parks the router on it. When
  # the person rules (`Tasks.transition_task/3` / `drop_task_to_column/3` ->
  # `RuntimeSupervision.release_needs_human_holds/2`) that hold is gone and
  # control reaches this guard — which, reading only the ack, withheld the
  # one dispatch the release existed to produce (01a06b2b-8185, 2026-09-04).
  # The release instant is compared to the ack the way `finished_since?/3`
  # compares the exit: an ack OLDER than the release protects nobody; an ack
  # NEWER than it (the executor took the re-dispatch) protects the stage as
  # before, which is what keeps a reconnect after the re-dispatch from
  # prompting twice.
  defp human_released_since?(task_id, stage_id, %DateTime{} = acked_at) do
    case RuntimeSupervision.last_human_release_at(task_id, stage_id) do
      %DateTime{} = released_at -> DateTime.compare(released_at, acked_at) != :lt
      _ -> false
    end
  end

  # WITHHOLDS THE PROMPT, KEEPS THE WATCHDOG. Arming the liveness timers here is
  # not an optimisation, it is what makes the guard safe: `clear_liveness/1`
  # runs on review gates, phase boundaries and `execution.finished`, so the
  # router regularly reaches this point with no lease and no timers at all.
  # Suppressing in that state would leave the stage with nothing scheduled to
  # notice it had gone quiet — the withheld dispatch would be undetectable,
  # which is the precise failure mode the boot-engagement guard refused to risk
  # when it stopped at `is_nil(stage)`.
  #
  # `record_dispatch/4` preserves `ack_at` when the row already names this stage
  # and builds a fresh zero-ack row when it does not, so re-arming here cannot
  # erase an ack (task 019fa469 stage 6) and cannot invent one. The no-ack alarm
  # reads Postgres via `stage_acked?/2` regardless, per ADR 0051.
  defp suppress_live_acked_executor(state, task, stage) do
    stage_kind = current_stage_type(%{state | current_stage_id: stage.id})
    arm_liveness_timers(state.task_id, stage, stage_kind)

    Logger.info(
      "[TaskRouter] suppressed dispatch for task=#{state.task_id} stage=#{stage.id}: " <>
        "stage already acked by a live executor inside its safety net"
    )

    emit_dispatch_suppressed_telemetry(state.task_id, :live_acked_executor)

    ExecutionSpace.post_log(
      state.execution_space_id,
      "Dispatch withheld: #{task.title} | stage #{stage.position} already has an acked " <>
        "executor inside its safety net, so it is not being re-sent. If that executor is " <>
        "gone, the safety net does NOT re-dispatch when it lapses: it broadcasts " <>
        "execution.safety_net_fired and posts a needs_human blocker, and the task then " <>
        "holds until a person acts. Recovery is manual: spawn a replacement executor, have " <>
        "it call task_ack, then clear the block with task_update status: in_progress, which " <>
        "releases the hold and lets the router dispatch this stage again."
    )

    {:noreply, %{state | task_status: task.status}}
  end

  # ── Unchanged-boot-engagement guard (task 01a03ed3 stage 3) ───────────
  #
  # A freshly booted router re-sends the planning prompt because `init/1` ends
  # in an unguarded `send(self(), :dispatch_boot)` and every repeat comes from
  # a NEW process, so no process-local flag can see the previous one. The
  # durable trace we do have is the last engagement posted to the execution
  # space, and the prompt is deterministic for unchanged state — so comparing
  # the freshly rendered prompt against what was last DELIVERED answers the
  # question without persisting a guard whose invalidation list would have to
  # be maintained by hand (a missed entry strands a task silently at a gate,
  # the failure mode this system is least able to notice).
  #
  # Suppress only when ALL FIVE hold. Any false, or anything raising, and we
  # dispatch — the module's stated policy at `unresolved_stage_dispatch?/3`
  # and `refresh_assignee/2`: failing open costs one redundant prompt,
  # failing closed costs a stalled task.
  defp unchanged_boot_engagement?(state, task, stage, prompt, boot_dispatch?) do
    # (a) only a boot dispatch repeats itself this way; an event-driven
    #     dispatch means something actually happened.
    # (b) planning with NO resolved stage keeps this the smallest guard that
    #     covers the incident. With no stage, `arm_liveness_timers/3`,
    #     `maybe_lease_deploy_credentials/3` and `maybe_provision_branches/4`
    #     are all already no-ops, so suppressing mints no lease, skips no
    #     branch round trip, and — decisively — deletes no `:check_no_ack`
    #     timer. On the execution path suppressing WOULD delete it, and that
    #     timer is the only thing that would ever surface a wrong suppression.
    boot_dispatch? and task.status == "planning" and is_nil(stage) and
      not is_nil(state.execution_space_id) and
      unchanged_delivered_engagement?(state, prompt)
  rescue
    error -> fail_open(state.task_id, error)
  catch
    kind, reason -> fail_open(state.task_id, {kind, reason})
  end

  # A SILENT fail-open here is indistinguishable from the bug this guard was
  # written to fix: falling open means "always dispatch", which is exactly the
  # pre-fix behaviour, so a predicate that raised from the first deploy would
  # produce no new symptom at all — its only evidence would be the same 30,059
  # character repeats nobody noticed for months. This emission is the only
  # thing that can tell a live guard from a dead one. Do not delete it as
  # noise. `Logger.warning` (not `info`) because the test env pins the logger
  # at `:warning` and an `info` line is unassertable.
  defp fail_open(task_id, error) do
    Logger.warning(
      "[TaskRouter] boot re-engagement guard failed open for task=#{task_id}: " <>
        "#{inspect(error)}; dispatching anyway"
    )

    :telemetry.execute(
      [:platform, :orchestration, :boot_reengagement_guard, :failed_open],
      %{count: 1},
      %{task_id: task_id, error: inspect(error)}
    )

    false
  end

  # Indirection exists so a test can inject a lookup that raises and prove the
  # rescue above is reachable — an untested rescue clause is indistinguishable
  # from an unreachable one, and this one stands between a bug in the predicate
  # and every task on the platform stalling. Defaults to the real module; no
  # production caller sets it.
  defp engagement_lookup do
    Application.get_env(:platform, :execution_space_engagement_lookup, ExecutionSpace)
  end

  defp unchanged_delivered_engagement?(state, prompt) do
    case engagement_lookup().latest_engagement(state.execution_space_id) do
      %{content: content, metadata: metadata} when is_map(metadata) ->
        # (c) byte-equal prompt, (d) addressed to the runtime THIS dispatch is
        #     addressed to — a phase reassignment through `refresh_assignee/2`
        #     points at a new runtime that has never received the prompt — and
        #     (e) `delivered_online` exactly `true`: an engagement recorded
        #     while the runtime was offline was never delivered, and the
        #     reconnect re-dispatch is the only thing that would ever deliver
        #     it, so suppressing on it strands the task outright.
        content == prompt and
          Map.get(metadata, "dispatch_runtime_id") == state.assignee.id and
          Map.get(metadata, "delivered_online") == true

      _ ->
        false
    end
  end

  # Deliberately does NOT call `clear_liveness/1`. The sibling suppression arms
  # call it because they park a task at a gate and there is no ack to wait for;
  # this arm is only declining to REPEAT a prompt, and clearing the lease would
  # delete the no-ack detector for whatever is genuinely live. `last_dispatch_at`
  # is left untouched for the same reason: nothing was dispatched.
  defp suppress_unchanged_boot_engagement(state, task) do
    Logger.info(
      "[TaskRouter] suppressed boot dispatch for task=#{state.task_id}: planning prompt " <>
        "is byte-identical to the last engagement delivered to runtime #{state.assignee.id}"
    )

    emit_dispatch_suppressed_telemetry(state.task_id, :unchanged_boot_engagement)

    ExecutionSpace.post_log(
      state.execution_space_id,
      "Dispatch withheld: #{task.title} | planning prompt is unchanged since the last " <>
        "delivered engagement — not re-sending it"
    )

    {:noreply, %{state | task_status: task.status}}
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
  # Durable-ack guard, BOUNDED BY THE LAST HUMAN RELEASE. The ETS lease row is
  # the only place an ack lives at runtime, and `clear_liveness/1` DELETES that
  # row from ~15 call sites — so any re-dispatch of a stage the executor
  # already acked (opening a review request is the reachable one) re-arms this
  # alarm against an agent that DID ack. `execution.acked` lives in Postgres
  # and survives every clear, so we consult it before firing and re-stamp the
  # ETS row on a hit. That is task 01a007bf / PR #757, and it stays: an alarm
  # that fires at a runtime which acked THIS dispatch is the false-positive
  # class that fills the blocked column.
  #
  # THE TIME BOUND (task 01a06d39, observed live 2026-09-04). "Was this stage
  # ever acked" is not the same question as "did anyone take THIS dispatch",
  # and one path drives them apart: the runtime acks, files
  # `report_blocker(needs_human: true)`, and a PERSON releases the hold on the
  # board. `Tasks.maybe_release_needs_human_holds/3` → `force_dispatch/1`
  # re-dispatches and arms a fresh five-minute window — and if the runtime
  # ignores that re-dispatch, the PRE-BLOCKER ack suppressed this alarm
  # forever, leaving only the 90-minute `execution.safety_net_fired`. So the
  # ack is compared against the most recent human release, exactly as the
  # DISPATCH-suppression guard already does (`live_acked_executor?/2` →
  # `human_released_since?/3`, backed by
  # `RuntimeSupervision.last_human_release_at/2`): an ack OLDER than the
  # release says nothing about the dispatch that release produced and does NOT
  # suppress; an ack NEWER than it means the runtime took the re-dispatch, and
  # suppresses exactly as before.
  #
  # STILL NOT BOUNDED BY `lease.dispatched_at`, for the reason the previous
  # revision of this comment gave: the re-dispatch ALWAYS postdates the ack, so
  # that bound re-opens the #757 false positive on every ordinary path. A human
  # release is a different quantity — a person caused it, it postdates the ack
  # only on the broken path, and it never occurs at all on the
  # clear-then-re-dispatch sequences `task_router_acked_stage_no_ack_test.exs`
  # pins.
  #
  # Consequence still accepted: a stage force-reassigned to a NEW runtime with
  # no human release recorded will not re-fire no-ack on the old owner's ack.
  # That case remains covered by `execution.safety_net_fired`, untouched here.
  #
  # Stage-scoped by construction: a lease with a nil/blank stage_id falls
  # through to the alarm (`last_stage_ack_at/2` returns nil for a blank stage,
  # carrying the same guard `stage_acked?/2` documents), and an ack on stage N
  # never suppresses the alarm for stage N+1.
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
    if durable_ack_suppresses_alarm?(task_id, lease.stage_id) do
      LeaseManager.record_ack(task_id)

      Logger.info(
        "[TaskRouter] task #{task_id} stage #{lease.stage_id} — no-ack alarm suppressed by a durable execution.acked event; re-stamping lease ack_at"
      )

      {:noreply, state}
    else
      do_fire_no_ack(state, task_id, lease)
    end
  end

  # The bounded form of the durable-ack read — see the guard note above.
  # `last_stage_ack_at/2` is the recency twin of `stage_acked?/2` (same query
  # shape, same nil/blank-stage_id guard), so the only behavioural difference
  # from the unbounded version is the `human_released_since?/3` clause.
  defp durable_ack_suppresses_alarm?(task_id, stage_id) do
    case Platform.Orchestration.last_stage_ack_at(task_id, stage_id) do
      %DateTime{} = acked_at -> not human_released_since?(task_id, stage_id, acked_at)
      _ -> false
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

          held =
            base_state
            |> clear_liveness()
            |> Map.put(:status, :waiting_human)

          # Task 01a04a8c. Arm the hold HERE, not only on the next dispatch
          # attempt. A blocker filed against a stage nothing then tries to
          # dispatch would otherwise be a SILENT hold — the failure mode the
          # sibling ticket 01a041b6 names as strictly worse than the noisy
          # loop, because a wait nobody is told about is a wait nobody
          # resolves.
          case needs_human_blocker_hold(held) do
            nil -> held
            hold -> enter_awaiting_human(held, hold)
          end
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
      # Task 01a03ec2 stage 2. FIRST, and the only unconditional entry. Every
      # other field can render "unknown" or be dropped by the `Enum.reject/2`
      # below, so a snapshot can legitimately consist of nothing but
      # placeholders; the task id is what keeps such a line worth anything to
      # whoever reads it. It is also precisely what this ticket lacked: a
      # suppression notice was quoted out of its execution space and filed
      # against the wrong message, because nothing in the line named its
      # subject. `state.task_id` rather than `task.id` deliberately, so the
      # line still identifies itself on the paths that pass a task struct
      # loaded from somewhere else.
      "task=#{state.task_id}",
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

    stamp_awaiting_human_action(state.task_id, "merge")

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

  # ── The `needs_human` hold (task 01a04a8c) ──────────────────────────────
  #
  # `report_blocker(needs_human: true)` says the next move belongs to a
  # PERSON. Until this task, that flag was written into the runtime event and
  # into `execution_leases.metadata` and then read by nothing: every liveness
  # decision treated it identically to `needs_human: false`. The lease
  # therefore expired on the 15-minute liveness clock, and the next runtime
  # reconnect re-dispatched the stage with the full payload — measured on
  # 2026-08-28 as three blockers over roughly six hours.
  #
  # Two halves, and BOTH are needed:
  #
  #   * `RuntimeSupervision.expire_stale_leases/2` never sweeps a
  #     stage-scoped `needs_human` lease and every lease reader treats it as
  #     live whatever its `expires_at` says (task 01a0665e stage 2 — it used
  #     to be a 12-hour horizon, which measurably re-dispatched refused
  #     work), which is what stops
  #     `TaskRouterWatcher.active_lease_present?/2` from waving the reconnect
  #     path through.
  #   * This guard stops every OTHER `:dispatch` injector —
  #     `force_dispatch/1`, the in-module sends, the 1s endpoint retry — for
  #     the same reason `plan_awaiting_review?/1` is a guard in the handler
  #     rather than a check in each caller.
  #
  # Deliberately re-derived from the DB on every dispatch rather than held in
  # `state`: a router restart must re-acquire the hold, and the hold must end
  # the moment the row stops saying so.
  #
  # Best-effort in the shape of its siblings — a lookup that raises yields
  # `nil`, i.e. DISPATCH. Failing open costs one redundant prompt; failing
  # closed strangles the task.
  defp needs_human_blocker_hold(%State{} = state) do
    stage_id = state.current_stage_id || running_stage_id(state.task_id)

    RuntimeSupervision.needs_human_hold(state.task_id, stage_id, state.assignee.id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp running_stage_id(task_id) do
    case task_id |> Tasks.current_plan() |> current_running_stage() do
      %Stage{id: id} -> id
      _ -> nil
    end
  end

  # The suppression itself. Nothing here accuses anybody and nothing here
  # re-prompts the agent: the whole point is that the executor did the right
  # thing and the wait is a human's.
  defp hold_for_needs_human_blocker(%State{} = state, task, hold) do
    emit_dispatch_suppressed_telemetry(state.task_id, :awaiting_human_blocker)

    state =
      state
      |> Map.put(:task_status, task.status)
      |> clear_liveness()
      |> Map.put(:status, :waiting_human)
      |> enter_awaiting_human(hold)

    {:noreply, state}
  end

  # Task 01a0665e stage 1. Reads the already-loaded `task.metadata` — no
  # query — so the check is free on every one of the ~10 dispatch injectors
  # that land in `do_dispatch/3`.
  defp delivered_but_open?(task), do: Tasks.delivered_but_open?(task)

  defp hold_for_delivered_but_open(%State{} = state, task) do
    emit_dispatch_suppressed_telemetry(state.task_id, :delivered_but_open)

    state =
      state
      |> Map.put(:task_status, task.status)
      |> clear_liveness()
      |> Map.put(:status, :waiting_human)
      |> note_delivered_but_open(task)

    {:noreply, state}
  end

  # Edge-triggered on the stamp's `_at`, mirroring `enter_awaiting_human/2`:
  # one hold, one notice, however many injectors re-enter it. No prompt is
  # sent and no lease is minted — the human exits are named in the notice.
  defp note_delivered_but_open(%State{} = state, task) do
    metadata = task.metadata || %{}
    key = Map.get(metadata, "delivered_but_open_at") || :unstamped_at

    if state.delivered_but_open_key == key do
      state
    else
      stamp = Map.get(metadata, "delivered_but_open") || %{}
      pr_url = Map.get(stamp, "pr_url") || "a PR"

      post_router_notice(
        state,
        "Delivered but open: #{pr_url} merged while this task is `#{task.status}` and no " <>
          "plan gate could absorb it. Dispatch is parked — the work is already on main. " <>
          "Two human exits: an admin runs `close_as_delivered`, or drag the task to " <>
          "in_progress and then to done.",
        %{
          "reason" => "task.delivered_but_open",
          "pr_url" => Map.get(stamp, "pr_url"),
          "merge_commit_sha" => Map.get(stamp, "merge_commit_sha"),
          "task_status" => task.status
        }
      )

      %{state | delivered_but_open_key: key}
    end
  end

  # Edge-triggered on `{stage_id, lease_id}`. Re-entering the SAME hold is a
  # no-op, which is what keeps a dozen dispatch injectors from producing a
  # dozen identical notices.
  defp enter_awaiting_human(%State{awaiting_human_key: {_stage, lease_id}} = state, %{
         id: lease_id
       }) do
    state
  end

  defp enter_awaiting_human(%State{} = state, hold) do
    state = cancel_awaiting_human_timer(state)

    post_router_notice(state, awaiting_human_notice(hold, 0), %{
      "reason" => "execution.awaiting_human_blocker",
      "stage_id" => hold.stage_id,
      "needs_human" => true,
      "elapsed_ms" => 0
    })

    stamp_awaiting_human_action(state.task_id, "blocker")

    state
    |> Map.put(:awaiting_human_key, {hold.stage_id, hold.id})
    |> arm_awaiting_human_reminder(hold.id)
  end

  defp arm_awaiting_human_reminder(%State{} = state, lease_id) do
    ref =
      Process.send_after(
        self(),
        {:awaiting_human_reminder, lease_id},
        awaiting_human_reminder_ms()
      )

    %{state | awaiting_human_timer: ref}
  end

  # Guarded on `awaiting_human_key` rather than on the stamp, so this can
  # never clear the UNRELATED `awaiting_human_action` stamp that
  # `note_awaiting_human_action/3` writes for a pending human merge.
  defp release_awaiting_human(%State{awaiting_human_key: nil} = state), do: state

  defp release_awaiting_human(%State{} = state) do
    state = cancel_awaiting_human_timer(state)
    clear_awaiting_human_stamp(state.task_id)
    %{state | awaiting_human_key: nil}
  end

  defp cancel_awaiting_human_timer(%State{awaiting_human_timer: nil} = state), do: state

  defp cancel_awaiting_human_timer(%State{awaiting_human_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | awaiting_human_timer: nil}
  end

  defp clear_awaiting_human_stamp(task_id) do
    Tasks.clear_awaiting_human_action(task_id)
    :ok
  rescue
    error ->
      Logger.warning(
        "[TaskRouter] task #{task_id} — could not clear awaiting_human_action: #{Exception.message(error)}"
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  # The reason is TRUNCATED, and that is a fix rather than a nicety. The
  # ticket that produced this code counted the blocker description being
  # echoed back into the execution space three times per lap; a reminder on
  # an hourly cadence would have been a fourth echo, unbounded in length.
  # A human reading the notice needs to know WHICH blocker, not to re-read
  # it — the full text is one message above, on the blocker itself.
  # Wide enough that a description plus three attempts and an unblock action
  # (the cost report_blocker demands) survive into the notice.
  @awaiting_human_reason_chars 1_200

  defp awaiting_human_notice(hold, elapsed_ms) do
    minutes = div(elapsed_ms, 60_000)

    prefix =
      cond do
        minutes < 120 -> "Awaiting a human ruling"
        minutes < 360 -> "STILL awaiting a human ruling"
        true -> "OVERDUE — awaiting a human ruling"
      end

    "#{prefix} (#{minutes}m). The executor filed a needs_human blocker on stage " <>
      "#{hold.stage_id}; this stage will NOT be re-dispatched while it stands. " <>
      "Reason: #{truncate_reason(hold.block_reason)} | This stage will not be " <>
      "re-dispatched until a person moves the task or the executor reports " <>
      "execution.unblocked."
  end

  defp truncate_reason(nil), do: "no reason recorded"

  defp truncate_reason(reason) when is_binary(reason) do
    if String.length(reason) > @awaiting_human_reason_chars do
      String.slice(reason, 0, @awaiting_human_reason_chars) <> "…"
    else
      reason
    end
  end

  defp truncate_reason(other), do: inspect(other)

  # Durable per-task home for the park, with NO status transition. Failure
  # path in the same shape as `stamp_blocked_reason/2`: log and continue.
  defp stamp_awaiting_human_action(task_id, action) do
    case Tasks.stamp_awaiting_human_action(task_id, action) do
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
  # happened to surface first. Historically `Platform.Tasks.Plan` declared
  # `has_many(:stages, …)` with NO default preload order, so preloaded stages
  # came back in incidental DB order and the engine would dispatch a
  # higher-position stage while lower-position ones were still pending
  # (observed on task 019edb16: engine dispatched stage 3, then 4, while 1
  # and 2 stayed `pending`). That association now carries
  # `preload_order: [asc: :position]` (ticket 01a077e7), so a PRELOADED list
  # already arrives sorted.
  #
  # The sort stays anyway, and not as superstition: `plan` reaches here from
  # several places, and nothing stops a caller building the struct with a
  # hand-assembled `:stages` list that never went through the association at
  # all — `Tasks.replace_plan_stages/3` returns exactly such a struct. Sorting
  # here makes dispatch order a property of this function rather than a
  # property of how its argument happened to be constructed.
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
      "runtime_id" => RuntimeSupervision.self_filed_runtime_id(),
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
