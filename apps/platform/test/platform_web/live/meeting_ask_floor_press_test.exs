defmodule PlatformWeb.MeetingAskFloorPressTest do
  @moduledoc """
  Two people holding the SAME agent's push-to-talk button, end to end
  (task 01a0cf5c stage 1).

  `meeting_push_to_talk_press_test.exs` proves a press opens a card
  through the real member mount, but every press in that file is the
  only presser in the meeting. Nothing there exercised the gap the
  design-direction canvas (Saru, 01a0cf5e-9cb0) calls out: `PressWindow`
  keys on the PRESSER's identity, so two DIFFERENT people holding the
  SAME agent's row each open their own window and their own card, with
  no signal to either that the other got there first.

  This file drives TWO real member mounts — two different users, two
  different sockets — into the same meeting and presses the same
  agent's row from both, asserting the second is refused before a
  window or a card exists for it, and that the FIRST viewer's own
  socket is told who now holds the floor.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    alice =
      Repo.insert!(%User{
        email: "ask_floor_alice_#{n}@example.com",
        name: "Alice #{n}",
        oidc_sub: "oidc-ask-floor-alice-#{n}"
      })

    bob =
      Repo.insert!(%User{
        email: "ask_floor_bob_#{n}@example.com",
        name: "Bob #{n}",
        oidc_sub: "oidc-ask-floor-bob-#{n}"
      })

    for user <- [alice, bob] do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member"
      })
      |> Repo.insert!()
    end

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Ask Floor Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Ask Floor Meeting #{n}",
        slug: "ask-floor-meeting-#{n}"
      })

    for user <- [alice, bob] do
      {:ok, _} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "askfloor-agent-#{n}",
        name: "Askfloor Agent #{n}",
        status: "active"
      })
      |> Repo.insert!()

    # An ACTIVE room, created up front (rather than through the normal
    # `MeetingHooks.join()`/LiveKit path, skipped below by
    # `no_autojoin=true`) so both mounts subscribe to a real room topic
    # and the cross-client `:ask_floor_taken` / `:ask_floor_released`
    # broadcasts this stage adds have somewhere to land.
    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)

    # The rail sources from LIVE meeting presence
    # (`Meetings.active_participants_for_space/1`), not durable chat
    # membership (`meeting_push_to_talk_control_test.exs` measured this
    # first) — so the agent has to be a `Meetings.Participant` in the
    # active room for its row, and its hold control, to render at all.
    {:ok, _} = Meetings.participant_joined(room, %{agent_id: agent.id, display_name: agent.name})

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
      AskFloor.clear_meeting(meeting.id)
    end)

    alice_conn = init_test_session(conn, current_user_id: alice.id)
    bob_conn = init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: bob.id)

    {:ok, alice_view, _html} =
      live(alice_conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    {:ok, bob_view, _html} =
      live(bob_conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    %{
      alice_view: alice_view,
      bob_view: bob_view,
      alice: alice,
      bob: bob,
      meeting: meeting,
      agent: agent
    }
  end

  test "a second presser on the SAME agent is refused, and the first viewer keeps the card",
       %{alice_view: alice_view, bob_view: bob_view, meeting: meeting, agent: agent, bob: bob} do
    assert Candidates.open_for_meeting(meeting.id) == []

    # Alice holds the agent's row first.
    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent.id})

    assert [card] = Candidates.open_for_meeting(meeting.id)
    assert card.assigned_agent_id == agent.id

    # Bob presses the SAME agent's row a moment later. Refused before any
    # window or card exists for it — the server never reaches
    # `PressCard.open/3` for this press.
    assert render_hook(bob_view, "push_to_talk_press", %{"agent_id" => agent.id})

    agent_id = agent.id

    assert_push_event(bob_view, "push_to_talk_rejected", %{
      "agent_id" => ^agent_id,
      "reason" => "held-by-other"
    })

    # Still exactly ONE open card for the agent — Bob's refused press
    # never opened a second one.
    assert [^card] = Candidates.open_for_meeting(meeting.id)

    # And no press window was ever opened in Bob's name.
    assert PressWindow.get(meeting.id, "user:#{bob.id}") == nil
  end

  test "the floor is broadcast to every connected client, and releases when the holder lets go",
       %{alice_view: alice_view, bob_view: bob_view, meeting: meeting, agent: agent} do
    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent.id})

    # Bob's OWN rail — a different socket, never told anything by Alice
    # directly — renders the agent's row as held, from the room-topic
    # broadcast `claim_ask_floor/4` fires.
    bob_html = render(bob_view)
    assert bob_html =~ "Held by"

    assert render_hook(alice_view, "push_to_talk_release", %{})

    bob_html_after = render(bob_view)
    refute bob_html_after =~ "Held by"

    # And now Bob CAN take it. Alice's own earlier card is still open —
    # `push_to_talk_release` only starts `PressWindow`'s grace timer, it
    # does not synchronously close anything (`meeting_push_to_talk_press_
    # test.exs` measures the same "release ≠ instant close" shape) — so
    # this asserts Bob's press succeeded and opened its OWN card, not
    # that Alice's disappeared.
    before_press = Candidates.open_for_meeting(meeting.id)
    assert render_hook(bob_view, "push_to_talk_press", %{"agent_id" => agent.id})
    after_press = Candidates.open_for_meeting(meeting.id)

    assert [bob_card] = after_press -- before_press
    assert bob_card.assigned_agent_id == agent.id
  end

  test "an UNTARGETED press never touches AskFloor and is unaffected by another agent's hold",
       %{alice_view: alice_view, bob_view: bob_view, meeting: meeting, agent: agent} do
    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent.id})

    # Bob's untargeted press (no agent_id) has no floor to claim, and is
    # not refused because of Alice's unrelated per-agent hold.
    assert render_hook(bob_view, "push_to_talk_press", %{})

    assert [_alice_card, _bob_card] = Candidates.open_for_meeting(meeting.id)
  end

  test "the floor is released on EVERY release path — real hold or early release alike (task 01a0cf5c stage 3)",
       %{alice_view: alice_view, bob_view: bob_view, meeting: meeting, agent: agent} do
    # The server has no notion of "early" vs. "real" hold at all — that
    # split is 380ms of purely client-side timing
    # (`meeting_push_to_talk.js`'s `HOLD_THRESHOLD_MS`) that never
    # reaches `push_to_talk_release`'s payload. So there is only ONE
    # release path on the server, and this asserts it frees the floor
    # immediately — well BEFORE `PressWindow`'s own empty-press grace
    # (3s) would otherwise close the underlying card. A viewer must
    # never be shown "Held by Alice" for a floor Alice already let go
    # of, no matter how briefly she held it or whether anything was
    # ever said.
    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent.id})
    assert render(bob_view) =~ "Held by"

    assert render_hook(alice_view, "push_to_talk_release", %{})

    # Released INSTANTLY — no sleep, no waiting on any grace timer.
    refute render(bob_view) =~ "Held by"
    assert AskFloor.holder(meeting.id, agent.id) == :none

    # And Bob can now claim it straight away.
    assert render_hook(bob_view, "push_to_talk_press", %{"agent_id" => agent.id})
    assert {:ok, %{identity: bob_identity}} = AskFloor.holder(meeting.id, agent.id)
    assert bob_identity =~ "user:"

    assert render_hook(bob_view, "push_to_talk_release", %{})
  end

  test "a dropped socket releases the floor immediately, not after the stuck-claim backstop (task 01a0cf5c stage 3)",
       %{alice_view: alice_view, bob_view: bob_view, meeting: meeting, agent: agent} do
    # Alice holds, then her tab closes (or the browser crashes) with no
    # `push_to_talk_release` ever reaching the server — `GenServer.stop/1`
    # is synchronous and, like any other normal LiveView shutdown, runs
    # `terminate/2` before returning, exactly like a real disconnect
    # would. Bob's button must un-freeze from THIS, not from
    # `AskFloor.stuck_claim_ms/0` (two minutes) eventually evicting a
    # claim nobody is defending any more.
    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent.id})
    assert render(bob_view) =~ "Held by"

    :ok = GenServer.stop(alice_view.pid)

    assert AskFloor.holder(meeting.id, agent.id) == :none
    refute render(bob_view) =~ "Held by"

    # Bob can claim it right away — no backstop timer stands in the way.
    assert render_hook(bob_view, "push_to_talk_press", %{"agent_id" => agent.id})
    assert {:ok, %{identity: bob_identity}} = AskFloor.holder(meeting.id, agent.id)
    assert bob_identity =~ "user:"

    assert render_hook(bob_view, "push_to_talk_release", %{})
  end

  test "held-to-released happy path: veil is open with the floor claimed, live transcript " <>
         "text arrives, and release flies the card while freeing the floor (task 01a0cf5c " <>
         "stage 3, e2e case 01a0cf65-0352-7001)",
       %{alice_view: alice_view, meeting: meeting, agent: agent} do
    agent_id = agent.id

    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
    assert [card] = Candidates.open_for_meeting(meeting.id)
    candidate_id = card.id

    # While held: the veil scaffold is mounted (its `data-open` toggle is
    # pure client-side JS state — see `meeting_ask_floor_veil.js` — so
    # this LiveView-level check is for the node existing at all, not for
    # `data-open`), and AskFloor names this press as the holder.
    assert has_element?(alice_view, "[data-role='meeting-ask-veil']")
    assert {:ok, %{identity: held_identity}} = AskFloor.holder(meeting.id, agent_id)
    assert held_identity =~ "user:"

    room_id = Meetings.room_name_for_space(meeting.chat_space_id)

    # Two segments arrive for THIS press while it is still held — well
    # past `PressWindow.release_grace_ms/0` worth of "meeting time" in
    # spirit, per the e2e case's own actions ("wait past release_grace_ms
    # while segments arrive") — the grace window matters at RELEASE, not
    # while still held, so this simply drives two chunks through the
    # real pipeline before releasing.
    MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
      room_id: room_id,
      transcript_id: Ecto.UUID.generate(),
      meeting_id: meeting.id,
      segment: %{
        "participant_identity" => held_identity,
        "text" => "here's the first part",
        "final" => true
      }
    })

    _ = render(alice_view)

    assert_push_event(alice_view, "meeting_ask_transcript_chunk", %{
      "text" => "here's the first part"
    })

    MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
      room_id: room_id,
      transcript_id: Ecto.UUID.generate(),
      meeting_id: meeting.id,
      segment: %{
        "participant_identity" => held_identity,
        "text" => "and the second",
        "final" => true
      }
    })

    _ = render(alice_view)
    assert_push_event(alice_view, "meeting_ask_transcript_chunk", %{"text" => "and the second"})

    assert render_hook(alice_view, "push_to_talk_release", %{})
    _ = render(alice_view)

    # Released: fly, not crumble — at least one segment was claimed.
    assert_push_event(alice_view, "meeting_ask_outcome", %{
      "outcome" => "fly",
      "candidate_id" => ^candidate_id
    })

    # The card is NOT crumbled — it stayed a real, open candidate right
    # up to the moment it flew, and the release freed the floor for the
    # next presser.
    assert [^card] = Candidates.open_for_meeting(meeting.id)
    assert AskFloor.holder(meeting.id, agent_id) == :none
  end

  @tag timeout: 10_000
  test "a quick release with nothing claimed frees the floor immediately and crumbles the " <>
         "card once the server's own empty-press grace confirms it (task 01a0cf5c stage 3, " <>
         "e2e case 01a0cf65-0352-7002)",
       %{alice_view: alice_view, meeting: meeting, agent: agent} do
    agent_id = agent.id

    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
    assert [card] = Candidates.open_for_meeting(meeting.id)
    candidate_id = card.id

    # The server has no notion of "early" vs. "real" hold (that split is
    # purely client-side JS timing — see the moduledoc on
    # `push_to_talk_release` in `meeting_live.ex`), so a quick release is
    # simply a release with nothing claimed yet.
    assert render_hook(alice_view, "push_to_talk_release", %{})

    # The floor frees INSTANTLY — no wait on any grace timer. A second
    # presser must be able to claim this agent right away.
    assert AskFloor.holder(meeting.id, agent_id) == :none

    _ = render(alice_view)
    refute_push_event(alice_view, "meeting_ask_outcome", %{})

    # The card itself is NOT torn down yet — a trailing segment could
    # still land inside `PressWindow.release_grace_ms/0`. Only once that
    # grace elapses with nothing claimed does the server's own
    # empty-press path close it (`reason: :unclassified`), and only THEN
    # does the veil crumble off that same signal.
    Process.sleep(PressWindow.release_grace_ms() + 300)

    assert_push_event(alice_view, "meeting_ask_outcome", %{
      "outcome" => "crumble",
      "candidate_id" => ^candidate_id
    })

    closed = Candidates.get(candidate_id)
    assert closed.state == :closed
    assert closed.closed_reason == :unclassified
    assert Candidates.open_for_meeting(meeting.id) == []
  end
end
