defmodule Platform.Meetings.VoiceSessionTest do
  @moduledoc """
  `Platform.Meetings.VoiceSession` (task 01a1557a-eab7, Voice tab stage 1).

  `async: false`: LiveKit config and the injected `:livekit_req_client` are
  both application env.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.VoiceSession
  alias Platform.Repo

  @livekit_agent_name "meeting-voice-agent"
  @create_dispatch "/twirp/livekit.AgentDispatchService/CreateDispatch"
  @send_data "/twirp/livekit.RoomService/SendData"

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :livekit_req_client,
      Req.new(plug: {Req.Test, :voice_session_test})
    )

    test_pid = self()

    Req.Test.stub(:voice_session_test, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:twirp, conn.request_path, decoded})
      Req.Test.json(conn, %{})
    end)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original)
      Application.delete_env(:platform, :livekit_req_client)
    end)

    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-session-#{n}@example.com",
      name: "Voice Session #{n}",
      oidc_sub: "oidc-voice-session-#{n}"
    })
  end

  defp agent!(slug) do
    %Agent{}
    |> Agent.changeset(%{slug: slug, name: "Agent #{slug}", status: "active"})
    |> Repo.insert!()
  end

  defp voice_agent!(slug \\ nil) do
    slug = slug || "voice-agent-#{System.unique_integer([:positive])}"
    agent = agent!(slug)

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(user!().id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    Repo.reload(agent)
  end

  # Voice-capable row with no LiveKit dispatch target and no connected
  # socket: `voice_reachable?/1` answers :voice_runtime_offline.
  defp offline_agent! do
    agent = agent!("offline-voice-#{System.unique_integer([:positive])}")

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(user!().id, agent, %{
        metadata: %{"client_info" => %{"features" => ["meeting_voice"]}}
      })

    Repo.reload(agent)
  end

  defp channel!(members) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Voice Ctx #{n}", slug: "voice-ctx-#{n}", kind: "channel"})

    for user <- members do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp clear_floor(session), do: AskFloor.clear_meeting("voice:" <> session.space_id)

  # The worker published into the room: the row now carries its identity.
  defp worker_joined!(session, agent) do
    {:ok, room} = Meetings.ensure_room(session.space_id)

    {:ok, _row} =
      Meetings.upsert_live_participant(room, %{identity: "agent:" <> agent.id, name: agent.name})

    :ok
  end

  defp drain_dispatches(acc \\ []) do
    receive do
      {:twirp, @create_dispatch, body} -> drain_dispatches([body | acc])
      {:twirp, _other, _body} -> drain_dispatches(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp send_data_payloads(acc \\ []) do
    receive do
      {:twirp, @send_data, body} ->
        send_data_payloads([{body["room"], body["topic"], Base.decode64!(body["data"])} | acc])

      {:twirp, _other, _body} ->
        send_data_payloads(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── start/3 ───────────────────────────────────────────────────────────

  describe "start/3" do
    test "dispatches with voice_1to1 mode and the space context, and returns the session" do
      user = user!()
      agent = voice_agent!()
      ctx_space = channel!([user])

      assert {:ok, session} =
               VoiceSession.start(user, agent, %{id: ctx_space.id, name: "Roadmap"})

      assert session.room_name == "space-" <> session.space_id
      assert session.agent_id == agent.id
      assert session.livekit_url == "wss://livekit.test"
      assert is_binary(session.token)

      assert [dispatch] = drain_dispatches()
      assert dispatch["room"] == "space-" <> session.space_id
      metadata = Jason.decode!(dispatch["metadata"])
      assert metadata["mode"] == "voice_1to1"

      assert metadata["voice_context"] == %{
               "kind" => "space",
               "id" => ctx_space.id,
               "name" => "Roadmap"
             }

      assert metadata["space_id"] == session.space_id
      assert metadata["human_identity"] == "user:" <> user.id
    end

    test "no context dispatches voice_context null" do
      user = user!()
      agent = voice_agent!()

      assert {:ok, _session} = VoiceSession.start(user, agent, nil)
      assert [dispatch] = drain_dispatches()
      metadata = Jason.decode!(dispatch["metadata"])
      assert metadata["mode"] == "voice_1to1"
      assert Map.has_key?(metadata, "voice_context")
      assert metadata["voice_context"] == nil
    end

    test "refuses a context space the user is not in" do
      user = user!()
      agent = voice_agent!()
      other_space = channel!([user!()])

      assert {:error, :forbidden} =
               VoiceSession.start(user, agent, %{id: other_space.id, name: "x"})

      assert drain_dispatches() == []
    end

    test "is idempotent: same DM and room, no second dispatch while the agent is live" do
      user = user!()
      agent = voice_agent!()

      assert {:ok, first} = VoiceSession.start(user, agent, nil)
      assert [_] = drain_dispatches()
      :ok = worker_joined!(first, agent)

      assert {:ok, second} = VoiceSession.start(user, agent, nil)
      assert second.space_id == first.space_id
      assert second.room_name == first.room_name
      assert drain_dispatches() == []
    end

    # Task 01a174e2: the shared room is stamped so room_finished skips the
    # meeting summary for a voice-only session.
    test "stamps the room voice_1to1 when it is idle, and join_for_user/3 clears it" do
      user = user!()
      agent = voice_agent!()

      assert {:ok, session} = VoiceSession.start(user, agent, nil)
      room = Meetings.get_room_by_name(session.room_name)
      assert room.status == "idle"
      assert Meetings.voice_1to1_room?(room)
      assert %DateTime{} = Meetings.session_mode_started_at(room)

      assert {:ok, _join} = Meetings.join_for_user(session.space_id, user.id, user.name)
      refute Meetings.voice_1to1_room?(Meetings.get_room_by_name(session.room_name))
    end

    test "does not stamp a room whose call is live (status active)" do
      user = user!()
      agent = voice_agent!()
      {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      assert {:ok, %{room: room}} = Meetings.join_for_user(dm.id, user.id, user.name)
      assert room.status == "active"

      assert {:ok, session} = VoiceSession.start(user, agent, nil)
      assert session.room_name == room.livekit_room_name
      refute Meetings.voice_1to1_room?(Meetings.get_room_by_name(session.room_name))
    end

    test "returns :voice_runtime_offline for an agent with no voice runtime online" do
      user = user!()
      agent = offline_agent!()

      assert {:error, :voice_runtime_offline} = VoiceSession.start(user, agent, nil)
      assert drain_dispatches() == []
    end

    test "returns :livekit_not_configured and dispatches nothing without LiveKit" do
      Application.put_env(:platform, :livekit, [])
      user = user!()
      agent = voice_agent!()

      assert {:error, :livekit_not_configured} = VoiceSession.start(user, agent, nil)
      assert drain_dispatches() == []
    end
  end

  # ── press/2 and release/2 ───────────────────────────────────────────

  describe "press/2 and release/2" do
    test "hit SendData for room space-<dm id> with open then closed" do
      user = user!()
      agent = voice_agent!()
      {:ok, session} = VoiceSession.start(user, agent, nil)
      on_exit(fn -> clear_floor(session) end)
      _ = drain_dispatches()

      room = "space-" <> session.space_id
      open = ~s({"agent_id":"#{agent.id}","event":"open"})
      closed = ~s({"agent_id":"#{agent.id}","event":"closed"})

      assert {:ok, _holder} = VoiceSession.press(session, user)
      assert [{^room, "mva.ask_floor", ^open}] = send_data_payloads()

      assert :ok = VoiceSession.release(session, user)
      assert [{^room, "mva.ask_floor", ^closed}] = send_data_payloads()
    end

    test "claims the floor under the voice:<dm id> key" do
      user = user!()
      agent = voice_agent!()
      {:ok, session} = VoiceSession.start(user, agent, nil)
      on_exit(fn -> clear_floor(session) end)

      assert {:ok, _} = VoiceSession.press(session, user)

      assert {:ok, %{identity: identity}} =
               AskFloor.holder("voice:" <> session.space_id, agent.id)

      assert identity == "user:" <> user.id
    end

    test "a same-identity re-press is idempotent: original claim, no second open" do
      user = user!()
      agent = voice_agent!()
      {:ok, session} = VoiceSession.start(user, agent, nil)
      on_exit(fn -> clear_floor(session) end)
      _ = send_data_payloads()

      assert {:ok, first} = VoiceSession.press(session, user)
      assert [_open] = send_data_payloads()

      assert {:ok, again} = VoiceSession.press(session, user)
      assert again.pressed_at == first.pressed_at
      assert send_data_payloads() == []
    end
  end

  # ── set_context/2 ───────────────────────────────────────────────────

  describe "set_context/2" do
    test "sends reliable mva.context room data for a space and for none" do
      user = user!()
      agent = voice_agent!()
      {:ok, session} = VoiceSession.start(user, agent, nil)
      _ = send_data_payloads()
      room = "space-" <> session.space_id
      space_id = Ecto.UUID.generate()

      assert :ok = VoiceSession.set_context(session, %{id: space_id, name: "Ops"})

      assert_received {:twirp, @send_data,
                       %{"kind" => "RELIABLE", "topic" => "mva.context"} = body}

      assert body["room"] == room

      assert Jason.decode!(Base.decode64!(body["data"])) ==
               %{"kind" => "space", "id" => space_id, "name" => "Ops"}

      assert :ok = VoiceSession.set_context(session, nil)
      assert [{^room, "mva.context", none}] = send_data_payloads()
      assert Jason.decode!(none) == %{"kind" => "none", "id" => nil, "name" => nil}
    end
  end

  # ── post_transcript/3 ───────────────────────────────────────────────

  describe "post_transcript/3" do
    test "posts as the user's participant with source voice" do
      user = user!()
      space = channel!([user])

      assert {:ok, %Message{} = message} =
               VoiceSession.post_transcript(user, space.id, "  what shipped today?  ")

      assert message.space_id == space.id
      assert message.content == "what shipped today?"
      assert message.metadata["source"] == "voice"

      participant = Repo.get!(Chat.Participant, message.participant_id)
      assert participant.participant_type == "user"
      assert participant.participant_id == user.id
    end

    test "refuses a space the user is not a member of" do
      user = user!()
      space = channel!([user!()])

      assert {:error, :forbidden} = VoiceSession.post_transcript(user, space.id, "hello")
    end

    test "refuses blank text" do
      user = user!()
      space = channel!([user])

      assert {:error, :blank} = VoiceSession.post_transcript(user, space.id, "   ")
      assert {:error, :blank} = VoiceSession.post_transcript(user, space.id, nil)
    end
  end

  # ── partners ─────────────────────────────────────────────────────────

  describe "partners/1 and default_partner/1" do
    test "Burrow first, with reachable? from voice_reachable?/1" do
      user = user!()
      burrow = voice_agent!("meeting-assistant")
      offline = offline_agent!()

      partners = VoiceSession.partners(user)
      assert %{agent: %Agent{id: first_id}, reachable?: true} = hd(partners)
      assert first_id == burrow.id

      assert %{reachable?: false} = Enum.find(partners, &(&1.agent.id == offline.id))
      assert VoiceSession.default_partner(user).id == burrow.id
    end
  end

  # ── The DM call shares the voice session's room ─────────────────────

  describe "a DM call in the same user<->agent DM" do
    test "joins the same room, does not re-dispatch, and press/release still hit it" do
      user = user!()
      agent = voice_agent!()

      {:ok, session} = VoiceSession.start(user, agent, nil)
      on_exit(fn -> clear_floor(session) end)
      assert [first_dispatch] = drain_dispatches()
      assert Jason.decode!(first_dispatch["metadata"])["mode"] == "voice_1to1"
      :ok = worker_joined!(session, agent)

      # The DM call button's join path (`MeetingHooks.do_join/1`).
      assert {:ok, %{room: call_room}} =
               Meetings.join_for_user(session.space_id, user.id, user.name)

      assert call_room.livekit_room_name == "space-" <> session.space_id
      assert drain_dispatches() == []

      room = "space-" <> session.space_id
      assert {:ok, _} = VoiceSession.press(session, user)
      assert [{^room, "mva.ask_floor", open}] = send_data_payloads()
      assert Jason.decode!(open)["event"] == "open"

      assert :ok = VoiceSession.release(session, user)
      assert [{^room, "mva.ask_floor", closed}] = send_data_payloads()
      assert Jason.decode!(closed)["event"] == "closed"
    end
  end

  # ── invite_agent/3 is unchanged ────────────────────────────────────

  describe "invite_agent/3" do
    test "writes no mode or voice_context into the dispatch metadata" do
      user = user!()
      agent = voice_agent!()
      space = channel!([user])
      {:ok, room} = Meetings.ensure_room(space.id)
      _ = drain_dispatches()

      assert {:ok, _} = Meetings.invite_agent(room, agent, user)
      assert [dispatch] = drain_dispatches()
      metadata = Jason.decode!(dispatch["metadata"])
      refute Map.has_key?(metadata, "mode")
      refute Map.has_key?(metadata, "voice_context")
    end
  end
end
