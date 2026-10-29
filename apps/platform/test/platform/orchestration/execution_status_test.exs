defmodule Platform.Orchestration.ExecutionStatusTest do
  use Platform.DataCase, async: true
  alias Platform.{Repo, Tasks}
  alias Platform.Orchestration.{ExecutionLease, ExecutionStatus, RuntimeEvent}

  setup do
    {:ok, p} = Tasks.create_project(%{name: "Activity #{System.unique_integer([:positive])}"})

    task =
      Repo.insert!(%Tasks.Task{project_id: p.id, title: "Current task", status: "in_progress"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    now = ~U[2026-10-29 01:00:00.000000Z]
    %{task: task, stage: stage, now: now}
  end

  defp lease(ctx, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        ExecutionLease,
        Map.merge(
          %{
            task_id: ctx.task.id,
            stage_id: ctx.stage.id,
            phase: "execution",
            runtime_id: "owner",
            status: "active",
            runtime_worker_ref: "worker1",
            started_at: ctx.now,
            last_progress_at: ctx.now,
            expires_at: DateTime.add(ctx.now, 600)
          },
          attrs
        )
      )
    )
  end

  test "ack alone and missing ownership never claim running", c do
    assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
    l = lease(c, %{last_progress_at: nil})

    Repo.insert!(%RuntimeEvent{
      task_id: c.task.id,
      lease_id: l.id,
      phase: "execution",
      runtime_id: "owner",
      event_type: "execution.acked",
      occurred_at: c.now,
      idempotency_key: Ecto.UUID.generate(),
      payload: %{"stage_id" => c.stage.id, "subagent_id" => "worker1"}
    })

    status = ExecutionStatus.load([c.task], c.now)[c.task.id]
    assert status.state == :unknown
    refute status.pulse?
  end

  test "120 second progress boundary and future progress fail closed", c do
    l = lease(c)
    assert ExecutionStatus.load([c.task], DateTime.add(c.now, 120))[c.task.id].state == :running
    assert ExecutionStatus.load([c.task], DateTime.add(c.now, 121))[c.task.id].state == :unknown
    assert ExecutionStatus.load([c.task], DateTime.add(c.now, -1))[c.task.id].state == :unknown
    Repo.update!(Ecto.Changeset.change(l, runtime_worker_ref: nil))
    assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
  end

  test "legacy human hold outranks fresh progress, ack and expired TTL", c do
    lease(c, %{
      status: "blocked",
      expires_at: DateTime.add(c.now, -100),
      block_reason: "approve plan",
      metadata: %{
        "needs_human" => true,
        "blocked_at" => DateTime.to_iso8601(DateTime.add(c.now, -50400))
      }
    })

    s = ExecutionStatus.load([c.task], c.now)[c.task.id]
    assert s.state == :human
    assert s.label == "Needs you: approve plan"
    assert s.elapsed == "14h"
    refute s.can_recheck?
    refute s.pulse?
  end

  test "typed dependency wait names dependency and stays waiting after completion", c do
    dep =
      Repo.insert!(%Tasks.Task{
        project_id: c.task.project_id,
        title: "Headline contract",
        status: "done"
      })

    lease(c, %{
      status: "blocked",
      metadata: %{
        "needs_human" => true,
        "wait_kind" => "dependency",
        "dependency_wait" => %{
          "dependencies" => [%{"task_id" => dep.id}],
          "state" => "exhausted",
          "reason" => "verification_failed"
        }
      }
    })

    s = ExecutionStatus.load([c.task], c.now)[c.task.id]
    assert s.state == :waiting
    assert s.label == "Waiting on: Headline contract"
    assert s.reason == "verification_failed"
    assert s.can_recheck?
  end

  test "old stage and wrong runtime signals are ignored", c do
    lease(c, %{
      stage_id: Ecto.UUID.generate(),
      status: "blocked",
      metadata: %{"needs_human" => true}
    })

    assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
  end

  test "matching terminal wins over recent lease progress", c do
    l = lease(c)

    Repo.insert!(%RuntimeEvent{
      task_id: c.task.id,
      lease_id: l.id,
      phase: "execution",
      runtime_id: "owner",
      event_type: "execution.finished",
      occurred_at: c.now,
      idempotency_key: Ecto.UUID.generate(),
      payload: %{"stage_id" => c.stage.id, "runtime_worker_ref" => "worker1"}
    })

    assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
  end
end
