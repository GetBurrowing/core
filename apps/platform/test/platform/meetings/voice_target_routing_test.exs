defmodule Platform.Meetings.VoiceTargetRoutingTest do
  @moduledoc """
  Task 01a06686 stage 2 — `meeting_join` and `meeting_say` go to the VOICE
  runtime, and an offline voice worker is an error, not a silent `:ok`.

  ## What was broken

  An agent's brain (`agent.runtime_id`, the socket that answers chat) and
  its voice worker (the process that can actually join a LiveKit room) are
  separate `agent_runtimes` rows since stage 1. `dispatch_meeting_join/3`
  and `say/4` still resolved through `IntentRuntimeAdapter.resolve_target/1`,
  which reads only the brain pointer, so every join and every utterance was
  pushed to a socket that cannot join a room, while the row that could
  listened to nothing.

  ## Shape of these tests

  Every scenario drives REAL runtime clients through
  `PlatformWeb.RuntimeSocket.connect/3` and `RuntimeChannel.join/3`, with the
  `client_info.features` declaration made in the join payload exactly as a
  worker makes it — so `persist_client_info/2` and `RuntimePresence.track/1`
  are in the path, not simulated. The test process subscribes to both
  runtime topics with `Endpoint.subscribe/1` and asserts on which one the
  `meeting_join` / `meeting_say` broadcast lands, with a `refute_receive` on
  the other. `join/3` rather than `subscribe_and_join/3` for the clients, so
  the test process holds exactly one subscription per topic.

  `async: false` — LiveKit lives in app env, `RuntimePresence` is one named
  process, and the channel writes through the shared sandbox.
  """
  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Meetings
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Repo

  @room_name "voice-target-routing-test"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-target-#{n}@example.com",
      name: "Voice Target #{n}",
      oidc_sub: "oidc-voice-target-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "voice-target-agent-#{n}",
      name: "Voice Target Agent #{n}",
      status: "active"
    })
  end

  # The brain: one row, linked through `link_agent/2` so `agent.runtime_id`
  # points at it — which is all `IntentRuntimeAdapter.resolve_target/1` reads.
  defp brain!(owner, agent) do
    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "vt-brain-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # The mouth: stage 1's second row, bound by `agent_id` only.
  defp voice!(owner, agent) do
    {:ok, runtime, raw_token} = Federation.register_voice_runtime(owner.id, agent)
    %{runtime: runtime, raw_token: raw_token}
  end

  defp agent_with_brain_and_voice! do
    owner = user!()
    %{agent: agent, runtime: brain, raw_token: brain_token} = brain!(owner, agent!())
    %{runtime: voice, raw_token: voice_token} = voice!(owner, agent)

    %{
      agent: agent,
      brain: brain,
      brain_token: brain_token,
      voice: voice,
      voice_token: voice_token,
      brain_topic: IntentRuntimeAdapter.runtime_topic(brain.runtime_id),
      voice_topic: IntentRuntimeAdapter.runtime_topic(voice.runtime_id)
    }
  end

  # A real client for `runtime`, joined on its one topic, declaring
  # `features` in the join payload the way a worker does. The test process is
  # NOT subscribed by this (see the moduledoc).
  defp join_client!(%AgentRuntime{} = runtime, raw_token, features) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, joined} =
      join(socket, "runtime:#{runtime.runtime_id}", %{
        "client_info" => %{
          "product" => "openclaw",
          "version" => "0.1.0",
          "features" => features
        }
      })

    joined
  end

  # Leave, and wait for the channel process to be gone — `terminate/2` is
  # where `RuntimePresence.untrack/1` runs, so the presence answer is only
  # settled once the process has exited. The channel is linked to the test
  # process, so unlink first or the `{:shutdown, :left}` exit takes the test
  # down with it.
  defp leave_and_wait!(joined) do
    Process.unlink(joined.channel_pid)
    ref = Process.monitor(joined.channel_pid)
    _ = leave(joined)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    :ok
  end

  defp subscribe_both!(%{brain_topic: brain_topic, voice_topic: voice_topic}) do
    :ok = PlatformWeb.Endpoint.subscribe(brain_topic)
    :ok = PlatformWeb.Endpoint.subscribe(voice_topic)
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Voice Target Space #{n}",
        slug: "voice-target-space-#{n}",
        kind: "channel"
      })

    space
  end

  # A room with `agent` seated, so `say/4`'s participant guard passes and
  # the only thing left to decide is the topic.
  defp seated_room!(agent) do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    {:ok, _row} = Chat.add_agent_participant(space.id, agent)

    {:ok, _participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    room
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  # ── Two rows, both online ────────────────────────────────────────────────

  describe "dispatch_meeting_join/3 with a brain and a voice row both connected" do
    test "lands on the voice topic and not the brain (brain joined first)" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      _voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      subscribe_both!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_join"},
                     1_000

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     300
    end

    test "lands on the voice topic and not the brain (voice joined first)" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      _voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      subscribe_both!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_join"},
                     1_000

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     300
    end

    test "meeting_join_topic/1 names the voice topic, and resolve_voice_target/1 the voice row" do
      %{agent: agent, voice_topic: voice_topic} = ctx = agent_with_brain_and_voice!()

      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      _voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])

      assert {:ok, ^voice_topic} = Meetings.meeting_join_topic(agent)

      assert {:ok,
              %{agent: ^agent, runtime: %AgentRuntime{id: voice_id}, runtime_id: rid, topic: t}} =
               Meetings.resolve_voice_target(agent)

      assert voice_id == ctx.voice.id
      assert rid == ctx.voice.runtime_id
      assert t == voice_topic
    end
  end

  # ── The voice socket goes away ───────────────────────────────────────────

  describe "when the voice socket has left" do
    test "dispatch is refused with :voice_runtime_offline while the brain is still online" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      subscribe_both!(ctx)

      # Positive control before the leave: the same agent routes fine.
      assert {:ok, ^voice_topic} = Meetings.meeting_join_topic(agent)

      leave_and_wait!(voice)

      assert {:error, :voice_runtime_offline} =
               Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert {:error, :voice_runtime_offline} = Meetings.meeting_join_topic(agent)

      # The brain is not what went away. Its presence is intact, and it must
      # NOT have been handed the join as a consolation prize.
      assert RuntimePresence.online?(ctx.brain.runtime_id)
      refute RuntimePresence.online?(ctx.voice.runtime_id)

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     300

      refute_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_join"},
                     100
    end

    test "invite_agent/3 surfaces :voice_runtime_offline as its own error and writes no row" do
      %{agent: agent} = ctx = agent_with_brain_and_voice!()
      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      leave_and_wait!(voice)

      space = space!()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)
      inviter = user!()

      {:ok, _row} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: inviter.id,
          display_name: inviter.name,
          joined_at: DateTime.utc_now()
        })

      assert {:error, :voice_runtime_offline} = Meetings.invite_agent(room, agent, inviter)

      assert Repo.all(
               from(p in Platform.Meetings.Participant,
                 where: p.room_id == ^room.id and p.agent_id == ^agent.id
               )
             ) == []
    end
  end

  describe "when the brain socket has left instead" do
    test "dispatch still lands on the voice topic" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      brain = join_client!(ctx.brain, ctx.brain_token, [])
      _voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      subscribe_both!(ctx)

      leave_and_wait!(brain)
      refute RuntimePresence.online?(ctx.brain.runtime_id)

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_join"},
                     1_000

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     300
    end
  end

  # ── Legacy shapes keep working ───────────────────────────────────────────

  describe "a single legacy runtime that declares voice itself" do
    test "receives the join on its own topic" do
      owner = user!()
      %{agent: agent, runtime: brain, raw_token: token} = brain!(owner, agent!())
      brain_topic = IntentRuntimeAdapter.runtime_topic(brain.runtime_id)

      _client = join_client!(brain, token, ["meeting_voice"])
      :ok = PlatformWeb.Endpoint.subscribe(brain_topic)

      assert {:ok, %{runtime_id: rid}} = Meetings.resolve_voice_target(agent)
      assert rid == brain.runtime_id

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     1_000
    end
  end

  describe "an agent with no voice-capable row" do
    test "falls back to the brain topic when the brain is online (never-declared client)" do
      owner = user!()
      %{agent: agent, runtime: brain, raw_token: token} = brain!(owner, agent!())
      brain_topic = IntentRuntimeAdapter.runtime_topic(brain.runtime_id)

      # No `client_info` at all — the legacy bridge that predates the field.
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => brain.runtime_id, "token" => token})

      {:ok, _reply, _joined} = join(socket, "runtime:#{brain.runtime_id}", %{})
      :ok = PlatformWeb.Endpoint.subscribe(brain_topic)

      assert {:ok, %{runtime_id: rid}} = Meetings.resolve_voice_target(agent)
      assert rid == brain.runtime_id

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     1_000
    end

    test "falls back to the brain topic when a voice row exists but declared nothing" do
      %{agent: agent, brain_topic: brain_topic, voice_topic: voice_topic} =
        ctx = agent_with_brain_and_voice!()

      # Brain connected; the voice row is registered but has never joined, so
      # it has no declaration. Nothing says voice → legacy route, not offline.
      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      subscribe_both!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_join"},
                     1_000

      refute_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_join"},
                     100
    end

    test "with no runtime at all is :no_runtime, not :voice_runtime_offline" do
      agent = agent!()
      assert {:error, :no_runtime} = Meetings.resolve_voice_target(agent)
      assert {:error, :no_runtime} = Meetings.dispatch_meeting_join(agent, @room_name, %{})
    end
  end

  # ── say/4 ────────────────────────────────────────────────────────────────

  describe "say/4 with a brain and a voice row" do
    test "broadcasts meeting_say on the voice topic, not the brain" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      _voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      subscribe_both!(ctx)

      room = seated_room!(agent)

      # Nothing answers, so the rendezvous times out — that is fine; the
      # assertion is about where the utterance went.
      assert {:ok, %{status: "no_ack"}} =
               Meetings.say(agent, room.livekit_room_name, "hello from the mouth",
                 ack_timeout_ms: 50
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^voice_topic,
                       event: "meeting_say",
                       payload: %{text: "hello from the mouth"}
                     },
                     1_000

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_say"}, 300
    end

    test "is refused with :voice_runtime_offline when the voice socket has left" do
      %{agent: agent, voice_topic: voice_topic, brain_topic: brain_topic} =
        ctx = agent_with_brain_and_voice!()

      _brain = join_client!(ctx.brain, ctx.brain_token, [])
      voice = join_client!(ctx.voice, ctx.voice_token, ["meeting_voice"])
      subscribe_both!(ctx)
      leave_and_wait!(voice)

      room = seated_room!(agent)

      assert {:error, :voice_runtime_offline} =
               Meetings.say(agent, room.livekit_room_name, "anyone there", ack_timeout_ms: 50)

      refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: "meeting_say"}, 300
      refute_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: "meeting_say"}, 100
    end
  end
end
