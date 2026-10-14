defmodule Platform.PushExternalPreviewTest do
  # async: false — the external-safe-preview guard reads org_memberships and the
  # supervised AttentionRouter shares the sandbox connection; keep serial to
  # match push_test.exs and avoid handler-id races on shared telemetry.
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Push
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp insert_user(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Test",
        slug: "test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

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

  # An external recipient's chat_participants row.
  defp external_participant do
    user = insert_user("Xavier External")

    {:ok, _} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.acme_org_id()})

    add_user_participant(create_space().id, user)
  end

  # A plain internal member recipient's chat_participants row.
  defp internal_participant do
    user = insert_user("Ian Internal")

    {:ok, _} =
      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: user.id,
        org_id: TenancyFixtures.acme_org_id(),
        role: "member"
      })
      |> Repo.insert()

    add_user_participant(create_space().id, user)
  end

  # Adversarial no-leak invariant: fail if ANY seeded internal string appears
  # in ANY value of the external recipient's resolved payload.
  defp refute_leak(payload, secrets) do
    haystack = payload |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(" ")

    Enum.each(secrets, fn secret ->
      refute haystack =~ secret,
             "external preview leaked #{inspect(secret)}: #{inspect(payload)}"
    end)
  end

  # ── Chat builder shape (AttentionRouter.maybe_send_push/4) ───────────────────

  describe "chat push builder shape" do
    @chat_payload %{
      title: "Rowan Ellis in Suite",
      body: "internal roadmap: shipping the Acme deal Friday",
      url: "/chat"
    }

    test "external recipient gets the generic preview with nothing internal leaked" do
      resolved = Push.preview_for_recipient(external_participant().id, @chat_payload)

      assert resolved == %{
               title: "New message",
               body: "You have a new message",
               url: "/chat"
             }

      refute_leak(resolved, ["Rowan Ellis", "internal roadmap", "Acme"])
    end

    test "internal recipient's payload is byte-identical (sender name + text intact)" do
      resolved = Push.preview_for_recipient(internal_participant().id, @chat_payload)
      assert resolved == @chat_payload
      assert resolved.title =~ "Rowan Ellis"
      assert resolved.body =~ "internal roadmap"
    end
  end

  # ── Meeting builder shape (MeetingNotifier.fan_out/1) ────────────────────────

  describe "meeting push builder shape" do
    @meeting_payload %{
      title: "Alex Kim started a meeting",
      body: "Q3 Board Prep",
      url: "/meetings/q3-board-prep"
    }

    test "external recipient loses meeting name and internal slug (url -> /chat)" do
      resolved = Push.preview_for_recipient(external_participant().id, @meeting_payload)

      assert resolved == %{
               title: "New message",
               body: "You have a new message",
               url: "/chat"
             }

      assert resolved.url == "/chat"
      refute_leak(resolved, ["Alex Kim", "Q3 Board Prep", "q3-board-prep"])
    end

    test "internal recipient's meeting payload is unchanged (single chokepoint, no builder edit)" do
      resolved = Push.preview_for_recipient(internal_participant().id, @meeting_payload)
      assert resolved == @meeting_payload
      assert resolved.url == "/meetings/q3-board-prep"
    end
  end
end
