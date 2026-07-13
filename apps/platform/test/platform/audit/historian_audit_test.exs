defmodule Platform.Audit.HistorianAuditTest do
  @moduledoc """
  Task 019f5bc4 stage 3 — read-side query helper for historian dispatch audit.

  Seeds directly via `Platform.Audit.record/1` (bypasses the telemetry path)
  because this module is pure read.
  """

  use Platform.DataCase, async: true

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Audit.HistorianAudit

  defp seed_event(overrides) do
    attrs =
      %{
        event_type: "platform.historian.pass_started",
        actor_type: "system",
        action: "pass_started",
        resource_type: "workspace",
        resource_id: Ecto.UUID.generate(),
        metadata: %{}
      }
      |> Map.merge(overrides)

    {:ok, event} = Audit.record(attrs)
    event
  end

  describe "recent_for_scope/2" do
    test "returns recent events for a workspace scope" do
      workspace_id = Ecto.UUID.generate()

      seed_event(%{resource_id: workspace_id, action: "pass_started"})

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.window_dispatched",
        action: "window_dispatched"
      })

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.pass_completed",
        action: "pass_completed"
      })

      events = HistorianAudit.recent_for_scope(workspace_id)

      assert length(events) == 3

      assert Enum.all?(events, fn %Event{} = e ->
               e.resource_type == "workspace" and e.resource_id == workspace_id
             end)

      assert Enum.map(events, & &1.event_type) == [
               "platform.historian.pass_started",
               "platform.historian.window_dispatched",
               "platform.historian.pass_completed"
             ]
    end

    test "filters out other workspaces" do
      workspace_a = Ecto.UUID.generate()
      workspace_b = Ecto.UUID.generate()

      seed_event(%{resource_id: workspace_a, action: "pass_started"})
      seed_event(%{resource_id: workspace_a, action: "pass_started"})
      seed_event(%{resource_id: workspace_b, action: "pass_started"})

      events = HistorianAudit.recent_for_scope(workspace_a)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.resource_id == workspace_a))
    end

    test "respects :limit" do
      workspace_id = Ecto.UUID.generate()

      for _ <- 1..60 do
        seed_event(%{resource_id: workspace_id, action: "window_dispatched"})
      end

      events = HistorianAudit.recent_for_scope(workspace_id, limit: 10)
      assert length(events) == 10
    end

    test "restricts to event subtype when :event_type given" do
      workspace_id = Ecto.UUID.generate()

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.pass_started",
        action: "pass_started"
      })

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.window_dispatched",
        action: "window_dispatched"
      })

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.window_dispatched",
        action: "window_dispatched"
      })

      events = HistorianAudit.recent_for_scope(workspace_id, event_type: "window_dispatched")

      assert length(events) == 2

      assert Enum.all?(
               events,
               &(&1.event_type == "platform.historian.window_dispatched")
             )
    end

    test "scope_type: \"org\" hits org-scoped rows" do
      org_id = Ecto.UUID.generate()

      seed_event(%{
        resource_type: "org",
        resource_id: org_id,
        event_type: "platform.historian.pass_started",
        action: "pass_started"
      })

      seed_event(%{
        resource_type: "org",
        resource_id: org_id,
        event_type: "platform.historian.pass_completed",
        action: "pass_completed"
      })

      # Same id under workspace scope — must NOT leak into org scope.
      seed_event(%{
        resource_type: "workspace",
        resource_id: org_id,
        event_type: "platform.historian.pass_started",
        action: "pass_started"
      })

      events = HistorianAudit.recent_for_scope(org_id, scope_type: "org")

      assert length(events) == 2
      assert Enum.all?(events, &(&1.resource_type == "org"))

      assert HistorianAudit.recent_for_scope(org_id) |> length() == 1
    end

    test "excludes non-historian events for the same resource" do
      workspace_id = Ecto.UUID.generate()

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.historian.pass_started",
        action: "pass_started"
      })

      seed_event(%{
        resource_id: workspace_id,
        event_type: "platform.chat.space_archived",
        action: "space_archived"
      })

      events = HistorianAudit.recent_for_scope(workspace_id)

      assert length(events) == 1
      assert hd(events).event_type == "platform.historian.pass_started"
    end
  end
end
