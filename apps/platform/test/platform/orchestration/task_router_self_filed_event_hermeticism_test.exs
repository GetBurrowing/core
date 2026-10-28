defmodule Platform.Orchestration.TaskRouterSelfFiledEventHermeticismTest do
  @moduledoc """
  Task 01a0a6e3 stage 2 — the router must not act on its OWN self-filed
  dispatch-trace events, and must still act on its own `execution.blocked`.

  This file is a sibling of `task_router_stageless_dispatch_trace_test.exs`
  rather than a fourth describe block inside it: that file is already 449 lines
  and is about the TRACE (does the event get written), while this one is about
  HERMETICISM (what happens when the router receives the event back). The
  harness — sandbox mode, project fixture, `start_router!/1`, the
  `sync_router/2` barrier, `await_token/2` — is mirrored from it verbatim, not
  reinvented.

  ## Scope of the property under test

  `Tasks.subscribe_board/0` means every event the router records with
  `RuntimeSupervision.self_filed_runtime_id()` comes back to the router as a
  `{:runtime_event, event}` message. Stage 1 added noop clauses for
  `execution.dispatch_stageless` and `execution.dispatch_unanswered`, and
  DELIBERATELY did not add one for `execution.blocked`. Each test below names
  one of those three decisions and is shown to fail when that decision is
  reversed.

  ## Anti-vacuity

  Every test asserts a POSITIVE precondition before the property: the router is
  observed to be `:stalled` (or the watchdog observed to be armed) before the
  self-filed event is delivered. A "still `:stalled`" assertion against a
  router that was never stalled would pass against any implementation at all.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Self-filed Hermeticism Project",
        repo_url: "https://github.com/test/self-filed-hermeticism"
      })

    %{project: project}
  end

  describe "clause 1 — execution.dispatch_stageless is inert on receipt" do
    test "a :stalled router receiving its own execution.dispatch_stageless stays :stalled", %{
      project: project
    } do
      # WHAT THIS PROTECTS, and a correction to the stage description.
      #
      # The stage brief predicted the harm of deleting this clause would be the
      # SUPPRESSION of the stageless watchdog: the event would stamp
      # `last_runtime_event_at`, making
      # `runtime_event_since_stageless_dispatch?/1` read true. That prediction
      # is FALSE on this tree, and the ordering test below is the measurement:
      # `RuntimeSupervision.record_event/1` stamps `occurred_at` in
      # `normalize_attrs/1` BEFORE the insert, and `arm_stageless_watchdog/2`
      # sets `stageless_dispatch_at` only on the `{:ok, _}` branch AFTERWARDS.
      # `apply_runtime_event/2` stamps `last_runtime_event_at` from
      # `event.occurred_at`, which is therefore strictly EARLIER than
      # `stageless_dispatch_at`, so the predicate returns false and the
      # watchdog is not suppressed. A "the watchdog still fires" test would be
      # green with AND without the clause — vacuous.
      #
      # The harm that IS live is the one this test asserts: the generic
      # `apply_runtime_event/2` arm runs `maybe_reset_stalled/1`, so without
      # the clause the router's own record of "I sent a frame that resolved no
      # stage" would clear a `:stalled` status that a no-ack or safety-net
      # alarm had set.
      %{task: task} = fixture = stage_task(project)
      %{pid: pid, runtime_id: owner} = start_router!(fixture)

      stalled_at = stall!(pid, task, owner)

      send(pid, {:runtime_event, self_filed_event(task.id, "execution.dispatch_stageless")})

      status = TaskRouter.current_status(task.id)

      assert status.status == :stalled,
             "observed #{inspect(Map.take(status, [:status, :last_runtime_event_at, :lease_status]))} — " <>
               "the router's own execution.dispatch_stageless must not clear a :stalled status"

      assert status.last_runtime_event_at == stalled_at,
             "the router's own dispatch trace is not runtime liveness and must not re-stamp " <>
               "last_runtime_event_at over the foreign event that stalled the router"
    end
  end

  describe "clause 2 — execution.dispatch_unanswered is inert on receipt" do
    test "a :stalled router receiving its own execution.dispatch_unanswered stays :stalled", %{
      project: project
    } do
      %{task: task} = fixture = stage_task(project)
      %{pid: pid, runtime_id: owner} = start_router!(fixture)

      stalled_at = stall!(pid, task, owner)

      send(pid, {:runtime_event, self_filed_event(task.id, "execution.dispatch_unanswered")})

      status = TaskRouter.current_status(task.id)

      assert status.status == :stalled,
             "observed #{inspect(Map.take(status, [:status, :last_runtime_event_at, :lease_status]))} — " <>
               "an event whose entire content is \"nothing came back\" must not be read as " <>
               "activity and reset the stall"

      assert status.last_runtime_event_at == stalled_at,
             "an unanswered-dispatch record must not be stamped as runtime liveness"
    end
  end

  describe "the ordering hazard that makes clause 1's suppression path unreachable" do
    test "stageless_dispatch_at is strictly after the recorded event's occurred_at", %{
      project: project
    } do
      # OPTION (a), chosen deliberately over option (b).
      #
      # (b) — the behavioural version — would have to run against a commit
      # WITHOUT clause 1, and once clause 1 is in place it asserts nothing, so
      # it could not live in this suite as a standing test. (a) survives on the
      # fixed tree, is cheap, and pins the exact invariant the suppression
      # hazard turns on: the event is RECORDED before the watchdog is ARMED.
      #
      # Swap those two lines in `maybe_record_stageless_dispatch/4` — the more
      # natural order, and a refactor nothing else would flag — and
      # `last_runtime_event_at` (taken from `occurred_at`) would land at or
      # after `stageless_dispatch_at`, so
      # `runtime_event_since_stageless_dispatch?/1` would read true off the
      # router's own record and `execution.dispatch_unanswered` could never
      # fire again. Clause 1 is what keeps that from mattering; this assertion
      # is what tells a reader WHY the clause-1 test above is written about
      # `maybe_reset_stalled/1` and not about suppression.
      put_watchdog_ms(60_000)

      %{task: task} = fixture = planning_task(project)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch)

      _token =
        await_token(task, 1) ||
          flunk(
            "ANTI-VACUITY: the watchdog was never armed, so stageless_dispatch_at is nil " <>
              "and the comparison below would be about a dispatch that never happened"
          )

      [event | _] = stageless_events(task.id)
      status = TaskRouter.current_status(task.id)

      assert %DateTime{} = status.stageless_dispatch_at

      assert DateTime.compare(status.stageless_dispatch_at, event.occurred_at) == :gt,
             "the execution.dispatch_stageless row must be recorded BEFORE the watchdog is " <>
               "armed; if this ever reads :lt or :eq, the record/arm order has been swapped " <>
               "and the watchdog can suppress itself off the router's own event"
    end
  end

  describe "regression control — the router's own execution.blocked is NOT inert" do
    test "a router-authored blocker with a nil payload stage_id still drives :waiting_human", %{
      project: project
    } do
      # This is the thing the ticket exists to protect, and the reason stage 1
      # added an allowlist entry instead of a third noop clause. Scoped
      # statement, because the unscoped one is false: seven sites in
      # `task_router.ex` assign `:waiting_human`, but for a ROUTER-AUTHORED
      # blocker (runtime_id == self_filed_runtime_id(), payload stage_id nil,
      # as `record_unresolved_stage_blocker/4` writes it) self-receipt through
      # `apply_runtime_event/2` is the live path. The pre-dispatch `human_hold`
      # guard does not cover it: `RuntimeSupervision.needs_human_hold/3`
      # filters on the assignee's runtime_id and returns nil for a nil
      # stage_id.
      #
      # `blocker_targets_current_stage?/2` maps a nil payload stage_id to true,
      # so the transition is unconditional for this shape. The other
      # `execution.blocked` emit site (`record_review_unrunnable_blocker/4`)
      # writes a REAL stage id and has its own drop path; it is out of scope
      # here and is deliberately not folded in.
      %{task: task} = fixture = stage_task(project)
      %{pid: pid} = start_router!(fixture)

      refute TaskRouter.current_status(task.id).status == :waiting_human,
             "ANTI-VACUITY: the router must not already be :waiting_human, or the " <>
               "assertion below is about a status it never transitioned into"

      send(pid, {:runtime_event, router_authored_blocker(task.id)})

      observed = TaskRouter.current_status(task.id)

      assert observed.status == :waiting_human,
             "observed #{inspect(Map.take(observed, [:status, :current_stage_id, :task_status, :last_runtime_event_at]))} — " <>
               "a router-authored execution.blocked must still reach :waiting_human — a noop " <>
               "clause for this type would leave the event row and the log line while " <>
               "silently disabling router self-blocking"
    end
  end

  describe "healthy controls — the noop clauses did not over-match" do
    # (a) An ANSWERED stageless dispatch still produces no
    # `execution.dispatch_unanswered`. Already covered, and cited rather than
    # duplicated: `task_router_stageless_dispatch_trace_test.exs`, describe
    # "stage 2 — an unanswered stageless dispatch records
    # execution.dispatch_unanswered", test "a runtime event arriving inside the
    # window suppresses the watchdog". That test feeds a FOREIGN
    # `execution.heartbeat` inside the window and refutes the unanswered row,
    # which is exactly assertion (a); re-writing it here would be a second copy
    # of the same measurement.

    test "only the owning runtime event stamps liveness and clears a stall", %{
      project: project
    } do
      # (b). The two new clauses match on `event_type` only, so the risk is not
      # that they match too few types but that a future edit generalises them.
      # A foreign `execution.heartbeat` must still run the generic arm: stamp
      # `last_runtime_event_at` and reset `:stalled` → `:running`.
      %{task: task} = fixture = stage_task(project)
      %{pid: pid, runtime_id: owner} = start_router!(fixture)

      stall!(pid, task, owner)

      event = foreign_event(task.id, "execution.heartbeat")
      send(pid, {:runtime_event, event})

      assert TaskRouter.current_status(task.id).status == :stalled
      owner_event = %{event | runtime_id: owner}
      send(pid, {:runtime_event, owner_event})
      status = TaskRouter.current_status(task.id)

      assert status.status == :running,
             "owning runtime liveness must reset a stalled router — the hermeticism " <>
               "clauses are scoped to the router's own two dispatch-trace types"

      assert status.last_runtime_event_at == event.occurred_at,
             "owning liveness must still be stamped"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # A `planning` task is used ONLY by the ordering test, which needs a dispatch
  # that resolves no stage. It is deliberately NOT used by the status tests:
  # `planning` starts a designer pre-plan run, and `{:design_edge_settled, _,
  # _}` / `{:DOWN, _, _, _, _}` set `status: :dispatching` asynchronously
  # (task_router.ex :971 / :1003), which was measured clobbering `:stalled`
  # between two consecutive `current_status/1` calls.
  defp planning_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Self-filed hermeticism probe",
        status: "planning"
      })

    %{task: task}
  end

  # An `in_progress` task with an approved plan and a running stage: no
  # designer run, so `status` is only moved by the thing under test.
  defp stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Self-filed hermeticism status probe",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    %{task: task, stage: stage}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Drives the router to `:stalled` through the ordinary runtime path
  # (`execution.failed` → lease cleared → `:stalled`) and ASSERTS it got
  # there. Every "stays :stalled" test below is vacuous without this check.
  #
  # Task 01a0dd2c stage 2: the failure is sent in the LEASE OWNER's name. A
  # foreign runtime's terminal event is now refused by
  # `LeaseManager.clear_if_owner/2` and no longer stalls the router, so the
  # stall must come from the runtime the stage was dispatched to.
  defp stall!(pid, task, owner_runtime_id) do
    event = %{foreign_event(task.id, "execution.failed") | runtime_id: owner_runtime_id}
    send(pid, {:runtime_event, event})

    # A plain `current_status/1` call, NOT `barrier/1`. `sync_router/2` drains
    # the debounced dispatch as well as the mailbox, and a drained dispatch
    # re-hydrates router state from the lease row — which was observed
    # resetting `:stalled` back to `:dispatching` before any assertion ran. The
    # GenServer call is already a complete mailbox barrier for a message sent
    # before it, which is all this needs.
    observed = TaskRouter.current_status(task.id)

    assert observed.status == :stalled,
           "ANTI-VACUITY: the router never reached :stalled, so a later \"still :stalled\" " <>
             "assertion would hold against any implementation. Observed: " <>
             inspect(Map.take(observed, [:status, :last_runtime_event_at, :task_status]))

    # Returned so callers can assert the self-filed event did not RE-stamp it.
    # `stall!/3` drives the stall through the owner's `execution.failed`, which
    # legitimately stamps liveness — "still nil" would be the wrong assertion.
    observed.last_runtime_event_at
  end

  # The shape the router writes for its own dispatch-trace events: self-filed
  # runtime id, nil payload stage_id, no lease.
  defp self_filed_event(task_id, event_type) do
    %RuntimeEvent{
      task_id: task_id,
      event_type: event_type,
      runtime_id: RuntimeSupervision.self_filed_runtime_id(),
      occurred_at: DateTime.utc_now(),
      payload: %{"stage_id" => nil, "reported_by" => "task_router"},
      lease: nil
    }
  end

  # The shape `record_unresolved_stage_blocker/4` writes.
  defp router_authored_blocker(task_id) do
    %RuntimeEvent{
      task_id: task_id,
      event_type: "execution.blocked",
      runtime_id: RuntimeSupervision.self_filed_runtime_id(),
      occurred_at: DateTime.utc_now(),
      payload: %{
        "stage_id" => nil,
        "needs_human" => true,
        "reported_by" => "task_router",
        "description" => "Task #{task_id} is at in_progress but NO stage is pending or running."
      },
      lease: nil
    }
  end

  defp foreign_event(task_id, event_type) do
    %RuntimeEvent{
      task_id: task_id,
      event_type: event_type,
      runtime_id: "runtime-foreign-#{System.unique_integer([:positive])}",
      occurred_at: DateTime.utc_now(),
      payload: %{},
      lease: nil
    }
  end

  defp stageless_events(task_id) do
    Repo.all(
      from(e in RuntimeEvent,
        where: e.task_id == ^task_id and e.event_type == "execution.dispatch_stageless",
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp put_watchdog_ms(ms) do
    previous = Application.get_env(:platform, :task_router_stageless_watchdog_ms)
    Application.put_env(:platform, :task_router_stageless_watchdog_ms, ms)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :task_router_stageless_watchdog_ms)
        value -> Application.put_env(:platform, :task_router_stageless_watchdog_ms, value)
      end
    end)
  end

  defp await_token(task, expected, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case TaskRouter.current_status(task.id) do
        %{stageless_dispatch_token: token} when token >= expected ->
          {:halt, token}

        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  # Mirrors `task_router_stageless_dispatch_trace_test.exs`: subscribe before
  # boot so the boot dispatch is observable, drain it with the barrier.
  defp start_router!(%{task: task}) do
    runtime_id = "runtime-hermetic-#{System.unique_integer([:positive])}"
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

    assignee = %{type: :federated, id: runtime_id}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    barrier(task)

    %{pid: pid, runtime_id: runtime_id}
  end

  defp barrier(task) do
    :ok = sync_router(task.id)
    TaskRouter.current_status(task.id)
  end
end
