defmodule Platform.Security.ExternalPushPreviewTest do
  @moduledoc """
  M15 security suite — Stage 6 (S6), push half: external-safe push preview (M13).

  Every notification field is scrubbed of internal content before it reaches an
  external recipient, at a single chokepoint (`Push.preview_for_recipient/2`) —
  the builders are never edited. Fed the two real builder-shaped payloads:

    * CHAT shape → an external chat_participant gets the generic safe preview
      (`New message` / `You have a new message` / `/chat`); NONE of the sender
      name, body, or internal text survives, and `[:platform, :push,
      :external_safe_preview]` fires once. An internal participant's payload is
      BYTE-IDENTICAL with no telemetry.
    * MEETING shape → the external recipient loses the meeting name AND the slug
      (url rewritten to `/chat`). Internal unchanged.
    * An agent participant → pass-through unchanged (no external redaction).
    * An archived external participant → `Push.send_notification/2` short-circuits
      on the pre-existing archived guard (no preview swap).

  A single adversarial helper scans the external output's VALUES and fails if any
  seeded internal string is present.

  Binds to M13 shipped: `Push.preview_for_recipient/2`, `external_safe_preview/1`,
  `send_notification/2`, `Tenancy.external_user?/1`.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Push
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  @chat_payload %{
    title: "Rowan Ellis in Suite",
    body: "internal roadmap: shipping the Acme deal Friday",
    url: "/chat"
  }

  @meeting_payload %{
    title: "Alex Kim started a meeting",
    body: "Q3 Board Prep",
    url: "/meetings/q3-board-prep"
  }

  # ── Recipient fixtures ─────────────────────────────────────────────────

  defp external_participant do
    user = World.create_user!(%{name: "Xavier External"})

    {:ok, _} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.fabrikam_org_id()})

    space = World.channel!()
    {p, _} = user_participant(space.id, user)
    p
  end

  defp internal_participant do
    user = World.create_user!(%{name: "Ian Internal"})
    World.plain_member!(user, Tenancy.get_org_by_slug!("fabrikam"))
    space = World.channel!()
    {p, _} = user_participant(space.id, user)
    p
  end

  defp archived_external_participant do
    user = World.create_user!(%{name: "Zoe Archived"})

    {:ok, _} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.fabrikam_org_id()})

    space = World.channel!()
    {p, _} = user_participant(space.id, user)
    {:ok, _} = Accounts.archive_user(user)
    p
  end

  defp agent_participant do
    space = World.channel!()
    World.add_agent!(space.id, Ecto.UUID.generate())
  end

  defp user_participant(space_id, user) do
    {:ok, p} =
      Platform.Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {p, user}
  end

  # Adversarial no-leak invariant: fail if ANY seeded internal string appears in
  # ANY value of the external recipient's resolved payload.
  defp refute_leak(payload, secrets) do
    haystack = payload |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(" ")

    Enum.each(secrets, fn secret ->
      refute haystack =~ secret, "external preview leaked #{inspect(secret)}: #{inspect(payload)}"
    end)
  end

  # ── Chat shape ─────────────────────────────────────────────────────────

  describe "chat payload" do
    test "external recipient gets the generic preview; internal is unchanged; telemetry fires once" do
      ext = external_participant()
      int = internal_participant()

      ref = attach([:platform, :push, :external_safe_preview], :safe_preview)

      resolved_ext = Push.preview_for_recipient(ext.id, @chat_payload)

      assert resolved_ext == %{title: "New message", body: "You have a new message", url: "/chat"}
      refute_leak(resolved_ext, ["Rowan Ellis", "internal roadmap", "Acme"])

      assert_receive {:safe_preview, %{count: 1}, %{participant_id: pid}}
      assert pid == ext.id

      # Mailbox is now clear of the external emit; the internal call must emit
      # nothing.
      resolved_int = Push.preview_for_recipient(int.id, @chat_payload)
      assert resolved_int == @chat_payload
      refute_receive {:safe_preview, _, _}, 50

      detach(ref)
    end
  end

  # ── Meeting shape ──────────────────────────────────────────────────────

  describe "meeting payload" do
    test "external recipient loses the meeting name and the internal slug" do
      ext = external_participant()

      resolved = Push.preview_for_recipient(ext.id, @meeting_payload)

      assert resolved == %{title: "New message", body: "You have a new message", url: "/chat"}
      assert resolved.url == "/chat"
      refute_leak(resolved, ["Alex Kim", "Q3 Board Prep", "q3-board-prep"])
    end

    test "internal recipient's meeting payload is unchanged" do
      int = internal_participant()
      resolved = Push.preview_for_recipient(int.id, @meeting_payload)
      assert resolved == @meeting_payload
      assert resolved.url == "/meetings/q3-board-prep"
    end
  end

  # ── Agent pass-through ─────────────────────────────────────────────────

  describe "agent participant" do
    test "pass-through unchanged (not redacted as external)" do
      agent = agent_participant()
      resolved = Push.preview_for_recipient(agent.id, @chat_payload)
      assert resolved == @chat_payload
    end
  end

  # ── Archived external: send_notification short-circuits ────────────────

  describe "archived external participant" do
    test "send_notification short-circuits on the archived guard — no preview swap" do
      archived = archived_external_participant()

      suppressed = attach([:platform, :push, :suppressed_archived_user], :suppressed)
      safe = attach([:platform, :push, :external_safe_preview], :safe_preview)

      assert :ok = Push.send_notification(archived.id, @chat_payload)

      assert_receive {:suppressed, _measurements, %{participant_id: pid}}
      assert pid == archived.id
      # The archived guard fires BEFORE the preview chokepoint — no swap emitted.
      refute_receive {:safe_preview, _, _}, 50

      detach(suppressed)
      detach(safe)
    end
  end

  # ── Telemetry plumbing ─────────────────────────────────────────────────

  defp attach(event, tag) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "m15-s6-push-#{inspect(ref)}",
      event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {tag, measurements, metadata})
      end,
      nil
    )

    ref
  end

  defp detach(ref), do: :telemetry.detach("m15-s6-push-#{inspect(ref)}")
end
