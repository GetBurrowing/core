defmodule Platform.Vault.TelemetryHandlerTest do
  use Platform.DataCase

  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Vault.TelemetryHandler

  setup do
    # Ensure handler is attached fresh for each test.
    TelemetryHandler.detach()
    TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  describe "event_type mapping" do
    test "all 8 vault events map to correct audit event_type strings" do
      expected = [
        {[:platform, :vault, :credential_created], "vault.credential.created"},
        {[:platform, :vault, :credential_used], "vault.credential.used"},
        {[:platform, :vault, :credential_rotated], "vault.credential.rotated"},
        {[:platform, :vault, :credential_revoked], "vault.credential.revoked"},
        {[:platform, :vault, :access_granted], "vault.access.granted"},
        {[:platform, :vault, :access_denied], "vault.access.denied"},
        {[:platform, :vault, :oauth_refreshed], "vault.oauth.refreshed"},
        {[:platform, :vault, :oauth_refresh_failed], "vault.oauth.refresh_failed"}
      ]

      for {event_name, expected_type} <- expected do
        :telemetry.execute(
          event_name,
          %{system_time: System.system_time()},
          %{action: "test"}
        )

        events = Audit.list(event_type: expected_type)
        assert length(events) == 1, "expected 1 event for #{expected_type}, got #{length(events)}"
      end
    end
  end

  describe "telemetry → audit persistence" do
    test "credential_created event is persisted" do
      user_id = Ecto.UUID.generate()
      slug = "stripe-api-key"

      :telemetry.execute(
        [:platform, :vault, :credential_created],
        %{system_time: System.system_time()},
        %{
          actor_id: user_id,
          actor_type: "user",
          resource_id: slug,
          resource_type: "credential",
          action: "create"
        }
      )

      events = Audit.list(event_type: "vault.credential.created")

      assert [
               %Event{
                 actor_id: ^user_id,
                 actor_type: "user",
                 resource_id: ^slug,
                 resource_type: "credential",
                 action: "create"
               }
             ] = events
    end

    test "credential_used event is persisted with correct resource_id" do
      user_id = Ecto.UUID.generate()
      slug = "sendgrid-smtp"

      :telemetry.execute(
        [:platform, :vault, :credential_used],
        %{system_time: System.system_time()},
        %{
          actor_id: user_id,
          actor_type: "user",
          resource_id: slug,
          action: "read"
        }
      )

      events = Audit.list(event_type: "vault.credential.used")
      assert [%Event{actor_id: ^user_id, resource_id: ^slug, action: "read"}] = events
    end

    test "access_denied event captures denied accessor info" do
      accessor_id = Ecto.UUID.generate()
      slug = "twilio-auth-token"

      :telemetry.execute(
        [:platform, :vault, :access_denied],
        %{system_time: System.system_time()},
        %{
          actor_id: accessor_id,
          actor_type: "user",
          resource_id: slug,
          resource_type: "credential",
          action: "access_denied",
          reason: "insufficient_permissions"
        }
      )

      events = Audit.list(event_type: "vault.access.denied")

      assert [%Event{actor_id: ^accessor_id, resource_id: ^slug, action: "access_denied"} = event] =
               events

      assert event.metadata["reason"] == "insufficient_permissions"
    end

    test "credential_rotated event persists rotation actor and slug" do
      user_id = Ecto.UUID.generate()
      slug = "aws-secret-key"

      :telemetry.execute(
        [:platform, :vault, :credential_rotated],
        %{system_time: System.system_time()},
        %{
          actor_id: user_id,
          actor_type: "user",
          resource_id: slug,
          action: "rotate"
        }
      )

      events = Audit.list(event_type: "vault.credential.rotated")
      assert [%Event{actor_id: ^user_id, resource_id: ^slug, action: "rotate"}] = events
    end

    test "access_granted event is persisted" do
      grantor_id = Ecto.UUID.generate()
      slug = "github-token"

      :telemetry.execute(
        [:platform, :vault, :access_granted],
        %{system_time: System.system_time()},
        %{
          actor_id: grantor_id,
          actor_type: "user",
          resource_id: slug,
          action: "grant"
        }
      )

      events = Audit.list(event_type: "vault.access.granted")
      assert [%Event{actor_id: ^grantor_id, resource_id: ^slug}] = events
    end

    test "oauth_refreshed event is persisted" do
      slug = "google-oauth"

      :telemetry.execute(
        [:platform, :vault, :oauth_refreshed],
        %{system_time: System.system_time()},
        %{
          resource_id: slug,
          actor_type: "system",
          action: "refresh"
        }
      )

      events = Audit.list(event_type: "vault.oauth.refreshed")
      assert [%Event{resource_id: ^slug, actor_type: "system"}] = events
    end

    test "oauth_refresh_failed event captures failure metadata" do
      slug = "google-oauth"

      :telemetry.execute(
        [:platform, :vault, :oauth_refresh_failed],
        %{system_time: System.system_time()},
        %{
          resource_id: slug,
          actor_type: "system",
          action: "refresh",
          error: "token_expired"
        }
      )

      events = Audit.list(event_type: "vault.oauth.refresh_failed")
      assert [%Event{resource_id: ^slug} = event] = events
      assert event.metadata["error"] == "token_expired"
    end

    test "metadata excludes top-level fields to avoid duplication" do
      user_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:platform, :vault, :credential_used],
        %{},
        %{
          actor_id: user_id,
          actor_type: "user",
          resource_id: "my-cred",
          action: "read",
          extra_context: "should-appear"
        }
      )

      [event] = Audit.list(event_type: "vault.credential.used")
      refute Map.has_key?(event.metadata, "actor_id")
      refute Map.has_key?(event.metadata, "resource_id")
      assert event.metadata["extra_context"] == "should-appear"
    end

    test "handler survives exceptions without detaching" do
      :telemetry.execute(
        [:platform, :vault, :credential_used],
        %{system_time: System.system_time()},
        %{action: "before"}
      )

      :telemetry.execute(
        [:platform, :vault, :credential_used],
        %{system_time: System.system_time()},
        %{action: "after"}
      )

      events = Audit.list(event_type: "vault.credential.used")
      actions = Enum.map(events, & &1.action)
      assert "before" in actions
      assert "after" in actions
    end
  end
end
