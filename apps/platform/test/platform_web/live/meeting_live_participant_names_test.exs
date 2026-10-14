defmodule PlatformWeb.MeetingLiveParticipantNamesTest do
  @moduledoc """
  Task 01a1117f stage 5, the two LiveView halves of the gate findings:

    * `data-participant-names` on `#meeting-room` and `#meeting-client` maps a
      folded legacy voice worker's LiveKit identity (`agent-AJ_…`) to Burrow,
      so the transcript pane (`meeting_room.js`) and quick-meet tiles
      (`meeting_client.js`) can label it. It never names the transcriber or
      a human.
    * a voice-present agent's rail word reads "Speaking" while its LiveKit
      identity is in `@speaking_identities`, and "Idle" when it is not.

  `async: false` for the same reason as the stage 4 test these fixtures come
  from: the LiveKit dispatch target is resolved through a runtime registered
  in application-wide state.
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
  defp burrow! do
    owner = user!("Burrow Owner")
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "pnames-burrow-#{n}", name: "Burrow", status: "active"})

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

  defp frag(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> frag() |> LazyHTML.query(selector)

  defp mount(conn, meeting) do
    {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
    {view, html}
  end

  defp names_on(html, selector) do
    [raw] = html |> query(selector) |> LazyHTML.attribute("data-participant-names")
    Jason.decode!(raw)
  end

  defp rail_words(html) do
    html
    |> query(~s([data-section="agents"] [data-role="agent-activity-primary"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "data-participant-names" do
    setup %{conn: conn} do
      {meeting, space, room} = meeting!()
      host = human!(room, "Rowan")
      burrow = burrow!()
      invite = invite_row!(room, burrow)

      # The legacy worker shape: LiveKit's default job identity, no name.
      {:ok, folded} =
        Meetings.upsert_live_participant(room, %{identity: "agent-AJ_names1", name: nil})

      assert folded.id == invite.id

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "transcriber:space-#{space.id}",
          name: "Transcription"
        })

      %{
        conn: authenticated_conn(conn),
        meeting: meeting,
        space: space,
        host: host,
        burrow: burrow
      }
    end

    test "both hook elements map the folded identity to Burrow and nothing else", %{
      conn: conn,
      meeting: meeting,
      space: space,
      host: host
    } do
      {_view, html} = mount(conn, meeting)

      for selector <- ["#meeting-room", "#meeting-client"] do
        names = names_on(html, selector)
        assert names == %{"agent-AJ_names1" => "Burrow"}
        refute Map.has_key?(names, "transcriber:space-#{space.id}")
        refute Map.has_key?(names, "user:#{host.id}")
        refute names |> Map.values() |> Enum.member?("Transcription")
      end
    end
  end

  describe "participant_names_json/1" do
    test "voice-present agents with a name only" do
      json =
        MeetingLive.participant_names_json([
          %{participant_type: "agent", identity: "agent:abc", display_name: "Burrow"},
          %{participant_type: "agent", identity: "agent-AJ_x", display_name: "Burrow"},
          %{participant_type: "agent", identity: nil, display_name: "Pending"},
          %{participant_type: "agent", identity: "agent:blank", display_name: "  "},
          %{participant_type: "user", identity: "user:1", display_name: "Marlowe"},
          %{participant_type: "user", identity: "zzz:stranger", display_name: nil}
        ])

      assert Jason.decode!(json) == %{"agent:abc" => "Burrow", "agent-AJ_x" => "Burrow"}
    end

    test "anything that is not a list is an empty object" do
      assert MeetingLive.participant_names_json(nil) == "{}"
      assert MeetingLive.participant_names_json([]) == "{}"
    end
  end

  describe "rail status while a voice agent speaks" do
    setup %{conn: conn} do
      {meeting, _space, room} = meeting!()
      _host = human!(room, "Rowan")
      burrow = burrow!()
      _invite = invite_row!(room, burrow)

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: "agent:#{burrow.id}", name: nil})

      %{conn: authenticated_conn(conn), meeting: meeting, burrow: burrow}
    end

    test "speaking shows Speaking in every rail, silence shows Idle", %{
      conn: conn,
      meeting: meeting,
      burrow: burrow
    } do
      {view, html} = mount(conn, meeting)
      words = rail_words(html)
      assert words != []
      assert Enum.all?(words, &(&1 == "Idle"))

      html = render_hook(view, "active_speakers", %{"identities" => ["agent:#{burrow.id}"]})
      words = rail_words(html)
      assert words != []
      assert Enum.all?(words, &(&1 == "Speaking"))

      html = render_hook(view, "active_speakers", %{"identities" => []})
      assert Enum.all?(rail_words(html), &(&1 == "Idle"))
    end

    test "another participant speaking leaves the agent Idle", %{conn: conn, meeting: meeting} do
      {view, _html} = mount(conn, meeting)
      html = render_hook(view, "active_speakers", %{"identities" => ["user:someone"]})
      words = rail_words(html)
      assert words != []
      assert Enum.all?(words, &(&1 == "Idle"))
    end
  end
end
