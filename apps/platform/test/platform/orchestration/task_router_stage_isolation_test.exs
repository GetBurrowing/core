defmodule Platform.Orchestration.TaskRouterStageIsolationTest do
  @moduledoc """
  End-to-end integration coverage for the stage-scoped lease + blocker
  contract shipped by task 019f6791. Where the per-module unit tests
  (`task_router_test.exs`, `runtime_supervision_test.exs`) exercise
  each helper in isolation, this suite drives the full sequence Rowan
  observed on task 019f6380 through the public API surface:

    * `Tasks.broadcast_board({:stage_transitioned, stage})` +
      `Ecto.Changeset.change` for stage lifecycle
    * `RuntimeSupervision.record_event/1` for runtime-event ingestion
    * `TaskRouter.start_link/1` + `TaskRouter.stop/1` for router boot /
      shutdown (rehydration path)
    * `TaskRouter.current_status/1` + subscription to
      `"runtime:<assignee>"` on `Platform.PubSub` for observation

  The four cases mirror the contract in the stage 4 plan spec:

    1. Bug repro — a blocker filed against stage B must not leak into
       stage C after the plan transitions.
    2. Historical blocker — a leaked `blocked` lease attached to a
       `passed` stage must not gate the currently-running stage's
       initial dispatch.
    3. Stage-scoped no-ack — the router's `:check_no_ack` timer must
       alert on the current stage's own lease, independent of any
       stale prior-stage lease still sitting in the DB.
    4. Router restart — after `stop/1` + `start_link/1`, a live
       blocker on the running stage must be preserved while a stale
       lease on a prior `passed` stage must be ignored.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.{
    ExecutionLease,
    ExecutionSpace,
    LeaseManager,
    RuntimeSupervision,
    TaskRouter
  }

  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stage Isolation Project #{System.unique_integer([:positive])}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stage Isolation Task",
        description: "Exercise the stage-scoped lease contract end-to-end",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    now = DateTime.utc_now()

    # 4-stage plan (A, B, C, D). A is already `passed`, B is `running`,
    # C and D are `pending`. Mirrors the real-world state at the moment
    # the router boots for a task that's mid-flight (task 019f6380 was
    # in this exact shape when the leak fired).
    {:ok, stage_a} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage A",
        description: "coding — stage 1",
        status: "passed",
        started_at: DateTime.add(now, -600, :second),
        completed_at: DateTime.add(now, -60, :second)
      })

    {:ok, _val_a} = Tasks.create_validation(%{stage_id: stage_a.id, kind: "test_pass"})

    {:ok, stage_b} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "stage B",
        description: "coding — stage 2",
        status: "running",
        started_at: DateTime.add(now, -30, :second)
      })

    {:ok, _val_b} = Tasks.create_validation(%{stage_id: stage_b.id, kind: "test_pass"})

    {:ok, stage_c} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 3,
        name: "stage C",
        description: "coding — stage 3"
      })

    {:ok, _val_c} = Tasks.create_validation(%{stage_id: stage_c.id, kind: "test_pass"})

    {:ok, stage_d} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 4,
        name: "stage D",
        description: "coding — stage 4"
      })

    {:ok, _val_d} = Tasks.create_validation(%{stage_id: stage_d.id, kind: "test_pass"})

    assignee = %{
      type: :federated,
      id: "runtime-stage-isolation-#{System.unique_integer([:positive])}"
    }

    # Dynamically spawned routers need to share the sandbox conn.
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

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{
      project: project,
      task: task,
      plan: plan,
      stage_a: stage_a,
      stage_b: stage_b,
      stage_c: stage_c,
      stage_d: stage_d,
      assignee: assignee
    }
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp seed_blocked_lease!(task_id, stage_id, runtime_id, opts) do
    now = DateTime.utc_now()
    reason = Keyword.get(opts, :reason, "seeded stale blocker")

    %ExecutionLease{}
    |> ExecutionLease.changeset(%{
      task_id: task_id,
      phase: "execution",
      runtime_id: runtime_id,
      stage_id: stage_id,
      status: "blocked",
      block_reason: reason,
      started_at: now,
      expires_at: DateTime.add(now, 15 * 60, :second)
    })
    |> Platform.Repo.insert!()
  end

  defp await_attention!(timeout \\ 1_000) do
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: _topic,
                     event: "attention",
                     payload: %{signal: %{reason: "task_assigned"}} = payload
                   },
                   timeout

    payload
  end

  # ------------------------------------------------------------------
  # Cases
  # ------------------------------------------------------------------

  test "stage 2 blocker does not leak into stage 3 dispatch", %{
    task: task,
    assignee: assignee,
    stage_b: stage_b,
    stage_c: stage_c
  } do
    Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    # Initial dispatch for stage B fires.
    await_attention!()
    Process.sleep(50)

    assert %{current_stage_id: current_id, status: :running} =
             TaskRouter.current_status(task.id)

    assert current_id == stage_b.id

    # File a legitimate blocker against stage B via the runtime-event
    # ingestion path. Router should flip to :waiting_human because the
    # blocker targets the current stage.
    {:ok, _event} =
      RuntimeSupervision.record_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => assignee.id,
        "event_type" => "execution.blocked",
        "payload" => %{
          "stage_id" => stage_b.id,
          "description" => "waiting on subagent",
          "needs_human" => false
        }
      })

    # `record_event/1` broadcasts on `tasks:board` which the router
    # subscribes to — allow the message to arrive.
    Process.sleep(100)

    assert TaskRouter.current_status(task.id).status == :waiting_human

    # Confirm the DB row exists for stage B.
    assert %{status: "blocked", stage_id: stage_b_id} =
             RuntimeSupervision.current_lease_for_stage(task.id, stage_b.id)

    assert stage_b_id == stage_b.id

    # Now transition B → passed and C → running (mirrors PlanEngine
    # finalize/advance). The router's stage-transition handler must
    # (a) drop stage B's lease, (b) reset :waiting_human → :dispatching,
    # (c) send `:dispatch` so a fresh attention broadcast fires for C.
    stage_b
    |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
    |> Platform.Repo.update!()

    stage_c
    |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
    |> Platform.Repo.update!()

    passed_b = Platform.Repo.get!(Platform.Tasks.Stage, stage_b.id)
    running_c = Platform.Repo.get!(Platform.Tasks.Stage, stage_c.id)

    Tasks.broadcast_board({:stage_transitioned, passed_b})
    Tasks.broadcast_board({:stage_transitioned, running_c})

    # Fresh dispatch attention for stage C must fire within 500ms.
    await_attention!(500)
    Process.sleep(50)

    status = TaskRouter.current_status(task.id)
    assert status.current_stage_id == stage_c.id
    assert status.status == :running
    refute status.lease_status == "blocked"
    # Old blocker's activity timestamp must not survive the transition.
    assert status.last_runtime_event_at == nil

    # Stage B's blocker row was abandoned by the transition handler.
    assert nil == RuntimeSupervision.current_lease_for_stage(task.id, stage_b.id)

    # Sanity: router still owns the process.
    assert Process.alive?(pid)
  end

  test "historical blocker on passed stage 1 does not gate stage 2 dispatch", %{
    task: task,
    assignee: assignee,
    stage_a: stage_a,
    stage_b: stage_b
  } do
    # Stage A already `passed` (from setup); seed a leaked `blocked`
    # lease against it — the shape a router boot after a crash would
    # find in the DB. Stage B is the currently-running stage.
    seed_blocked_lease!(task.id, stage_a.id, assignee.id,
      reason: "leaked historical blocker on stage A"
    )

    Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

    {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    # Fresh attention broadcast for stage B fires normally — the stale
    # stage-A `blocked` row must NOT gate the initial dispatch.
    await_attention!()
    Process.sleep(50)

    status = TaskRouter.current_status(task.id)
    assert status.current_stage_id == stage_b.id
    assert status.status == :running
    # State.lease_status must not surface the stage-A blocker.
    refute status.lease_status == "blocked"

    # The stale stage-A lease is still present in the DB — this fix is
    # about not rehydrating it into router state, not about deleting
    # arbitrary historical rows.
    assert %{status: "blocked", stage_id: stage_a_id} =
             RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)

    assert stage_a_id == stage_a.id
  end

  test "no_ack alarm fires per stage, independent of prior stage state", %{
    task: task,
    assignee: assignee,
    stage_a: stage_a,
    stage_b: stage_b
  } do
    # Stage A carries a stale `blocked` lease (like case 2).
    seed_blocked_lease!(task.id, stage_a.id, assignee.id,
      reason: "leaked historical blocker on stage A"
    )

    Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    # Initial dispatch arms the ack timer via LeaseManager.
    await_attention!()
    Process.sleep(100)

    # The router recorded a dispatch for stage B — this is the row the
    # no-ack timer will consult. Confirm the shape before we fire.
    assert %{stage_id: recorded_stage_id, ack_at: nil, no_ack_fired?: false} =
             LeaseManager.get(task.id)

    assert recorded_stage_id == stage_b.id

    # Subscribe to `tasks:board` so we can observe the router-emitted
    # `execution.no_ack_timeout` event (it broadcasts back to itself,
    # but tests get a copy too).
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

    # Force the :check_no_ack handler to fire without waiting 5min. The
    # LeaseManager row still has ack_at=nil and no_ack_fired?=false, so
    # the handler will path through `mark_no_ack_fired` + emit the alert.
    send(pid, :check_no_ack)

    assert_receive {:runtime_event,
                    %{
                      event_type: "execution.no_ack_timeout",
                      stage_id: alert_stage_id,
                      payload: %{stage_id: payload_stage_id}
                    }},
                   1_000

    # The alarm names stage B (the currently-running stage), not stage A
    # (whose stale blocker sits in the DB).
    assert alert_stage_id == stage_b.id
    assert payload_stage_id == stage_b.id

    # Router transitioned to :stalled per the no-ack contract.
    Process.sleep(50)
    assert TaskRouter.current_status(task.id).status == :stalled

    # A human-facing blocker was posted to the execution space, and its
    # content references the ack timeout (naming the current stage's
    # lease, not any prior stage).
    space = ExecutionSpace.find_by_task_id(task.id)
    assert space, "expected an execution space to exist for the task"
    messages = ExecutionSpace.list_messages_with_participants(space.id)

    assert Enum.any?(messages, fn msg ->
             String.contains?(msg.content, "Executor never acked the dispatch")
           end),
           "expected an 'Executor never acked the dispatch' blocker in the execution space"
  end

  test "router restart preserves in-flight stage 2 blocker, drops stage 1 historical blocker",
       %{
         task: task,
         assignee: assignee,
         stage_a: stage_a,
         stage_b: stage_b
       } do
    # Boot phase 1 — record a legitimate stage-B blocker via the public
    # runtime-event path so the lease row goes through the standard
    # `record_event/1` write.
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    Process.sleep(100)

    {:ok, _event} =
      RuntimeSupervision.record_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => assignee.id,
        "event_type" => "execution.blocked",
        "payload" => %{
          "stage_id" => stage_b.id,
          "description" => "real stage-B blocker (needs human)",
          "needs_human" => true
        }
      })

    Process.sleep(100)

    # Confirm the row is present + router state matches before restart.
    assert %{status: "blocked", stage_id: stage_b_id} =
             RuntimeSupervision.current_lease_for_stage(task.id, stage_b.id)

    assert stage_b_id == stage_b.id
    assert TaskRouter.current_status(task.id).status == :waiting_human

    # Seed a stale historical blocker on stage A after the fact — this
    # simulates a leaked row that survived from an earlier stage the
    # router hasn't cleaned up. (Ordinarily `drop_leases_for_stage/2`
    # would have caught this at the transition, but a router that
    # crashed before the handler ran leaves the row behind.)
    seed_blocked_lease!(task.id, stage_a.id, assignee.id,
      reason: "leaked historical blocker on stage A"
    )

    # Stop the router.
    :ok = TaskRouter.stop(task.id)
    refute Process.alive?(pid)

    # Boot phase 2 — rehydrate from the DB. The stage-B blocker must be
    # preserved; the stage-A blocker must be ignored.
    {:ok, restarted_pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    Process.sleep(150)

    status = TaskRouter.current_status(task.id)

    assert status.current_stage_id == stage_b.id
    # In-flight stage-B blocker is preserved.
    assert status.lease_status == "blocked"
    assert status.status == :waiting_human

    # Both DB rows are still present — this fix is about router-state
    # rehydration semantics, not about deleting historical rows.
    assert %{status: "blocked"} =
             RuntimeSupervision.current_lease_for_stage(task.id, stage_a.id)

    assert %{status: "blocked"} =
             RuntimeSupervision.current_lease_for_stage(task.id, stage_b.id)

    # Router owns the fresh process (not the stopped one).
    assert Process.alive?(restarted_pid)

    # Resolving the real stage-B blocker returns the router to :running.
    {:ok, _unblock} =
      RuntimeSupervision.record_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => assignee.id,
        "event_type" => "execution.unblocked",
        "payload" => %{"stage_id" => stage_b.id, "description" => "human resolved"}
      })

    Process.sleep(100)
    assert TaskRouter.current_status(task.id).status == :running
  end
end
