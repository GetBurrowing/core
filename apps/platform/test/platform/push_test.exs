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

  # Subscribe a SPECIFIC endpoint under a participant row. The same physical
  # device (endpoint) is subscribed under many participant rows of the same
  # user — the exact shape that produced the duplicate-push storm.
  defp subscribe_endpoint(participant_id, endpoint) do
    n = System.unique_integer([:positive])

    {:ok, sub} =
      Push.subscribe(participant_id, %{
        endpoint: endpoint,
        keys: %{p256dh: "p256dh-#{n}", auth: "auth-#{n}"}
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

  describe "subscriptions_for_recipient/1 across conversations (task 019ffd19)" do
    test "a device enabled in conversation B is resolved for a mention in conversation A" do
      user = insert_user(name: "Two Channel User")

      # The same user, two conversations, therefore two chat_participants rows.
      participant_a = add_user_participant(create_space().id, user)
      participant_b = add_user_participant(create_space().id, user)

      # Two devices, each registered while the user was looking at a different
      # conversation: the phone in A, the laptop in B. Turning notifications on
      # is a per-device act, so which conversation was open at the time is an
      # accident of timing and must not decide where a mention lands.
      endpoint_phone = "https://push.example.com/device/phone"
      endpoint_laptop = "https://push.example.com/device/laptop"
      subscribe_endpoint(participant_a.id, endpoint_phone)
      subscribe_endpoint(participant_b.id, endpoint_laptop)

      resolved =
        participant_a.id
        |> Push.subscriptions_for_recipient()
        |> Enum.map(& &1.endpoint)
        |> Enum.sort()

      assert resolved == Enum.sort([endpoint_phone, endpoint_laptop]),
             "a mention in conversation A must reach every device the user owns, " <>
               "including the one registered in conversation B; got #{inspect(resolved)}"
    end

    test "one physical device registered under two memberships resolves ONCE" do
      user = insert_user(name: "One Device Two Channels")

      participant_a = add_user_participant(create_space().id, user)
      participant_b = add_user_participant(create_space().id, user)

      # ONE device. The browser re-registers the same endpoint under whichever
      # conversation was open when notifications were turned on, so a user in N
      # conversations owns N rows for the SAME endpoint. Resolving across
      # memberships with a plain join would therefore send N copies to one
      # device: the duplicate-storm defect wearing the cross-conversation fix's
      # clothes. The endpoint collapse is what keeps the two apart.
      endpoint = "https://push.example.com/device/only-phone"
      subscribe_endpoint(participant_a.id, endpoint)
      subscribe_endpoint(participant_b.id, endpoint)

      assert Repo.aggregate(Subscription, :count) == 2,
             "fixture must store one subscription row per membership"

      resolved =
        participant_a.id
        |> Push.subscriptions_for_recipient()
        |> Enum.map(& &1.endpoint)

      assert resolved == [endpoint],
             "two membership rows for one endpoint must resolve to one device; " <>
               "got #{inspect(resolved)}"

      # End to end on the same path: with VAPID unconfigured each do_send_push
      # logs exactly one "VAPID keys not configured" line, so counting the line
      # counts delivery attempts. One device, one push.
      log =
        capture_log(fn ->
          assert Push.send_notification(participant_a.id, %{title: "hi", body: "there"}) == :ok
        end)

      deliveries =
        log |> String.split("VAPID keys not configured") |> length() |> Kernel.-(1)

      assert deliveries == 1,
             "one physical device must be pushed once, not once per membership; " <>
               "got #{deliveries}; log: #{log}"
    end
  end

  describe "subscriptions_for_recipient/1 recipient typing (task 019ffd19)" do
    test "agent-typed recipient keeps the per-membership device set" do
      space = create_space()

      {:ok, agent} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Zip",
          joined_at: DateTime.utc_now()
        })

      endpoint = "https://push.example.com/device/agent-row"
      subscribe_endpoint(agent.id, endpoint)

      resolved =
        agent.id
        |> Push.subscriptions_for_recipient()
        |> Enum.map(& &1.endpoint)

      # The user-scoped query joins on `participant_type == "user"`, so handing
      # an agent row to it resolves nothing at all. Agent recipients must stay
      # on the per-membership lookup.
      assert resolved == [endpoint],
             "an agent recipient must resolve its own membership's devices; " <>
               "got #{inspect(resolved)}"
    end

    test "an agent row whose participant_id collides with a user id resolves NO user devices" do
      # `participant_id` holds a USER id on a user row and an AGENT id on an
      # agent row: two id spaces in one column. Handing an agent row to the
      # user-scoped lookup asks "which user-typed rows carry this id", so a
      # collision would hand the agent every device that user owns. The type
      # branch, not the improbability of a UUID collision, is what prevents it.
      user = insert_user(name: "Collision User")
      user_participant = add_user_participant(create_space().id, user)
      human_endpoint = "https://push.example.com/device/human-laptop"
      subscribe_endpoint(user_participant.id, human_endpoint)

      {:ok, agent} =
        Chat.add_participant(create_space().id, %{
          participant_type: "agent",
          participant_id: user.id,
          display_name: "Zip",
          joined_at: DateTime.utc_now()
        })

      resolved =
        agent.id
        |> Push.subscriptions_for_recipient()
        |> Enum.map(& &1.endpoint)

      assert resolved == [],
             "an agent recipient must never resolve a user's devices; got #{inspect(resolved)}"
    end
  end

  describe "send_to_user/2 endpoint dedup (#592 duplicate-storm fix)" do
    test "same endpoint under many participant rows → exactly ONE push per endpoint" do
      user = insert_user(name: "Heavy User")

      # Three spaces → three user-typed participant rows for the SAME user,
      # modelling a heavy user active in many channels.
      participants =
        for _ <- 1..3 do
          space = create_space()
          add_user_participant(space.id, user)
        end

      # The same physical device (endpoint E1) is subscribed under ALL three
      # participant rows — exactly the shape that fanned one assignment out to
      # the same device once per space.
      endpoint_shared = "https://push.example.com/device/shared"
      Enum.each(participants, &subscribe_endpoint(&1.id, endpoint_shared))

      # Plus a second distinct device (E2) under one of the rows.
      endpoint_other = "https://push.example.com/device/other"
      subscribe_endpoint(hd(participants).id, endpoint_other)

      # 3 rows for E1 + 1 row for E2 = 4 subscription rows, 2 distinct endpoints.
      assert Repo.aggregate(Subscription, :count) == 4

      # With VAPID unconfigured (test default) each do_send_push logs exactly
      # one "VAPID keys not configured" line, so counting that line counts the
      # deliveries attempted. Endpoint-dedup must make it 2 (one per distinct
      # endpoint), NOT 4 (one per subscription row).
      log =
        capture_log(fn ->
          assert Push.send_to_user(user.id, %{title: "hi", body: "there", url: "/x"}) == :ok
        end)

      deliveries =
        log |> String.split("VAPID keys not configured") |> length() |> Kernel.-(1)

      assert deliveries == 2,
             "expected one delivery per distinct endpoint (2), got #{deliveries}; log: #{log}"
    end

    test "archived user: suppressed with telemetry, no delivery attempted" do
      attach_suppressed_handler()

      space = create_space()
      user = insert_user(name: "Archived Heavy")
      participant = add_user_participant(space.id, user)
      subscribe_endpoint(participant.id, "https://push.example.com/device/z")

      {:ok, _archived} = Accounts.archive_user(user)

      log =
        capture_log(fn ->
          assert Push.send_to_user(user.id, %{title: "hi", body: "there", url: "/x"}) == :ok
        end)

      refute log =~ "VAPID keys not configured",
             "archived user must short-circuit before any delivery"

      assert_received {:suppressed_archived_user, %{count: 1}, %{user_id: uid}}
      assert uid == user.id
    end
  end
end
