defmodule Platform.Orchestration.RuntimeSupervisionOwnerIdentityTest do
  @moduledoc """
  ADR 0040 Stage 1 — owner identity behavior for `record_event/1`.

  Covers the architect's CRITICAL finding (idempotency key must include
  invoked_by_user_id to prevent multi-user-per-runtime collisions at the
  same microsecond) and the schema-level acceptance of the new fields.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent, RuntimeSupervision}
  alias Platform.Tasks
  alias Platform.Repo

  defp create_task!(suffix \\ "") do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Owner Identity Project #{suffix} #{System.unique_integer([:positive])}"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Owner Identity Task"})
    task
  end

  describe "owner_attribution_status computation" do
    test "is 'attributed' when both invoked_by_user_id and owner_org_id are present" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:test-attributed",
                 event_type: "execution.started",
                 invoked_by_user_id: user_id,
                 owner_org_id: org_id
               })

      assert event.invoked_by_user_id == user_id
      assert event.owner_org_id == org_id
      assert event.owner_attribution_status == "attributed"
    end

    test "is 'attribution_failed' when both ids are missing (legacy callers)" do
      task = create_task!()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:test-noattr",
                 event_type: "execution.started"
               })

      assert is_nil(event.invoked_by_user_id)
      assert is_nil(event.owner_org_id)
      assert event.owner_attribution_status == "attribution_failed"
    end

    test "is 'attribution_failed' when only invoked_by_user_id is present" do
      task = create_task!()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:test-partial-user",
                 event_type: "execution.started",
                 invoked_by_user_id: Ecto.UUID.generate()
               })

      assert event.owner_attribution_status == "attribution_failed"
    end

    test "is 'attribution_failed' when only owner_org_id is present" do
      task = create_task!()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:test-partial-org",
                 event_type: "execution.started",
                 owner_org_id: Ecto.UUID.generate()
               })

      assert event.owner_attribution_status == "attribution_failed"
    end

    test "string-keyed attrs work the same as atom-keyed" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      assert {:ok, event} =
               RuntimeSupervision.record_event(%{
                 "task_id" => task.id,
                 "phase" => "execution",
                 "runtime_id" => "runtime:test-strings",
                 "event_type" => "execution.started",
                 "invoked_by_user_id" => user_id,
                 "owner_org_id" => org_id
               })

      assert event.invoked_by_user_id == user_id
      assert event.owner_org_id == org_id
      assert event.owner_attribution_status == "attributed"
    end
  end

  describe "idempotency_key includes invoked_by_user_id (architect-finding-1)" do
    test "two users hitting same (runtime, task, phase, event_type) at the same microsecond produce DISTINCT events" do
      # This is the CRITICAL test from ADR 0040 architect review: without
      # invoked_by_user_id in the idempotency key, multi-user federation
      # would silently collapse simultaneous invocations to one event row.
      task = create_task!()
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      # Pin the timestamp to a fixed microsecond so both events would have
      # produced an identical idempotency_key under the old shape.
      same_moment = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, event_a} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:multi-user",
                 event_type: "execution.started",
                 occurred_at: same_moment,
                 invoked_by_user_id: user_a,
                 owner_org_id: org_id
               })

      assert {:ok, event_b} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:multi-user",
                 event_type: "execution.started",
                 occurred_at: same_moment,
                 invoked_by_user_id: user_b,
                 owner_org_id: org_id
               })

      # Two distinct event rows
      refute event_a.id == event_b.id

      # Distinct idempotency keys
      refute event_a.idempotency_key == event_b.idempotency_key

      # Each user's id is in their respective key
      assert String.contains?(event_a.idempotency_key, user_a)
      assert String.contains?(event_b.idempotency_key, user_b)
    end

    test "same-user same-moment IS idempotent (deduplicates)" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      same_moment = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        task_id: task.id,
        phase: "execution",
        runtime_id: "runtime:idempotent",
        event_type: "execution.started",
        occurred_at: same_moment,
        invoked_by_user_id: user_id,
        owner_org_id: Ecto.UUID.generate()
      }

      assert {:ok, event_1} = RuntimeSupervision.record_event(attrs)
      assert {:ok, event_2} = RuntimeSupervision.record_event(attrs)

      # Same row returned (idempotency intact for same user)
      assert event_1.id == event_2.id
    end

    test "legacy callers (no user_id) use '-' sentinel and remain idempotent across retries" do
      task = create_task!()
      same_moment = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        task_id: task.id,
        phase: "execution",
        runtime_id: "runtime:legacy",
        event_type: "execution.started",
        occurred_at: same_moment
      }

      assert {:ok, event_1} = RuntimeSupervision.record_event(attrs)
      assert {:ok, event_2} = RuntimeSupervision.record_event(attrs)

      # Same row returned (legacy callers stay idempotent under the sentinel)
      assert event_1.id == event_2.id
      # Sentinel is in the key
      assert String.contains?(event_1.idempotency_key, ":-:")
    end
  end

  describe "execution_lease captures owner identity at creation" do
    test "new lease populated from the initial event's owner fields" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      assert {:ok, _event} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:lease-owned",
                 event_type: "execution.started",
                 invoked_by_user_id: user_id,
                 owner_org_id: org_id
               })

      lease = RuntimeSupervision.current_lease_for_task(task.id)
      assert lease.invoked_by_user_id == user_id
      assert lease.owner_org_id == org_id
      assert lease.owner_attribution_status == "attributed"
    end

    test "subsequent events do NOT overwrite the lease's owner fields" do
      # This is the "owner stays stable for lease lifetime" invariant.
      # Even if a malformed downstream event lacks owner identity, the lease
      # must keep the attribution it was created with.
      task = create_task!()
      original_user = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      # Event 1: creates lease WITH owner
      assert {:ok, _event_1} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:lease-stable",
                 event_type: "execution.started",
                 invoked_by_user_id: original_user,
                 owner_org_id: org_id
               })

      # Event 2: heartbeat WITHOUT owner (simulates a malformed/legacy event)
      assert {:ok, _event_2} =
               RuntimeSupervision.record_event(%{
                 task_id: task.id,
                 phase: "execution",
                 runtime_id: "runtime:lease-stable",
                 event_type: "execution.heartbeat"
               })

      lease = RuntimeSupervision.current_lease_for_task(task.id)
      # Original owner fields preserved
      assert lease.invoked_by_user_id == original_user
      assert lease.owner_org_id == org_id
      assert lease.owner_attribution_status == "attributed"
    end
  end

  describe "schema-level acceptance" do
    test "RuntimeEvent.changeset/2 accepts the new owner fields" do
      changeset =
        RuntimeEvent.changeset(%RuntimeEvent{}, %{
          task_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime:cs-accept",
          event_type: "execution.started",
          occurred_at: DateTime.utc_now(),
          idempotency_key: "test-key",
          invoked_by_user_id: Ecto.UUID.generate(),
          owner_org_id: Ecto.UUID.generate(),
          owner_attribution_status: "attributed"
        })

      assert changeset.valid?
    end

    test "RuntimeEvent.changeset/2 rejects invalid owner_attribution_status" do
      changeset =
        RuntimeEvent.changeset(%RuntimeEvent{}, %{
          task_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime:cs-reject",
          event_type: "execution.started",
          occurred_at: DateTime.utc_now(),
          idempotency_key: "test-key",
          owner_attribution_status: "made_up_value"
        })

      refute changeset.valid?
      assert %{owner_attribution_status: [_message]} = errors_on(changeset)
    end

    test "ExecutionLease.changeset/2 accepts the new owner fields" do
      changeset =
        ExecutionLease.changeset(%ExecutionLease{}, %{
          task_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime:cs-lease",
          status: "active",
          started_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600),
          invoked_by_user_id: Ecto.UUID.generate(),
          owner_org_id: Ecto.UUID.generate(),
          owner_attribution_status: "attributed"
        })

      assert changeset.valid?
    end

    test "ExecutionLease.changeset/2 rejects invalid owner_attribution_status" do
      changeset =
        ExecutionLease.changeset(%ExecutionLease{}, %{
          task_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime:cs-lease-bad",
          status: "active",
          started_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600),
          owner_attribution_status: "garbage"
        })

      refute changeset.valid?
      assert %{owner_attribution_status: [_message]} = errors_on(changeset)
    end

    test "attribution_statuses/0 returns the canonical enum values" do
      expected = ~w(legacy_pre_migration attributed attribution_failed pseudonymous)
      assert RuntimeEvent.attribution_statuses() == expected
      assert ExecutionLease.attribution_statuses() == expected
    end
  end

  describe "default value for legacy rows" do
    test "RuntimeEvent struct defaults owner_attribution_status to 'legacy_pre_migration'" do
      assert %RuntimeEvent{}.owner_attribution_status == "legacy_pre_migration"
    end

    test "ExecutionLease struct defaults owner_attribution_status to 'legacy_pre_migration'" do
      assert %ExecutionLease{}.owner_attribution_status == "legacy_pre_migration"
    end
  end

  describe "owner-unknown breadcrumb (observability gap discovery)" do
    setup do
      # Test config sets Logger level to :warning, which drops info-level
      # messages at the source. Lower the level for this describe block so
      # capture_log can observe the breadcrumb. Production correctly logs
      # at :info — this is just a test-environment workaround.
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    test "logs runtime_event_owner_unknown when attribution_status='attribution_failed'" do
      task = create_task!()

      log =
        capture_log([level: :info], fn ->
          {:ok, _event} =
            RuntimeSupervision.record_event(%{
              task_id: task.id,
              phase: "execution",
              runtime_id: "runtime:no-owner",
              event_type: "execution.started"
              # No invoked_by_user_id, no owner_org_id — should trigger breadcrumb
            })
        end)

      # Per ADR 0040: a single info-level breadcrumb makes the gap discoverable
      # in production telemetry without flooding logs.
      assert log =~ "runtime_event_owner_unknown"
    end

    test "does NOT log breadcrumb when attribution_status='attributed'" do
      task = create_task!()

      log =
        capture_log([level: :info], fn ->
          {:ok, _event} =
            RuntimeSupervision.record_event(%{
              task_id: task.id,
              phase: "execution",
              runtime_id: "runtime:has-owner",
              event_type: "execution.started",
              invoked_by_user_id: Ecto.UUID.generate(),
              owner_org_id: Ecto.UUID.generate()
            })
        end)

      refute log =~ "runtime_event_owner_unknown"
    end

    test "breadcrumb message includes runtime_id and phase for triage" do
      task = create_task!()

      log =
        capture_log([level: :info], fn ->
          {:ok, _event} =
            RuntimeSupervision.record_event(%{
              task_id: task.id,
              phase: "execution",
              runtime_id: "runtime:specific-id-for-triage",
              event_type: "execution.started"
            })
        end)

      # The breadcrumb should be specific enough that an investigator can
      # filter to the offending runtime without spelunking.
      assert log =~ "runtime:specific-id-for-triage"
    end
  end

  # Local errors_on/1 — /core convention is to define this per-test-file
  # rather than centralizing it in DataCase. Mirrors project_test.exs:75-81.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "DB column existence (smoke test that migration applied)" do
    test "runtime_events has the new columns" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          task_id: task.id,
          phase: "execution",
          runtime_id: "runtime:smoke-re",
          event_type: "execution.started",
          invoked_by_user_id: user_id,
          owner_org_id: org_id
        })

      [row] = Repo.all(RuntimeEvent)
      assert row.invoked_by_user_id == user_id
      assert row.owner_org_id == org_id
      assert row.owner_attribution_status == "attributed"
    end

    test "execution_leases has the new columns" do
      task = create_task!()
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      {:ok, _event} =
        RuntimeSupervision.record_event(%{
          task_id: task.id,
          phase: "execution",
          runtime_id: "runtime:smoke-el",
          event_type: "execution.started",
          invoked_by_user_id: user_id,
          owner_org_id: org_id
        })

      [lease] = Repo.all(ExecutionLease)
      assert lease.invoked_by_user_id == user_id
      assert lease.owner_org_id == org_id
      assert lease.owner_attribution_status == "attributed"
    end
  end
end
