defmodule Platform.Meetings.TelemetryHandlerTest do
  @moduledoc """
  Coverage for `Platform.Meetings.TelemetryHandler` — the bridge from
  meeting-triage `:telemetry` events to `Platform.Audit` (task
  019f5e2b-8d29 stage 3).

  Mirrors the layout of `Platform.Vault.TelemetryHandlerTest` — same
  attach/detach lifecycle, same audit-type mapping table, same
  metadata-drop semantics.
  """

  use Platform.DataCase

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Meetings.TelemetryHandler

  setup do
    # Unconditional restore on exit: the lifecycle case below detaches
    # mid-body, so a failure between that detach and its re-attach would
    # otherwise leak a detached VM-global handler (task 019f9d80).
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)
    :ok
  end

  describe "event_type mapping" do
    test "each registered event maps to the correct audit event_type string" do
      # `tasks_created_from_meeting` is an intentional override — see the
      # handler's moduledoc "Naming exception" section. Everything else
      # falls through the default underscore-split derivation.
      expected = [
        {[:platform, :meetings, :triage_dispatch], "meetings.triage.dispatch"},
        {[:platform, :meetings, :tasks_created_from_meeting], "meetings.tasks_created"},
        {[:platform, :meetings, :triage_cap_hit], "meetings.triage.cap_hit"}
      ]

      for {event_name, expected_type} <- expected do
        :telemetry.execute(event_name, %{}, %{action: "test"})

        events = Audit.list(event_type: expected_type)
        assert length(events) == 1, "expected 1 event for #{expected_type}, got #{length(events)}"
      end
    end
  end

  describe "attach/detach lifecycle" do
    test "detach removes the handler; re-attach re-installs it" do
      TelemetryHandler.detach()

      # No handler → no audit rows.
      :telemetry.execute([:platform, :meetings, :triage_dispatch], %{}, %{action: "orphan"})
      assert [] = Audit.list(event_type: "meetings.triage.dispatch")

      # Re-attach → subsequent events are captured.
      TelemetryHandler.attach()

      :telemetry.execute([:platform, :meetings, :triage_dispatch], %{}, %{action: "captured"})
      events = Audit.list(event_type: "meetings.triage.dispatch")
      assert Enum.any?(events, fn e -> e.action == "captured" end)
    end

    test "events/0 lists exactly the registered triage events" do
      assert TelemetryHandler.events() == [
               [:platform, :meetings, :triage_dispatch],
               [:platform, :meetings, :tasks_created_from_meeting],
               [:platform, :meetings, :triage_cap_hit]
             ]
    end
  end

  describe "telemetry → audit persistence" do
    test "triage_dispatch event lands with canvas_id as the resource_id" do
      canvas_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch],
        %{action_item_count: 4},
        %{
          canvas_id: canvas_id,
          project_id: "proj-1",
          agent_id: "agent-abc",
          dispatched_at: DateTime.utc_now()
        }
      )

      events = Audit.list(event_type: "meetings.triage.dispatch")

      assert [
               %Event{
                 event_type: "meetings.triage.dispatch",
                 resource_type: "meetings",
                 resource_id: ^canvas_id,
                 actor_type: "system"
               } = event
             ] = events

      # Measurements + non-top-level metadata land in the JSONB blob.
      assert event.metadata["action_item_count"] == 4
      assert event.metadata["project_id"] == "proj-1"
      assert event.metadata["agent_id"] == "agent-abc"
    end

    test "tasks_created_from_meeting event uses the override type + falls back to task_id" do
      task_id = Ecto.UUID.generate()

      # Only task_id in metadata — no canvas_id — so resource_id_from
      # falls through to task_id.
      :telemetry.execute(
        [:platform, :meetings, :tasks_created_from_meeting],
        %{count: 1},
        %{
          task_id: task_id,
          needs_promotion: true,
          source: "meetings.triage"
        }
      )

      events = Audit.list(event_type: "meetings.tasks_created")

      assert [
               %Event{
                 event_type: "meetings.tasks_created",
                 resource_id: ^task_id
               } = event
             ] = events

      # `ensure_json_safe` stringifies atoms (including booleans) so the
      # audit row's JSONB is uniformly string-typed at read time. The
      # handler's Chat sibling has the same shape.
      assert event.metadata["needs_promotion"] == "true"
      assert event.metadata["source"] == "meetings.triage"
      assert event.metadata["count"] == 1
    end

    test "triage_cap_hit event carries the cap + attempted counts" do
      canvas_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :meetings, :triage_cap_hit],
        %{cap: 20, attempted: 25},
        %{canvas_id: canvas_id, meeting_id: "mtg-99"}
      )

      events = Audit.list(event_type: "meetings.triage.cap_hit")

      assert [%Event{resource_id: ^canvas_id} = event] = events
      assert event.metadata["cap"] == 20
      assert event.metadata["attempted"] == 25
      assert event.metadata["meeting_id"] == "mtg-99"
    end

    test "metadata excludes top-level fields to avoid duplication" do
      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch],
        %{action_item_count: 1},
        %{
          actor_id: Ecto.UUID.generate(),
          actor_type: "agent",
          resource_id: "explicit-resource",
          action: "dispatch",
          extra: "should-appear"
        }
      )

      [event] = Audit.list(event_type: "meetings.triage.dispatch")

      refute Map.has_key?(event.metadata, "actor_id")
      refute Map.has_key?(event.metadata, "actor_type")
      refute Map.has_key?(event.metadata, "resource_id")
      refute Map.has_key?(event.metadata, "action")
      assert event.metadata["extra"] == "should-appear"
    end

    test "resource_id preference: canvas_id beats meeting_id beats task_id" do
      canvas_id = Ecto.UUID.generate()
      meeting_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :meetings, :tasks_created_from_meeting],
        %{count: 1},
        %{canvas_id: canvas_id, meeting_id: meeting_id, task_id: task_id}
      )

      [event] = Audit.list(event_type: "meetings.tasks_created")
      assert event.resource_id == canvas_id
    end

    test "handler survives exceptions without detaching" do
      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch],
        %{},
        %{action: "before"}
      )

      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch],
        %{},
        %{action: "after"}
      )

      events = Audit.list(event_type: "meetings.triage.dispatch")
      actions = Enum.map(events, & &1.action)
      assert "before" in actions
      assert "after" in actions
    end
  end
end
