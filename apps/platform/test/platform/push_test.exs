defmodule Platform.PushTest do
  # async: false because we attach process-scoped telemetry handlers keyed on
  # module name; parallel tests would race on the shared handler id.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Push
  alias Platform.Push.Subscription
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp insert_user(opts) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "User #{n}"),
      email: Keyword.get(opts, :email, "user-#{n}@example.com"),
      oidc_sub: "sub-#{n}"
    })
  end

  defp create_space do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(default)
    space
  end

  defp add_user_participant(space_id, user) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp subscribe(participant_id) do
    n = System.unique_integer([:positive])

    {:ok, sub} =
      Push.subscribe(participant_id, %{
        endpoint: "https://push.example.com/sub/#{n}",
        keys: %{
          p256dh: "p256dh-#{n}",
          auth: "auth-#{n}"
        }
      })

    sub
  end

  defp attach_suppressed_handler do
    handler_id = "push-test-suppressed-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :push, :suppressed_archived_user],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:suppressed_archived_user, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # Mark a user external in the seeded fabrikam org (M13 external-preview fixtures).
  defp mark_external(user) do
    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.fabrikam_org_id()
      })

    user
  end

  defp attach_external_preview_handler do
    handler_id = "push-test-external-preview-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :push, :external_safe_preview],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:external_safe_preview, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # ── Tests ───────────────────────────────────────────────────────────────────

  describe "send_notification/2 archived-user guard (Stage 4)" do
    test "archived-user participant: returns :ok, emits telemetry, does NOT dispatch push" do
      attach_suppressed_handler()

      space = create_space()
      user = insert_user(name: "Bob Archived")
      participant = add_user_participant(space.id, user)
      _sub = subscribe(participant.id)

      {:ok, _archived_user} = Accounts.archive_user(user)

      # If the guard fires early, do_send_push is never reached, so no
      # "[Push] VAPID keys not configured" warning is emitted. Wrapping
      # in capture_log lets us assert the negative.
      log =
        capture_log(fn ->
          assert Push.send_notification(participant.id, %{title: "hi", body: "there"}) == :ok
        end)

      refute log =~ "VAPID keys not configured",
             "guard must short-circuit BEFORE do_send_push runs; log was: #{log}"

      refute log =~ "[Push] failed to send",
             "no per-subscription failure should be logged when the guard fires"

      assert_received {:suppressed_archived_user, %{count: 1}, %{participant_id: pid}}

      assert pid == participant.id
    end

    test "non-archived user participant: does NOT emit telemetry; reaches do_send_push" do
      attach_suppressed_handler()

      space = create_space()
      user = insert_user(name: "Alice Active")
      participant = add_user_participant(space.id, user)
      _sub = subscribe(participant.id)

      # Regression guard: the archival check must not accidentally suppress
      # active users. Without VAPID configured (default in test), do_send_push
      # logs "VAPID keys not configured" — the presence of that line proves
      # the send flow reached the delivery boundary.
      log =
        capture_log(fn ->
          assert Push.send_notification(participant.id, %{title: "hi", body: "there"}) == :ok
        end)

      assert log =~ "VAPID keys not configured",
             "active user must reach do_send_push; got log: #{log}"

      refute_received {:suppressed_archived_user, _, _}
    end

    test "agent participant: never treated as archived (guard is user-scoped)" do
      attach_suppressed_handler()

      space = create_space()

      # Agent participant — participant_type == "agent" so the guard's user
      # branch never runs even if a users row with the same UUID happened
      # to exist and be archived.
      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Zip",
          joined_at: DateTime.utc_now()
        })

      _sub = subscribe(participant.id)

      log =
        capture_log(fn ->
          assert Push.send_notification(participant.id, %{title: "hi", body: "there"}) == :ok
        end)

      assert log =~ "VAPID keys not configured",
             "agent must reach do_send_push; got log: #{log}"

      refute_received {:suppressed_archived_user, _, _}
    end

    test "unknown participant_id (no chat_participants row): behaves as before, no telemetry" do
      attach_suppressed_handler()

      unknown_id = Ecto.UUID.generate()

      # No subscriptions either, so nothing to iterate — send_notification
      # returns :ok (the Enum.each over an empty list) without hitting any
      # push endpoint. The guard must NOT treat unknown participants as
      # archived (they might legitimately be non-user, non-existent, or
      # test fixtures with random UUIDs).
      assert Push.send_notification(unknown_id, %{title: "hi", body: "there"}) == :ok

      refute_received {:suppressed_archived_user, _, _}

      # And no subscription row leaked.
      assert Repo.all(Subscription) == []
    end
  end

  describe "external_safe_preview/1 (Stage 1)" do
    test "returns the fixed generic map regardless of input" do
      assert Push.external_safe_preview(%{
               title: "Rowan Ellis in Suite",
               body: "internal roadmap: shipping the Acme deal Friday",
               url: "/chat"
             }) == %{
               title: "New message",
               body: "You have a new message",
               url: "/chat"
             }
    end

    test "drops every sensitive string from a chat-shaped payload" do
      preview =
        Push.external_safe_preview(%{
          title: "Rowan Ellis in Suite",
          body: "internal roadmap: shipping the Acme deal Friday",
          url: "/chat"
        })

      values = preview |> Map.values() |> Enum.join(" ")
      refute values =~ "Rowan Ellis"
      refute values =~ "internal roadmap"
      refute values =~ "Acme"
    end

    test "drops the meeting name and internal slug from a meeting-shaped payload" do
      preview =
        Push.external_safe_preview(%{
          title: "Alex Kim started a meeting",
          body: "Q3 Board Prep",
          url: "/meetings/q3-board-prep"
        })

      values = preview |> Map.values() |> Enum.join(" ")
      refute values =~ "Alex Kim"
      refute values =~ "Q3 Board Prep"
      refute values =~ "q3-board-prep"
      assert preview.url == "/chat"
    end
  end

  describe "preview_for_recipient/2 (Stage 2)" do
    test "external recipient: returns generic preview and fires telemetry once" do
      attach_external_preview_handler()

      space = create_space()
      user = insert_user(name: "Xavier External") |> mark_external()
      participant = add_user_participant(space.id, user)

      payload = %{
        title: "Rowan Ellis in Suite",
        body: "internal roadmap: shipping the Acme deal Friday",
        url: "/chat"
      }

      assert Push.preview_for_recipient(participant.id, payload) == %{
               title: "New message",
               body: "You have a new message",
               url: "/chat"
             }

      assert_received {:external_safe_preview, %{count: 1}, %{participant_id: pid}}
      assert pid == participant.id
      refute_received {:external_safe_preview, _, _}
    end

    test "internal member recipient: returns payload byte-identical, no telemetry" do
      attach_external_preview_handler()

      space = create_space()
      user = insert_user(name: "Ian Internal")

      {:ok, _} =
        %Platform.Tenancy.OrgMembership{}
        |> Platform.Tenancy.OrgMembership.changeset(%{
          user_id: user.id,
          org_id: TenancyFixtures.fabrikam_org_id(),
          role: "member"
        })
        |> Repo.insert()

      participant = add_user_participant(space.id, user)

      payload = %{
        title: "Rowan Ellis in Suite",
        body: "internal roadmap: shipping the Acme deal Friday",
        url: "/chat"
      }

      assert Push.preview_for_recipient(participant.id, payload) == payload
      refute_received {:external_safe_preview, _, _}
    end

    test "agent participant: pass-through unchanged, no telemetry" do
      attach_external_preview_handler()

      space = create_space()

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Zip",
          joined_at: DateTime.utc_now()
        })

      payload = %{title: "Rowan Ellis in Suite", body: "x", url: "/chat"}

      assert Push.preview_for_recipient(participant.id, payload) == payload
      refute_received {:external_safe_preview, _, _}
    end

    test "unknown participant: pass-through unchanged, no telemetry" do
      attach_external_preview_handler()

      payload = %{title: "t", body: "b", url: "/chat"}
      assert Push.preview_for_recipient(Ecto.UUID.generate(), payload) == payload
      refute_received {:external_safe_preview, _, _}
    end

    test "archived external recipient: archived guard wins, no preview swap, no send" do
      attach_suppressed_handler()
      attach_external_preview_handler()

      space = create_space()
      user = insert_user(name: "Ada ArchivedExternal") |> mark_external()
      participant = add_user_participant(space.id, user)
      _sub = subscribe(participant.id)

      {:ok, _archived} = Accounts.archive_user(user)

      log =
        capture_log(fn ->
          assert Push.send_notification(participant.id, %{title: "t", body: "b"}) == :ok
        end)

      refute log =~ "VAPID keys not configured",
             "archived guard must short-circuit before do_send_push; log: #{log}"

      # Archived wins: the archived telemetry fires, the external-preview one
      # does not (the two guards compose, no double handling).
      assert_received {:suppressed_archived_user, %{count: 1}, %{participant_id: pid}}
      assert pid == participant.id
      refute_received {:external_safe_preview, _, _}
    end
  end
end
