defmodule Platform.Meetings.LivekitAgentDispatchTest do
  @moduledoc """
  Task 01a0d4a0 (Option 2): a runtime whose voice worker is a
  livekit-agents process (like `services/meeting-voice-agent`) never opens
  a `RuntimeChannel` socket, so `RuntimePresence.online?/1` can never
  observe it and `resolve_voice_target/1` answers `:voice_runtime_offline`
  for it forever — even while the worker is live and reachable by LiveKit
  itself.

  These tests pin the fix: a runtime that declares an explicit,
  opt-in `metadata["client_info"]["livekit_agent_name"]` routes an invite
  through LiveKit's own `AgentDispatchService/CreateDispatch` Twirp RPC
  instead, while a runtime that has never declared that key — every other
  agent in the system today — keeps exactly its old `:voice_runtime_offline`
  behaviour. `resolve_voice_target/1` itself is not touched by this task and
  is not re-tested here; `voice_target_routing_test.exs` already covers it.

  `async: false`: LiveKit lives in application env, and the injected Req
  client (`Platform.ExternalAgentsTest`'s `Req.Test` pattern, also used by
  `media_room_presence_test.exs`) is application env too.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Participant
  alias Platform.Repo

  @room_name "livekit-agent-dispatch-test"
  @livekit_agent_name "meeting-voice-agent"

  defp configured do
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
      Req.new(plug: {Req.Test, :livekit_dispatch_test})
    )

    Req.Test.stub(:livekit_dispatch_test, response_fn)
    on_exit(fn -> Application.delete_env(:platform, :livekit_req_client) end)
  end

  defp decode_claims(jwt) do
    jwt
    |> String.split(".")
    |> Enum.at(1)
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "livekit-dispatch-#{n}@example.com",
      name: "LiveKit Dispatch #{n}",
      oidc_sub: "oidc-livekit-dispatch-#{n}"
    })
  end

  defp agent!(slug_prefix) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "#{slug_prefix}-#{n}",
      name: "#{slug_prefix} #{n}",
      status: "active"
    })
  end

  # A voice-capable row that declares the LiveKit Agent Dispatch opt-in key
  # — the shape `mix platform.seed_meeting_voice_agent` now stamps on the
  # Burrow's runtime — but that never connects a `RuntimeChannel`
  # socket, exactly like the real livekit-agents worker never does.
  defp dispatch_capable_agent! do
    owner = user!()
    agent = agent!("livekit-dispatch-agent")

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    {owner, Repo.reload(agent)}
  end

  # A voice-capable row that declares ONLY the pre-existing `features` key
  # — every agent in the system before this task, and every agent that
  # never opts in to LiveKit Agent Dispatch after it.
  defp offline_voice_only_agent! do
    owner = user!()
    agent = agent!("offline-voice-agent")

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{"client_info" => %{"features" => ["meeting_voice"]}}
      })

    {owner, Repo.reload(agent)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "LiveKit Dispatch Space #{n}",
        slug: "livekit-dispatch-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp room! do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  defp add_writer!(space_id, user) do
    {:ok, _row} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  # ── create_livekit_agent_dispatch/3 (the raw Twirp call) ──────────────────

  describe "create_livekit_agent_dispatch/3" do
    test "posts CreateDispatch with a roomAdmin-scoped token and the given agent_name" do
      configured()

      stub_livekit(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/twirp/livekit.AgentDispatchService/CreateDispatch"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert %{"video" => %{"roomAdmin" => true, "room" => @room_name}} = decode_claims(jwt)

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "room" => @room_name,
                 "agent_name" => @livekit_agent_name,
                 "metadata" => "{}"
               }

        Req.Test.json(conn, %{})
      end)

      assert :ok = Meetings.create_livekit_agent_dispatch(@room_name, @livekit_agent_name, "{}")
    end

    test "without LiveKit configured returns :livekit_not_configured" do
      Application.put_env(:platform, :livekit, [])
      on_exit(fn -> Application.delete_env(:platform, :livekit) end)

      assert {:error, :livekit_not_configured} =
               Meetings.create_livekit_agent_dispatch(@room_name, @livekit_agent_name)
    end

    test "a non-2xx response is a clean error tuple, not a raise" do
      configured()
      stub_livekit(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:http_error, 500, "boom"}} =
               Meetings.create_livekit_agent_dispatch(@room_name, @livekit_agent_name)
    end
  end

  # ── dispatch_meeting_join/3 routes an opted-in runtime through LiveKit ────

  describe "dispatch_meeting_join/3 for a runtime declaring livekit_agent_name" do
    test "routes through LiveKit Agent Dispatch instead of a RuntimeChannel broadcast" do
      configured()
      {_owner, agent} = dispatch_capable_agent!()

      # Nothing subscribes to any `runtime:*` topic in this test — if the
      # old broadcast path ran, there would be nobody to receive it and no
      # way to see it failed. The only way this can pass is via the new
      # Twirp call.
      test_pid = self()

      stub_livekit(fn conn ->
        assert conn.request_path == "/twirp/livekit.AgentDispatchService/CreateDispatch"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["room"] == @room_name
        assert decoded["agent_name"] == @livekit_agent_name
        send(test_pid, {:dispatch_body, decoded})
        Req.Test.json(conn, %{})
      end)

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})
      assert_receive {:dispatch_body, _decoded}, 1_000
    end

    test "a failed CreateDispatch call surfaces as :livekit_dispatch_failed" do
      configured()
      {_owner, agent} = dispatch_capable_agent!()

      stub_livekit(fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

      assert {:error, :livekit_dispatch_failed} =
               Meetings.dispatch_meeting_join(agent, @room_name, %{})
    end
  end

  # ── Regression: every other runtime is completely unaffected ─────────────

  describe "regression: a runtime that never declares livekit_agent_name" do
    test "dispatch_meeting_join/3 still answers :voice_runtime_offline while offline" do
      configured()
      {_owner, agent} = offline_voice_only_agent!()

      # No LiveKit stub configured at all: if this agent's dispatch ever
      # fell through to `create_livekit_agent_dispatch/3`, the call would
      # error (or, with a raised expectation, fail the test loudly) rather
      # than quietly returning the old error tuple.
      assert {:error, :voice_runtime_offline} =
               Meetings.dispatch_meeting_join(agent, @room_name, %{})
    end

    test "resolve_voice_target/1 is untouched: still :voice_runtime_offline" do
      configured()
      {_owner, agent} = offline_voice_only_agent!()

      assert {:error, :voice_runtime_offline} = Meetings.resolve_voice_target(agent)
    end

    test "invite_agent/3 still refuses with :voice_runtime_offline and writes no participant row" do
      configured()
      {_owner, agent} = offline_voice_only_agent!()

      room = room!()
      inviter = user!()
      add_writer!(room.space_id, inviter)

      assert {:error, :voice_runtime_offline} = Meetings.invite_agent(room, agent, inviter)

      assert Repo.all(
               from(p in Participant, where: p.room_id == ^room.id and p.agent_id == ^agent.id)
             ) == []
    end

    test "an agent with no runtime at all is still :no_runtime, not :voice_runtime_offline" do
      configured()
      agent = agent!("no-runtime-agent")

      assert {:error, :no_runtime} = Meetings.dispatch_meeting_join(agent, @room_name, %{})
    end
  end

  # ── invite_agent/3 is reachable end to end for the opted-in runtime ───────

  describe "invite_agent/3 for a runtime declaring livekit_agent_name" do
    test "writes a participant row and dispatches via LiveKit Agent Dispatch" do
      configured()
      {_owner, agent} = dispatch_capable_agent!()

      room = room!()
      inviter = user!()
      add_writer!(room.space_id, inviter)

      stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

      assert {:ok, participant} = Meetings.invite_agent(room, agent, inviter)
      assert participant.agent_id == agent.id

      assert Repo.all(
               from(p in Participant, where: p.room_id == ^room.id and p.agent_id == ^agent.id)
             ) != []
    end

    # Task 01a0d4a0 stage 5 item 2: Dalton's dual-agent moon run found a
    # worker's `AgentSession` linking to the OTHER invited agent's own room
    # participant instead of the human, when two agents were invited within
    # milliseconds of each other. The dispatch's job metadata now carries
    # the inviting human's LiveKit identity so the worker can pin its
    # session to that participant deterministically instead of accepting
    # whichever remote participant it observes first.
    test "dispatch metadata carries the inviting human's LiveKit identity as human_identity" do
      configured()
      {_owner, agent} = dispatch_capable_agent!()

      room = room!()
      inviter = user!()
      add_writer!(room.space_id, inviter)

      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end)

      assert {:ok, _participant} = Meetings.invite_agent(room, agent, inviter)

      assert_receive {:dispatch_body, decoded}, 1_000
      metadata = Jason.decode!(decoded["metadata"])

      assert metadata["human_identity"] == "user:#{inviter.id}"
      assert metadata["space_id"] == room.space_id
    end

    test "dispatch metadata's human_identity is nil for a non-human inviting actor" do
      configured()
      {_owner, agent} = dispatch_capable_agent!()

      room = room!()

      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end)

      # An {:agent, id} actor is a resolvable SpaceAccess.actor() but not a
      # human one — invite_agent/3 must not raise trying to derive an
      # identity from it, and must not fabricate a "user:" identity for a
      # non-user actor.
      inviting_agent = agent!("inviting-agent")

      assert {:ok, _writer} =
               Platform.Chat.add_participant(room.space_id, %{
                 participant_type: "agent",
                 participant_id: inviting_agent.id,
                 display_name: inviting_agent.name,
                 joined_at: DateTime.utc_now()
               })

      assert {:ok, _participant} =
               Meetings.invite_agent(room, agent, {:agent, inviting_agent.id})

      assert_receive {:dispatch_body, decoded}, 1_000
      metadata = Jason.decode!(decoded["metadata"])

      assert metadata["human_identity"] == nil
    end
  end
end
