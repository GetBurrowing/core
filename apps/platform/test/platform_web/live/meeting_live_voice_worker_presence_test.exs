defmodule PlatformWeb.MeetingLiveVoiceWorkerPresenceTest do
  @moduledoc """
  Task 01a1117f stage 3: the render-layer half of the voice-worker fix.

  Stage 1 folds a legacy livekit-agents worker (identity `agent-AJ_…`) onto
  the one LiveKit-dispatched agent invited to the room. What it could NOT
  fold (zero or several candidates) is still inserted as a nil-FK row, and
  before this stage that row rendered as "Unknown participant" next to the
  agent it probably is.

  What these tests pin, one property each:

    * an unfoldable `agent-AJ_` row is absent from `meeting_presence/1`, the
      gallery, the rail and the top-bar count, and does not light the
      transcribing pill;
    * any OTHER unresolvable identity (`zzz:foo`) still renders "Unknown
      participant": only the LiveKit agent-job shape is hidden;
    * a folded Burrow row renders once, as Burrow, and is `:in_call`, not
      pending;
    * the transcriber stays hidden with `transcriber_present?` true;
    * `agent_gallery_identity/1` prefers the row's agent identity, so a
      speaking `agent:<slug>` agent (and a folded `agent-AJ_` one) is
      promoted by `gallery_participants/2`.

  `async: false`: the LiveKit dispatch target is resolved through a runtime
  registered in application-wide state, mirroring `voice_worker_identity_test`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.{Chat, Federation, Meetings, Repo}
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MeetingLive

  @livekit_agent_name "meeting-voice-agent"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice_worker_presence_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-voice-worker-presence-#{n}"
    })
  end

  defp authenticated_conn(conn) do
    viewer = user!("Viewer")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    init_test_session(conn, current_user_id: viewer.id)
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Voice Worker Presence #{n}",
        slug: "voice-worker-presence-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Voice Worker Presence Project #{n}",
        slug: "voice-worker-presence-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "voice-worker-presence-#{n}",
        name: "Voice Worker Presence",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  defp human!(room, name) do
    user = user!(name)

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: name})

    user
  end

  # Burrow's shape: a voice runtime declaring `client_info.livekit_agent_name`,
  # so `livekit_dispatch_target/1` resolves it and stage 1's fold applies.
  defp burrow!(name \\ "Burrow") do
    owner = user!("Burrow Owner")
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "vwp-burrow-#{n}", name: name, status: "active"})

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

  # The invite row as `invite_participant_row/2` writes it: agent FK, NO
  # identity yet.
  defp invite_row!(room, %Agent{} = agent) do
    {:ok, row} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    row
  end

  # A worker join that stage 1 cannot fold: no LiveKit-dispatched invite row
  # in the room, so it is inserted as a nil-FK row carrying the identity.
  defp orphan_worker!(room, identity \\ "agent-AJ_orphan1") do
    {:ok, row} = Meetings.upsert_live_participant(room, %{identity: identity, name: nil})
    assert is_nil(row.agent_id) and is_nil(row.user_id)
    assert row.metadata["identity"] == identity
    row
  end

  defp frag(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> frag() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp roster_readout(html), do: query(html, ~s([data-role="meeting-roster-count"]))

  defp mount(conn, meeting) do
    {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
    {view, html}
  end

  # ── The predicate ───────────────────────────────────────────────────────

  describe "Meetings.unresolved_agent_worker_participant?/1" do
    test "is true only for a nil-FK row in LiveKit's agent-job shape" do
      {_meeting, _space, room} = meeting!()
      orphan = orphan_worker!(room)
      human = human!(room, "Ada Human")

      assert Meetings.unresolved_agent_worker_participant?(orphan)

      human_row =
        room.space_id
        |> Meetings.active_participants_for_space()
        |> Enum.find(&(&1.user_id == human.id))

      refute Meetings.unresolved_agent_worker_participant?(human_row)

      # An FK makes it a folded agent row, never an unresolved worker.
      refute Meetings.unresolved_agent_worker_participant?(%{
               orphan
               | agent_id: Ecto.UUID.generate()
             })

      # Other unresolvable shapes are not matched: they keep the honest label.
      for identity <- ["zzz:foo", "agent-foo", "agent:dalton", "transcriber:space-x", nil] do
        refute Meetings.unresolved_agent_worker_participant?(%{
                 orphan
                 | metadata: %{"identity" => identity}
               }),
               "matched #{inspect(identity)}"
      end

      # Keyed on the identity, never on the display name.
      refute Meetings.unresolved_agent_worker_participant?(%{
               orphan
               | display_name: "agent-AJ_lookalike",
                 metadata: %{}
             })

      refute Meetings.unresolved_agent_worker_participant?(nil)
    end
  end

  # ── Unfoldable worker row: hidden everywhere ────────────────────────────

  describe "an unfoldable agent-AJ_ row" do
    setup %{conn: conn} do
      {meeting, space, room} = meeting!()
      ada = human!(room, "Ada Human")
      orphan = orphan_worker!(room)

      %{
        conn: authenticated_conn(conn),
        meeting: meeting,
        space: space,
        room: room,
        ada: ada,
        orphan: orphan
      }
    end

    test "is absent from meeting_presence/1 and build_meeting_participants/1", %{
      space: space,
      ada: ada
    } do
      assert {[only], false} = MeetingLive.meeting_presence(space.id)
      assert only.participant_id == ada.id
      assert MeetingLive.build_meeting_participants(space.id) == [only]

      # Positive control: the row IS live, so the exclusion above could fire.
      assert space.id
             |> Meetings.active_participants_for_space()
             |> Enum.any?(&Meetings.unresolved_agent_worker_participant?/1)
    end

    test "is absent from the rendered gallery, rail and count, and lights no pill", %{
      conn: conn,
      meeting: meeting,
      ada: ada
    } do
      {view, html} = mount(conn, meeting)

      assert count(html, ~s([data-participant^="agent-AJ_"])) == 0
      assert count(html, ~s([data-participant-identity^="agent-AJ_"])) == 0
      refute html =~ "agent-AJ_"
      refute html =~ "Unknown participant"

      # Positive control: Ada's tile and rail row DID render.
      assert count(html, ~s([data-gallery-grid] [data-participant="user:#{ada.id}"])) == 1
      assert count(html, ~s([data-participant-identity="user:#{ada.id}"])) >= 1

      assert html
             |> query("[data-gallery-tile-count]")
             |> LazyHTML.attribute("data-gallery-tile-count") ==
               ["1"]

      readout = roster_readout(html)
      assert LazyHTML.attribute(readout, "data-people") == ["1"]
      assert LazyHTML.attribute(readout, "data-agents") == ["0"]

      refute has_element?(view, ~s([data-role="meeting-transcribing-pill"]))
      assert :sys.get_state(view.pid).socket.assigns.transcriber_present? == false
    end
  end

  describe "a zzz:foo nil-FK row" do
    test "still renders as Unknown participant", %{conn: conn} do
      {meeting, space, room} = meeting!()
      human!(room, "Ada Human")

      {:ok, _} = Meetings.upsert_live_participant(room, %{identity: "zzz:foo", name: "Mallory"})

      assert {participants, false} = MeetingLive.meeting_presence(space.id)
      assert Enum.any?(participants, &(&1.identity == "zzz:foo"))

      {_view, html} = mount(authenticated_conn(conn), meeting)

      assert count(html, ~s([data-gallery-grid] [data-participant="zzz:foo"])) == 1
      assert html =~ "Unknown participant"
      assert roster_readout(html) |> LazyHTML.attribute("data-people") == ["2"]
    end
  end

  # ── Folded Burrow ───────────────────────────────────────────────────────

  describe "a folded Burrow row" do
    setup %{conn: conn} do
      {meeting, space, room} = meeting!()
      human!(room, "Ada Human")
      burrow = burrow!()
      invite = invite_row!(room, burrow)

      {:ok, folded} =
        Meetings.upsert_live_participant(room, %{identity: "agent-AJ_fold1", name: nil})

      # Stage 1's fold: the SAME row, now carrying the worker identity.
      assert folded.id == invite.id
      assert folded.agent_id == burrow.id
      assert folded.metadata["identity"] == "agent-AJ_fold1"

      %{conn: authenticated_conn(conn), meeting: meeting, space: space, burrow: burrow}
    end

    test "is one Burrow participant that reads in_call, not pending", %{
      space: space,
      burrow: burrow
    } do
      assert {participants, false} = MeetingLive.meeting_presence(space.id)

      assert [agent] = Enum.filter(participants, &(&1.participant_type == "agent"))
      assert agent.participant_id == burrow.id
      assert agent.display_name == "Burrow"
      assert agent.identity == "agent-AJ_fold1"

      assert MeetingLive.pending_invite_agent_ids(participants) == MapSet.new()

      assert [%{state: :in_call}] =
               space.id
               |> MeetingLive.invite_rows(participants)
               |> Enum.filter(&(&1.agent.id == burrow.id))
    end

    test "renders once in the rail as Burrow, with no Unknown participant", %{
      conn: conn,
      meeting: meeting,
      burrow: burrow
    } do
      {_view, html} = mount(conn, meeting)

      # The page renders the participant rail more than once (desktop rail
      # and the People tab), so the property is per rail: each agents
      # section holds exactly ONE agent row, and it is Burrow's.
      sections = query(html, ~s([data-section="agents"]))
      assert Enum.count(sections) >= 1

      for section <- sections do
        rows = LazyHTML.query(section, ~s(li[data-participant-type="agent"]))
        assert Enum.count(rows) == 1
        assert LazyHTML.attribute(rows, "data-participant-identity") == ["agent-AJ_fold1"]

        assert rows |> LazyHTML.query(~s([data-role="participant-name"])) |> LazyHTML.text() =~
                 "Burrow"
      end

      refute html =~ "Unknown participant"
      refute html =~ "Invite sent, no answer yet"

      readout = roster_readout(html)
      assert LazyHTML.attribute(readout, "data-people") == ["1"]
      assert LazyHTML.attribute(readout, "data-agents") == ["1"]

      refute html =~ ~s(data-agent-id="#{burrow.id}" data-invite-state="pending")
    end
  end

  # ── Transcriber unchanged ───────────────────────────────────────────────

  describe "with a transcriber and an unfoldable worker in the room" do
    test "both are hidden and transcriber_present? stays true", %{conn: conn} do
      {meeting, space, room} = meeting!()
      ada = human!(room, "Ada Human")

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "transcriber:space-#{space.id}",
          name: "Transcription"
        })

      orphan_worker!(room, "agent-AJ_orphan2")

      assert {[only], true} = MeetingLive.meeting_presence(space.id)
      assert only.participant_id == ada.id

      {view, html} = mount(authenticated_conn(conn), meeting)
      assert :sys.get_state(view.pid).socket.assigns.transcriber_present? == true
      assert has_element?(view, ~s([data-role="meeting-transcribing-pill"]))
      refute html =~ "Unknown participant"
      assert roster_readout(html) |> LazyHTML.attribute("data-people") == ["1"]
    end
  end

  # ── Gallery identity and promotion ──────────────────────────────────────

  describe "agent_gallery_identity/1" do
    test "prefers an agent: identity on the row, else agent:<participant_id>" do
      id = Ecto.UUID.generate()

      assert MeetingLive.agent_gallery_identity(%{participant_id: id, identity: "agent:dalton"}) ==
               "agent:dalton"

      assert MeetingLive.agent_gallery_identity(%{participant_id: id, identity: nil}) ==
               "agent:" <> id

      assert MeetingLive.agent_gallery_identity(%{participant_id: id}) == "agent:" <> id
    end

    test "prefers a folded agent-AJ_ identity, ignores any other shape" do
      id = Ecto.UUID.generate()

      assert MeetingLive.agent_gallery_identity(%{participant_id: id, identity: "agent-AJ_fold1"}) ==
               "agent-AJ_fold1"

      for other <- ["user:#{id}", "zzz:foo", "agent:", "agent-foo", ""] do
        assert MeetingLive.agent_gallery_identity(%{participant_id: id, identity: other}) ==
                 "agent:" <> id,
               "took #{inspect(other)}"
      end

      assert MeetingLive.agent_gallery_identity(%{}) == "agent:"
    end
  end

  describe "gallery_participants/2 promotion" do
    test "a speaking agent:<slug> channel agent is promoted to the grid" do
      id = Ecto.UUID.generate()

      agent = %{
        participant_type: "agent",
        participant_id: id,
        identity: "agent:dalton",
        display_name: "Dalton"
      }

      assert MeetingLive.gallery_participants([agent], MapSet.new(["agent:dalton"])) == [agent]
      # Silent: not in the grid.
      assert MeetingLive.gallery_participants([agent], MapSet.new()) == []
    end

    test "a speaking folded agent-AJ_ worker is promoted to the grid" do
      agent = %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        identity: "agent-AJ_fold1",
        display_name: "Burrow"
      }

      assert MeetingLive.gallery_participants([agent], MapSet.new(["agent-AJ_fold1"])) == [agent]
    end

    test "an agent with no identity is still promoted on agent:<uuid>" do
      id = Ecto.UUID.generate()
      agent = %{participant_type: "agent", participant_id: id, identity: nil}

      assert MeetingLive.gallery_participants([agent], MapSet.new(["agent:" <> id])) == [agent]
    end
  end
end
