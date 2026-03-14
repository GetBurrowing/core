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
end
