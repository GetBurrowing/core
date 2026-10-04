defmodule PlatformWeb.MeetingAskFloorVoiceCardLinkTest do
  @moduledoc """
  Task 01a0e47c stage 3 — the verify-and-close-gaps stage.

  Stage 2 built the missing coupling: `AskFloor.claim/5`/`release/3` now
  signal the dedicated Burrow voice worker's LiveKit room over
  a data channel. This file proves what stage 2 did NOT need to touch
  and stage 3 is on the hook to confirm: the FRONT of the hold-to-ask
  pipe (the ask-veil, the live transcript feed, the resulting
  `CandidateRail` card) already treats a voice-dispatched agent
  IDENTICALLY to any text-only one, because none of it keys on the
  agent's kind at all —

    * `AskFloor.claim/5`/`release/3` are agent-id-agnostic (see that
      module's moduledoc).
    * The live transcript feed (`meeting_live.ex`'s
      `claim_ask_transcript_segment/2`) is keyed on the PRESSER's own
      identity via `PressWindow`, fed by the room's own STT pipeline
      (`PlatformWeb.MeetingAgentController` /
      `LiveKitWebhookController` -> `Meetings.append_segment/2`) — never
      by the target agent's runtime. A voice session's HEARD box shows
      real STT text for the same reason a text agent's does: it is the
      SAME broadcast, matched the SAME way.
    * `CandidateRail` renders off `Platform.Meetings.MeetingCandidate`
      rows, which `PressCard.open/3` writes the same way regardless of
      which kind of agent was addressed.

  So this test drives the real press -> transcript -> release -> fly
  sequence against a LiveKit-dispatched voice agent (the same shape
  `meeting_ask_floor_voice_gate_test.exs` uses for the backend gate) and
  asserts it reads exactly like `meeting_ask_floor_press_test.exs`'s
  text-agent happy path, THEN drives the landed candidate through
  `:shaping` -> `:acting` and asserts the rail's new
  `meeting-candidate-step` node (`CandidateRail.live_card/1`,
  `CandidateDisplay.stage_label/1`) shows the ladder rung advancing on
  the SAME `data-candidate-id` the veil's `meeting_ask_outcome` named —
  the "connection to the cards" gap this stage closes.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  @livekit_agent_name "meeting-voice-agent"

  defp user!(tag) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "voice_card_link_#{tag}_#{n}@example.com",
        name: "#{tag} #{n}",
        oidc_sub: "oidc-voice-card-link-#{tag}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  # Same shape `meeting_ask_floor_voice_gate_test.exs` uses: the ONLY
  # metadata shape `Meetings.livekit_dispatch_target/1` (and therefore
  # `ask_floor_window_signal/3`) resolves as "this is the dedicated voice
  # worker", matching `mix platform.seed_meeting_voice_agent`'s real one.
  defp voice_gated_agent! do
    n = System.unique_integer([:positive])
    owner = user!("owner-#{n}")

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "meeting-assistant-#{n}",
        name: "Burrow",
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    Repo.reload(agent)
  end

  setup %{conn: conn} do
    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :livekit_req_client,
      Req.new(plug: {Req.Test, :voice_card_link_test})
    )

    # The LiveKit SendData calls stage 2 wires up are not this stage's
    # remit (`meeting_ask_floor_voice_gate_test.exs` already covers
    # them) — stub a bare 200 so `AskFloor.claim/5`/`release/3` proceed
    # exactly as they would with the real signal delivered.
    Req.Test.stub(:voice_card_link_test, fn conn ->
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)
      Application.delete_env(:platform, :livekit_req_client)
    end)

    agent = voice_gated_agent!()
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Voice Card Link Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Voice Card Link Meeting #{n}",
        slug: "voice-card-link-meeting-#{n}"
      })

    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)
    {:ok, _} = Meetings.participant_joined(room, %{agent_id: agent.id, display_name: agent.name})

    alice = user!("alice")

    {:ok, _} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: alice.id,
        display_name: alice.name,
        joined_at: DateTime.utc_now()
      })

    alice_conn = init_test_session(conn, current_user_id: alice.id)

    {:ok, alice_view, _html} =
      live(alice_conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    on_exit(fn ->
      PressWindow.clear_meeting(meeting.id)
      AskFloor.clear_meeting(meeting.id)
    end)

    %{alice_view: alice_view, meeting: meeting, agent: agent, room: room}
  end

  test "holding Ask on Burrow reads exactly like any other agent, and the landed card carries the ladder onward",
       %{alice_view: alice_view, meeting: meeting, agent: agent} do
    agent_id = agent.id

    assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
    assert [card] = Candidates.open_for_meeting(meeting.id)
    candidate_id = card.id
    assert card.assigned_agent_id == agent_id

    # SAME veil scaffold, SAME per-row live transcript popover (the Ask
    # mockup's `.tr.live`) as any text-only agent — nothing here is
    # voice-specific markup. The invariant this test guards — voice gets
    # no special-cased markup — checks the popover on Burrow's own row.
    assert has_element?(alice_view, "[data-role='meeting-ask-veil']")

    assert has_element?(
             alice_view,
             ~s(li.row[data-participant-type="agent"] [data-role="meeting-agent-hold-to-talk"][data-agent-id="#{agent_id}"])
           )

    assert has_element?(
             alice_view,
             ~s(li.row[data-participant-type="agent"] .tr.live[data-role="meeting-ask-live"])
           )

    assert {:ok, %{identity: held_identity}} = AskFloor.holder(meeting.id, agent_id)
    room_id = Meetings.room_name_for_space(meeting.chat_space_id)

    # The room's OWN STT segment for the presser's identity — the exact
    # broadcast a text-agent session is fed by (`meeting_ask_floor_press_
    # test.exs`'s happy path), never anything voice-worker-specific. If
    # this pipeline were secretly keyed on the agent's kind, THIS would
    # be where it silently dropped the segment for a voice target.
    MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
      room_id: room_id,
      transcript_id: Ecto.UUID.generate(),
      meeting_id: meeting.id,
      segment: %{
        "participant_identity" => held_identity,
        "text" => "file a ticket for the voice bug",
        "final" => true
      }
    })

    _ = render(alice_view)

    assert_push_event(alice_view, "meeting_ask_transcript_chunk", %{
      "text" => "file a ticket for the voice bug"
    })

    assert render_hook(alice_view, "push_to_talk_release", %{})
    _ = render(alice_view)

    assert_push_event(alice_view, "meeting_ask_outcome", %{
      "outcome" => "fly",
      "candidate_id" => ^candidate_id
    })

    # Still a real, open candidate — the release freed the floor without
    # tearing the card down.
    assert [^card] = Candidates.open_for_meeting(meeting.id)
    assert AskFloor.holder(meeting.id, agent_id) == :none

    # Drive the SAME candidate through the ladder the veil named rung 1
    # for. In production this is the classifier/sweeper's job
    # (`Platform.Meetings.CandidateSweeper`); doing it directly here
    # keeps the assertion about what the RAIL renders once the ladder
    # advances, which is this stage's job, not a second proof of the
    # classifier.
    assert {:ok, shaping} = Candidates.advance(candidate_id, :shaping)
    assert shaping.state == :shaping

    _ = render(alice_view)

    # `MeetingCandidate`'s own column default is `outcome_kind: :task`
    # (never guessed here), so the rung carries the SAME "· TASK" note
    # `countdown_foot/1` already says in "Creating a task in 24" — the
    # mockup's own "[3 · TAKING SHAPE · TASK]" bracket.
    assert step_text(alice_view, candidate_id) ==
             CandidateDisplay.stage_label(:shaping) <> " · TASK"

    assert {:ok, acting} = Candidates.advance(shaping, :acting)
    assert acting.state == :acting

    _ = render(alice_view)

    # No `task_id` minted yet (no `graduate/2` call in this test — that
    # is the classifier/sweeper's job, out of scope here), so the note
    # still comes from the armed `outcome_kind`, not a reached
    # deliverable — same source, same word.
    assert step_text(alice_view, candidate_id) ==
             CandidateDisplay.stage_label(:acting) <> " · TASK"

    # Still the SAME row `data-candidate-id` the veil's own
    # `meeting_ask_outcome` named — the spatial anchor and the ladder
    # rung agree about which card this hold session produced.
    assert has_element?(
             alice_view,
             "[data-role='meeting-candidate-card'][data-candidate-id='#{candidate_id}']"
           )

    # `open_for_meeting/1` excludes `:acting` on purpose (it is the
    # sweeper's/countdown's turf now, not the "still forming" board) —
    # the row is still the exact same candidate, read directly rather
    # than through that filtered query.
    assert Candidates.get(candidate_id).id == acting.id
    assert Candidates.get(candidate_id).state == :acting
  end

  defp step_text(view, candidate_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "[data-role='meeting-candidate-card'][data-candidate-id='#{candidate_id}'] " <>
        "[data-role='meeting-candidate-step']"
    )
    |> LazyHTML.text()
    |> String.trim()
  end
end
