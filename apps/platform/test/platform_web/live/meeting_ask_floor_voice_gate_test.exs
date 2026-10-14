defmodule PlatformWeb.MeetingAskFloorVoiceGateTest do
  @moduledoc """
  The missing link task 01a0e47c stage 2 builds: on a successful
  `AskFloor.claim/5` for the meeting-assistant voice agent specifically,
  Core signals "listening window open" into that agent's LiveKit room over
  `RoomService/SendData`; on release (or a refused second claim leaving
  the floor untouched), it signals "closed" or nothing at all.

  Every OTHER roster agent (no LiveKit `agent_name` declared) must see
  ZERO LiveKit calls from a press/release — this is a targeted addition
  to the general `AskFloor` mechanism `meeting_ask_floor_press_test.exs`
  already covers end to end, not a new lock.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.PressWindow
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @livekit_agent_name "meeting-voice-agent"

  defp configured_livekit do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp stub_livekit(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :livekit_req_client,
      Req.new(plug: {Req.Test, :ask_floor_voice_gate_test})
    )

    Req.Test.stub(:ask_floor_voice_gate_test, response_fn)
    on_exit(fn -> Application.delete_env(:platform, :livekit_req_client) end)
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ask_floor_voice_#{tag}_#{n}@example.com",
        name: "#{tag} #{n}",
        oidc_sub: "oidc-ask-floor-voice-#{tag}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp meeting_with_agent!(agent) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Ask Floor Voice Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Ask Floor Voice Meeting #{n}",
        slug: "ask-floor-voice-meeting-#{n}"
      })

    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)
    {:ok, _} = Meetings.participant_joined(room, %{agent_id: agent.id, display_name: agent.name})

    {meeting, room}
  end

  # A voice-capable agent whose runtime declares the LiveKit Agent Dispatch
  # opt-in key — the shape `mix platform.seed_meeting_voice_agent` stamps
  # on the real Burrow, and the ONLY shape `livekit_dispatch_target/1`
  # (and therefore `ask_floor_window_signal/3`) resolves.
  defp voice_gated_agent! do
    n = System.unique_integer([:positive])
    owner = user!("owner-#{n}")

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "meeting-assistant-#{n}",
        name: "Burrow #{n}",
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

  # An ordinary text-only roster agent — no voice runtime, no LiveKit
  # dispatch target at all. The regression baseline.
  defp text_only_agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "text-only-agent-#{n}",
      name: "Text Only Agent #{n}",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp mount_member!(conn, meeting, user) do
    member_conn = init_test_session(conn, current_user_id: user.id)

    {:ok, view, _html} =
      live(member_conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    view
  end

  setup do
    configured_livekit()
    :ok
  end

  describe "the meeting-assistant voice agent: LiveKit signal follows the floor" do
    setup %{conn: conn} do
      agent = voice_gated_agent!()
      {meeting, room} = meeting_with_agent!(agent)
      alice = user!("alice")
      bob = user!("bob")

      for user <- [alice, bob] do
        {:ok, _} =
          Chat.add_participant(meeting.chat_space_id, %{
            participant_type: "user",
            participant_id: user.id,
            display_name: user.name,
            joined_at: DateTime.utc_now()
          })
      end

      alice_view = mount_member!(conn, meeting, alice)
      bob_view = mount_member!(Phoenix.ConnTest.build_conn(), meeting, bob)

      on_exit(fn ->
        PressWindow.clear_meeting(meeting.id)
        AskFloor.clear_meeting(meeting.id)
      end)

      %{
        agent: agent,
        meeting: meeting,
        room: room,
        alice_view: alice_view,
        bob_view: bob_view
      }
    end

    test "a successful claim sends exactly one 'open' SendData call, to the right room",
         %{agent: agent, meeting: meeting, alice_view: alice_view} do
      test_pid = self()
      expected_room = Meetings.room_name_for_space(meeting.chat_space_id)

      stub_livekit(fn conn ->
        assert conn.request_path == "/twirp/livekit.RoomService/SendData"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")

        claims =
          jwt
          |> String.split(".")
          |> Enum.at(1)
          |> Base.url_decode64!(padding: false)
          |> Jason.decode!()

        assert %{"video" => %{"roomAdmin" => true}} = claims

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
        send(test_pid, {:sent, decoded["room"], decoded["topic"], decoded["kind"], payload})
        Req.Test.json(conn, %{})
      end)

      agent_id = agent.id
      assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})

      assert_receive {:sent, room_name, topic, kind, payload}, 1_000
      assert room_name == expected_room
      assert topic == "mva.ask_floor"
      assert kind == "RELIABLE"
      assert payload == %{"event" => "open", "agent_id" => agent_id}

      refute_receive {:sent, _, _, _, _}, 200
    end

    test "release sends a 'closed' SendData call", %{
      agent: agent,
      meeting: meeting,
      alice_view: alice_view
    } do
      test_pid = self()
      expected_room = Meetings.room_name_for_space(meeting.chat_space_id)

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
        send(test_pid, {:sent, decoded["room"], payload})
        Req.Test.json(conn, %{})
      end)

      agent_id = agent.id
      assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
      assert_receive {:sent, ^expected_room, %{"event" => "open"}}, 1_000

      assert render_hook(alice_view, "push_to_talk_release", %{})

      assert_receive {:sent, ^expected_room, %{"event" => "closed", "agent_id" => ^agent_id}},
                     1_000
    end

    test "a REFUSED second claim never sends an 'open' signal — the gate is never partially opened",
         %{agent: agent, alice_view: alice_view, bob_view: bob_view} do
      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
        send(test_pid, {:sent, payload})
        Req.Test.json(conn, %{})
      end)

      agent_id = agent.id
      assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
      assert_receive {:sent, %{"event" => "open"}}, 1_000

      # Bob's press on the SAME agent is refused server-side by
      # `AskFloor.claim/5`'s atomic lock — this is the SAME refusal
      # `meeting_ask_floor_press_test.exs` proves for a text-only agent;
      # this test additionally proves the refusal never triggers a second
      # (redundant, or worse, premature) LiveKit signal.
      assert render_hook(bob_view, "push_to_talk_press", %{"agent_id" => agent_id})

      assert_push_event(bob_view, "push_to_talk_rejected", %{
        "agent_id" => ^agent_id,
        "reason" => "held-by-other"
      })

      # Only the ONE "open" from Alice's real claim ever arrived — no
      # second SendData call for Bob's refused attempt.
      refute_receive {:sent, _}, 300
    end
  end

  describe "regression: a text-only roster agent never touches LiveKit at all" do
    test "press and release send zero LiveKit calls", %{conn: conn} do
      agent = text_only_agent!()
      {meeting, _room} = meeting_with_agent!(agent)
      alice = user!("alice-text-only")

      {:ok, _} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: alice.id,
          display_name: alice.name,
          joined_at: DateTime.utc_now()
        })

      alice_view = mount_member!(conn, meeting, alice)

      on_exit(fn ->
        PressWindow.clear_meeting(meeting.id)
        AskFloor.clear_meeting(meeting.id)
      end)

      stub_livekit(fn conn ->
        flunk("no LiveKit call should have been made for a non-dispatch-capable agent")
        Req.Test.json(conn, %{})
      end)

      agent_id = agent.id
      assert render_hook(alice_view, "push_to_talk_press", %{"agent_id" => agent_id})
      assert render_hook(alice_view, "push_to_talk_release", %{})

      # Nothing above raised via the flunking stub — confirmed by simply
      # reaching this line — and the floor lock itself still worked
      # normally (unaffected by the LiveKit no-op).
      assert AskFloor.holder(meeting.id, agent_id) == :none
    end
  end
end
