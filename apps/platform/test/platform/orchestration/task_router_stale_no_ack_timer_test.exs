defmodule Platform.Orchestration.TaskRouterStaleNoAckTimerTest do
  @moduledoc """
  `handle_info(:check_no_ack, ...)` must treat a timer wake as "look at the
  lease", not as "the ack window closed" (task 019fa469 stage 6).

  ## The reproduction this file pins

  On 2026-07-27 a `no_ack_timeout` fired against a live, acked agent **29
  seconds** after its dispatch — not the nominal 300. `arm_liveness_timers/3`
  always records the dispatch with `DateTime.utc_now()`, so the deadline was
  correct; the alarm was woken by the `Process.send_after` from the PREVIOUS
  dispatch, which nothing cancels (no ref is stored, nothing calls
  `Process.cancel_timer/1`). The handler then fired without ever comparing
  `now` to `lease.no_ack_at`.

  Its sibling `handle_info(:check_safety_net, ...)` has always made exactly
  that comparison and rescheduled when the deadline had not passed. One of two
  liveness handlers validated its own deadline and the other did not.

  ## Why the LeaseManager fix alone is not enough

  This stage also made `record_dispatch/4` preserve the ack on a same-stage
  re-dispatch, which stops the duplicate-dispatch form of the above. It cannot
  stop the stage-transition form: stage B's lease is CORRECTLY built with
  `ack_at: nil`, and stage A's orphan timer lands in the middle of B's window
  and sees exactly what a dropped runtime looks like. Same 29-second signature,
  unreachable by a `stage_id` comparison, because it IS a stage transition.
  `"orphan timer from the previous STAGE"` below is that case.

  ## Evidence shape

  Every "no alarm fired" assertion here is followed, on the same router and
  the same lease, by expiring the deadline and asserting the alarm DOES fire.
  A refutation on its own would pass just as happily against a handler that
  never fires at all — and the detector is what this stage edits.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.{ExecutionSpace, LeaseManager, TaskRouter}
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Stale Timer Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stale no-ack timer",
        description: "Pin the orphan-timer contract",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage_a} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage A",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage_a.id, kind: "test_pass"})

    {:ok, stage_b} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "stage B",
        description: "coding — stage 2"
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage_b.id, kind: "test_pass"})

    assignee = %{
      type: :federated,
      id: "runtime-stale-timer-#{System.unique_integer([:positive])}"
    }

    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      LeaseManager.clear(task.id)
    end)

    %{task: task, assignee: assignee, stage_a: stage_a, stage_b: stage_b}
  end

  # Boot a router and let its initial dispatch land. Returns the pid.
  defp boot_router!(task, assignee) do
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end

  # Drop the lease's no-ack deadline into the past. The ONE field that
  # differs between the two halves of every pair below.
  defp expire_no_ack_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row"
    assert lease.no_ack_at, "expected an armed deadline to expire"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | no_ack_at: past}})
    :ok
  end

  defp ack_via_runtime_event!(task, stage, assignee) do
    Tasks.broadcast_board(
      {:runtime_event,
       %{
         id: nil,
         task_id: task.id,
         stage_id: stage.id,
         event_type: "execution.acked",
         payload: %{},
         occurred_at: DateTime.utc_now(),
         runtime_id: assignee.id,
         phase: "execution",
         lease: nil
       }}
    )

    :ok = sync_router(task.id)
    assert %{ack_at: %DateTime{}} = LeaseManager.get(task.id)
    :ok
  end

  defp blocker_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.count(&String.contains?(&1.content, "Executor never acked"))
  end

  describe "a timer wake is not a deadline" do
    test "early wake reschedules and stays silent; the SAME lease fires once the deadline passes",
         %{task: task, assignee: assignee, stage_a: stage_a} do
      pid = boot_router!(task, assignee)

      # The window is wide open — `no_ack_at` is ~5 minutes out.
      assert %{no_ack_at: %DateTime{} = deadline, ack_at: nil} = LeaseManager.get(task.id)
      assert DateTime.compare(deadline, DateTime.utc_now()) == :gt

      before_blockers = blocker_count(task.id)

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status == :running
      assert blocker_count(task.id) == before_blockers

      # Counterfactual on the same router and the same lease: the only thing
      # that changes is the deadline. If the refutation above were passing
      # because the detector is broken rather than because it is patient,
      # this half would refute it.
      expire_no_ack_deadline!(task.id)
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      assert_received {:runtime_event,
                       %{event_type: "execution.no_ack_timeout", stage_id: fired_stage_id}}

      assert fired_stage_id == stage_a.id
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status == :stalled
      assert blocker_count(task.id) == before_blockers + 1
    end
  end

  describe "orphan timer from the previous STAGE" do
    test "does not fire against the incoming stage's fresh lease", %{
      task: task,
      assignee: assignee,
      stage_a: stage_a,
      stage_b: stage_b
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_runtime_event!(task, stage_a, assignee)

      # Stage A completes and stage B dispatches. `record_dispatch/4` is what
      # `arm_liveness_timers/3` calls; a different stage_id correctly yields a
      # fresh `ack_at: nil` row — stage B has not been acked, and the
      # same-stage preservation added by this stage deliberately does not
      # apply here.
      transition_at = DateTime.utc_now()
      :ok = LeaseManager.record_dispatch(task.id, stage_b.id, "coding", transition_at)
      assert %{stage_id: stage_b_id, ack_at: nil} = LeaseManager.get(task.id)
      assert stage_b_id == stage_b.id

      before_blockers = blocker_count(task.id)

      # Stage A's timer, armed 5 minutes before the transition and never
      # cancelled, lands here. Stage B's executor has had seconds to spawn.
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status != :stalled
      assert blocker_count(task.id) == before_blockers

      # …and stage B's OWN deadline still works. Without this half, a handler
      # that ignored `:check_no_ack` entirely would pass the refutation above.
      expire_no_ack_deadline!(task.id)
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      assert_received {:runtime_event,
                       %{event_type: "execution.no_ack_timeout", stage_id: fired_stage_id}}

      assert fired_stage_id == stage_b.id,
             "the alarm must name the stage whose window actually closed"

      assert blocker_count(task.id) == before_blockers + 1
    end
  end

  describe "duplicate dispatch of the SAME stage" do
    test "leaves an acked, mid-flight agent alone", %{
      task: task,
      assignee: assignee,
      stage_a: stage_a
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_runtime_event!(task, stage_a, assignee)

      # The duplicate `task_assigned` — same stage, ~4.5 minutes in.
      :ok = LeaseManager.record_dispatch(task.id, stage_a.id, "coding", DateTime.utc_now())

      assert %{ack_at: %DateTime{}, no_ack_at: nil} = LeaseManager.get(task.id),
             "a re-dispatch of the acked stage must not wipe the ack"

      before_blockers = blocker_count(task.id)

      # Both the orphan timer from the first dispatch and the fresh one from
      # the duplicate wake the handler. Neither may fire.
      send(pid, :check_no_ack)
      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status == :running
      assert blocker_count(task.id) == before_blockers
    end

    test "does NOT rescue a runtime that never acked once the original deadline passes", %{
      task: task,
      assignee: assignee,
      stage_a: stage_a
    } do
      pid = boot_router!(task, assignee)

      # No ack — this is the case the alarm exists for. Backdate the original
      # dispatch past the ack window, then hit it with a duplicate. If the
      # duplicate pushed `no_ack_at` forward, a dropped runtime would evade
      # the alarm for as long as duplicates kept arriving.
      elapsed = LeaseManager.stage_kind_timeouts()["coding"].ack_ms + 60_000
      original_at = DateTime.add(DateTime.utc_now(), -elapsed, :millisecond)

      LeaseManager.clear(task.id)
      :ok = LeaseManager.record_dispatch(task.id, stage_a.id, "coding", original_at)
      %{no_ack_at: original_deadline} = LeaseManager.get(task.id)

      :ok = LeaseManager.record_dispatch(task.id, stage_a.id, "coding", DateTime.utc_now())

      assert %{ack_at: nil, no_ack_at: ^original_deadline} = LeaseManager.get(task.id)

      before_blockers = blocker_count(task.id)

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status == :stalled
      assert blocker_count(task.id) == before_blockers + 1
    end
  end

  describe "leases with the alarm disabled" do
    test "an orphan timer never fires against a manual_approval lease", %{
      task: task,
      assignee: assignee,
      stage_b: stage_b
    } do
      pid = boot_router!(task, assignee)

      # `manual_approval` has a nil `ack_ms`, so the router arms no timer for
      # such a stage — but a timer armed for the PREVIOUS coding stage can
      # still reach it, and the handler used to fire on a lease whose alarm
      # was explicitly disabled.
      :ok =
        LeaseManager.record_dispatch(task.id, stage_b.id, "manual_approval", DateTime.utc_now())

      assert %{no_ack_at: nil, ack_at: nil} = LeaseManager.get(task.id)

      before_blockers = blocker_count(task.id)

      send(pid, :check_no_ack)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: false} = LeaseManager.get(task.id)
      assert TaskRouter.current_status(task.id).status != :stalled
      assert blocker_count(task.id) == before_blockers
    end
  end
end
