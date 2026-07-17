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
end
