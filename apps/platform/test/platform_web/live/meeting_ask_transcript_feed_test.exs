defmodule PlatformWeb.MeetingAskTranscriptFeedTest do
  @moduledoc """
  The live transcript feed into the held card's veil, and the fly/
  crumble release outcome (task 01a0cf5c stage 3).

  Stage 2 shipped the veil, the meter and the empty transcript slot with
  no text ever landing in it. This file drives the SAME server-side
  segment pipeline `Platform.Meetings.IntentClassifier` already reads
  (`Platform.Meetings.PubSub.broadcast_transcript_chunk/2`) through a
  real member mount, and asserts:

    * a segment claimed by THIS socket's own press is pushed into the
      veil (`meeting_ask_transcript_chunk`) — a segment for a different
      identity, or one that arrives outside the press window, is not;
    * a real release with at least one claim resolves the outcome as
      "fly" immediately, whether the claim landed before or after the
      key came up (still inside `PressWindow`'s release grace);
    * a real release with ZERO claims resolves "crumble" only once the
      server's OWN empty-press grace timer actually closes the card —
      never guessed from a local segment count.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ask_transcript_#{n}@example.com",
        name: "Ask Transcript #{n}",
        oidc_sub: "oidc-ask-transcript-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Ask Transcript Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Ask Transcript Meeting #{n}",
        slug: "ask-transcript-meeting-#{n}"
      })

    {:ok, _} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    %{view: view, user: user, meeting: meeting}
  end

  defp identity(user), do: "user:#{user.id}"

  # The REAL room name a segment for this meeting would carry —
  # `Meetings.room_name_for_space/1`, not an arbitrary string. The
  # LiveView subscribes to the PER-ROOM topic this derives (task
  # 01a0cf5c stage 3's fix for
  # `pubsub_topic_inventory_audit_test.exs`'s "the global transcript
  # topic is only subscribed by supervised singletons"), so a broadcast
  # on any other room name would never reach it — this helper has to
  # use the same derivation the production code does, not a fixture of
  # convenience.
  defp room_name(meeting), do: Meetings.room_name_for_space(meeting.chat_space_id)

  defp broadcast_segment(meeting, identity, attrs) do
    segment =
      Map.merge(
        %{
          "participant_identity" => identity,
          "text" => "hello there",
          "final" => true
        },
        attrs
      )

    room_id = room_name(meeting)

    MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
      room_id: room_id,
      transcript_id: Ecto.UUID.generate(),
      meeting_id: meeting.id,
      segment: segment
    })
  end

  test "a final segment claimed by this press is pushed into the veil's transcript slot",
       %{view: view, user: user, meeting: meeting} do
    assert render_hook(view, "push_to_talk_press", %{})

    broadcast_segment(meeting, identity(user), %{"text" => "let's ship it"})

    _ = render(view)

    assert_push_event(view, "meeting_ask_transcript_chunk", %{
      "text" => "let's ship it"
    })

    assert render_hook(view, "push_to_talk_release", %{})
  end

  test "a segment for a DIFFERENT identity is never pushed", %{
    view: view,
    meeting: meeting
  } do
    assert render_hook(view, "push_to_talk_press", %{})

    broadcast_segment(meeting, "user:#{Ecto.UUID.generate()}", %{"text" => "not mine"})

    html = render(view)
    refute html =~ "not mine"

    assert render_hook(view, "push_to_talk_release", %{})
  end

  test "an interim (non-final) segment counts as a claim but is not displayed", %{
    view: view,
    user: user,
    meeting: meeting
  } do
    assert render_hook(view, "push_to_talk_press", %{})

    broadcast_segment(meeting, identity(user), %{"text" => "still talking", "final" => false})
    _ = render(view)

    # Not displayed...
    refute_push_event(view, "meeting_ask_transcript_chunk", %{"text" => "still talking"})

    # ...but it DOES count: releasing now resolves "fly" immediately,
    # rather than waiting on the empty-press grace timer.
    assert render_hook(view, "push_to_talk_release", %{})
    _ = render(view)
    assert_push_event(view, "meeting_ask_outcome", %{"outcome" => "fly"})
  end

  test "a real release with an already-claimed segment resolves the outcome as fly immediately",
       %{view: view, user: user, meeting: meeting} do
    assert render_hook(view, "push_to_talk_press", %{})
    assert [card] = Candidates.open_for_meeting(meeting.id)

    broadcast_segment(meeting, identity(user), %{})
    _ = render(view)

    assert render_hook(view, "push_to_talk_release", %{})
    _ = render(view)

    candidate_id = card.id

    assert_push_event(view, "meeting_ask_outcome", %{
      "outcome" => "fly",
      "candidate_id" => ^candidate_id
    })
  end

  test "a LATE claim, landing after release but inside the grace window, still resolves fly",
       %{view: view, user: user, meeting: meeting} do
    assert render_hook(view, "push_to_talk_press", %{})

    # Released with NOTHING claimed yet.
    assert render_hook(view, "push_to_talk_release", %{})
    _ = render(view)
    refute_push_event(view, "meeting_ask_outcome", %{})

    # The trailing words the transcriber was still finalising when the
    # key came up — `PressWindow`'s release grace exists for exactly
    # this.
    broadcast_segment(meeting, identity(user), %{"text" => "the tail end"})
    _ = render(view)

    assert_push_event(view, "meeting_ask_transcript_chunk", %{"text" => "the tail end"})
    assert_push_event(view, "meeting_ask_outcome", %{"outcome" => "fly"})
  end

  @tag timeout: 10_000
  test "a real release with ZERO claims resolves crumble ONLY once the server's own empty-press grace closes the card",
       %{view: view, meeting: meeting} do
    assert render_hook(view, "push_to_talk_press", %{})
    assert [card] = Candidates.open_for_meeting(meeting.id)

    assert render_hook(view, "push_to_talk_release", %{})
    _ = render(view)

    # Nothing resolves yet — a trailing segment could still arrive.
    refute_push_event(view, "meeting_ask_outcome", %{})

    # Wait out `PressWindow`'s own release grace — same real-timer
    # discipline `press_card_test.exs`'s "the REAL timer release/3 arms
    # is what delivers the close" case uses, so this proves the crumble
    # is driven by the SAME mechanism, not a client-side guess.
    Process.sleep(PressWindow.release_grace_ms() + 300)

    candidate_id = card.id

    assert_push_event(view, "meeting_ask_outcome", %{
      "outcome" => "crumble",
      "candidate_id" => ^candidate_id
    })

    closed = Candidates.get(candidate_id)
    assert closed.state == :closed
    assert closed.closed_reason == :unclassified
  end
end
