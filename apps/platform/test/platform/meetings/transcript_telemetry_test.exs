defmodule Platform.Meetings.TranscriptTelemetryTest do
  @moduledoc """
  Task 01a07400 stage 2 — the inbound half of a meeting turn: a transcript
  frame going out to an agent (`[:platform, :meetings, :transcript,
  :delivered]`), and that agent's first say afterwards
  (`[:platform, :meetings, :agent, :responded]`).

  Stage 1 traced one utterance from dispatch to posted. These two events sit
  in front of it, so `response_ms` is FRAME DELIVERY TO SAY DISPATCH — not a
  first-token time, which core cannot see at all. Nothing in this file should
  be readable as a claim about what the model did; every assertion is about
  two instants core observed itself.

  ## What each block is defending

  **One emit per recipient.** `deliver_transcript_segment/2` fans one segment
  out to a roster. The event is per AGENT, not per segment, and the speaker
  is excluded from its own speech — so the room's two agents give two
  different answers to "did you hear that".

  **Magnitude, not sign.** Both measurements are asserted against a floor
  hundreds of milliseconds clear of zero, seeded by a gap the test controls.
  `lag_ms > 0` and `response_ms > 0` are satisfied by a value measured from
  the WRONG instant — a sibling stage shipped exactly that assertion and it
  passed on the bug it was written to catch, 1.4 ms out. So `lag_ms` is
  seeded from a `spoken_at` three seconds in the past and floored at 2000 ms,
  and `response_ms` from a 300 ms park and floored at 250 ms. The smallest
  wrong value that still satisfies either floor is not a value any plausible
  bug produces; measuring from `now` gives ~0 and detonates.

  **The frame-precedence check — THE NAMED MUTATION.** An agent that says
  something with NO preceding delivered frame must produce no `response_ms`
  at all. Delete the `nil ->` clause in `TranscriptTelemetry.responded/3` (or
  give it a fallback instant to measure from) and
  `a say with no preceding delivered frame is not a response` goes RED.
  A fabricated latency in the record is worse than no latency.

  **The correlation key, with a fixture that would show the wrong one.**
  The room holds TWO agents and only ONE of them is ever given a frame: agent
  A speaks, so the frame goes to B alone. A correlation that keyed on
  `meeting_id` and ignored `agent_id` would hand A the frame that was
  delivered to B — visibly wrong, and caught twice over, because B is then
  asked for its own response and must still have the mark A did not take.

  `async: false` — LiveKit lives in app env, `SayRegistry`'s tables are named
  and process-wide, and `:telemetry` handlers are VM-global.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.SayRegistry
  alias Platform.Meetings.TranscriptTelemetry
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @delivered [:platform, :meetings, :transcript, :delivered]
  @responded [:platform, :meetings, :agent, :responded]

  # The seeded gaps and the floors they have to clear. Each floor sits an
  # order of magnitude above scheduler jitter and well below the gap, so the
  # only way to fail one is to measure from a different instant.
  @seeded_spoken_at_age_s 3
  @lag_floor_ms 2_000
  @seeded_response_delay_ms 300
  @response_floor_ms 250

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "transcript-telemetry-#{n}@example.com",
      name: "Transcript Telemetry #{n}",
      oidc_sub: "oidc-transcript-telemetry-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "tt-agent-#{n}",
      name: "Transcript Telemetry Agent #{n}",
      status: "active"
    })
  end

  # A brain runtime linked through `link_agent/2`, which is all
  # `IntentRuntimeAdapter.resolve_target/1` reads.
  defp agent_with_runtime!(owner) do
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "tt-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    agent
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Transcript Telemetry Space #{n}",
        slug: "tt-space-#{n}",
        kind: "channel"
      })

    space
  end

  # A live `meetings` row, so `transcript_frame_payload/2`'s `:meeting_id`
  # resolves. Without it the frame is still emitted but has no
  # `{meeting_id, agent_id}` key to be filed under, so nothing can answer it
  # — the case `a frame in a room with no live meeting` pins deliberately.
  defp live_meeting!(space, room) do
    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "TT Project #{System.unique_integer([:positive])}",
        slug: "tt-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, meeting} =
      %Meeting{id: Platform.Types.UUIDv7.generate()}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "tt-meeting-#{System.unique_integer([:positive])}",
        name: "Transcript Telemetry Meeting",
        livekit_room_name: room.livekit_room_name,
        status: "live"
      })
      |> Repo.insert()

    meeting
  end

  # A room with `agent_count` agents seated, a transcript, and (unless
  # `meeting: false`) a live meeting row.
  defp room!(agent_count, opts \\ []) do
    owner = user!()
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    agents =
      for _ <- 1..agent_count do
        agent = agent_with_runtime!(owner)
        {:ok, _row} = Chat.add_agent_participant(space.id, agent)

        {:ok, _participant} =
          Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

        agent
      end

    meeting =
      if Keyword.get(opts, :meeting, true) do
        live_meeting!(space, room)
      end

    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room.livekit_room_name, space_id: space.id})

    %{
      space: space,
      room: room,
      room_name: room.livekit_room_name,
      transcript: transcript,
      meeting: meeting,
      agents: agents
    }
  end

  defp segment(overrides) do
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

  defp append!(ctx, overrides \\ %{}) do
    assert {:ok, %Transcript{}} =
             Meetings.append_segment(ctx.transcript.id, segment(overrides))

    :ok
  end

  # ── Telemetry capture ────────────────────────────────────────────────────

  defp capture_events! do
    test_pid = self()
    handler_id = "transcript-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        TranscriptTelemetry.events(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:tt_event, event, measurements, metadata})
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
    capture_events!()

    :ok
  end

  # ── Delivered ────────────────────────────────────────────────────────────

  describe "[:platform, :meetings, :transcript, :delivered]" do
    test "fires once per recipient agent, carrying agent_id, meeting_id and segment_id" do
      ctx = room!(2)
      [a, b] = ctx.agents

      :ok = append!(ctx)

      assert_receive {:tt_event, @delivered, _m1, first}
      assert_receive {:tt_event, @delivered, _m2, second}
      refute_receive {:tt_event, @delivered, _m3, _md3}

      # Per RECIPIENT, not per segment: two agents, two events, one segment.
      assert Enum.sort([first.agent_id, second.agent_id]) == Enum.sort([a.id, b.id])
      assert first.segment_id == second.segment_id
      assert is_binary(first.segment_id)

      for metadata <- [first, second] do
        assert metadata.meeting_id == ctx.meeting.id
      end

      # The frame's own id, not a second derivation of it.
      stored = Meetings.get_transcript(ctx.transcript.id)
      assert [%{"id" => stored_id}] = stored.segments
      assert first.segment_id == stored_id
    end

    test "does not fire for the agent whose own speech the segment is" do
      ctx = room!(2)
      [a, b] = ctx.agents

      :ok = append!(ctx, %{"participant_identity" => "agent:#{a.slug}", "speaker_name" => a.name})

      assert_receive {:tt_event, @delivered, _m, metadata}
      assert metadata.agent_id == b.id
      refute metadata.agent_id == a.id

      # The speaker hears nothing: one agent seated, one event, and it is B's.
      refute_receive {:tt_event, @delivered, _m2, _md2}
    end

    test "does not fire for an interim segment, which is stored and never delivered" do
      ctx = room!(1)

      :ok = append!(ctx, %{"final" => false})

      refute_receive {:tt_event, @delivered, _m, _md}
    end

    # THE LAG FLOOR. `spoken_at` is seeded #{@seeded_spoken_at_age_s} s in the
    # past, so a `lag_ms` measured from the segment's own timestamp is ~3000
    # and one measured from `now` (the plausible bug — the payload defaults
    # `spoken_at` to `utc_now` when the transcriber omits it) is ~0. The
    # floor sits between them with two orders of magnitude to spare, which
    # `lag_ms > 0` would not have.
    test "lag_ms measures speech-end to delivery, not something inside the noise floor" do
      ctx = room!(1)

      spoken_at =
        DateTime.utc_now()
        |> DateTime.add(-@seeded_spoken_at_age_s, :second)
        |> DateTime.to_iso8601()

      :ok = append!(ctx, %{"spoken_at" => spoken_at})

      assert_receive {:tt_event, @delivered, measurements, _metadata}
      assert is_integer(measurements.lag_ms)

      assert measurements.lag_ms >= @lag_floor_ms,
             "lag_ms was #{measurements.lag_ms}, under the #{@lag_floor_ms}ms floor for a " <>
               "segment spoken #{@seeded_spoken_at_age_s}s before it was delivered — it is " <>
               "being measured from the wrong instant"
    end

    test "omits lag_ms entirely when spoken_at is not a timestamp" do
      ctx = room!(1)

      :ok = append!(ctx, %{"spoken_at" => "half past whenever"})

      assert_receive {:tt_event, @delivered, measurements, _metadata}

      # Omitted, not nil: the audit handler stringifies atoms, so a nil
      # measurement would persist as the string "nil". Stage 1's convention.
      refute Map.has_key?(measurements, :lag_ms)
    end

    test "fires for a room with no live meeting, with a nil meeting_id" do
      ctx = room!(1, meeting: false)

      :ok = append!(ctx)

      assert_receive {:tt_event, @delivered, _measurements, metadata}
      assert is_nil(metadata.meeting_id)
      assert is_binary(metadata.segment_id)
    end
  end

  # ── Responded ────────────────────────────────────────────────────────────

  describe "[:platform, :meetings, :agent, :responded]" do
    # THE RESPONSE FLOOR, and the segment it names. The park is real elapsed
    # time because elapsed time IS the quantity — this is not a
    # synchronisation sleep.
    test "response_ms measures delivery to say dispatch, and names the frame it measured from" do
      ctx = room!(1)
      [agent] = ctx.agents

      :ok = append!(ctx)
      assert_receive {:tt_event, @delivered, _m, %{agent_id: agent_id, segment_id: segment_id}}
      assert agent_id == agent.id

      Process.sleep(@seeded_response_delay_ms)

      assert {:ok, %{utterance_id: utterance_id}} =
               Meetings.say(agent, ctx.room_name, "on it", ack_timeout_ms: 20)

      assert_receive {:tt_event, @responded, measurements, metadata}
      assert metadata.agent_id == agent.id
      assert metadata.meeting_id == ctx.meeting.id
      assert metadata.segment_id == segment_id
      assert metadata.utterance_id == utterance_id
      assert metadata.room_name == ctx.room_name

      assert measurements.response_ms >= @response_floor_ms,
             "response_ms was #{measurements.response_ms}, under the #{@response_floor_ms}ms " <>
               "floor for a say dispatched #{@seeded_response_delay_ms}ms after the frame — " <>
               "it is being measured from the wrong instant"
    end

    # THE NAMED MUTATION. Drop the frame-precedence check in
    # `TranscriptTelemetry.responded/3` — delete the `nil ->` clause, or give
    # it any fallback instant to measure from — and this goes RED.
    #
    # An unprompted say is not a response. There is no frame here to be late
    # relative to, so there is no honest number, and emitting one anyway puts
    # a fabricated latency in the record under an agent's name.
    test "a say with no preceding delivered frame is not a response" do
      ctx = room!(1)
      [agent] = ctx.agents

      # No transcript segment has been appended: nothing has been delivered
      # to this agent at all.
      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "unprompted", ack_timeout_ms: 20)

      refute_receive {:tt_event, @responded, _m, _md}
    end

    # THE WRONG-KEY DETONATOR. Agent A speaks, so the frame is delivered to B
    # and to B ONLY. A then says. A correlation keyed on `meeting_id` alone
    # would find B's mark and report A as having responded to a frame A never
    # received — and would consume it, so B's own response would then vanish.
    # Both halves are asserted.
    test "a frame delivered to another agent is neither attributed to nor consumed by this one" do
      ctx = room!(2)
      [a, b] = ctx.agents

      :ok = append!(ctx, %{"participant_identity" => "agent:#{a.slug}", "speaker_name" => a.name})

      assert_receive {:tt_event, @delivered, _m, %{agent_id: b_id, segment_id: segment_id}}
      assert b_id == b.id

      Process.sleep(@seeded_response_delay_ms)

      # A speaks. A has no frame — B's must not be borrowed.
      assert {:ok, %{}} = Meetings.say(a, ctx.room_name, "me first", ack_timeout_ms: 20)
      refute_receive {:tt_event, @responded, _m1, _md1}

      # And B's frame is still there to be answered.
      assert {:ok, %{}} = Meetings.say(b, ctx.room_name, "answering", ack_timeout_ms: 20)

      assert_receive {:tt_event, @responded, measurements, metadata}
      assert metadata.agent_id == b.id
      assert metadata.segment_id == segment_id
      assert measurements.response_ms >= @response_floor_ms
    end

    test "one frame is credited to one say: the agent's second say is not a second response" do
      ctx = room!(1)
      [agent] = ctx.agents

      :ok = append!(ctx)
      assert_receive {:tt_event, @delivered, _m, _md}

      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "first", ack_timeout_ms: 20)
      assert_receive {:tt_event, @responded, _m1, _md1}

      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "and also", ack_timeout_ms: 20)
      refute_receive {:tt_event, @responded, _m2, _md2}
    end

    # Two frames, no say between them. The measurement is from the SECOND —
    # so this is a ceiling, and an implementation that kept the first frame
    # would report ~#{@seeded_response_delay_ms * 2} ms against a ceiling of
    # #{@seeded_response_delay_ms}.
    test "measures from the most recent delivered frame, not the first" do
      ctx = room!(1)
      [agent] = ctx.agents

      :ok = append!(ctx, %{"text" => "first thing"})
      assert_receive {:tt_event, @delivered, _m1, %{segment_id: first_segment_id}}

      Process.sleep(@seeded_response_delay_ms)

      :ok = append!(ctx, %{"text" => "second thing"})
      assert_receive {:tt_event, @delivered, _m2, %{segment_id: second_segment_id}}
      refute first_segment_id == second_segment_id

      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "on the second", ack_timeout_ms: 20)

      assert_receive {:tt_event, @responded, measurements, metadata}
      assert metadata.segment_id == second_segment_id

      assert measurements.response_ms < @seeded_response_delay_ms,
             "response_ms was #{measurements.response_ms}, at or above the " <>
               "#{@seeded_response_delay_ms}ms gap between the two frames — it is being " <>
               "measured from the first frame rather than the most recent one"
    end

    test "a frame in a room with no live meeting cannot be answered, and no number is invented" do
      ctx = room!(1, meeting: false)
      [agent] = ctx.agents

      :ok = append!(ctx)
      assert_receive {:tt_event, @delivered, _m, %{meeting_id: nil}}

      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "hello", ack_timeout_ms: 20)

      refute_receive {:tt_event, @responded, _m2, _md2}
    end
  end

  # ── The correlation store ────────────────────────────────────────────────

  describe "the delivered-frame marks" do
    test "age out under the same five-minute ceiling as the rest of SayRegistry" do
      ctx = room!(1)
      [agent] = ctx.agents

      :ok = append!(ctx)
      assert_receive {:tt_event, @delivered, _m, _md}

      # The ceiling is SayRegistry's own, read from it rather than restated:
      # a second copy of the number is a second number that can drift.
      cutoff = System.monotonic_time(:millisecond) - SayRegistry.ttl_ms()

      # The table is named and process-wide: rows left by the same beam's
      # other tests share it, so the raw sweep count is not a safe absolute
      # to pin. Bind it (foreign rows may legitimately be swept) and let the
      # room-scoped check below carry the weight: THIS room's freshly
      # delivered mark must still be present because it is not past the ttl.
      _swept = SayRegistry.frames_sweep(cutoff)

      # Room-scoped lookup mirroring take_delivered_frame/2: exactly one
      # `{meeting_id, agent_id}` row carries this room's fresh mark, and it
      # must still be newer than the cutoff.
      assert [{_meeting_id, at_ms}] =
               :ets.select(:meeting_transcript_frames, [
                 {{{:"$1", agent.id}, %{room_name: ctx.room_name, at_ms: :"$2"}}, [],
                  [{{:"$1", :"$2"}}]}
               ])

      assert at_ms > cutoff

      # `>= 1` rather than `== 1`: the table is named and process-wide, so
      # marks from other tests in the same run share it. What this pins is
      # that the sweep reaches these rows at all, and the say below is what
      # proves THIS room's mark is the one that went.
      assert SayRegistry.frames_sweep(System.monotonic_time(:millisecond)) >= 1

      assert {:ok, %{}} = Meetings.say(agent, ctx.room_name, "too late", ack_timeout_ms: 20)
      refute_receive {:tt_event, @responded, _m2, _md2}
    end

    test "there is no durable store behind them" do
      # Diagnostic state, deliberately: no schema, no migration, no table.
      # `to_regclass` answers nil for a name that is not a relation.
      for name <- ~w(meeting_transcript_frames transcript_deliveries agent_responses) do
        assert %{rows: [[nil]]} =
                 Repo.query!("SELECT to_regclass($1)", ["public.#{name}"])
      end
    end
  end

  # ── The Audit sink ───────────────────────────────────────────────────────

  describe "the Audit event log" do
    test "responded is registered, and delivered is deliberately not" do
      registered = Platform.Audit.TelemetryHandler.events()

      assert TranscriptTelemetry.responded_event() in registered

      # Once per recipient agent per final segment, uncapped. An audit row
      # per frame would make the audit log mostly transcript delivery.
      refute TranscriptTelemetry.delivered_event() in registered
    end

    test "a response lands as an audit row carrying response_ms and the segment it answered" do
      ctx = room!(1)
      [agent] = ctx.agents

      :ok = append!(ctx)
      assert_receive {:tt_event, @delivered, _m, %{segment_id: segment_id}}

      Process.sleep(@seeded_response_delay_ms)

      assert {:ok, %{utterance_id: utterance_id}} =
               Meetings.say(agent, ctx.room_name, "on it", ack_timeout_ms: 20)

      assert_receive {:tt_event, @responded, _m2, _md2}

      assert [row] =
               Audit.list(
                 resource_id: utterance_id,
                 event_type: "platform.meetings.agent.responded"
               )

      assert row.actor_type == "agent"
      assert row.actor_id == agent.id
      assert row.resource_type == "meeting_utterance"
      assert row.action == "responded"
      assert row.metadata["agent_id"] == agent.id
      assert row.metadata["meeting_id"] == ctx.meeting.id
      assert row.metadata["segment_id"] == segment_id
      assert row.metadata["response_ms"] >= @response_floor_ms
    end
  end
end
