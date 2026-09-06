defmodule Platform.Meetings.SayTelemetryTest do
  @moduledoc """
  Task 01a07400 stage 1 — the `meeting_say` telemetry trace and its Audit
  sink.

  This stage only OBSERVES. Nothing asserted here should be readable as a
  behaviour change: `say/4` returns what it returned, a `"failed"` ack still
  posts nothing, and the ack timing is untouched.

  ## What each block is defending

  **The literal status.** The ack event's `status` metadata must be the
  string the runtime sent, carried through, not a value this codebase
  re-derived from the same branch that decides whether to post. The named
  mutation for that is: hardcode `"spoken"` in the emit in
  `record_agent_say_ack/2`. `relays the runtime's literal status` and
  `relays an unrecognised status verbatim` must both go RED. A test that
  stays green under that mutation is reading the wrong source.

  **The latency floor.** `latency_ms >= 0` is satisfied by any wrong value
  sitting in the noise floor — a sibling stage shipped an assertion that
  passed on the exact bug it was written for, because the wrong number was
  1.4 ms from the right one. So the ack here is deliberately delayed by
  150 ms and the assertion is a floor at 100 ms, well above scheduler noise. The
  `Process.sleep/1` is not a synchronisation wait (which the house rules
  forbid); the elapsed time IS the quantity under test, and there is no way
  to make real wall-clock elapse without letting it elapse.

  **The subscribe/emit order.** `say/4` subscribes to
  `"meetings:say:<utterance_id>"` before it broadcasts, and the dispatch
  emit sits between the two. `meetings.ex` says in prose that no test
  reliably catches an inverted subscribe — true of the SUBSCRIBE vs the
  BROADCAST, which race in different processes. The emit is different: it
  runs synchronously in `say/4`'s own process, so a handler that answers
  the ack topic from inside the emit proves the subscription was already
  live at that instant. Move the emit above the subscribe and
  `the dispatch emit happens after the ack subscription is live` returns
  `no_ack`.

  `async: false` — LiveKit lives in app env, `SayRegistry` is a single named
  ETS table, and `:telemetry` handlers are VM-global.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.SayRegistry
  alias Platform.Meetings.SayTelemetry
  alias Platform.Repo

  @dispatch [:platform, :meetings, :say, :dispatch]
  @ack [:platform, :meetings, :say, :ack]
  @posted [:platform, :meetings, :say, :posted]

  # How long the delayed-ack test parks before acking, and the floor the
  # measured latency has to clear. The gap between them absorbs scheduler
  # jitter; the floor is two orders of magnitude above it.
  @seeded_delay_ms 150
  @latency_floor_ms 100

  # ── Fixtures (same shape as MeetingSayTest) ──────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "say-telemetry-#{n}@example.com",
      name: "Say Telemetry #{n}",
      oidc_sub: "oidc-say-telemetry-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "say-tel-agent-#{n}",
      name: "Say Telemetry Agent #{n}",
      status: "active"
    })
  end

  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "say-tel-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Say Telemetry Space #{n}",
        slug: "say-tel-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp seated_agent! do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    %{agent: agent, runtime: runtime} = agent_with_runtime!()

    {:ok, _row} = Chat.add_agent_participant(space.id, agent)

    {:ok, _participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{space: space, room: room, agent: agent, room_name: room.livekit_room_name}
  end

  # ── Telemetry capture ────────────────────────────────────────────────────

  # Forwards every say event to the test process. Detached on exit so a
  # failure cannot leak a handler into the rest of the run.
  defp capture_say_events! do
    test_pid = self()
    handler_id = "say-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        SayTelemetry.events(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:say_event, event, measurements, metadata})
        end,
        %{}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
    capture_say_events!()

    :ok
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────

  describe "[:platform, :meetings, :say, :dispatch]" do
    test "fires once per accepted say, carrying utterance_id, agent_id and room_name" do
      %{agent: agent, room_name: room_name} = seated_agent!()

      assert {:ok, %{utterance_id: id}} =
               Meetings.say(agent, room_name, "hello", ack_timeout_ms: 50)

      assert_receive {:say_event, @dispatch, _measurements, metadata}
      assert metadata.utterance_id == id
      assert metadata.agent_id == agent.id
      assert metadata.room_name == room_name

      refute_receive {:say_event, @dispatch, _m, _md}
    end

    test "does not fire for a say that was refused before the broadcast" do
      %{agent: agent} = agent_with_runtime!()

      assert {:error, :room_not_found} = Meetings.say(agent, "no-such-room", "hello")

      refute_receive {:say_event, @dispatch, _m, _md}
    end

    # The ordering guard. The handler answers the ack topic from INSIDE the
    # dispatch emit, which runs synchronously in `say/4`'s process. If the
    # subscription is already live at that point the ack lands in the
    # caller's own mailbox and the rendezvous completes; if the emit were
    # moved above the subscribe, nothing is listening and this returns
    # no_ack.
    test "the dispatch emit happens after the ack subscription is live" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      handler_id = "say-telemetry-order-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          SayTelemetry.dispatch_event(),
          fn _event, _measurements, metadata, _config ->
            Phoenix.PubSub.broadcast(
              Platform.PubSub,
              "meetings:say:#{metadata.utterance_id}",
              {:meeting_say_ack, metadata.utterance_id,
               %{status: "spoken", duration_s: nil, error: nil, room_name: metadata.room_name}}
            )
          end,
          %{}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{status: "spoken"}} =
               Meetings.say(agent, room_name, "hello", ack_timeout_ms: 200)
    end
  end

  # ── Ack ──────────────────────────────────────────────────────────────────

  describe "[:platform, :meetings, :say, :ack]" do
    # THE NAMED MUTATION. Hardcode `"spoken"` in the emit in
    # `record_agent_say_ack/2` and this must fail. "failed" is the string
    # this test itself put into the payload — it is not re-derived from the
    # function under test, and `record_agent_say_ack/2` returns `:ok`
    # either way, so there is no other route by which it could show up here.
    test "relays the runtime's literal status" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => utterance_id,
                 "room_name" => room_name,
                 "status" => "failed",
                 "error" => "tts_unavailable"
               })

      assert_receive {:say_event, @ack, _measurements, metadata}
      assert metadata.status == "failed"
      assert metadata.utterance_id == utterance_id
      assert metadata.agent_id == agent.id
      assert metadata.room_name == room_name
    end

    test "relays an unrecognised status verbatim rather than bucketing it" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "half-spoken-then-cut"
      })

      assert_receive {:say_event, @ack, _measurements, metadata}
      assert metadata.status == "half-spoken-then-cut"
    end

    test "an absent status is relayed as the literal \"unknown\"" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name
      })

      assert_receive {:say_event, @ack, _measurements, metadata}
      assert metadata.status == "unknown"
    end

    test "carries the runtime's duration_s as a measurement" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "failed",
        "duration_s" => 1.25
      })

      assert_receive {:say_event, @ack, measurements, _metadata}
      assert measurements.duration_s == 1.25
    end

    # THE LATENCY FLOOR. A deliberately delayed ack, and an assertion that
    # the reported latency clears a floor two orders of magnitude above
    # scheduler noise. `latency_ms > 0` would be satisfied by a value
    # measured from the wrong instant; #{@latency_floor_ms} ms is not.
    test "latency_ms measures dispatch-to-ack, not something inside the noise floor" do
      %{space: space, room: room, agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = Platform.Types.UUIDv7.generate()

      # Seeded directly so the dispatch instant is the one this test
      # controls; `put/2` stamps `inserted_at_ms` exactly as `say/4` does.
      SayRegistry.put(utterance_id, %{
        text: "hello",
        room_id: room.id,
        room_name: room_name,
        space_id: space.id,
        agent_id: agent.id
      })

      # Not a synchronisation wait: the elapsed time IS the measurement
      # under test, so it has to actually elapse.
      Process.sleep(@seeded_delay_ms)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "failed"
      })

      assert_receive {:say_event, @ack, measurements, _metadata}
      assert is_integer(measurements.latency_ms)

      assert measurements.latency_ms >= @latency_floor_ms,
             "latency_ms was #{measurements.latency_ms}, under the #{@latency_floor_ms}ms " <>
               "floor for an ack seeded #{@seeded_delay_ms}ms after dispatch — it is being " <>
               "measured from the wrong instant"
    end

    test "omits latency_ms for an ack whose utterance was never dispatched here" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      unknown_id = Platform.Types.UUIDv7.generate()

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => unknown_id,
        "room_name" => room_name,
        "status" => "failed"
      })

      assert_receive {:say_event, @ack, measurements, metadata}
      refute Map.has_key?(measurements, :latency_ms)
      assert metadata.utterance_id == unknown_id
    end
  end

  # ── Posted ───────────────────────────────────────────────────────────────

  describe "[:platform, :meetings, :say, :posted]" do
    test "fires when the dispatched text reaches the room's space" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "spoken"
      })

      assert_receive {:say_event, @posted, _measurements, metadata}
      assert metadata.utterance_id == utterance_id
      assert metadata.agent_id == agent.id
      assert metadata.room_name == room_name
    end

    test "does not fire for a failed ack, which posts nothing" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "failed"
      })

      assert_receive {:say_event, @ack, _m, _md}
      refute_receive {:say_event, @posted, _m2, _md2}
    end

    # A "spoken" ack from an agent other than the speaker posts nothing, so
    # it must not emit `:posted` either — otherwise the audit log says a
    # forged ack put text in a room.
    test "does not fire for a spoken ack from an agent other than the speaker" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()
      other = agent!()
      {:ok, _row} = Chat.add_agent_participant(space.id, other)

      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(other.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "spoken"
      })

      assert_receive {:say_event, @ack, _m, _md}
      refute_receive {:say_event, @posted, _m2, _md2}
    end
  end

  # ── The Audit sink ───────────────────────────────────────────────────────

  describe "the Audit event log" do
    test "all three events are registered with Platform.Audit.TelemetryHandler" do
      registered = Platform.Audit.TelemetryHandler.events()

      for event <- SayTelemetry.events() do
        assert event in registered,
               "#{inspect(event)} is not registered in Platform.Audit.TelemetryHandler's " <>
                 "@events — the emit would fail silently and no audit row would ever appear"
      end
    end

    test "a dispatch, a spoken ack and the post each land as an audit row" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "spoken",
        "duration_s" => 2.5
      })

      assert_receive {:say_event, @posted, _m, _md}

      rows = Audit.list(resource_id: utterance_id)
      by_type = Map.new(rows, &{&1.event_type, &1})

      assert Map.keys(by_type) |> Enum.sort() == [
               "platform.meetings.say.ack",
               "platform.meetings.say.dispatch",
               "platform.meetings.say.posted"
             ]

      for {_type, row} <- by_type do
        assert row.actor_type == "agent"
        assert row.actor_id == agent.id
        assert row.resource_type == "meeting_utterance"
        assert row.metadata["utterance_id"] == utterance_id
        assert row.metadata["agent_id"] == agent.id
        assert row.metadata["room_name"] == room_name
      end

      assert by_type["platform.meetings.say.dispatch"].action == "dispatch"
      assert by_type["platform.meetings.say.ack"].action == "ack"
      assert by_type["platform.meetings.say.posted"].action == "posted"

      ack_row = by_type["platform.meetings.say.ack"]
      assert ack_row.metadata["status"] == "spoken"
      assert ack_row.metadata["duration_s"] == 2.5
      assert is_integer(ack_row.metadata["latency_ms"])
    end

    test "the ack row records a failed status as failed" do
      %{agent: agent, room_name: room_name} = seated_agent!()
      utterance_id = dispatch_and_take_id!(agent, room_name)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "failed",
        "error" => "tts_unavailable"
      })

      assert_receive {:say_event, @ack, _m, _md}

      assert [row] =
               Audit.list(resource_id: utterance_id, event_type: "platform.meetings.say.ack")

      assert row.metadata["status"] == "failed"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Runs one say to completion of the DISPATCH half only (nothing acks, so
  # it returns no_ack after a short window), and hands back the utterance
  # id the registry now holds. Everything the ack tests need is in place:
  # a real registry row stamped at dispatch, and a real roster.
  defp dispatch_and_take_id!(agent, room_name) do
    assert {:ok, %{status: "no_ack", utterance_id: utterance_id}} =
             Meetings.say(agent, room_name, "hello", ack_timeout_ms: 20)

    assert_receive {:say_event, @dispatch, _measurements, %{utterance_id: ^utterance_id}}

    utterance_id
  end
end
