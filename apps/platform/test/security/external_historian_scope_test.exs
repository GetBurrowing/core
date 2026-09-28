defmodule Platform.Security.ExternalHistorianScopeTest do
  @moduledoc """
  M15 security suite — Stage 6 (S6), historian half: both-direction digest
  exclusion (M12).

  Neither digest direction leaks the other's content. Given an internal-only
  channel, a fully-external space, and a MIXED (Fabrikam + external) space — each
  with in-window messages and a completed transcript:

    * `Chat.external_space_ids/0` classifies the external AND mixed spaces
      external, and NOT the internal-only one;
    * `ActivityDigest.build/2` (default `:internal`) OMITS external + mixed
      content; `ActivityDigest.build_external/3` INCLUDES them and OMITS the
      internal one — neither direction leaks;
    * `Chat.list_messages_since/2` and `Meetings.list_transcripts_since/2`
      partition identically on `:scope`;
    * `Historian.pending_windows_input/1` byte tuples EXCLUDE external-space
      bytes (byte-sizing agrees with digest selection);
    * ZERO-EXTERNAL REGRESSION — with no external memberships, everything is
      byte-identical to the all-internal baseline (`NOT IN ^[]` is a no-op).

  Binds to M12 shipped: `Chat.external_space_ids/0`,
  `participant_space_ids_for_user/1`, `list_messages_since/2` `:scope`,
  `Meetings.list_transcripts_since/2` `:scope`, `Historian.pending_windows_input/1`,
  `ActivityDigest.build/2` + `build_external/3`.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.ActivityDigest
  alias Platform.Agents.Historian
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600, :second), DateTime.add(now, 3600, :second)}
  end

  defp external_user! do
    user = World.create_user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.tenant_org_id("sxi")
      })

    user
  end

  defp post_msg!(space_id, participant_id, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: "T"
    })
    |> Repo.insert!()
  end

  defp transcript!(space_id, summary) do
    now = DateTime.utc_now()

    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "room-#{System.unique_integer([:positive])}",
      space_id: space_id,
      status: "complete",
      started_at: DateTime.add(now, -600, :second),
      completed_at: now,
      summary: summary
    })
    |> Repo.insert!()
  end

  # Internal-only #fabrikam-eng, fully-external #sxi-support, mixed #sxi-shared.
  defp seed_three_spaces do
    fabrikam = World.create_user!()
    ext = external_user!()

    internal = World.channel!(%{name: "fabrikam-eng-m15"})
    kp = World.add_user!(internal.id, fabrikam.id)
    post_msg!(internal.id, kp.id, "engmsg-internal-secret")
    transcript!(internal.id, "eng-transcript-internal")

    external = World.channel!(%{name: "sxi-support-m15"})
    ep = World.add_user!(external.id, ext.id)
    post_msg!(external.id, ep.id, "supportmsg-external-secret")
    transcript!(external.id, "support-transcript-external")

    mixed = World.channel!(%{name: "sxi-shared-m15"})
    mk = World.add_user!(mixed.id, fabrikam.id)
    _me = World.add_user!(mixed.id, ext.id)
    post_msg!(mixed.id, mk.id, "sharedmsg-mixed-secret")
    transcript!(mixed.id, "shared-transcript-mixed")

    %{internal: internal, external: external, mixed: mixed, ext: ext}
  end

  # ── Classification ─────────────────────────────────────────────────────

  describe "external_space_ids/0 classification" do
    test "includes fully-external + mixed, excludes internal-only" do
      s = seed_three_spaces()
      ids = Chat.external_space_ids()

      assert s.external.id in ids
      assert s.mixed.id in ids
      refute s.internal.id in ids
    end
  end

  # ── ActivityDigest both directions ─────────────────────────────────────

  describe "ActivityDigest both-direction exclusion" do
    test "internal digest omits external + mixed; external digest includes them and omits internal" do
      s = seed_three_spaces()
      {ws, we} = window()

      internal_digest = ActivityDigest.build(ws, we)
      assert internal_digest =~ "engmsg-internal-secret"
      refute internal_digest =~ "supportmsg-external-secret"
      refute internal_digest =~ "sharedmsg-mixed-secret"

      external_digest = ActivityDigest.build_external(s.ext.id, ws, we)
      assert external_digest =~ "supportmsg-external-secret"
      assert external_digest =~ "sharedmsg-mixed-secret"
      refute external_digest =~ "engmsg-internal-secret"
    end
  end

  # ── list_messages_since / list_transcripts_since :scope ────────────────

  describe "list_messages_since / list_transcripts_since :scope partition" do
    test "messages: default :internal excludes external+mixed; external scope restricts to them" do
      s = seed_three_spaces()
      {ws, we} = window()

      internal_contents =
        Chat.list_messages_since(ws, window_end: we) |> Enum.map(& &1.content)

      assert "engmsg-internal-secret" in internal_contents
      refute "supportmsg-external-secret" in internal_contents
      refute "sharedmsg-mixed-secret" in internal_contents

      ext_space_ids = Chat.participant_space_ids_for_user(s.ext.id)

      external_contents =
        Chat.list_messages_since(ws, window_end: we, scope: {:external_spaces, ext_space_ids})
        |> Enum.map(& &1.content)

      assert "supportmsg-external-secret" in external_contents
      assert "sharedmsg-mixed-secret" in external_contents
      refute "engmsg-internal-secret" in external_contents
    end

    test "transcripts: :scope partitions identically" do
      s = seed_three_spaces()
      {ws, we} = window()

      # Task 01a0a12e: the transcripts corpus is excluded from the digest by
      # default, in BOTH partitions. The partition itself is pinned below with
      # `meeting_transcripts: :included` passed explicitly.
      assert Meetings.list_transcripts_since(ws, window_end: we) == []

      assert Meetings.list_transcripts_since(ws,
               window_end: we,
               scope: {:external_spaces, Chat.participant_space_ids_for_user(s.ext.id)}
             ) == []

      internal_summaries =
        Meetings.list_transcripts_since(ws, window_end: we, meeting_transcripts: :included)
        |> Enum.map(& &1.summary)

      assert "eng-transcript-internal" in internal_summaries
      refute "support-transcript-external" in internal_summaries
      refute "shared-transcript-mixed" in internal_summaries

      ext_space_ids = Chat.participant_space_ids_for_user(s.ext.id)

      external_summaries =
        Meetings.list_transcripts_since(ws,
          window_end: we,
          scope: {:external_spaces, ext_space_ids},
          meeting_transcripts: :included
        )
        |> Enum.map(& &1.summary)

      assert "support-transcript-external" in external_summaries
      refute "eng-transcript-internal" in external_summaries
    end
  end

  # ── Historian byte-sizing excludes external content ────────────────────

  describe "Historian.pending_windows_input/1 byte exclusion" do
    test "message + transcript bytes exclude external-space content" do
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      internal = World.channel!(%{name: "fabrikam-eng-bytes"})
      fabrikam = World.create_user!()
      kp = World.add_user!(internal.id, fabrikam.id)
      im = post_msg!(internal.id, kp.id, "internal-hist-msg")
      backdate_message(im, one_hour_ago)
      transcript!(internal.id, "internal-hist-mtg")

      external = World.channel!(%{name: "sxi-support-bytes"})
      ext = external_user!()
      ep = World.add_user!(external.id, ext.id)
      em = post_msg!(external.id, ep.id, String.duplicate("E", 200))
      backdate_message(em, one_hour_ago)
      transcript!(external.id, String.duplicate("X", 200))

      input = Historian.pending_windows_input(nil)

      {_, mbytes} = input.messages
      # Only the internal message content is counted; the 200-byte external one
      # is excluded.
      assert mbytes == byte_size("internal-hist-msg")

      # Task 01a0a12e: transcripts are excluded from the digest by default, so
      # neither the internal nor the external transcript contributes bytes.
      # `pending_windows_input/1` takes no opts, so the scope arithmetic on
      # this corpus is pinned at the seam instead
      # (`list_transcripts_since(..., meeting_transcripts: :included)` above).
      {_, tbytes} = input.transcripts
      assert tbytes == 0
    end
  end

  # ── Zero-external regression (NOT IN ^[] is a no-op) ────────────────────

  describe "zero-external regression" do
    test "with no external memberships, classification is [] and internal content survives" do
      internal = World.channel!(%{name: "fabrikam-only-m15"})
      fabrikam = World.create_user!()
      kp = World.add_user!(internal.id, fabrikam.id)
      post_msg!(internal.id, kp.id, "solo-internal-secret")
      transcript!(internal.id, "solo-transcript")

      assert Chat.external_space_ids() == []

      {ws, we} = window()
      digest = ActivityDigest.build(ws, we)
      assert digest =~ "solo-internal-secret"

      contents = Chat.list_messages_since(ws, window_end: we) |> Enum.map(& &1.content)
      assert "solo-internal-secret" in contents
    end
  end

  defp backdate_message(message, %DateTime{} = ts) do
    {1, _} =
      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: ts]
      )

    :ok
  end
end
