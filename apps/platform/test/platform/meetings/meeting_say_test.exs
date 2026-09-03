defmodule Platform.Meetings.MeetingSayTest do
  @moduledoc """
  Task 01a06672 stage 1 — `Platform.Meetings.say/4` and its ack rendezvous.

  ## What each block is for

  The happy path drives the whole rendezvous from both ends: the test is the
  runtime (subscribed to the agent's runtime topic, answering with
  `record_agent_say_ack/2`) and the caller (a `Task` blocked in `say/4`).
  The refusal blocks assert the two things a refusal must do together —
  return the named error AND broadcast nothing — because a guard that
  returns an error after the voice has already gone out is not a guard.

  The forged-ack test is the reason `SayRegistry` exists: an ack from an
  agent other than the one that spoke must not put text into chat under the
  speaker's name.

  `async: false` — LiveKit lives in app env, and `SayRegistry` is a single
  named ETS table.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting-say-#{n}@example.com",
      name: "Meeting Say #{n}",
      oidc_sub: "oidc-meeting-say-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "say-agent-#{n}",
      name: "Say Agent #{n}",
      status: "active"
    })
  end

  # An agent with a live, activated, LINKED runtime, so `meeting_join_topic/1`
  # resolves. Same shape as `MeetingJoinDispatchTopicTest`.
  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "say-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Say Space #{n}",
        slug: "say-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp room! do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    %{space: space, room: room}
  end

  # Chat membership, so `authorize_writer/2` admits the agent when the
  # spoken text is posted. Deliberately separate from the roster row: the
  # non-participant test below gives an agent THIS and not the roster row,
  # to prove space membership alone does not license speech.
  #
  # Idempotent on purpose: `Federation.link_agent/2` already auto-rosters a
  # federated agent into every channel space, so for a runtime-linked agent
  # this is a no-op and for a plain `agent!/0` it is the insert.
  defp add_agent_to_space!(space, agent) do
    {:ok, _row} = Chat.add_agent_participant(space.id, agent)
    :ok
  end

  # The roster row `invite_agent/3` writes — the thing `say/4` guards on.
  defp seat_agent!(room, agent) do
    {:ok, participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    participant
  end

  defp seated_agent! do
    %{space: space, room: room} = room!()
    %{agent: agent, runtime: runtime} = agent_with_runtime!()
    add_agent_to_space!(space, agent)
    seat_agent!(room, agent)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{space: space, room: room, agent: agent, runtime: runtime, room_name: room.livekit_room_name}
  end

  defp say_messages(space_id) do
    Repo.all(
      from(m in Message,
        where:
          m.space_id == ^space_id and fragment("?->>'source' = ?", m.metadata, "meetings.say")
      )
    )
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

  # ── The rendezvous ───────────────────────────────────────────────────────

  describe "say/4 with a seated agent" do
    test "broadcasts meeting_say, returns the spoken ack, and posts the text to chat" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "hello", ack_timeout_ms: 2_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id, text: "hello", token: token} = payload
                     },
                     1_000

      assert [_header, _claims, _sig] = String.split(token, ".")
      assert payload.room_name == room_name
      assert payload.agent_identity == "agent:" <> agent.slug
      assert payload.space_id == space.id
      assert payload.livekit_url == "wss://livekit.test"

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 1.2
               })

      assert {:ok, %{status: "spoken", utterance_id: ^id, duration_s: 1.2}} = Task.await(task)

      assert [%Message{content: "hello", metadata: metadata}] = say_messages(space.id)
      assert metadata["utterance_id"] == id
      assert metadata["room_name"] == room_name
    end

    test "returns no_ack when nothing answers, and posts nothing" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()

      assert {:ok, %{status: "no_ack", utterance_id: id, room_name: ^room_name}} =
               Meetings.say(agent, room_name, "anyone there", ack_timeout_ms: 200)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "meeting_say",
        payload: %{utterance_id: ^id}
      }

      assert say_messages(space.id) == []
    end

    test "a failed ack is returned as failed and posts nothing" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "hello", ack_timeout_ms: 2_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => id,
        "room_name" => room_name,
        "status" => "failed",
        "error" => "tts_unavailable"
      })

      assert {:ok, %{status: "failed", error: "tts_unavailable", utterance_id: ^id}} =
               Task.await(task)

      assert say_messages(space.id) == []
    end

    test "exactly max chars is accepted" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      text = String.duplicate("a", Meetings.meeting_say_max_chars())

      assert {:ok, _} = Meetings.say(agent, room_name, text, ack_timeout_ms: 100)
      assert_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}
    end
  end

  # ── The forged ack ───────────────────────────────────────────────────────

  describe "record_agent_say_ack/2 from an agent other than the speaker" do
    test "relays nothing to chat" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      other = agent!()
      add_agent_to_space!(space, other)

      task = Task.async(fn -> Meetings.say(agent, room_name, "hello", ack_timeout_ms: 2_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      # The forged ack still reaches the waiting caller (it is a receipt
      # on the id), but the text must not be posted under either name.
      Meetings.record_agent_say_ack(other.id, %{
        "utterance_id" => id,
        "room_name" => room_name,
        "status" => "spoken"
      })

      assert {:ok, %{utterance_id: ^id}} = Task.await(task)
      assert say_messages(space.id) == []
    end

    test "an ack for an id that was never dispatched posts nothing" do
      %{space: space, agent: agent} = seated_agent!()

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => Platform.Types.UUIDv7.generate(),
                 "room_name" => "space-nope",
                 "status" => "spoken"
               })

      assert say_messages(space.id) == []
    end
  end

  # ── Refusals: the named error AND no broadcast ───────────────────────────

  describe "the participant guard" do
    test "an agent in the space but not in the call is refused" do
      %{space: space, room: room} = room!()
      %{agent: agent, runtime: runtime} = agent_with_runtime!()
      add_agent_to_space!(space, agent)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      assert [] =
               Repo.all(
                 from(p in MeetingParticipant,
                   where: p.room_id == ^room.id and p.agent_id == ^agent.id
                 )
               )

      assert {:error, :not_in_room} = Meetings.say(agent, room.livekit_room_name, "hello")
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "an agent that has left the call is refused" do
      %{space: space, room: room} = room!()
      %{agent: agent, runtime: runtime} = agent_with_runtime!()
      add_agent_to_space!(space, agent)
      seat_agent!(room, agent)

      {:ok, %MeetingParticipant{left_at: %DateTime{}}} =
        Meetings.participant_left(room, agent.name)

      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      assert {:error, :not_in_room} = Meetings.say(agent, room.livekit_room_name, "hello")
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end
  end

  describe "text validation" do
    test "blank text is refused before anything is looked up" do
      %{agent: agent, room_name: room_name} = seated_agent!()

      assert {:error, :empty_text} = Meetings.say(agent, room_name, "   ")
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "one character over the cap is refused, naming the cap" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      max = Meetings.meeting_say_max_chars()
      assert max == 2_000

      assert {:error, {:text_too_long, 2_000}} =
               Meetings.say(agent, room_name, String.duplicate("a", max + 1))

      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end
  end

  describe "an unknown room" do
    test "is refused" do
      %{agent: agent, runtime: runtime} = agent_with_runtime!()
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      assert {:error, :room_not_found} = Meetings.say(agent, "space-does-not-exist", "hello")
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end
  end
end
