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
    * USER-SCOPED path (task 019ffd19) → chat push now resolves a recipient's
      devices across every conversation they belong to, which moved the router
      onto `Push.send_to_user/2` and its `preview_for_user/2` chokepoint. Same
      three safe strings, same telemetry, and a device registered in another
      conversation is reached only with the redacted copy.

  A single adversarial helper scans the external output's VALUES and fails if any
  seeded internal string is present.

  Binds to M13 shipped: `Push.preview_for_recipient/2`, `external_safe_preview/1`,
  `send_notification/2`, `Tenancy.external_user?/1`.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

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
    user = external_user!("Xavier External")
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

  defp external_user!(name) do
    user = World.create_user!(%{name: name})

    {:ok, _} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.fabrikam_org_id()})

    user
  end

  defp subscribe_endpoint!(participant_id, endpoint) do
    n = System.unique_integer([:positive])

    {:ok, sub} =
      Push.subscribe(participant_id, %{
        endpoint: endpoint,
        keys: %{p256dh: "p256dh-#{n}", auth: "auth-#{n}"}
      })

    sub
  end

  # With VAPID unconfigured (the test default) each attempted delivery logs
  # exactly one "VAPID keys not configured" line, so counting the line counts
  # the devices actually reached.
  defp delivery_attempts(log),
    do: log |> String.split("VAPID keys not configured") |> length() |> Kernel.-(1)

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

  # ── User-scoped push path (task 019ffd19) ──────────────────────────────

  # Resolving a recipient's devices across every conversation they belong to
  # moved the chat push path onto `Push.send_to_user/2`, whose redaction
  # chokepoint is `preview_for_user/2` rather than `preview_for_recipient/2`.
  # The control has to hold on the new path with the same strings, or the fix
  # for the missed-notification bug becomes a leak.
  describe "user-scoped path (task 019ffd19)" do
    test "external recipient gets the generic preview; channel name is redacted too" do
      channel_name = "Acme Launch War Room"
      user = external_user!("Xavier External")
      space = World.channel!(%{name: channel_name})
      {_p, _} = user_participant(space.id, user)

      payload = %{
        title: "Rowan Ellis in #{channel_name}",
        body: "internal roadmap: shipping the Acme deal Friday",
        url: "/chat"
      }

      ref = attach([:platform, :push, :external_safe_preview], :safe_preview)

      resolved = Push.preview_for_user(user.id, payload)

      assert resolved == %{title: "New message", body: "You have a new message", url: "/chat"}
      refute_leak(resolved, ["Rowan Ellis", "internal roadmap", "Acme", channel_name])

      assert_receive {:safe_preview, %{count: 1}, %{user_id: uid}}
      assert uid == user.id

      detach(ref)
    end

    test "internal recipient's payload is byte-identical on the user-scoped path" do
      user = World.create_user!(%{name: "Ian Internal"})
      World.plain_member!(user, Tenancy.get_org_by_slug!("fabrikam"))

      ref = attach([:platform, :push, :external_safe_preview], :safe_preview)

      # Positive control: the redaction is external-scoped, so a green external
      # assertion above cannot be an unconditional swap.
      assert Push.preview_for_user(user.id, @chat_payload) == @chat_payload
      refute_receive {:safe_preview, _, _}, 50

      detach(ref)
    end

    test "a device registered in another conversation is reached, and still only redacted" do
      user = external_user!("Yara External")

      # Two conversations, so two chat_participants rows. The device was
      # registered in B; the message arrives in A. Before task 019ffd19 that
      # device resolved nothing, so the redaction never even got a chance to
      # run for it.
      {participant_a, _} = user_participant(World.channel!().id, user)
      {participant_b, _} = user_participant(World.channel!().id, user)
      subscribe_endpoint!(participant_b.id, "https://push.example.com/device/ext-laptop")

      ref = attach([:platform, :push, :external_safe_preview], :safe_preview)

      log =
        capture_log(fn ->
          assert :ok = Push.send_notification(participant_a.id, @chat_payload)
        end)

      assert delivery_attempts(log) == 1,
             "the conversation-B device must now be reached from conversation A; log: #{log}"

      # Reached, and redacted on the way: the widened device resolution does not
      # route around the external chokepoint.
      assert_receive {:safe_preview, %{count: 1}, %{participant_id: pid}}
      assert pid == participant_a.id

      detach(ref)
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
