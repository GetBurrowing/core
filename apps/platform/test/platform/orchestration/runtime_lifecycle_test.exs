defmodule Platform.Orchestration.RuntimeLifecycleTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  alias Platform.Orchestration.{RuntimeSupervision, RuntimeEvent, ExecutionLease, LeaseManager}
  alias Platform.{Repo, Tasks}

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Lifecycle #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lifecycle"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    now = DateTime.utc_now()
    on_exit(fn -> LeaseManager.clear(task.id) end)
    %{task: task, stage: stage, runtime: "runtime-lifecycle", now: now}
  end

  defp event(ctx, type, payload, offset) do
    RuntimeSupervision.record_event(%{
      task_id: ctx.task.id,
      runtime_id: ctx.runtime,
      event_type: type,
      occurred_at: DateTime.add(ctx.now, offset, :second),
      payload: Map.put(payload, "stage_id", ctx.stage.id)
    })
  end

  defp reserve(ctx, offset \\ 0),
    do:
      RuntimeSupervision.reserve_dispatch(
        ctx.task.id,
        ctx.stage.id,
        ctx.runtime,
        DateTime.add(ctx.now, offset, :second)
      )

  test "persist-before-send reservation survives lost ETS/restart and duplicate injectors", ctx do
    assert {:ok, {:reserved, attempt}} = reserve(ctx)
    LeaseManager.clear(ctx.task.id)

    for _ <- 1..5 do
      assert {:ok, {:in_flight, correlation}} = reserve(ctx, 1)
      assert correlation == attempt.payload["correlation_id"]
    end

    assert Repo.aggregate(
             from(e in RuntimeEvent,
               where: e.task_id == ^ctx.task.id and e.event_type == "execution.dispatch_attempt"
             ),
             :count
           ) == 1

    assert attempt.runtime_id == RuntimeSupervision.self_filed_runtime_id()
    assert attempt.payload["addressed_runtime"] == ctx.runtime
    assert attempt.payload["runtime_receipt"] == "unknown"
    assert attempt.payload["worker_start"] == "unknown"
    assert is_binary(attempt.payload["core_build"])
  end

  test "a different runtime cannot reserve over an unknown owning worker", ctx do
    {:ok, {:reserved, attempt}} = reserve(ctx)
    other = %{ctx | runtime: "other-runtime"}
    assert {:ok, {:in_flight, correlation}} = reserve(other, 1)
    assert correlation == attempt.payload["correlation_id"]

    assert {:error, :stale_stage} =
             RuntimeSupervision.reserve_dispatch(ctx.task.id, Ecto.UUID.generate(), ctx.runtime)
  end

  test "bounded transport redelivery reuses one token and only one worker can claim it", ctx do
    {:ok, {:reserved, attempt}} = reserve(ctx)

    for offset <- 1..3 do
      assert {:ok, {:reserved, retry}} =
               RuntimeSupervision.reserve_dispatch(
                 ctx.task.id,
                 ctx.stage.id,
                 ctx.runtime,
                 DateTime.add(ctx.now, offset, :second),
                 transport_retry: true
               )

      assert retry.id == attempt.id
      assert retry.payload["correlation_id"] == attempt.payload["correlation_id"]
    end

    assert {:error, :worker_reference_required} = event(ctx, "execution.started", %{}, 4)
    assert {:ok, _} = event(ctx, "execution.started", %{"runtime_worker_ref" => "worker-one"}, 5)

    assert {:error, :worker_already_started} =
             event(ctx, "execution.started", %{"runtime_worker_ref" => "worker-two"}, 6)

    assert {:ok, {:in_flight, _}} =
             RuntimeSupervision.reserve_dispatch(
               ctx.task.id,
               ctx.stage.id,
               ctx.runtime,
               DateTime.add(ctx.now, 7, :second),
               transport_retry: true
             )

    assert Repo.aggregate(
             from(e in RuntimeEvent,
               where: e.task_id == ^ctx.task.id and e.event_type == "execution.started"
             ),
             :count
           ) == 1
  end

  test "simultaneous worker starts admit one identity and conflicting replay cannot admit another",
       ctx do
    {:ok, {:reserved, attempt}} = reserve(ctx)
    parent = self()

    workers =
      for name <- ["worker-a", "worker-b"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :start ->
              RuntimeSupervision.record_event(%{
                task_id: ctx.task.id,
                runtime_id: ctx.runtime,
                event_type: "execution.started",
                idempotency_key: "claim:#{ctx.task.id}:#{name}",
                runtime_worker_ref: name,
                payload: %{
                  "stage_id" => ctx.stage.id,
                  "correlation_id" => attempt.payload["correlation_id"]
                }
              })
          end
        end)
      end

    for _ <- workers do
      assert_receive {:ready, _}
    end

    Enum.each(workers, &send(&1.pid, :start))
    results = Enum.map(workers, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :worker_already_started}, &1)) == 1
    {:ok, admitted} = Enum.find(results, &match?({:ok, _}, &1))

    assert {:error, :idempotency_conflict} =
             RuntimeSupervision.record_event(%{
               task_id: ctx.task.id,
               runtime_id: ctx.runtime,
               event_type: "execution.started",
               idempotency_key: admitted.idempotency_key,
               runtime_worker_ref: "forged-second-worker",
               payload: %{
                 "stage_id" => ctx.stage.id,
                 "correlation_id" => attempt.payload["correlation_id"]
               }
             })
  end

  test "stale stage and wrong runtime terminal cannot clear the current liveness owner", ctx do
    :ok = LeaseManager.record_dispatch(ctx.task.id, ctx.stage.id, "coding", ctx.now, ctx.runtime)

    assert {:error, :stale_stage} =
             LeaseManager.clear_if_owner(ctx.task.id, ctx.runtime, Ecto.UUID.generate())

    assert {:error, {:not_owner, _}} =
             LeaseManager.clear_if_owner(ctx.task.id, "stranger", ctx.stage.id)

    assert LeaseManager.get(ctx.task.id).stage_id == ctx.stage.id
    assert :ok = LeaseManager.clear_if_owner(ctx.task.id, ctx.runtime, ctx.stage.id)
  end

  test "top-level stage ingress is durable and its release replay stays idempotent after restart",
       ctx do
    {:ok, {:reserved, _}} = reserve(ctx)

    attrs = %{
      task_id: ctx.task.id,
      stage_id: ctx.stage.id,
      runtime_id: ctx.runtime,
      event_type: "execution.blocked",
      payload: %{"needs_human" => true},
      occurred_at: DateTime.add(ctx.now, 1, :second)
    }

    assert {:ok, blocked} = RuntimeSupervision.record_event(attrs)
    assert blocked.payload["stage_id"] == ctx.stage.id

    release =
      %{
        attrs
        | event_type: "execution.unblocked",
          payload: %{"reason" => "fixture verified"},
          occurred_at: DateTime.add(ctx.now, 2, :second)
      }
      |> Map.put(:idempotency_key, "top-level-release:#{ctx.task.id}")

    assert {:ok, first} = RuntimeSupervision.record_event(release)
    assert {:ok, {:reserved, _}} = reserve(ctx, 3)
    LeaseManager.clear(ctx.task.id)
    assert {:ok, duplicate} = RuntimeSupervision.record_event(release)
    assert first.id == duplicate.id
    assert {:ok, {:in_flight, _}} = reserve(ctx, 4)
  end

  test "transport acceptance with an online socket is not runtime receipt; failed send can retry",
       ctx do
    {:ok, {:reserved, attempt}} = reserve(ctx)
    assert {:ok, accepted} = RuntimeSupervision.dispatch_result(attempt, :ok, true)
    assert attempt.phase == "planning"
    assert accepted.phase == "planning"
    assert accepted.payload["transport_send"] == "accepted"
    assert accepted.payload["runtime_receipt"] == "unknown"
    assert {:ok, {:in_flight, _}} = reserve(ctx, 1)

    {:ok, other_task} =
      Tasks.create_task(%{project_id: ctx.task.project_id, title: "Failed transport"})

    {:ok, other_plan} =
      Tasks.create_plan(%{task_id: other_task.id, version: 1, status: "approved"})

    {:ok, other_stage} =
      Tasks.create_stage(%{plan_id: other_plan.id, position: 1, name: "Build", status: "running"})

    other = %{ctx | task: other_task, stage: other_stage}
    {:ok, {:reserved, failed}} = reserve(other)

    assert {:ok, failed_event} =
             RuntimeSupervision.dispatch_result(failed, {:error, :endpoint_not_ready}, false)

    assert failed_event.payload["transport_send"] == "failed"
    assert {:ok, {:reserved, replacement}} = reserve(other, 2)
    refute replacement.id == failed.id
  end

  test "human hold survives heartbeat, progress, turn end, expiry and late ack", ctx do
    # This old durable human hold must survive beyond its informational expiry.
    old = %{ctx | now: DateTime.add(DateTime.utc_now(), -14 * 60 * 60, :second)}

    {:ok, blocked} =
      event(old, "execution.blocked", %{"needs_human" => true, "wait_kind" => "human"}, 0)

    for type <-
          ~w(execution.started execution.heartbeat execution.progress execution.finished execution.failed execution.abandoned execution.acked) do
      assert {:ok, _} = event(old, type, %{}, 1)

      assert %ExecutionLease{status: "blocked", id: id} =
               RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime)

      assert id == blocked.lease_id
    end

    assert Repo.get!(ExecutionLease, blocked.lease_id).last_progress_at == nil
  end

  test "a contradictory blocked report cannot silently release a human ruling", ctx do
    assert {:ok, blocked} =
             event(ctx, "execution.blocked", %{"needs_human" => true, "wait_kind" => "human"}, 0)

    assert {:error, :human_action_required} =
             event(ctx, "execution.blocked", %{"needs_human" => false}, 1)

    assert RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime).id ==
             blocked.lease_id
  end

  test "verified explicit release invalidates historical ack but replacement worker fences stale terminal",
       ctx do
    {:ok, {:reserved, first}} = reserve(ctx)
    {:ok, _} = event(ctx, "execution.acked", %{"subagent_id" => "old"}, 1)
    {:ok, _} = event(ctx, "execution.blocked", %{"needs_human" => true}, 2)
    {:ok, _} = event(ctx, "execution.unblocked", %{"reason" => "verified installed fixture"}, 3)
    assert {:ok, {:reserved, replacement}} = reserve(ctx, 4)
    refute first.payload["correlation_id"] == replacement.payload["correlation_id"]
    {:ok, _} = event(ctx, "execution.started", %{"runtime_worker_ref" => "new-worker"}, 5)

    {:ok, stale} =
      event(
        ctx,
        "execution.finished",
        %{
          "runtime_worker_ref" => "old-worker",
          "correlation_id" => first.payload["correlation_id"]
        },
        6
      )

    refute stale.payload["worker_event_applied"]
    refute RuntimeSupervision.event_matches_worker?(stale, ctx.stage.id, ctx.runtime)
    assert {:ok, {:in_flight, _}} = reserve(ctx, 7)
    {:ok, finished} = event(ctx, "execution.finished", %{"runtime_worker_ref" => "new-worker"}, 8)
    assert finished.payload["worker_event_applied"]
    assert {:ok, {:reserved, _}} = reserve(ctx, 9)
  end

  test "turn end before receipt ack cannot become a live worker after late ack", ctx do
    {:ok, {:reserved, attempt}} = reserve(ctx)

    {:ok, _} =
      event(
        ctx,
        "execution.finished",
        %{"correlation_id" => attempt.payload["correlation_id"]},
        1
      )

    {:ok, ack} =
      event(
        ctx,
        "execution.acked",
        %{
          "correlation_id" => attempt.payload["correlation_id"],
          "subagent_id" => "already-ended"
        },
        2
      )

    refute RuntimeSupervision.event_matches_worker?(ack, ctx.stage.id, ctx.runtime)
    assert RuntimeSupervision.dispatch_turn_ended?(ctx.task.id, ctx.stage.id, ctx.runtime)
    assert {:ok, {:reserved, _}} = reserve(ctx, 3)
  end

  test "a new human hold on the same lease posts immediately with a distinct generation", ctx do
    {:ok, first} =
      event(ctx, "execution.blocked", %{"needs_human" => true, "wait_kind" => "human"}, 0)

    sender = fn _ ->
      send(self(), :notice_sent)
      {:ok, :message}
    end

    assert {:ok, :sent} =
             RuntimeSupervision.deliver_hold_notice(first.lease_id, 3_600_000, sender, ctx.now)

    assert_receive :notice_sent
    old = Repo.get!(ExecutionLease, first.lease_id)
    {:ok, _} = event(ctx, "execution.unblocked", %{"reason" => "first ruling resolved"}, 1)

    {:ok, second} =
      event(
        ctx,
        "execution.blocked",
        %{
          "needs_human" => true,
          "wait_kind" => "human",
          "dependency_wait" => %{"revision" => "obsolete-dependency-revision"}
        },
        2
      )

    assert second.lease_id == first.lease_id

    assert {:ok, :sent} =
             RuntimeSupervision.deliver_hold_notice(
               second.lease_id,
               3_600_000,
               sender,
               DateTime.add(ctx.now, 2, :second)
             )

    assert_receive :notice_sent
    current = Repo.get!(ExecutionLease, second.lease_id)
    assert is_binary(old.metadata["hold_revision"])
    refute old.metadata["hold_revision"] == current.metadata["hold_revision"]
    {:ok, _} = event(ctx, "execution.unblocked", %{"reason" => "second ruling resolved"}, 3)
    assert {:ok, {:reserved, resumed}} = reserve(ctx, 4)
    assert resumed.payload["hold_revision"] == current.metadata["hold_revision"]
  end

  test "reminders persist successful delivery across restart and retry failures without storms",
       ctx do
    {:ok, hold} = event(ctx, "execution.blocked", %{"needs_human" => true}, 0)

    sender = fn _ ->
      send(self(), :notice_sent)
      {:ok, :message}
    end

    assert {:ok, :sent} =
             RuntimeSupervision.deliver_hold_notice(hold.lease_id, 3_600_000, sender, ctx.now)

    assert_receive :notice_sent
    LeaseManager.clear(ctx.task.id)

    assert {:ok, :not_due} =
             RuntimeSupervision.deliver_hold_notice(
               hold.lease_id,
               3_600_000,
               sender,
               DateTime.add(ctx.now, 3599, :second)
             )

    refute_receive :notice_sent, 0
    failed = fn _ -> {:error, :offline} end
    next = DateTime.add(ctx.now, 3600, :second)

    assert {:ok, {:delivery_failed, {:error, :offline}}} =
             RuntimeSupervision.deliver_hold_notice(hold.lease_id, 3_600_000, failed, next)

    assert Repo.get!(ExecutionLease, hold.lease_id).metadata["human_notice_result"] == "failed"

    assert {:ok, :not_due} =
             RuntimeSupervision.deliver_hold_notice(
               hold.lease_id,
               3_600_000,
               sender,
               DateTime.add(next, 59, :second)
             )

    assert {:ok, :sent} =
             RuntimeSupervision.deliver_hold_notice(
               hold.lease_id,
               3_600_000,
               sender,
               DateTime.add(next, 60, :second)
             )

    assert_receive :notice_sent

    assert {:ok, :not_due} =
             RuntimeSupervision.deliver_hold_notice(
               hold.lease_id,
               3_600_000,
               sender,
               DateTime.add(next, 60, :second)
             )
  end
end
