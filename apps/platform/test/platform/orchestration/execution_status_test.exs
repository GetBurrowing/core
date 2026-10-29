defmodule Platform.Orchestration.ExecutionStatusTest do
  use Platform.DataCase, async: true
  alias Platform.{Repo, Tasks}
  alias Platform.Orchestration.{ExecutionLease, ExecutionStatus, RuntimeEvent}

  setup do
    {:ok, p} = Tasks.create_project(%{name: "Activity #{System.unique_integer([:positive])}"})

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "owner#{Ecto.UUID.generate()}@example.com",
        name: "Owner",
        oidc_sub: Ecto.UUID.generate()
      })

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "owner-#{Ecto.UUID.generate()}",
        owner_user_id: user.id,
        display_name: "Status owner"
      })

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "status-#{Ecto.UUID.generate()}",
        name: "Status owner",
        status: "active",
        runtime_id: runtime.id
      })

    task =
      Repo.insert!(%Tasks.Task{
        project_id: p.id,
        title: "Current task",
        status: "in_progress",
        assignee_id: agent.id,
        assignee_type: "agent"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    now = ~U[2026-10-29 01:00:00.000000Z]
    %{task: task, stage: stage, now: now, runtime: runtime}
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
            runtime_id: ctx.runtime.runtime_id,
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
      runtime_id: c.runtime.runtime_id,
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

  test "unassigned active lease does not prove ownership", c do
    lease(c)
    task = Repo.update!(Ecto.Changeset.change(c.task, assignee_id: nil, assignee_type: nil))
    assert ExecutionStatus.load([task], c.now)[task.id].state == :unknown
  end

  test "matching terminal wins over recent lease progress", c do
    l = lease(c)

    Repo.insert!(%RuntimeEvent{
      task_id: c.task.id,
      lease_id: l.id,
      phase: "execution",
      runtime_id: c.runtime.runtime_id,
      event_type: "execution.finished",
      occurred_at: c.now,
      idempotency_key: Ecto.UUID.generate(),
      payload: %{"stage_id" => c.stage.id, "runtime_worker_ref" => "worker1"}
    })

    assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
  end

  describe "running stage without a lease" do
    defp event(ctx, type, at, attrs \\ %{}) do
      Repo.insert!(%RuntimeEvent{
        task_id: Map.get(attrs, :task_id, ctx.task.id),
        phase: "execution",
        runtime_id: Map.get(attrs, :runtime_id, ctx.runtime.runtime_id),
        event_type: type,
        occurred_at: at,
        idempotency_key: Ecto.UUID.generate(),
        payload: %{"stage_id" => Map.get(attrs, :stage_id, ctx.stage.id)}
      })
    end

    defp drain(ref, n) do
      receive do
        {^ref, :query} -> drain(ref, n + 1)
      after
        0 -> n
      end
    end

    defp ago(ctx, minutes), do: DateTime.add(ctx.now, -minutes * 60)

    test "owner ack 5 min ago reads Working without pulse", c do
      event(c, "execution.acked", ago(c, 5))
      s = ExecutionStatus.load([c.task], c.now)[c.task.id]
      assert s.state == :working
      assert s.label == "Working"
      assert s.elapsed == "5m"
      refute s.pulse?
    end

    test "validation evaluated 3 min ago outranks an 80 min old ack", c do
      event(c, "execution.acked", ago(c, 80))

      Repo.insert!(%Platform.Tasks.Validation{
        stage_id: c.stage.id,
        kind: "test_pass",
        status: "passed",
        evaluated_at: ago(c, 3)
      })

      s = ExecutionStatus.load([c.task], c.now)[c.task.id]
      assert s.state == :working
      assert s.elapsed == "3m"
    end

    test "ack 91 min ago is No activity with a known elapsed", c do
      event(c, "execution.acked", ago(c, 91))
      s = ExecutionStatus.load([c.task], c.now)[c.task.id]
      assert s.state == :unknown
      assert s.label == "No activity"
      assert s.elapsed == "1h"
      refute s.pulse?
    end

    test "ack exactly 90 min ago is still Working", c do
      event(c, "execution.acked", ago(c, 90))
      assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :working
    end

    test "non-owner runtime ack is not activity", c do
      event(c, "execution.acked", ago(c, 5), %{runtime_id: "other-#{Ecto.UUID.generate()}"})
      assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
    end

    test "ack for a different stage is not activity", c do
      event(c, "execution.acked", ago(c, 5), %{stage_id: Ecto.UUID.generate()})
      assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
    end

    test "a dispatch attempt alone is not activity", c do
      event(c, "execution.dispatch_attempt", ago(c, 5))
      assert ExecutionStatus.load([c.task], c.now)[c.task.id].state == :unknown
    end

    test "terminal owner event reads Worker ended", c do
      event(c, "execution.finished", ago(c, 5))
      s = ExecutionStatus.load([c.task], c.now)[c.task.id]
      assert s.state == :unknown
      assert s.reason == "Worker ended; awaiting current execution evidence"
      assert s.elapsed == "5m"
    end

    test "in_progress task with no running stage has no status", c do
      Repo.update!(Ecto.Changeset.change(c.stage, status: "passed"))
      statuses = ExecutionStatus.load([c.task], c.now)
      assert statuses[c.task.id] == nil
      assert ExecutionStatus.for_task(c.task) == nil
    end

    test "load/3 issues the same query count for 20 tasks as for 1", c do
      tasks =
        for i <- 1..20 do
          t =
            Repo.insert!(%Tasks.Task{
              project_id: c.task.project_id,
              title: "Batch #{i}",
              status: "in_progress",
              assignee_id: c.task.assignee_id,
              assignee_type: "agent"
            })

          {:ok, plan} = Tasks.create_plan(%{task_id: t.id, status: "approved", version: 1})

          {:ok, stage} =
            Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "B", status: "running"})

          event(c, "execution.acked", ago(c, 5), %{task_id: t.id, stage_id: stage.id})
          t
        end

      count = fn list ->
        pid = self()
        ref = make_ref()
        id = "execution-status-count-#{inspect(ref)}"

        :telemetry.attach(
          id,
          [:platform, :repo, :query],
          fn _, _, _, _ -> if self() == pid, do: send(pid, {ref, :query}) end,
          nil
        )

        statuses = ExecutionStatus.load(list, c.now)
        :telemetry.detach(id)
        {statuses, drain(ref, 0)}
      end

      {_, one} = count.([hd(tasks)])
      {statuses, twenty} = count.(tasks)
      assert one > 0
      assert one == twenty
      assert Enum.all?(tasks, &(statuses[&1.id].state == :working))
    end
  end
end
