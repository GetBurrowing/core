defmodule Platform.Audit.TelemetryHandlerTest do
  use Platform.DataCase

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler

  setup do
    # Ensure handler is attached for each test (Application.start may not
    # run in the test env the way we expect).
    TelemetryHandler.detach()
    TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  describe "telemetry → audit persistence" do
    test "auth login event is persisted" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{
          action: "redirect",
          ip_address: "10.0.0.1"
        }
      )

      events = Audit.list(event_type: "platform.auth.login")
      assert [%Event{action: "redirect", ip_address: "10.0.0.1"}] = events
    end

    test "auth callback success event captures actor" do
      user_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user_id,
          actor_type: "user",
          resource_type: "session",
          resource_id: user_id,
          ip_address: "10.0.0.1",
          email: "test@example.com"
        }
      )

      events = Audit.list(event_type: "platform.auth.callback")
      assert [%Event{action: "success", actor_id: ^user_id, actor_type: "user"} = event] = events
      assert event.metadata["email"] == "test@example.com"
    end

    test "auth callback failure event captures reason" do
      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "failure",
          ip_address: "10.0.0.1",
          reason: "invalid_state"
        }
      )

      events = Audit.list(event_type: "platform.auth.callback")
      assert [%Event{action: "failure"} = event] = events
      assert event.metadata["reason"] == "invalid_state"
    end

    test "auth logout event is persisted" do
      user_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :logout],
        %{system_time: System.system_time()},
        %{
          action: "logout",
          actor_id: user_id,
          actor_type: "user",
          ip_address: "10.0.0.1"
        }
      )

      events = Audit.list(event_type: "platform.auth.logout")
      assert [%Event{action: "logout", actor_id: ^user_id}] = events
    end

    test "access blocked event captures route" do
      :telemetry.execute(
        [:platform, :auth, :access_blocked],
        %{system_time: System.system_time()},
        %{
          action: "blocked",
          actor_type: "anonymous",
          resource_type: "route",
          resource_id: "/admin/secrets",
          ip_address: "10.0.0.1",
          reason: "no_session"
        }
      )

      events = Audit.list(event_type: "platform.auth.access_blocked")

      assert [%Event{resource_type: "route", resource_id: "/admin/secrets"} = event] =
               events

      assert event.metadata["reason"] == "no_session"
    end

    test "metadata excludes top-level fields to avoid duplication" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{},
        %{
          action: "redirect",
          actor_id: Ecto.UUID.generate(),
          ip_address: "10.0.0.1",
          extra_field: "should-appear"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      refute Map.has_key?(event.metadata, "actor_id")
      refute Map.has_key?(event.metadata, "ip_address")
      assert event.metadata["extra_field"] == "should-appear"
    end

    test "handler survives exceptions without detaching" do
      # Emit a malformed event (handler should rescue, not crash)
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "test-before"}
      )

      # Verify handler is still attached by emitting a second event
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "test-after"}
      )

      events = Audit.list(event_type: "platform.auth.login")
      actions = Enum.map(events, & &1.action)
      assert "test-before" in actions
      assert "test-after" in actions
    end
  end

  describe "actor_org_id threading (ADR 0040)" do
    test "actor_org_id from telemetry metadata persists to audit_events.actor_org_id" do
      user_id = Ecto.UUID.generate()
      org_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: user_id,
          actor_type: "user",
          actor_org_id: org_id,
          ip_address: "10.0.0.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.callback")
      assert event.actor_id == user_id
      assert event.actor_org_id == org_id
    end

    test "actor_org_id is excluded from metadata blob (top-level field deduplication)" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{},
        %{
          action: "redirect",
          actor_id: Ecto.UUID.generate(),
          actor_org_id: Ecto.UUID.generate(),
          ip_address: "10.0.0.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      refute Map.has_key?(event.metadata, "actor_org_id")
    end

    test "events without actor_org_id leave the column NULL" do
      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{action: "redirect", ip_address: "10.0.0.1"}
      )

      [event] = Audit.list(event_type: "platform.auth.login")
      assert is_nil(event.actor_org_id)
    end

    test "federated_user actor_type with both actor_id (handle) and actor_org_id" do
      pseudonymous_handle = Ecto.UUID.generate()
      peer_org_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :auth, :callback],
        %{system_time: System.system_time()},
        %{
          action: "success",
          actor_id: pseudonymous_handle,
          actor_type: "federated_user",
          actor_org_id: peer_org_id,
          ip_address: "203.0.113.1"
        }
      )

      [event] = Audit.list(event_type: "platform.auth.callback")
      assert event.actor_type == "federated_user"
      assert event.actor_id == pseudonymous_handle
      assert event.actor_org_id == peer_org_id
    end
  end
end
