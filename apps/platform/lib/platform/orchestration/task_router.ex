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

  manual_approval stages get NO liveness timers (both `ack_ms` and
  `safety_net_ms` are `nil` in `LeaseManager.stage_kind_timeouts/0`); a daily
  digest surfaces long-pending review requests separately (out of scope for
  this task).

  All decisions remain deterministic — no LLM in the router.
  """

  use GenServer

  require Logger

  # ADR-0046 member 7 stage 5 — how long a pre-plan design step may hold the
  # planner before it is expired and planning proceeds anyway.
  #
  # The literal lives here and the READ goes through `Application.get_env/3` so
  # a test can inject a small value per-case. There is deliberately NO override
  # in `config/test.exs`: a test-only config value that silently becomes the
  # production one is exactly the amended-safety-net failure this stack is
  # written against. `default_design_step_timeout_ms/0` exposes the literal so a
  # guard can assert the shipped default independently of whatever a running
  # test has injected.
  @design_step_timeout_ms 1_800_000

  alias Platform.Design.PreplanStep
  alias Platform.Execution.CredentialLease
  alias Platform.Federation

  alias Platform.Orchestration.{
    ContextAssembler,
    ExecutionSpace,
    HeartbeatScheduler,
    LeaseManager,
    RuntimeSupervision
  }

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{DeployResolver, ReviewRequests, Stage}

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
            task_status: String.t() | nil,
            lease_status: String.t() | nil,
            deploy_lease: CredentialLease.t() | nil,
            design_deadline_ref: reference() | nil,
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
      :task_status,
      :lease_status,
      :deploy_lease,
      # ADR-0046 member 7 stage 5. Purely an OPTIMISATION: it exists so a hold
      # that nothing else pokes still ends on time. It is NOT the correctness
      # guarantee, and it deliberately holds no information the DB does not
      # already carry — see `design_hold_expired?/2`.
      :design_deadline_ref,
      # ADR-0046 member 5 stage 5. Held only so a re-arm can cancel the
      # previous one-shot instead of stacking duplicates; the timer is an
      # optimisation, never the correctness guarantee (see
      # `handle_info({:architecture_gate_deadline, _}, _)`).
      :architecture_deadline_ref,
      status: :dispatching
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

  @doc """
  How long a pre-plan design step may hold the planner, in milliseconds.

  Read through `Application.get_env/3` on every use so a test can inject a
  small value for one case without a `config/test.exs` entry.
  """
  @spec design_step_timeout_ms() :: pos_integer()
  def design_step_timeout_ms do
    Application.get_env(:platform, :design_step_timeout_ms, @design_step_timeout_ms)
  end

  @doc """
  The SHIPPED default hold window (30 minutes), independent of any injected
  config. Exposed so a guard can prove a test-only value has not become the
  production one.
  """
  @spec default_design_step_timeout_ms() :: pos_integer()
  def default_design_step_timeout_ms, do: @design_step_timeout_ms

  defp via(task_id) do
    {:via, Registry, {Platform.Orchestration.Registry, task_id}}
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(%{task_id: task_id, assignee: assignee}) do
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
      lease_status: state.lease_status
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    # START SITE for the pre-plan design step (ADR-0046 member 7 stage 5).
    # Deliberately here and not on the `backlog -> planning` transition: that
    # transition has FOUR writers with four different gate sets
    # (`Tasks.transition_task/3`, `transition_task_status/2`,
    # `drop_task_to_column/3`, and the unguarded `update_task/3` that
    # `Stacks.promote/1` uses), and a fifth the day someone adds one. All five
    # funnel into a router, because `TaskRouterWatcher.should_run?/1` spawns one
    # for any task in `planning`. One chokepoint instead of five.
    task =
      state.task_id
      |> Tasks.get_task_detail()
      |> maybe_start_design_step(state)

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

      design_step_open?(task) ->
        # Pre-dispatch guard, DESIGN level (ADR-0046 member 7 stage 5).
        # "Design runs BEFORE planning" is only true if the planner actually
        # waits. Ordered AFTER `pending_review_request?/1` on purpose: a human
        # gate outranks a machine one.
        handle_design_hold(state, task)

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

        emit_dispatch_suppressed_telemetry(state.task_id)

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
            maybe_fire_no_ack(state, task_id, lease)
        end

      lease ->
        maybe_fire_no_ack(state, task_id, lease)
    end
  end

  # `:design_deadline` — armed once per design hold. This is the EAGER path,
  # not the correctness path: `handle_design_hold/2` re-derives the same
  # verdict from the DB on every dispatch tick, so losing this message (router
  # restart, a `Process.cancel_timer/1` race) costs latency and nothing else.
  #
  # Both branches below are LEVEL checks against `PreplanStep.open?/1`, never
  # against router state. A timer that fires after `settle/2` already closed
  # the step must not re-open it as a failure and must not re-dispatch — the
  # settle wake-up in `{:task_updated, _}` already did.
  def handle_info(:design_deadline, %State{} = state) do
    state = %{state | design_deadline_ref: nil}

    case Tasks.get_task_detail(state.task_id) do
      nil ->
        {:noreply, state}

      task ->
        if design_step_open?(task) do
          expire_design_step(task)
          send(self(), :dispatch)
          {:noreply, %{state | status: :dispatching}}
        else
          {:noreply, state}
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
              fire_safety_net_alert(state, lease)
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

    # DESIGN WAKE-UP (ADR-0046 member 7 stage 5). `PreplanStep.settle/2` closes
    # the step through `Tasks.set_planning_step/2`, which broadcasts
    # `{:task_updated, _}` — so no new subscription is needed. But this handler
    # did NOT previously re-dispatch, so without this the planner would stay
    # parked until some unrelated tick arrived. The stage brief asserted the
    # re-dispatch already existed; it did not.
    #
    # EDGE-TRIGGERED ON PURPOSE, and this is the one place in the stage where
    # that is the right shape. `settle/2` emits more than one `{:task_updated}`
    # (the outcome write, then the cursor write), and `update_task/3` emits more
    # for reasons that have nothing to do with design. Leaving `:waiting_design`
    # in the same expression that sends the dispatch makes the status itself the
    # de-duplication token: exactly one dispatch per hold, asserted by count.
    # The edge is safe here only because the LEVEL check in
    # `handle_design_hold/2` is what actually bounds the hold — if this wake-up
    # never fires at all, the hold still ends.
    state =
      if state.status == :waiting_design do
        release_design_hold_if_closed(state)
      else
        state
      end

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

          cond do
            # Deploy stage failed — bounce deploying → in_progress
            task && task.status == "deploying" ->
              handle_deploy_stage_failure(state, task, stage)

            # Review stage failed — bounce in_review → in_progress
            task && task.status == "in_review" ->
              case Tasks.transition_task(task, "in_progress") do
                {:ok, _updated} ->
                  Logger.info(
                    "[TaskRouter] review stage failed — bounced task #{state.task_id} back to in_progress"
                  )

                {:error, reason} ->
                  Logger.warning(
                    "[TaskRouter] failed to bounce task #{state.task_id} to in_progress: #{inspect(reason)}"
                  )
              end

            true ->
              :ok
          end

          # Re-dispatch so the agent picks up the in_progress prompt. The
          # subsequent `do_dispatch/2` call will `record_dispatch/4` +
          # re-arm liveness timers automatically.
          if state.execution_space_id do
            ExecutionSpace.post_log(
              state.execution_space_id,
              "Stage failure bounced task back to in_progress | " <>
                diagnostic_snapshot(state, task, stage_override: stage)
            )
          end

          send(self(), :dispatch)
          %{state | status: :running}
        else
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

  # Board PubSub: plan completed for our task
  # in_progress → in_review (execution plan done, hand off to review)
  # in_review   → deploying (review plan done, deploy stage injected by PlanEngine)
  # deploying   → done      (deploy stage passed)
  def handle_info(
        {:plan_updated, %{task_id: task_id, status: "completed"} = plan},
        %State{task_id: task_id} = state
      ) do
    task = Tasks.get_task_detail(task_id)

    if task do
      {target_status, log_label} =
        case task.status do
          "in_progress" ->
            {"in_review", "execution plan completed"}

          "in_review" ->
            {"deploying", "review plan completed"}

          "deploying" ->
            # A `completed` plan is NOT sufficient evidence that the deploy
            # landed — see task 019f9b34 / incident 019f9ae5, where a stale
            # `completed` broadcast emitted by `inject_deploy_stage/4` flipped
            # the task to `done` eight minutes before its PR merged, with the
            # deploy stage still `running`. Require the deploy stage itself to
            # be terminal before promoting deploying -> done.
            if deploy_stage_settled?(Map.get(plan, :id)) do
              {"done", "deploy completed"}
            else
              Logger.warning(
                "[TaskRouter] held task #{task_id} at deploying — plan #{inspect(Map.get(plan, :id))} " <>
                  "broadcast `completed` but its deploy stage is #{inspect(unsettled_deploy_statuses(Map.get(plan, :id)))}. " <>
                  "Something upstream completed the plan early (see task 019f9b34)."
              )

              {nil, "deploy stage still running — holding at deploying"}
            end

          other ->
            {nil, other}
        end

      if target_status do
        case Tasks.transition_task(task, target_status) do
          {:ok, _updated} ->
            Logger.info(
              "[TaskRouter] #{log_label} — transitioned task #{task_id} to #{target_status}"
            )

          {:error, reason} ->
            Logger.warning(
              "[TaskRouter] failed to transition task #{task_id} to #{target_status}: #{inspect(reason)}"
            )
        end
      end
    end

    # Phase boundary — clear the prior stage's liveness. Next dispatch will
    # arm fresh timers keyed off the new phase's first stage.
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

  @impl true
  def terminate(_reason, state) do
    clear_liveness(state)
    revoke_deploy_lease(state)

    # Archive execution space on shutdown (best-effort — DB may be unavailable)
    if state.execution_space_id do
      try do
        ExecutionSpace.post_log(
          state.execution_space_id,
          "Task router stopped for task #{state.task_id}"
        )

        ExecutionSpace.archive(state.task_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Dispatch helpers ───────────────────────────────────────────────────

  defp do_dispatch(state, task) do
    plan = Tasks.current_plan(state.task_id)
    stage = current_running_stage(plan)

    # Capture the INCOMING status before the unconditional
    # `Map.put(:status, :running)` below overwrites it. Both tail branches of
    # this function re-check `waiting_for_human_review?/1` and can park the
    # router at `:waiting_human`; those parks need an edge, and by then
    # `state.status` has already been clobbered to `:running`. See the
    # episode-start narration at those two sites (task 019f9b34).
    entry_status = state.status

    # Stage-level responsibility routing (task 019f5d47 — progressive enhancement).
    # `state.assignee` stays fixed on the phase assignee so bookkeeping keys off
    # task-level identity; only the runtime broadcast target changes per-dispatch
    # when a stage carries a `responsibility` role key. If the role is
    # unassigned or the target runtime is offline, we fall back to
    # `state.assignee` and emit telemetry — never blocks dispatch.
    dispatch_assignee = resolve_stage_dispatch_assignee(stage, task, state) || state.assignee

    # Lease deploy credentials if this is a deploy stage
    state = maybe_lease_deploy_credentials(state, task, stage)

    context = ContextAssembler.build(state.task_id, state.deploy_lease)
    {agent, runtime} = Federation.lookup_assignment(dispatch_assignee.id)
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
        parent_plans: parent_plans
      )

    case dispatch_attention(dispatch_assignee, state.task_id, "task_assigned", context, prompt) do
      :ok ->
        # Post log message to execution space after successful runtime dispatch so
        # boot retries do not duplicate task-assigned chatter.
        if state.execution_space_id do
          stage_count = if plan, do: length(plan.stages || []), else: 0
          stage_pos = if stage, do: stage.position, else: 1

          assignee_log =
            if dispatch_assignee.id == state.assignee.id do
              "Assignee: #{state.assignee.id}"
            else
              "Assignee: #{state.assignee.id} (stage-routed to #{dispatch_assignee.id})"
            end

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

  # Resolve a stage-level responsibility (e.g. `"designer"`) to a `%{type: :federated, id: runtime_id}`
  # tuple pointing at the current role owner's runtime. Returns `nil` when the
  # stage carries no responsibility, when the role has no assignee, when the
  # assigned agent doesn't exist, or when that agent isn't linked to a live
  # runtime. Fallback paths emit `[:platform, :plans, :stage_dispatch,
  # :assignee_unresolvable]` telemetry so observability captures degraded
  # dispatches (Stage 4 bridges this into the audit trail).
  defp resolve_stage_dispatch_assignee(nil, _task, _state), do: nil
  defp resolve_stage_dispatch_assignee(%{responsibility: nil}, _task, _state), do: nil

  defp resolve_stage_dispatch_assignee(%{responsibility: role_key} = stage, task, state)
       when is_binary(role_key) do
    case Platform.Roles.agent_id_for_role(role_key) do
      nil ->
        emit_stage_dispatch_fallback(stage, task, state, :role_unresolvable)
        nil

      agent_id ->
        case Repo.get(Platform.Agents.Agent, agent_id) do
          nil ->
            emit_stage_dispatch_fallback(stage, task, state, :agent_not_found)
            nil

          agent ->
            case Federation.get_runtime_for_agent(agent) do
              nil ->
                emit_stage_dispatch_fallback(stage, task, state, :runtime_unresolvable)
                nil

              runtime ->
                %{type: :federated, id: runtime.runtime_id}
            end
        end
    end
  end

  defp resolve_stage_dispatch_assignee(_stage, _task, _state), do: nil

  defp emit_stage_dispatch_fallback(stage, task, state, reason) do
    :telemetry.execute(
      [:platform, :plans, :stage_dispatch, :assignee_unresolvable],
      %{count: 1},
      %{
        stage_id: stage.id,
        task_id: task.id,
        responsibility: stage.responsibility,
        fallback_runtime_id: state.assignee.id,
        reason: reason,
        actor_type: "system",
        resource_type: "stage",
        resource_id: stage.id
      }
    )
  end

  defp dispatch_attention(%{type: :federated, id: runtime_id}, task_id, reason, context, prompt) do
    task_status = context[:task][:status] || context[:task]["status"]
    space_id = context[:execution_space_id]

    payload = %{
      signal: %{reason: reason, task_id: task_id, task_status: task_status, space_id: space_id},
      context: context,
      message: %{content: prompt, author: "TaskRouter"}
    }

    topic = "runtime:#{runtime_id}"

    case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
      :ok ->
        Logger.info("[TaskRouter] dispatched #{reason} to #{topic} for task #{task_id}")
        :ok

      {:error, err} ->
        Logger.error("[TaskRouter] broadcast failed to #{topic}: #{inspect(err)}")
        {:error, :broadcast_failed}
    end
  rescue
    error in ArgumentError ->
      Logger.warning(
        "[TaskRouter] endpoint not ready while dispatching #{reason} for task #{task_id}: #{Exception.message(error)}"
      )

      {:error, :endpoint_not_ready}
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

  # Idempotency-guarded fire path shared by `handle_info(:check_no_ack, ...)`'s
  # default no-silence branch and the silence-lapsed fall-through above.
  # `mark_no_ack_fired/1` flips the LeaseManager row's `no_ack_fired?`
  # atomically — if it returns anything other than `{:ok, :fired}`
  # (already-fired race), we swallow the check with no state change.
  defp maybe_fire_no_ack(%State{} = state, task_id, lease) do
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

    post_router_blocker(
      state,
      "Executor never acked the dispatch. No `task_ack` runtime event received within " <>
        "#{div(elapsed_ms, 1_000)}s of dispatch — the runtime likely dropped before " <>
        "the agent spawned. Manual intervention required.",
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

    post_router_blocker(
      state,
      "Stage safety-net exceeded (#{div(elapsed_ms, 60_000)}m elapsed for #{lease.stage_kind}). " <>
        "The executor acked but has not produced validation progress within the stage's safety-net window. " <>
        "Check whether the agent is stuck; manual intervention may be required.",
      %{
        "reason" => "execution.safety_net_fired",
        "stage_id" => lease.stage_id,
        "stage_kind" => lease.stage_kind,
        "needs_human" => true,
        "elapsed_ms" => elapsed_ms
      }
    )
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

      _ ->
        state
    end
  end

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
        _ = LeaseManager.record_ack(state.task_id)

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
        Enum.map(targets, fn target -> target["name"] || inspect(target) end)

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

  # LEVEL CHECK. Pure function of (task row, now) — no router state, no timer.
  defp design_hold_expired?(task, timeout_ms) do
    case Map.get(task, :updated_at) do
      %DateTime{} = at ->
        DateTime.diff(DateTime.utc_now(), at, :millisecond) >= timeout_ms

      %NaiveDateTime{} = at ->
        NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :millisecond) >= timeout_ms

      _ ->
        false
    end
  end

  defp handle_design_hold(state, task) do
    timeout_ms = design_step_timeout_ms()

    if design_hold_expired?(task, timeout_ms) do
      # Overdue reads as expired at the LEVEL check, without waiting for the
      # timer. Falls straight into `do_dispatch/2` in the same tick rather than
      # re-sending `:dispatch`: re-sending would loop forever if the expiry
      # write failed and left the cursor at `"designing"`.
      Logger.info(
        "[TaskRouter] design step overdue for task=#{state.task_id} " <>
          "(timeout=#{timeout_ms}ms) — expiring and releasing the planner"
      )

      expire_design_step(task)

      state = cancel_design_deadline(state)
      do_dispatch(state, Tasks.get_task_detail(state.task_id) || task)
    else
      hold_for_design(state, task, timeout_ms)
    end
  end

  defp hold_for_design(state, task, timeout_ms) do
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
      # NOT optional. Leaving the ack timer armed would fire
      # `execution.no_ack_timeout` five minutes into a LEGITIMATELY held design
      # step — the same liveness-signal miscalibration journalled for
      # screenshot-driven UI stages, where the router alerted on a stage that
      # was working exactly as designed.
      |> clear_liveness()
      |> Map.put(:status, :waiting_design)
      |> arm_design_deadline(task, timeout_ms)

    {:noreply, state}
  end

  # Armed once per hold: a live ref is left alone, so repeated ticks against an
  # open step do not stack timers.
  defp arm_design_deadline(%State{design_deadline_ref: ref} = state, _task, _timeout_ms)
       when is_reference(ref),
       do: state

  defp arm_design_deadline(%State{} = state, task, timeout_ms) do
    # Fire when the DB-derived deadline lapses, not `timeout_ms` from now. A
    # router that boots into an already-half-elapsed hold inherits the
    # remaining window instead of restarting the clock, which is what keeps a
    # crash-loop from extending the hold without bound.
    remaining =
      case Map.get(task, :updated_at) do
        %DateTime{} = at ->
          timeout_ms - DateTime.diff(DateTime.utc_now(), at, :millisecond)

        %NaiveDateTime{} = at ->
          timeout_ms - NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :millisecond)

        _ ->
          timeout_ms
      end

    ref = Process.send_after(self(), :design_deadline, max(remaining, 0))
    %{state | design_deadline_ref: ref}
  end

  defp cancel_design_deadline(%State{design_deadline_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | design_deadline_ref: nil}
  end

  defp cancel_design_deadline(%State{} = state), do: %{state | design_deadline_ref: nil}

  # Enveloped: `expire/2` already rescues internally, and this belt-and-braces
  # layer exists so a fault in the seam itself cannot take the dispatch tick
  # down. The return value is deliberately IGNORED by both callers — design
  # falls open whatever happens here.
  defp expire_design_step(task) do
    PreplanStep.expire(task, design_step_timeout_ms())
  rescue
    e ->
      Logger.warning("[TaskRouter] design expire raised: #{Exception.message(e)}")
      {:error, :expire_raised}
  catch
    :exit, reason ->
      Logger.warning("[TaskRouter] design expire exited: #{inspect(reason)}")
      {:error, :expire_exited}
  end

  # Re-read from the DB rather than trusting the broadcast payload: the wake-up
  # must observe the same field the hold reads, from the same place.
  defp release_design_hold_if_closed(%State{} = state) do
    task = Tasks.get_task_detail(state.task_id)

    if design_step_open?(task) do
      state
    else
      Logger.info(
        "[TaskRouter] design step closed for task=#{state.task_id} — releasing the planner"
      )

      send(self(), :dispatch)

      state
      |> cancel_design_deadline()
      |> Map.put(:status, :dispatching)
    end
  end

  # Idempotent by construction on the `PreplanStep` side (`{:ok, :already_settled}`
  # / `{:ok, :already_open}` short-circuit before any fire), which is what makes
  # calling it on EVERY tick free. Gated on the pre-plan window: status
  # `planning` with no plan of any status yet.
  #
  # The re-read is load-bearing. `start/1` can move the cursor to `"designing"`,
  # and `design_step_open?/1` below reads the cursor — handing it the pre-start
  # struct would dispatch the planner straight into the step this stage exists
  # to wait for.
  defp maybe_start_design_step(nil, _state), do: nil

  defp maybe_start_design_step(task, %State{} = state) do
    if task.status == "planning" and Tasks.latest_plan(task.id) == nil do
      _ = safe_start_design_step(task)
      Tasks.get_task_detail(state.task_id) || task
    else
      task
    end
  end

  defp safe_start_design_step(task) do
    PreplanStep.start(task)
  rescue
    e ->
      Logger.warning("[TaskRouter] design step start raised: #{Exception.message(e)}")
      {:error, :start_raised}
  catch
    :exit, reason ->
      Logger.warning("[TaskRouter] design step start exited: #{inspect(reason)}")
      {:error, :start_exited}
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

  defp emit_dispatch_suppressed_telemetry(task_id) do
    :telemetry.execute(
      [:platform, :orchestration, :dispatch_suppressed],
      %{count: 1},
      %{task_id: task_id, reason: :settled_stack_member}
    )

    :ok
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

  # True when every deploy stage on the plan has reached a terminal state.
  # `Enum.all?/2` over an empty list is `true`, which is the right default: a
  # plan with no deploy stage at all is unaffected by this guard.
  defp deploy_stage_settled?(nil), do: true

  defp deploy_stage_settled?(plan_id) do
    plan_id
    |> deploy_stages()
    |> Enum.all?(&(&1.status in ~w(passed skipped)))
  end

  # Diagnostic companion to `deploy_stage_settled?/1` — the statuses of the
  # deploy stages that are holding the task back, for the warning log.
  defp unsettled_deploy_statuses(plan_id) do
    plan_id
    |> deploy_stages()
    |> Enum.reject(&(&1.status in ~w(passed skipped)))
    |> Enum.map(&"#{&1.name}=#{&1.status}")
  end

  defp deploy_stages(nil), do: []

  defp deploy_stages(plan_id) do
    plan_id
    |> Tasks.list_stages()
    |> Enum.filter(&deploy_stage?/1)
  end

  # ── Deploy failure handling ────────────────────────────────────────────

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
