defmodule Platform.Orchestration.RuntimeSupervisionTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.{ExecutionSpace, RuntimeSupervision}
  alias Platform.Tasks

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{name: "Lease Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lease Task"})
    task
  end

  test "record_event/1 creates an active lease and mirrors to execution space" do
    task = create_task!()
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started",
               "execution_space_id" => space.id,
               "payload" => %{"summary" => "worker booted"}
             })

    assert event.event_type == "execution.started"
    lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert lease.status == "active"
    assert lease.runtime_id == "runtime:test"

    messages = ExecutionSpace.list_messages_with_participants(space.id)
    assert Enum.any?(messages, &String.contains?(&1.content, "started execution"))
  end

  test "record_event/1 marks blockers and preserves a single active lease" do
    task = create_task!()

    assert {:ok, _started} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started"
             })

    assert {:ok, _blocked} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.blocked",
               "payload" => %{"description" => "waiting on human"}
             })

    lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert lease.status == "blocked"
    assert lease.block_reason == "waiting on human"
  end

  test "record_event/1 folds attempts and unblock_action into the lease block_reason" do
    task = create_task!()

    assert {:ok, _blocked} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.blocked",
               "payload" => %{
                 "description" => "migration fails",
                 "attempts" => ["ran mix test", "read the ADR", "reset the DB"],
                 "unblock_action" => "Rowan picks A or B"
               }
             })

    lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert lease.status == "blocked"

    assert lease.block_reason ==
             "migration fails | tried: ran mix test; read the ADR; reset the DB | unblock: Rowan picks A or B"
  end

  test "record_event/1 is idempotent by idempotency_key" do
    task = create_task!()

    attrs = %{
      "task_id" => task.id,
      "phase" => "execution",
      "runtime_id" => "runtime:test",
      "event_type" => "execution.heartbeat",
      "idempotency_key" => "same-key"
    }

    assert {:ok, first} = RuntimeSupervision.record_event(attrs)
    assert {:ok, second} = RuntimeSupervision.record_event(attrs)
    assert first.id == second.id
  end

  test "execution.progress truncates long summaries to 300 characters" do
    task = create_task!()
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    # Start execution first to create a lease
    assert {:ok, _started} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started",
               "execution_space_id" => space.id,
               "payload" => %{}
             })

    long_summary = String.duplicate("a", 500)

    assert {:ok, _progress} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.progress",
               "execution_space_id" => space.id,
               "payload" => %{"summary" => long_summary}
             })

    messages = ExecutionSpace.list_messages_with_participants(space.id)

    progress_msg =
      Enum.find(messages, fn m ->
        String.contains?(m.content, "Runtime progress from runtime:test:")
      end)

    assert progress_msg != nil
    # 300 chars of 'a' + ellipsis, should NOT contain the full 500-char string
    refute String.contains?(progress_msg.content, long_summary)
    assert String.contains?(progress_msg.content, String.duplicate("a", 300) <> "…")
  end

  test "execution.progress passes short summaries through unchanged" do
    task = create_task!()
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    assert {:ok, _started} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started",
               "execution_space_id" => space.id,
               "payload" => %{}
             })

    short_summary = "agent replied: hello world"

    assert {:ok, _progress} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.progress",
               "execution_space_id" => space.id,
               "payload" => %{"summary" => short_summary}
             })

    messages = ExecutionSpace.list_messages_with_participants(space.id)

    progress_msg =
      Enum.find(messages, fn m ->
        String.contains?(m.content, short_summary)
      end)

    assert progress_msg != nil
  end

  test "execution.acked preserves subagent_id in RuntimeEvent.payload verbatim" do
    # Task 019f6c73 stage 2 — the ToolSurface `task_ack` tool now enforces a
    # non-empty, bounded `subagent_id` param and emits it as part of the ack
    # payload. RuntimeSupervision persists `attrs.payload` unchanged (see
    # `record_event/1` and the payload field on `RuntimeEvent`), so this
    # regression guard proves the field round-trips into the durable row
    # exactly as passed. Downstream audit + presence consumers read
    # `RuntimeEvent.payload["subagent_id"]` directly — no separate telemetry
    # emit — so any refactor that drops the field from the payload map would
    # silently break the audit trail.
    task = create_task!()
    stage_id = Ecto.UUID.generate()
    acked_at = DateTime.utc_now() |> DateTime.to_iso8601()

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.acked",
               "payload" => %{
                 "stage_id" => stage_id,
                 "acked_at" => acked_at,
                 "runtime_id" => "runtime:test",
                 "subagent_id" => "test-runtime-slug"
               }
             })

    assert event.event_type == "execution.acked"
    assert event.payload["subagent_id"] == "test-runtime-slug"
    assert event.payload["stage_id"] == stage_id
    assert event.payload["acked_at"] == acked_at
  end

  test "execution.alarm_silenced is a recognised event_type and does NOT flip lease status" do
    # Task 019f6791-c01b stage 3 — silence is orthogonal to lifecycle
    # (same rule as execution.acked). The @event_statuses entry maps to
    # `nil`, so record_event/1 must accept it AND leave any existing
    # active lease's status unchanged.
    task = create_task!()
    stage_id = Ecto.UUID.generate()

    # Seed an active lease first so we can prove silenced-event doesn't
    # overwrite it.
    assert {:ok, _started} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started"
             })

    pre_lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert pre_lease.status == "active"

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.alarm_silenced",
               "payload" => %{
                 "stage_id" => stage_id,
                 "silenced_until" => DateTime.utc_now() |> DateTime.to_iso8601(),
                 "reason" => "operator override"
               }
             })

    assert event.event_type == "execution.alarm_silenced"

    post_lease = RuntimeSupervision.current_lease_for_task(task.id)
    assert post_lease.status == "active"
    assert post_lease.id == pre_lease.id
  end

  test "current_lease_for_task_runtime/2 expires stale leases on lookup" do
    task = create_task!()

    assert {:ok, event} =
             RuntimeSupervision.record_event(%{
               "task_id" => task.id,
               "phase" => "execution",
               "runtime_id" => "runtime:test",
               "event_type" => "execution.started"
             })

    lease_id = event.lease_id
    stale_time = DateTime.add(DateTime.utc_now(), -60, :second)

    from(l in Platform.Orchestration.ExecutionLease, where: l.id == ^lease_id)
    |> Platform.Repo.update_all(set: [expires_at: stale_time])

    assert RuntimeSupervision.current_lease_for_task_runtime(task.id, "runtime:test") == nil

    expired = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, lease_id)
    assert expired.status == "expired"
  end

  # ------------------------------------------------------------------
  # Stage-scoped lease keying (task 019f6791)
  # ------------------------------------------------------------------

  describe "stage-scoped lease keying" do
    test "record_event with payload.stage_id creates a lease keyed by that stage" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:test",
                 "event_type" => "execution.blocked",
                 "payload" => %{"stage_id" => stage_a, "description" => "waiting on human"}
               })

      lease = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, event.lease_id)
      assert lease.stage_id == stage_a
      assert lease.status == "blocked"
      assert lease.block_reason == "waiting on human"
    end

    test "record_event for two distinct stages produces two coexisting active leases" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()
      stage_b = Ecto.UUID.generate()

      assert {:ok, ev_a} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:test",
                 "event_type" => "execution.blocked",
                 "payload" => %{"stage_id" => stage_a, "description" => "stage A blocker"}
               })

      assert {:ok, ev_b} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:test",
                 "event_type" => "execution.started",
                 "payload" => %{"stage_id" => stage_b}
               })

      refute ev_a.lease_id == ev_b.lease_id

      lease_a = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, ev_a.lease_id)
      lease_b = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, ev_b.lease_id)

      assert lease_a.stage_id == stage_a
      assert lease_a.status == "blocked"
      assert lease_b.stage_id == stage_b
      assert lease_b.status == "active"
    end

    test "current_lease_for_stage/2 returns only the lease for the requested stage" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()
      stage_b = Ecto.UUID.generate()

      {:ok, _} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.blocked",
          "payload" => %{"stage_id" => stage_a, "description" => "old blocker"}
        })

      {:ok, _} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.started",
          "payload" => %{"stage_id" => stage_b}
        })

      lease_a = RuntimeSupervision.current_lease_for_stage(task.id, stage_a)
      lease_b = RuntimeSupervision.current_lease_for_stage(task.id, stage_b)

      assert lease_a.stage_id == stage_a
      assert lease_a.status == "blocked"
      assert lease_b.stage_id == stage_b
      assert lease_b.status == "active"

      assert RuntimeSupervision.current_lease_for_stage(task.id, Ecto.UUID.generate()) == nil
    end

    test "drop_leases_for_stage/2 abandons matching leases and returns the count" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()
      stage_b = Ecto.UUID.generate()

      {:ok, ev_a} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.blocked",
          "payload" => %{"stage_id" => stage_a, "description" => "leaking blocker"}
        })

      {:ok, ev_b} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.started",
          "payload" => %{"stage_id" => stage_b}
        })

      assert RuntimeSupervision.drop_leases_for_stage(task.id, stage_a) == 1

      lease_a = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, ev_a.lease_id)
      lease_b = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, ev_b.lease_id)

      assert lease_a.status == "abandoned"
      assert lease_a.block_reason == nil
      # Stage B untouched.
      assert lease_b.status == "active"
      assert lease_b.stage_id == stage_b

      # Idempotent second call sees nothing to drop.
      assert RuntimeSupervision.drop_leases_for_stage(task.id, stage_a) == 0
    end

    test "list_active_leases_for_task/1 returns every active/blocked lease across stages" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()
      stage_b = Ecto.UUID.generate()

      {:ok, _} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.blocked",
          "payload" => %{"stage_id" => stage_a, "description" => "blocker"}
        })

      {:ok, _} =
        RuntimeSupervision.record_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => "runtime:test",
          "event_type" => "execution.started",
          "payload" => %{"stage_id" => stage_b}
        })

      leases = RuntimeSupervision.list_active_leases_for_task(task.id)
      stage_ids = leases |> Enum.map(& &1.stage_id) |> Enum.sort()

      assert length(leases) == 2
      assert stage_ids == Enum.sort([stage_a, stage_b])
    end

    test "legacy record_event with no stage_id in payload produces a stage_id: nil lease" do
      task = create_task!()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:legacy",
                 "event_type" => "execution.started"
               })

      lease = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, event.lease_id)
      assert lease.stage_id == nil
      assert lease.status == "active"

      # A second NULL-stage lease from a different runtime coexists via the
      # NULL-permissive partial unique index.
      assert {:ok, second} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:legacy-2",
                 "event_type" => "execution.started"
               })

      second_lease = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, second.lease_id)
      assert second_lease.stage_id == nil
      refute lease.id == second_lease.id
    end

    test "top-level stage_id attr is honoured when payload omits it" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 stage_id: stage_a,
                 phase: "execution",
                 runtime_id: "runtime:direct",
                 event_type: "execution.started"
               })

      lease = Platform.Repo.get!(Platform.Orchestration.ExecutionLease, event.lease_id)
      assert lease.stage_id == stage_a
    end
  end

  describe "format_log_message/2 dispatch events" do
    # Every assertion below is on a literal written into the fixture payload,
    # never on a string re-derived by calling the renderer.

    defp record_dispatch_event!(event_type, payload, runtime_id \\ nil) do
      task = create_task!()
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      assert {:ok, _event} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => runtime_id || RuntimeSupervision.self_filed_runtime_id(),
                 "event_type" => event_type,
                 "execution_space_id" => space.id,
                 "idempotency_key" => "fmt-log-#{System.unique_integer([:positive])}",
                 "payload" => payload
               })

      ExecutionSpace.list_messages_with_participants(space.id)
      |> Enum.map(& &1.content)
    end

    test "execution.dispatch_stageless mirrors the payload description verbatim" do
      contents =
        record_dispatch_event!("execution.dispatch_stageless", %{
          "stage_id" => nil,
          "description" => "SENTINEL-stageless-7f3a"
        })

      assert Enum.any?(contents, &String.contains?(&1, "SENTINEL-stageless-7f3a"))

      refute Enum.any?(
               contents,
               &(&1 == "Runtime task_router event: execution.dispatch_stageless")
             )
    end

    test "execution.dispatch_unanswered mirrors the payload description verbatim" do
      contents =
        record_dispatch_event!("execution.dispatch_unanswered", %{
          "stage_id" => nil,
          "description" => "SENTINEL-unanswered-9c1e"
        })

      assert Enum.any?(contents, &String.contains?(&1, "SENTINEL-unanswered-9c1e"))

      refute Enum.any?(
               contents,
               &(&1 == "Runtime task_router event: execution.dispatch_unanswered")
             )
    end

    test "control: execution.blocked still renders its description unchanged" do
      contents =
        record_dispatch_event!(
          "execution.blocked",
          %{"stage_id" => nil, "description" => "SENTINEL-blocked-4d2b"},
          "runtime:control"
        )

      assert "Runtime reported blocker: SENTINEL-blocked-4d2b" in contents
    end

    test "dispatch_stageless without a binary description falls back without raising" do
      for payload <- [%{"stage_id" => nil}, %{"stage_id" => nil, "description" => 42}] do
        contents = record_dispatch_event!("execution.dispatch_stageless", payload)

        assert "Runtime task_router recorded a stage-less dispatch (no description in payload)" in contents
      end
    end

    test "dispatch_unanswered without a binary description falls back without raising" do
      for payload <- [%{"stage_id" => nil}, %{"stage_id" => nil, "description" => 42}] do
        contents = record_dispatch_event!("execution.dispatch_unanswered", payload)

        assert "Runtime task_router recorded an unanswered stage-less dispatch (no description in payload)" in contents
      end
    end
  end
end
