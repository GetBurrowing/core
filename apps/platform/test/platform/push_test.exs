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

  # Mark a user external in the seeded acme org (M13 external-preview fixtures).
  defp mark_external(user) do
    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.acme_org_id()
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

  # ── VAPID fixtures (task 01a0108a) ──────────────────────────────────────────

  # ALL KEY-SHAPED LITERALS BELOW ARE INVENTED. This repository is public. None
  # of these is a key, none has ever been a key, and none resembles the base64url
  # shape of a real VAPID key. A DIFFERENT constant per resolution source is
  # deliberate: it makes a value arriving from the wrong path visible as the
  # wrong string instead of indistinguishable from the right one.

  # Invented, not a key: the env-var path.
  @env_public_key "fake-vapid-public-key-from-env-not-a-real-key"
  # Invented, not a key: the env-var path.
  @env_private_key "fake-vapid-private-key-from-env-not-a-real-key"
  # Invented, not a key: the Vault fallback path.
  @vault_public_key "fake-vapid-public-key-from-vault-not-a-real-key"
  # Invented, not a key: the Vault fallback path.
  @vault_private_key "fake-vapid-private-key-from-vault-not-a-real-key"

  # Back to the NEITHER state: all three inputs absent. Deletes rather than nils
  # (nil persists as a value), and clears any Vault rows a prior fixture seeded.
  defp reset_vapid_inputs do
    System.delete_env("VAPID_PUBLIC_KEY")
    System.delete_env("VAPID_PRIVATE_KEY")
    Application.delete_env(:web_push_encryption, :vapid_details)
    delete_vault_vapid()
    :ok
  end

  defp seed_env_only do
    System.put_env("VAPID_PUBLIC_KEY", @env_public_key)
    System.put_env("VAPID_PRIVATE_KEY", @env_private_key)
    :ok
  end

  # Both halves in Vault, nothing in env or app env. `Platform.Vault.get/2`
  # documents platform-scoped credentials as readable by any accessor, which is
  # what lets `Platform.Push`'s `{:system, nil}` accessor — a supervised process
  # carrying no user or agent identity — reach these rows.
  defp seed_vault_only do
    seed_vault_key("vapid-public-key", @vault_public_key)
    seed_vault_key("vapid-private-key", @vault_private_key)
    :ok
  end

  # Public half resolvable, private half unresolvable in ALL THREE sources.
  defp seed_public_half_only do
    System.put_env("VAPID_PUBLIC_KEY", @env_public_key)
    :ok
  end

  # The mirror: private half only.
  defp seed_private_half_only do
    System.put_env("VAPID_PRIVATE_KEY", @env_private_key)
    :ok
  end

  defp seed_vault_key(slug, value) do
    {:ok, _credential} =
      Platform.Vault.put(slug, :keypair, value,
        scope: {:platform, nil},
        name: "Test #{slug} (invented value, not a key)"
      )

    :ok
  end

  defp delete_vault_vapid do
    Repo.delete_all(
      from(c in Platform.Vault.Credential,
        where: c.slug in ["vapid-public-key", "vapid-private-key"]
      )
    )

    :ok
  end

  # An env var cannot hold nil, so "was absent" restores by DELETING. Setting ""
  # would not restore absence either: `Platform.Push`'s presence/1 treats "" as
  # unconfigured so it lands in the same half, but unset is still a different
  # observable state.
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp count_occurrences(log, needle) do
    log |> String.split(needle) |> length() |> Kernel.-(1)
  end

  # Attached per test and detached in on_exit: a leaked :telemetry handler makes a
  # later test observe events it did not cause.
  defp attach_half_configured_handler do
    handler_id = "push-test-vapid-half-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :push, :vapid_half_configured],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:vapid_half_configured, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # Drive one real delivery attempt so the half-configured branch in
  # `do_send_push/2` actually runs. Logs are captured because that branch is
  # deliberately loud (Logger.error).
  defp trigger_send_attempt(endpoint) do
    space = create_space()
    user = insert_user(name: "Half Configured")
    participant = add_user_participant(space.id, user)
    subscribe_endpoint(participant.id, endpoint)

    log =
      capture_log(fn ->
        assert Push.send_to_user(user.id, %{title: "hi", body: "there", url: "/x"}) == :ok
      end)

    assert log =~ "VAPID half-configured",
           "a half configuration is a misconfiguration and must log loudly"

    refute log =~ @env_public_key, "the log must name the half, never the value"
    refute log =~ @env_private_key, "the log must name the half, never the value"

    log
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
               title: "Avery Rivera in Suite",
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
          title: "Avery Rivera in Suite",
          body: "internal roadmap: shipping the Acme deal Friday",
          url: "/chat"
        })

      values = preview |> Map.values() |> Enum.join(" ")
      refute values =~ "Avery Rivera"
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
        title: "Avery Rivera in Suite",
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
          org_id: TenancyFixtures.acme_org_id(),
          role: "member"
        })
        |> Repo.insert()

      participant = add_user_participant(space.id, user)

      payload = %{
        title: "Avery Rivera in Suite",
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

      payload = %{title: "Avery Rivera in Suite", body: "x", url: "/chat"}

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

  describe "subscribe_for_user/2 (task 019ffe52)" do
    defp device(n),
      do: %{endpoint: "https://push.example.com/dev/#{n}", keys: %{p256dh: "p", auth: "a"}}

    test "files against the user's EARLIEST membership, whichever space is open" do
      user = insert_user(name: "Multi Channel")

      # joined_at set explicitly and apart, so the assertion below is about the
      # ordering and not about how fast three inserts happened to run.
      participants =
        for i <- 1..3 do
          create_space().id
          |> add_user_participant(user)
          |> Ecto.Changeset.change(joined_at: DateTime.add(DateTime.utc_now(), i, :second))
          |> Repo.update!()
        end

      {:ok, sub} = Push.subscribe_for_user(user.id, device(1))

      assert sub.participant_id == hd(participants).id,
             "the anchor row must be the earliest membership, not an arbitrary one"

      # Repeat calls land on the same row, so one physical device stays one row
      # no matter how many times the client re-registers. Asserted by count and
      # anchor, not by id: `subscribe/2` upserts with
      # `on_conflict: {:replace, ...}` and no `returning:`, so the struct it
      # hands back on a conflict carries the id Ecto generated for the insert
      # it did not perform, never the stored row's.
      {:ok, again} = Push.subscribe_for_user(user.id, device(1))
      assert again.participant_id == sub.participant_id
      assert Repo.aggregate(Subscription, :count) == 1
    end

    test "a user in no space gets {:error, :no_participant} and writes nothing" do
      user = insert_user(name: "Spaceless")

      assert Push.subscribe_for_user(user.id, device(2)) == {:error, :no_participant}
      assert Repo.aggregate(Subscription, :count) == 0
    end

    # `where: p.participant_id == ^user_id` pins a `:binary_id` column, so an
    # id that is not a UUID raises Ecto.Query.CastError out of the query rather
    # than returning nothing. This is public API: the caller that exists today
    # reads a session value, and the next one need not.
    test "a malformed user id is refused, not raised on" do
      assert Push.subscribe_for_user("definitely-not-a-uuid", device(3)) ==
               {:error, :no_participant}

      assert Repo.aggregate(Subscription, :count) == 0
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

  describe "FCM is a third transport for the same notification (task 01a10d8e)" do
    setup do
      saved = Application.get_env(:platform, :fcm)
      :persistent_term.erase({Platform.Push.FCM, :access_token})

      on_exit(fn ->
        if saved,
          do: Application.put_env(:platform, :fcm, saved),
          else: Application.delete_env(:platform, :fcm)

        :persistent_term.erase({Platform.Push.FCM, :access_token})
      end)

      Platform.FCMFixtures.configure!(Platform.FCMFixtures.generated_rsa_pem())
      Platform.FCMFixtures.stub_fcm(self(), {200, %{"name" => "projects/p/messages/1"}})
      :ok
    end

    defp fcm_notification do
      Platform.Push.Notification.new(%{
        kind: "chat_mention",
        title: "Sam in Design",
        body: "secret plans",
        url: "/chat/design",
        space_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        author_name: "Sam",
        space_name: "Design"
      })
    end

    test "send_to_user reaches FCM for a user with an fcm_devices row" do
      user = insert_user(name: "Android User")
      Platform.FCMFixtures.insert_fcm_device(user)
      n = fcm_notification()

      log = capture_log(fn -> assert :ok = Push.send_to_user(user.id, n) end)

      assert_received {:fcm_send, req}
      assert req.body["message"]["token"] == Platform.FCMFixtures.sentinel_token()

      # Task 01a1261e: Platform.Push stamps the recipient's unread count (and
      # its time) into the native copy's data; everything else is the struct.
      message = Map.delete(req.body["message"], "token")
      assert message["data"]["unread_count"] == "0"
      assert is_binary(message["data"]["unread_as_of"])

      assert update_in(message["data"], &Map.drop(&1, ~w(unread_count unread_as_of))) ==
               Platform.Push.Notification.to_fcm_payload(n)

      Platform.FCMFixtures.refute_secrets(log)
    end

    test "an external user's FCM push carries the redacted copy" do
      user = insert_user(name: "Xavier External") |> mark_external()
      Platform.FCMFixtures.insert_fcm_device(user)

      capture_log(fn -> Push.send_to_user(user.id, fcm_notification()) end)

      assert_received {:fcm_send, req}
      data = req.body["message"]["data"]
      assert data["title"] == "New message"
      refute Jason.encode!(data) =~ "secret plans"
      refute Map.has_key?(data, "author_name")
      refute Map.has_key?(data, "space_name")
    end

    test "an archived user gets no FCM push" do
      user = insert_user(name: "Archived Android")
      Platform.FCMFixtures.insert_fcm_device(user)
      {:ok, _} = Accounts.archive_user(user)

      capture_log(fn -> Push.send_to_user(user.id, fcm_notification()) end)

      refute_received {:fcm_send, _}
    end

    test "send_notification: a user row reaches FCM, an agent row never does" do
      user = insert_user(name: "Android Member")
      Platform.FCMFixtures.insert_fcm_device(user)
      space = create_space()
      user_row = add_user_participant(space.id, user)

      # An AGENT-typed row whose participant_id equals the user's id: only the
      # row TYPE may decide, never the id.
      agent_row =
        Repo.insert!(%Platform.Chat.Participant{
          space_id: space.id,
          participant_type: "agent",
          participant_id: user.id,
          display_name: "Agent",
          joined_at: DateTime.utc_now()
        })

      capture_log(fn -> Push.send_notification(agent_row.id, fcm_notification()) end)
      refute_received {:fcm_send, _}

      capture_log(fn -> Push.send_notification(user_row.id, fcm_notification()) end)
      assert_received {:fcm_send, _}
    end
  end

  describe "VAPID key resolution vs the send path's configuration probe" do
    # HISTORY, kept deliberately. Task 01a01041 stage 2 added this block as a
    # CHARACTERISATION test of a real defect: `vapid_public_key/0` resolved env
    # then Vault, while `do_send_push/2` and `vapid_configured?/0` read only
    # `Application.get_env(:web_push_encryption, :vapid_details)` — which
    # `config/runtime.exs` populates ONLY from the two env vars. So a
    # Vault-configured host advertised a public key to the browser, accepted
    # subscriptions, and then delivered nothing. Its test was named "a
    # Vault-only deployment resolves keys while the send path reads
    # unconfigured" and ASSERTED that disagreement, with a comment instructing
    # the follow-up ticket to invert it rather than relax it.
    #
    # Task 01a0108a is that follow-up. Both surfaces now read one all-or-nothing
    # `vapid_details/0`, so the tests below assert AGREEMENT. The disagreement is
    # recorded here as the OLD, NOW-REJECTED behaviour: if a future reader finds
    # a test asserting that the subscribe surface can report configured while the
    # send surface does not, that is the bug returning, not a spec.
    #
    # The invented constants and fixture helpers live in the fixtures section at
    # the top of this file. A DIFFERENT constant is used per resolution source on
    # purpose: a value arriving from the wrong path is then visible as the wrong
    # string rather than indistinguishable from the right one.

    # Every test in this block starts from the NEITHER state and restores all
    # three inputs afterwards. `System.delete_env/1` and `Application.delete_env/2`
    # are used rather than setting nil, because nil persists as a VALUE: an env
    # var cannot hold nil, and `Application.put_env(.., nil)` leaves a key whose
    # value is the atom nil, which is a different state from absent.
    setup do
      previous_app_env = Application.get_env(:web_push_encryption, :vapid_details)
      previous_public = System.get_env("VAPID_PUBLIC_KEY")
      previous_private = System.get_env("VAPID_PRIVATE_KEY")

      Application.delete_env(:web_push_encryption, :vapid_details)
      System.delete_env("VAPID_PUBLIC_KEY")
      System.delete_env("VAPID_PRIVATE_KEY")

      on_exit(fn ->
        if previous_app_env do
          Application.put_env(:web_push_encryption, :vapid_details, previous_app_env)
        else
          Application.delete_env(:web_push_encryption, :vapid_details)
        end

        restore_env("VAPID_PUBLIC_KEY", previous_public)
        restore_env("VAPID_PRIVATE_KEY", previous_private)
      end)

      :ok
    end

    # ── Fixture 1: ENV-ONLY ───────────────────────────────────────────────────

    test "ENV-ONLY: both surfaces agree that env-supplied keys are configured" do
      seed_env_only()

      assert Push.vapid_public_key() == @env_public_key
      assert Push.vapid_configured?()
    end

    # ── Fixture 2: FALLBACK-ONLY (Vault). THE REGRESSION CASE ─────────────────

    # Converted from 01a01041's "a Vault-only deployment resolves keys while the
    # send path reads unconfigured". Before task 01a0108a this exact fixture
    # produced public-key-present + configured?-false. That state is now
    # unreachable, and this test is what detonates if it becomes reachable again.
    #
    # It also closes a GAP in the original: that test never seeded a Vault
    # secret, so its "Vault-only" case was really the NEITHER case and could not
    # observe the bug it was named for. The assertions below prove the seeded
    # value is what comes back, and that it is the VAULT constant rather than the
    # env constant — which is what distinguishes this fixture from fixture 3.
    test "FALLBACK-ONLY: a Vault-seeded pair resolves AND the send path reads configured" do
      seed_vault_only()

      # Anti-vacuity: prove this is genuinely the Vault path and not the
      # neither-case wearing its name. Both env vars are absent and no app env
      # is set, so the ONLY source that can supply these strings is Vault.
      refute System.get_env("VAPID_PUBLIC_KEY")
      refute System.get_env("VAPID_PRIVATE_KEY")
      refute Application.get_env(:web_push_encryption, :vapid_details)

      assert Push.vapid_public_key() == @vault_public_key,
             "the public key must come back from Vault, and be the SEEDED value"

      refute Push.vapid_public_key() == @env_public_key,
             "a value arriving from the env path here would mean the fixture leaked"

      assert Push.vapid_private_key() == @vault_private_key

      # The send surface reads the same resolver, so it agrees. On origin/main
      # this line was `refute` — that inversion IS the fix.
      assert Push.vapid_configured?()

      details = Push.vapid_details()
      assert details[:public_key] == @vault_public_key
      assert details[:private_key] == @vault_private_key
      assert details[:subject] =~ "mailto:push@"
    end

    test "the default subject is a mailto on the endpoint's host, never a literal fallback" do
      host = PlatformWeb.Endpoint.struct_url().host

      assert Push.vapid_subject([]) == "mailto:push@" <> host
      assert Push.vapid_subject(subject: "") == "mailto:push@" <> host
      refute Push.vapid_subject([]) =~ "suite.app"
      assert Push.vapid_subject(subject: "mailto:ops@example.net") == "mailto:ops@example.net"
    end

    # ── Fixture 3: NEITHER ────────────────────────────────────────────────────

    test "NEITHER: no key advertised, not configured, and a send attempt fails visibly" do
      # setup/0 already deleted all three inputs and no Vault rows are seeded.
      assert Push.vapid_public_key() == nil,
             "an empty meta tag is what makes push_subscribe.js decline to subscribe"

      refute Push.vapid_configured?()

      space = create_space()
      user = insert_user(name: "Neither Configured")
      participant = add_user_participant(space.id, user)
      subscribe_endpoint(participant.id, "https://push.example.com/device/neither")

      log =
        capture_log(fn ->
          assert Push.send_to_user(user.id, %{title: "hi", body: "there", url: "/x"}) == :ok
        end)

      # The error reason is the primary signal, and it is a DIFFERENT string from
      # the "VAPID keys not configured" warning that other tests in this file
      # count as a delivery-attempt counter. Asserting on it here neither changes
      # nor duplicates that counter.
      assert log =~ ":vapid_keys_missing",
             "the send attempt must surface {:error, :vapid_keys_missing}, not fail silently"

      # And the neither-half branch still emits EXACTLY ONE warning for the one
      # subscription, which is the invariant those counter assertions rest on.
      assert count_occurrences(log, "VAPID keys not configured") == 1
    end

    # ── Fixtures 4 and 5: HALF configurations, one absence assertion per side ──

    # Two cases, not one: a single half-configuration test cannot prove symmetry.
    # A resolver that refused only a missing private key would pass a public-only
    # test and still advertise on the mirror configuration.

    test "HALF (public only): nothing is advertised and telemetry names the missing private half" do
      attach_half_configured_handler()
      seed_public_half_only()

      assert Push.vapid_public_key() == nil,
             "the public half resolved, but all-or-nothing means it is never advertised"

      refute Push.vapid_configured?()

      log = capture_log(fn -> assert Push.vapid_details() == nil end)
      refute log =~ @env_public_key, "no log line may carry a key value"

      trigger_send_attempt("https://push.example.com/device/half-public")

      assert_received {:vapid_half_configured, %{count: 1}, %{missing: :private_key}}
    end

    test "HALF (private only): nothing is advertised and telemetry names the missing public half" do
      attach_half_configured_handler()
      seed_private_half_only()

      # 01a01041's block asserted `Push.vapid_private_key() == "env-private-key-fixture"`
      # here — that a private-half env var alone was readable. Task 01a0108a
      # deliberately rejects that: a half configuration resolves to nothing on
      # either surface, so this is now nil even though the env var IS set.
      assert System.get_env("VAPID_PRIVATE_KEY") == @env_private_key
      assert Push.vapid_private_key() == nil
      assert Push.vapid_public_key() == nil
      refute Push.vapid_configured?()

      trigger_send_attempt("https://push.example.com/device/half-private")

      assert_received {:vapid_half_configured, %{count: 1}, %{missing: :public_key}}
    end

    # ── The agreement property ────────────────────────────────────────────────

    test "AGREEMENT: (vapid_public_key() != nil) == vapid_configured?() across all five fixtures" do
      # WHAT THIS IS, stated honestly. This asserts a STRUCTURAL INVARIANT, not
      # a behaviour: that both surfaces read one resolver. Against the current
      # implementation it is TRUE BY CONSTRUCTION and cannot fail for any input —
      # `vapid_configured?/0` is exactly `vapid_details() != nil`,
      # `vapid_public_key/0` is exactly `vapid_details()[:public_key]`, and
      # `vapid_details/0` is all-or-nothing, so the two sides of the equality are
      # the same expression read twice.
      #
      # It is kept anyway, and it is not a behaviour check. Its job is to
      # DETONATE if someone reintroduces a second, independent source of truth —
      # e.g. `vapid_configured?/0` or `do_send_push/2` reading
      # `Application.get_env(:web_push_encryption, :vapid_details)` directly
      # again. That reintroduction is precisely the defect task 01a0108a fixed,
      # and it was verified to redden this test by temporarily re-splitting the
      # two readers with only the Vault fixture seeded.
      #
      # The BEHAVIOURAL coverage lives in the five fixtures above, because those
      # seed states the resolver has to interpret. This is the regression pin on
      # the shape, not a substitute for them.
      for {name, seed} <- [
            {"env-only", &seed_env_only/0},
            {"vault-only", &seed_vault_only/0},
            {"neither", fn -> :ok end},
            {"public-half-only", &seed_public_half_only/0},
            {"private-half-only", &seed_private_half_only/0}
          ] do
        reset_vapid_inputs()
        seed.()

        assert Push.vapid_public_key() != nil == Push.vapid_configured?(),
               "the subscribe surface and the send surface disagreed on the #{name} fixture: " <>
                 "public_key present? #{Push.vapid_public_key() != nil}, " <>
                 "configured? #{Push.vapid_configured?()}"
      end
    end
  end
end
