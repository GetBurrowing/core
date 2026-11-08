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

    # A hung-up call leaves the room "active" until LiveKit's room_finished
    # arrives, with no human in it. A Voice tab session started in that gap
    # was not stamped, so its room_finished summarized the voice conversation
    # as a meeting.
    test "stamps a room left active by a call nobody is in any more" do
      user = user!()
      agent = voice_agent!()
      {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      assert {:ok, %{room: room}} = Meetings.join_for_user(dm.id, user.id, user.name)
      assert room.status == "active"
      assert :ok = Meetings.leave_for_user(dm.id, user.id)

      assert {:ok, session} = VoiceSession.start(user, agent, nil)
      room = Meetings.get_room_by_name(session.room_name)
      assert room.status == "active"
      assert Meetings.voice_1to1_room?(room)
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

  # ── Voice DM records (task 01a1b6c3 stage 2) ─────────────────────────

  defp dm_messages(session) do
    from(m in Message, where: m.space_id == ^session.space_id, order_by: [asc: m.id])
    |> Repo.all()
  end

  defp author(message) do
    p = Repo.get!(Chat.Participant, message.participant_id)
    {p.participant_type, p.participant_id}
  end

  defp started!(user, agent \\ nil) do
    agent = agent || voice_agent!()
    {:ok, session} = VoiceSession.start(user, agent, nil)
    {session, agent}
  end

  defp turn!(session, user, who, text, opts \\ []) do
    {:ok, session, _info} = VoiceSession.record_turn(session, user, who, text, opts)
    session
  end

  defp summaries(session) do
    session
    |> dm_messages()
    |> Enum.filter(&(&1.metadata["voice_kind"] == "summary"))
  end

  describe "start/3 session identity" do
    test "returns a UUIDv7 id and started_at, new per start" do
      user = user!()
      agent = voice_agent!()
      {:ok, first} = VoiceSession.start(user, agent, nil)
      {:ok, second} = VoiceSession.start(user, agent, nil)

      assert {:ok, _} = Platform.Types.UUIDv7.cast(first.id)
      assert %DateTime{} = first.started_at
      refute first.id == second.id
      assert first.turns == 0
    end
  end

  describe "record_turn/5 with no context" do
    test "3 user + 3 agent turns land in the DM in order, by user and agent, tagged" do
      user = user!()
      {session, agent} = started!(user)

      session =
        session
        |> turn!(user, :me, "first question")
        |> turn!(user, :agent, "first answer")
        |> turn!(user, :me, "second question", input: :typed)
        |> turn!(user, :agent, "second answer")
        |> turn!(user, :me, "third question")
        |> turn!(user, :agent, "third answer")

      rows = dm_messages(session)

      assert Enum.map(rows, & &1.content) == [
               "first question",
               "first answer",
               "second question",
               "second answer",
               "third question",
               "third answer"
             ]

      assert Enum.map(rows, &author/1) ==
               List.flatten(List.duplicate([{"user", user.id}, {"agent", agent.id}], 3))

      for {row, i} <- Enum.with_index(rows, 1) do
        input = if i == 3, do: "typed", else: "voice"

        assert row.metadata == %{
                 "source" => "voice",
                 "voice_session_id" => session.id,
                 "voice_turn" => i,
                 "input" => input
               }

        assert row.content_type == "text"
      end

      assert session.turns == 6
    end
  end

  describe "record_turn/5 with a context" do
    test "user turns post to the context only; the DM gets agent turns and one pointer per context" do
      user = user!()
      ctx_a = channel!([user])
      ctx_b = channel!([user])
      {session, _agent} = started!(user)
      a = %{id: ctx_a.id, name: "roadmap"}
      b = %{id: ctx_b.id, name: "launch"}

      assert {:ok, session, %{posted_to: "roadmap"}} =
               VoiceSession.record_turn(session, user, :me, "one", context: a)

      session =
        session
        |> turn!(user, :agent, "reply one")
        |> turn!(user, :me, "two", context: a)
        |> turn!(user, :agent, "reply two")
        |> turn!(user, :me, "three", context: b)
        |> turn!(user, :agent, "reply three")

      ctx_a_rows = Chat.list_messages(ctx_a.id) |> Enum.sort_by(& &1.id)
      assert Enum.map(ctx_a_rows, & &1.content) == ["one", "two"]
      assert Enum.map(ctx_a_rows, & &1.metadata["voice_turn"]) == [1, 3]
      assert Enum.all?(ctx_a_rows, &(&1.metadata["voice_session_id"] == session.id))
      assert Enum.all?(ctx_a_rows, &(author(&1) == {"user", user.id}))
      assert [%{content: "three"}] = Chat.list_messages(ctx_b.id)

      rows = dm_messages(session)

      assert Enum.map(rows, & &1.content) == [
               "Your side was posted to #roadmap",
               "reply one",
               "reply two",
               "Your side was posted to #launch",
               "reply three"
             ]

      refute Enum.any?(rows, &(&1.content in ["one", "two", "three"]))

      pointers = Enum.filter(rows, &(&1.metadata["voice_kind"] == "context_pointer"))

      assert Enum.map(pointers, & &1.metadata) == [
               %{
                 "source" => "voice",
                 "voice_session_id" => session.id,
                 "voice_kind" => "context_pointer",
                 "context_space_id" => ctx_a.id,
                 "context_name" => "roadmap"
               },
               %{
                 "source" => "voice",
                 "voice_session_id" => session.id,
                 "voice_kind" => "context_pointer",
                 "context_space_id" => ctx_b.id,
                 "context_name" => "launch"
               }
             ]

      assert Enum.all?(pointers, &(&1.content_type == "system"))
    end

    test "a :forbidden context falls back to the DM, so nothing is lost" do
      user = user!()
      not_mine = channel!([user!()])
      {session, _agent} = started!(user)

      assert {:ok, session, %{posted_to: nil}} =
               VoiceSession.record_turn(session, user, :me, "still said",
                 context: %{id: not_mine.id, name: "elsewhere"}
               )

      assert [row] = dm_messages(session)
      assert row.content == "still said"
      assert author(row) == {"user", user.id}
      assert row.metadata["voice_turn"] == 1
      assert Chat.list_messages(not_mine.id) == []
      assert session.pointers == MapSet.new()
    end
  end

  describe "record_turn/5 finals and segments" do
    test "an explicit final: false posts nothing" do
      user = user!()
      {session, _agent} = started!(user)

      assert {:skip, session, :not_final} =
               VoiceSession.record_turn(session, user, :me, "half a", final: false)

      assert {:skip, _session, :not_final} =
               VoiceSession.record_turn(session, user, :agent, "half b", final: false)

      assert dm_messages(session) == []
    end

    test "a repeated segment id posts once; another id posts" do
      user = user!()
      {session, _agent} = started!(user)

      session = turn!(session, user, :agent, "said once", segment_id: "SG_1")

      assert {:skip, session, :duplicate} =
               VoiceSession.record_turn(session, user, :agent, "said once", segment_id: "SG_1")

      session = turn!(session, user, :agent, "said twice", segment_id: "SG_2")

      assert Enum.map(dm_messages(session), & &1.content) == ["said once", "said twice"]
      assert session.turns == 2
    end
  end

  describe "unread and inbox" do
    test "a 3-turn session leaves the DM's unread count for the user unchanged" do
      user = user!()
      {session, _agent} = started!(user)

      # CONTROL: a plain agent message in the same DM is unread.
      control =
        Chat.post_message(%{
          space_id: session.space_id,
          participant_id: session.agent_participant_id,
          content_type: "text",
          content: "a plain reply"
        })

      assert {:ok, control} = control
      assert Map.get(Chat.unread_counts_for_user(user.id), session.space_id) == 1
      :ok = Chat.mark_space_read(session.user_participant_id, control.id)
      before = Map.get(Chat.unread_counts_for_user(user.id), session.space_id, 0)
      assert before == 0

      session
      |> turn!(user, :me, "q1")
      |> turn!(user, :agent, "a1")
      |> turn!(user, :me, "q2")
      |> turn!(user, :agent, "a2")
      |> turn!(user, :me, "q3")
      |> turn!(user, :agent, "a3")
      |> VoiceSession.finish()

      assert Map.get(Chat.unread_counts_for_user(user.id), session.space_id, 0) == before
    end

    test "an unread typed agent reply before a voice turn keeps its badge" do
      user = user!()
      {session, _agent} = started!(user)

      {:ok, _typed} =
        Chat.post_message(%{
          space_id: session.space_id,
          participant_id: session.agent_participant_id,
          content_type: "text",
          content: "a typed reply nobody has read"
        })

      assert Map.get(Chat.unread_counts_for_user(user.id), session.space_id) == 1

      _ = turn!(session, user, :me, "a spoken question")

      # The typed reply is still unread. The cursor did not jump over it, so
      # the user's own voice turn adds nothing (it is their own row).
      assert Map.get(Chat.unread_counts_for_user(user.id), session.space_id) == 1
    end

    test "with only voice rows past the cursor, the cursor still advances" do
      user = user!()
      {session, _agent} = started!(user)

      session
      |> turn!(user, :me, "q1")
      |> turn!(user, :agent, "a1")
      |> turn!(user, :agent, "a2")

      assert Map.get(Chat.unread_counts_for_user(user.id), session.space_id, 0) == 0
    end

    test "a voice row naming the user creates no inbox row; the same plain post does" do
      user = user!()
      {session, _agent} = started!(user)
      text = "noted for @[#{user.name}]"
      inbox_rows = fn -> Repo.aggregate(where(Platform.Inbox.Item, user_id: ^user.id), :count) end

      _ = turn!(session, user, :agent, text)
      assert inbox_rows.() == 0

      # CONTROL: the same words posted plainly by the agent do make one.
      {:ok, _} =
        Chat.post_message(%{
          space_id: session.space_id,
          participant_id: session.agent_participant_id,
          content_type: "text",
          content: text
        })

      assert inbox_rows.() == 1
    end
  end

  describe "finish/1 and finish_unfinished/1" do
    test "posts one summary row, once, however often it is called" do
      user = user!()
      {session, agent} = started!(user)

      session =
        session
        |> turn!(user, :me, "q1")
        |> turn!(user, :agent, "a1")
        |> turn!(user, :me, "q2")

      assert {:ok, %Message{} = summary} = VoiceSession.finish(session)
      assert {:ok, :already_finished} = VoiceSession.finish(session)
      assert {:ok, 0} = VoiceSession.finish_unfinished(session.space_id)

      assert [%{id: summary_id}] = summaries(session)
      assert summary_id == summary.id
      assert summary.content_type == "system"
      assert summary.content == "Voice chat · 3 turns · 1 min"
      assert author(summary) == {"agent", agent.id}
      assert summary.metadata["source"] == "voice"
      assert summary.metadata["voice_session_id"] == session.id
      assert summary.metadata["voice_kind"] == "summary"
      assert summary.metadata["turns"] == 3
      assert is_integer(summary.metadata["duration_ms"]) and summary.metadata["duration_ms"] >= 0
      assert summary.metadata["started_at"] == DateTime.to_iso8601(session.started_at)
    end

    test "two racing callers post one summary" do
      user = user!()
      {session, _agent} = started!(user)
      session = turn!(session, user, :me, "q1")
      parent = self()

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            VoiceSession.finish(session)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.count(results, &match?({:ok, %Message{}}, &1)) == 1
      assert length(summaries(session)) == 1
    end

    test "no summary for a session with zero turns" do
      user = user!()
      {session, _agent} = started!(user)

      assert {:ok, :no_turns} = VoiceSession.finish(session)
      assert {:ok, 0} = VoiceSession.finish_unfinished(session.space_id)
      assert dm_messages(session) == []
    end

    test "the room_finished fallback summarizes a session nobody closed, context turns counted" do
      user = user!()
      ctx = channel!([user])
      {session, _agent} = started!(user)

      session
      |> turn!(user, :me, "q1", context: %{id: ctx.id, name: "roadmap"})
      |> turn!(user, :agent, "a1")

      assert {:ok, 1} = VoiceSession.finish_unfinished(session.space_id)
      assert {:ok, 0} = VoiceSession.finish_unfinished(session.space_id)
      assert [summary] = summaries(session)
      assert summary.metadata["turns"] == 2
      assert summary.content == "Voice chat · 2 turns · 1 min"
      assert {:ok, :already_finished} = VoiceSession.finish(session)
    end
  end

  describe "no row wakes the agent" do
    setup do
      previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
      Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

      on_exit(fn ->
        if previous_mode,
          do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
          else: Application.delete_env(:platform, :chat_agent_dispatch_mode)
      end)

      router =
        Process.whereis(Platform.Chat.AttentionRouter) ||
          start_supervised!({Platform.Chat.AttentionRouter, []})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), router)

      store =
        Process.whereis(Platform.Chat.ActiveAgentStore) ||
          start_supervised!({Platform.Chat.ActiveAgentStore, []})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), store)

      presence =
        Process.whereis(Platform.Federation.RuntimePresence) ||
          start_supervised!(Platform.Federation.RuntimePresence)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), presence)
      :ok
    end

    defp online_external_agent! do
      owner = user!()
      n = System.unique_integer([:positive])

      runtime =
        Repo.insert!(%Platform.Agents.AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: "rt-voice-dm-#{n}",
          display_name: "voice-dm-rt"
        })

      Platform.Federation.RuntimePresence.track(runtime.runtime_id)
      on_exit(fn -> Platform.Federation.RuntimePresence.untrack(runtime.runtime_id) end)

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "voice-dm-agent-#{n}",
          name: "Helper Agent",
          status: "active",
          max_concurrent: 1,
          sandbox_mode: "off",
          runtime_type: "external",
          runtime_id: runtime.id,
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        })
        |> Repo.insert!()

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)
      {agent, topic}
    end

    # The session `start/3` would return, minus LiveKit: record_turn/5 and
    # finish/1 read only these keys.
    defp record_session!(user, agent) do
      {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      {:ok, up} = Platform.Chat.SpaceAccess.authorize_writer(dm.id, user)
      {:ok, ap} = Platform.Chat.SpaceAccess.authorize_writer(dm.id, {:agent, agent.id})

      %{
        id: Platform.Types.UUIDv7.generate(),
        started_at: DateTime.utc_now(),
        space_id: dm.id,
        agent_id: agent.id,
        user_participant_id: up.id,
        agent_participant_id: ap.id
      }
    end

    defp drain_router, do: :ok = GenServer.call(Platform.Chat.AttentionRouter, :__drain__)

    test "every DM row routes to [] and no runtime broadcast arrives; a plain post does" do
      user = user!()
      {agent, topic} = online_external_agent!()
      ctx = channel!([user])
      session = record_session!(user, agent)

      session =
        session
        |> turn!(user, :me, "dm question")
        |> turn!(user, :agent, "dm answer")
        |> turn!(user, :me, "ctx question", context: %{id: ctx.id, name: "roadmap"})
        |> turn!(user, :agent, "ctx answer")

      {:ok, %Message{}} = VoiceSession.finish(session)
      drain_router()

      rows = dm_messages(session)
      assert length(rows) == 5
      assert Enum.map(rows, & &1.metadata["voice_kind"]) |> Enum.count(&(&1 != nil)) == 2

      for row <- rows do
        assert Platform.Chat.AttentionRouter.voice_record?(row)
        assert {:ok, []} = Platform.Chat.AttentionRouter.route(row)
      end

      drain_router()
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic}, 300

      # CONTROL: the fixture can fail. A plain message in the same DM reaches
      # the agent's runtime.
      {:ok, plain} =
        Chat.post_message(%{
          space_id: session.space_id,
          participant_id: session.user_participant_id,
          content_type: "text",
          content: "a typed DM"
        })

      plain_id = plain.id

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{signal: %{message_id: ^plain_id}}
                     },
                     2_000

      drain_router()
    end
  end
end
