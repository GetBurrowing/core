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

  The forged-ack tests are the reason `SayRegistry` exists: an ack from an
  agent other than the one that spoke must not put text into chat under the
  speaker's name, and (task 01a066af stage 2) must not satisfy the speaker's
  waiting `say/4` either. The two halves are asserted separately because
  they used to disagree: the write was guarded and the relay was not.

  The ack-window block (task 01a066af stage 3) is the one that fails if the
  window ever goes back to being a constant. A short-utterance test alone
  was the vacuous one that let a hard ~190-character ceiling on agent
  speech ship, so the contrast is asserted deliberately: pin the window to
  the floor for every length and the long-utterance tests go red while
  `a short utterance is unchanged` stays green.

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

  # ── The ack window (task 01a066af stage 3) ───────────────────────────────
  #
  # The worker acks only after playback ENDS, so a fixed window was a
  # ceiling on how long an agent could speak before `say/4` reported
  # `no_ack` for something the room heard perfectly. Live, 2026-09-08: five
  # short utterances all `spoken`; two ~700-character ones, ~45 s of speech
  # each, both `no_ack` against a 15 s window.
  #
  # The arithmetic is asserted through the pure function, so nothing here
  # waits on a real window. The one test that drives `say/4` end to end
  # shrinks BOTH seams so the whole thing runs in well under a second.

  # Both seams are unset in config, so a test that wants the module
  # defaults has to make sure no earlier test left one behind.
  defp put_ack_env(floor_ms, ms_per_char) do
    original = {
      Application.fetch_env(:platform, :meeting_say_ack_timeout_ms),
      Application.fetch_env(:platform, :meeting_say_ack_ms_per_char)
    }

    set = fn
      _key, nil -> :ok
      key, value -> Application.put_env(:platform, key, value)
    end

    Application.delete_env(:platform, :meeting_say_ack_timeout_ms)
    Application.delete_env(:platform, :meeting_say_ack_ms_per_char)
    set.(:meeting_say_ack_timeout_ms, floor_ms)
    set.(:meeting_say_ack_ms_per_char, ms_per_char)

    on_exit(fn ->
      {floor_env, rate_env} = original

      restore = fn
        key, {:ok, value} -> Application.put_env(:platform, key, value)
        key, :error -> Application.delete_env(:platform, key)
      end

      restore.(:meeting_say_ack_timeout_ms, floor_env)
      restore.(:meeting_say_ack_ms_per_char, rate_env)
    end)
  end

  describe "the ack window" do
    test "the ack window scales past fifteen seconds for a long utterance" do
      put_ack_env(nil, nil)

      long = String.duplicate("a", Meetings.meeting_say_max_chars())

      window = Meetings.say_ack_timeout_for(long)

      # The whole point: it is no longer the constant.
      assert window > 15_000

      # And it is not merely bigger — it covers the audio. Speech runs
      # ~15.5 characters a second by both the module's own "2,000 chars is
      # roughly two minutes" note and the 2026-09-08 live data.
      audio_ms = round(Meetings.meeting_say_max_chars() / 15.5 * 1_000)
      assert window >= audio_ms

      # The floor is a floor, not an addend: anything short enough to have
      # worked before waits exactly as long as it did before.
      assert Meetings.say_ack_timeout_for(String.duplicate("a", 10)) == 15_000
    end

    test "a long utterance acked after the old fixed window still reports spoken" do
      # 200 ms floor and 1 ms per character stand in for 15_000 and 80, so
      # 900 characters buys a 900 ms window — the same shape as 700
      # characters buying 56 s in production, in a thousandth of the time.
      put_ack_env(200, 1)

      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      long = String.duplicate("a", 900)

      assert Meetings.say_ack_timeout_for(long) == 900

      started = System.monotonic_time(:millisecond)
      task = Task.async(fn -> Meetings.say(agent, room_name, long) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      # Deliberate: the ack lands after the 200 ms the old fixed window
      # would have allowed, and before the 900 ms this text earns. A
      # `Process.monitor` cannot express "later than X", which is the
      # whole assertion.
      Process.sleep(500)

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 0.9
               })

      assert {:ok, %{status: "spoken", utterance_id: ^id}} = Task.await(task)
      assert [%Message{content: ^long}] = say_messages(space.id)

      # The suite must not pay 15 seconds to learn this.
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "an explicit ack_timeout_ms is not scaled" do
      put_ack_env(nil, nil)

      %{agent: agent, room_name: room_name} = seated_agent!()
      long = String.duplicate("a", Meetings.meeting_say_max_chars())

      # Scaling would give this text over a hundred seconds...
      assert Meetings.say_ack_timeout_for(long) > 100_000

      # ...and the option must ignore that entirely, or every existing
      # test that shortens the wait starts waiting again.
      {elapsed_us, result} =
        :timer.tc(fn -> Meetings.say(agent, room_name, long, ack_timeout_ms: 200) end)

      assert {:ok, %{status: "no_ack"}} = result
      assert div(elapsed_us, 1_000) < 2_000
    end

    test "the app-env ack timeout alone still pins the window, whatever the length" do
      # The other half of the guard. `:meeting_say_ack_timeout_ms` set on
      # its own means what it has always meant — a fixed window — because
      # that is what the tool-surface and budget suites use to avoid a real
      # 15-second wait. Scaling comes back only with a rate beside it.
      put_ack_env(200, nil)

      %{agent: agent, room_name: room_name} = seated_agent!()
      long = String.duplicate("a", Meetings.meeting_say_max_chars())

      assert Meetings.say_ack_timeout_for(long) == 200

      {elapsed_us, result} = :timer.tc(fn -> Meetings.say(agent, room_name, long) end)

      assert {:ok, %{status: "no_ack"}} = result
      assert div(elapsed_us, 1_000) < 2_000
    end

    test "a short utterance is unchanged" do
      put_ack_env(nil, nil)

      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      short = "twenty characters ok"

      assert String.length(short) == 20
      assert Meetings.say_ack_timeout_for(short) == 15_000

      task = Task.async(fn -> Meetings.say(agent, room_name, short) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id, text: ^short}
                     },
                     1_000

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 1.3
               })

      assert {:ok, %{status: "spoken", utterance_id: ^id}} = Task.await(task)
      assert [%Message{content: ^short}] = say_messages(space.id)
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

      # This block asserts the WRITE guard only — nothing lands in chat
      # under either name. What the forged ack does (or no longer does) to
      # the waiting caller is asserted in the block below.
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

  # ── The waiter's view of a forged ack (task 01a066af stage 2) ────────────

  describe "record_agent_say_ack/2 and the waiting say/4" do
    # THE NAMED MUTATION for this stage: move the `Phoenix.PubSub.broadcast`
    # in `record_agent_say_ack/2` back above the `SayRegistry.get` that
    # gates it, so the relay is unconditional again. This test must go RED
    # (the waiter gets "spoken") while the two below stay GREEN.
    test "a spoken ack from another agent does not satisfy the waiter" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      other = agent!()
      add_agent_to_space!(space, other)

      task =
        Task.async(fn ->
          Meetings.say(agent, room_name, "mine to say", ack_timeout_ms: 2_000)
        end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      assert :ok =
               Meetings.record_agent_say_ack(other.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 3.4
               })

      # The whole point: the speaking agent is told core does not know,
      # which is true, rather than "spoken", which is not.
      assert {:ok, %{status: "no_ack", utterance_id: ^id}} = Task.await(task, 5_000)
      assert say_messages(space.id) == []
    end

    test "the owning agent's ack still satisfies the waiter" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      other = agent!()
      add_agent_to_space!(space, other)

      task =
        Task.async(fn ->
          Meetings.say(agent, room_name, "mine to say", ack_timeout_ms: 2_000)
        end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 # A runtime echoing text back. It is ignored: the row is
                 # written from what core dispatched, never from the ack.
                 "text" => "something else entirely"
               })

      assert {:ok, %{status: "spoken", utterance_id: ^id}} = Task.await(task, 5_000)
      assert [%Message{content: "mine to say"}] = say_messages(space.id)
    end

    # The registry-miss carve-out, pinned so a later refactor cannot quietly
    # fold it into the refusal branch above. A miss has no owner to compare
    # against, and this is the path a late ack inside the 5-minute ttl and
    # the `no_ack` case both run through.
    test "an ack for an unknown utterance id still reaches the waiter" do
      %{space: space, agent: agent} = seated_agent!()
      unknown_id = Platform.Types.UUIDv7.generate()

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meetings:say:#{unknown_id}")

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => unknown_id,
                 "room_name" => "space-never-dispatched",
                 "status" => "spoken"
               })

      assert_receive {:meeting_say_ack, ^unknown_id, %{status: "spoken"}}, 1_000
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
