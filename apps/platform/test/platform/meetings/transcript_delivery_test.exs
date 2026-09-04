defmodule Platform.Meetings.TranscriptDeliveryTest do
  @moduledoc """
  Task 01a06672 stage 1 — a FINAL transcript segment reaches the BRAIN
  runtime of every agent seated in the room, as the `"meeting_transcript"`
  event on `runtime:<runtime_id>`, from `Meetings.append_segment/2`'s
  success branch.

  What the tests pin, one property each:

    * every current agent participant hears a human segment;
    * an agent does not hear itself, but the other agent does;
    * the brain row hears, the voice row hears nothing;
    * a participant with `left_at` set hears nothing;
    * a non-final segment is stored but not delivered;
    * an agent with no runtime is skipped and the append still succeeds.

  Fixture shape is `voice_target_routing_test.exs`'s: real rows through
  `Federation.register_runtime/2` + `activate_runtime/1` + `link_agent/2`
  (the brain) and `Federation.register_voice_runtime/3` (the mouth); a room
  from `Meetings.ensure_room/1` + `activate_room/1`; seating through
  `Chat.add_agent_participant/2` + `Meetings.participant_joined/2`. The
  test process subscribes with `PlatformWeb.Endpoint.subscribe/1` and
  asserts on the `%Phoenix.Socket.Broadcast{}` it receives.

  The brain-vs-voice test connects a REAL voice client through
  `PlatformWeb.RuntimeSocket.connect/3` + `RuntimeChannel.join/3` declaring
  `meeting_voice`, because an OFFLINE voice row is invisible to
  `resolve_voice_target/1` (it falls back to the brain), and a test that
  cannot tell the two resolvers apart pins nothing.

  `async: false` — `RuntimePresence` is one named process, and the channel
  writes through the shared sandbox.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @event "meeting_transcript"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "transcript-delivery-#{n}@example.com",
      name: "Transcript Delivery #{n}",
      oidc_sub: "oidc-transcript-delivery-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "transcript-delivery-agent-#{n}",
      name: "Transcript Delivery Agent #{n}",
      status: "active"
    })
  end

  # The brain: linked through `link_agent/2` so `agent.runtime_id` points at
  # it — which is all `IntentRuntimeAdapter.resolve_target/1` reads.
  defp brain!(owner, agent) do
    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "td-brain-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # The mouth: a second row bound by `agent_id` only.
  defp voice!(owner, agent) do
    {:ok, runtime, raw_token} = Federation.register_voice_runtime(owner.id, agent)
    %{runtime: runtime, raw_token: raw_token}
  end

  # A real client for `runtime`, joined on its one topic, declaring
  # `features` the way a worker does. `join/3` rather than
  # `subscribe_and_join/3` so the test process holds exactly one
  # subscription per topic (the explicit `Endpoint.subscribe/1` below).
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

  defp agent_with_brain!(owner) do
    %{agent: agent, runtime: brain} = brain!(owner, agent!())
    %{agent: agent, brain_topic: IntentRuntimeAdapter.runtime_topic(brain.runtime_id)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Transcript Delivery Space #{n}",
        slug: "transcript-delivery-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp seated_room!(agents) do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    for agent <- agents do
      {:ok, _row} = Chat.add_agent_participant(space.id, agent)

      {:ok, _participant} =
        Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})
    end

    %{space: space, room: room}
  end

  defp transcript!(%{space: space, room: room}) do
    {:ok, %Transcript{} = transcript} =
      Meetings.ensure_transcript(%{room_id: room.livekit_room_name, space_id: space.id})

    transcript
  end

  defp segment(overrides \\ %{}) do
    Map.merge(
      %{
        "participant_identity" => "user:#{Ecto.UUID.generate()}",
        "speaker_name" => "Ada",
        "text" => "Let's ship the transcript frame.",
        "start_time" => 0,
        "end_time" => 500,
        "language" => "en",
        "final" => true
      },
      overrides
    )
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  test "a final human segment reaches the brain topic of every current agent participant" do
    owner = user!()
    %{agent: a, brain_topic: a_topic} = agent_with_brain!(owner)
    %{agent: b, brain_topic: b_topic} = agent_with_brain!(owner)
    ctx = seated_room!([a, b])
    transcript = transcript!(ctx)
    room_name = ctx.room.livekit_room_name

    :ok = PlatformWeb.Endpoint.subscribe(a_topic)
    :ok = PlatformWeb.Endpoint.subscribe(b_topic)

    text = "Hello from a human"

    assert {:ok, %Transcript{}} =
             Meetings.append_segment(transcript.id, segment(%{"text" => text}))

    assert_receive %Phoenix.Socket.Broadcast{topic: ^a_topic, event: @event, payload: a_payload},
                   500

    assert_receive %Phoenix.Socket.Broadcast{topic: ^b_topic, event: @event, payload: b_payload},
                   500

    for payload <- [a_payload, b_payload] do
      assert payload.speaker_kind == "human"
      assert payload.room_name == room_name
      assert is_binary(payload.segment_id)
      assert payload.text == text
      assert is_binary(payload.spoken_at)
      assert Map.has_key?(payload, :meeting_id)
      assert Map.has_key?(payload, :participant_identity)
      assert Map.has_key?(payload, :speaker_name)
    end

    # The stored segment carries the same id the frame announced.
    stored = Meetings.get_transcript(transcript.id)
    assert [%{"id" => stored_id, "text" => ^text}] = stored.segments
    assert stored_id == a_payload.segment_id
    assert a_payload.segment_id == b_payload.segment_id
  end

  test "an agent's own segment is not delivered to it but reaches the other agent" do
    owner = user!()
    %{agent: a, brain_topic: a_topic} = agent_with_brain!(owner)
    %{agent: b, brain_topic: b_topic} = agent_with_brain!(owner)
    ctx = seated_room!([a, b])
    transcript = transcript!(ctx)

    :ok = PlatformWeb.Endpoint.subscribe(a_topic)
    :ok = PlatformWeb.Endpoint.subscribe(b_topic)

    assert {:ok, %Transcript{}} =
             Meetings.append_segment(
               transcript.id,
               segment(%{"participant_identity" => "agent:#{a.slug}", "speaker_name" => a.name})
             )

    assert_receive %Phoenix.Socket.Broadcast{topic: ^b_topic, event: @event, payload: payload},
                   500

    assert payload.speaker_kind == "agent"
    assert payload.participant_identity == "agent:#{a.slug}"

    refute_receive %Phoenix.Socket.Broadcast{topic: ^a_topic, event: @event}, 300
  end

  test "delivery lands on the brain topic and the voice row receives nothing" do
    owner = user!()
    %{agent: agent, runtime: brain, raw_token: brain_token} = brain!(owner, agent!())
    %{runtime: voice, raw_token: voice_token} = voice!(owner, agent)
    brain_topic = IntentRuntimeAdapter.runtime_topic(brain.runtime_id)
    voice_topic = IntentRuntimeAdapter.runtime_topic(voice.runtime_id)
    refute brain_topic == voice_topic

    # Both rows ONLINE, the voice one declaring `meeting_voice`. Positive
    # control: the voice resolver now names the voice row, so a delivery
    # that (wrongly) routed through it would land on `voice_topic`.
    _brain = join_client!(brain, brain_token, [])
    _voice = join_client!(voice, voice_token, ["meeting_voice"])
    assert {:ok, %{topic: ^voice_topic}} = Meetings.resolve_voice_target(agent)

    ctx = seated_room!([agent])
    transcript = transcript!(ctx)

    :ok = PlatformWeb.Endpoint.subscribe(brain_topic)
    :ok = PlatformWeb.Endpoint.subscribe(voice_topic)

    assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment())

    assert_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: @event}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^voice_topic, event: @event}, 300
  end

  test "an agent whose participant row has left_at set receives nothing" do
    owner = user!()
    %{agent: agent, brain_topic: brain_topic} = agent_with_brain!(owner)
    ctx = seated_room!([agent])
    transcript = transcript!(ctx)

    {:ok, %{left_at: %DateTime{}}} = Meetings.participant_left(ctx.room, agent.name)

    :ok = PlatformWeb.Endpoint.subscribe(brain_topic)

    assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment())

    refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: @event}, 300
  end

  test "a non-final segment is persisted but not delivered" do
    owner = user!()
    %{agent: agent, brain_topic: brain_topic} = agent_with_brain!(owner)
    ctx = seated_room!([agent])
    transcript = transcript!(ctx)

    :ok = PlatformWeb.Endpoint.subscribe(brain_topic)

    assert {:ok, %Transcript{}} =
             Meetings.append_segment(
               transcript.id,
               segment(%{"final" => false, "text" => "interim"})
             )

    assert [%{"text" => "interim", "final" => false}] =
             Meetings.get_transcript(transcript.id).segments

    refute_receive %Phoenix.Socket.Broadcast{topic: ^brain_topic, event: @event}, 300
  end

  test "an agent with no runtime is skipped and the append still succeeds" do
    agent = agent!()
    assert is_nil(agent.runtime_id)
    ctx = seated_room!([agent])
    transcript = transcript!(ctx)
    agent_id = agent.id

    assert {:ok, %Transcript{} = updated} = Meetings.append_segment(transcript.id, segment())
    assert [stored] = updated.segments

    assert {:ok, %{delivered: [], skipped: [{^agent_id, :no_runtime}]}} =
             Meetings.deliver_transcript_segment(updated, stored)
  end

  # Task 01a06d01 stage 2 — the discriminating case for `RuntimePresence.proven`.
  #
  # The client here DECLARES `meeting_transcript` in `client_info.features`
  # and core successfully broadcasts a transcript frame to it. Neither of
  # those is evidence: the declaration is a claim by the process under
  # suspicion, and the broadcast is a frame core SENT. Whether the plugin on
  # the far end has the listener at all (added in `63229eb`; the commit
  # before it drops the frame in silence, with a byte-identical
  # `client_info`) is unobservable from this side, so the proof must stay
  # absent and the cell must read `never`.
  #
  # This is the assertion that kills the tempting "just prove it at the
  # broadcast" change, which would report every connected runtime as able to
  # hear meetings — the exact inversion this mechanism exists to remove.
  test "delivering a transcript records NO proof, even when the client declared the feature" do
    owner = user!()
    %{agent: agent, runtime: brain, raw_token: raw_token} = brain!(owner, agent!())
    _client = join_client!(brain, raw_token, ["system_event_prompt", "meeting_transcript"])

    ctx = seated_room!([agent])
    transcript = transcript!(ctx)
    topic = IntentRuntimeAdapter.runtime_topic(brain.runtime_id)
    :ok = PlatformWeb.Endpoint.subscribe(topic)

    assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment())

    # The frame really did go out — without this the absence below would hold
    # for the boring reason that nothing happened at all.
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: @event}, 500

    proven = Platform.Federation.RuntimePresence.status(brain.runtime_id).proven

    refute Map.has_key?(proven, "meeting_transcript")
    assert proven == %{}
  end
end
