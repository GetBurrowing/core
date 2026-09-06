defmodule Platform.Meetings.AgentActivityTest do
  @moduledoc """
  Stage 1 of task `01a04a98` — the per-meeting agent activity source.

  The bug this replaces was NOT "the tile renders the wrong state". It
  was that the tile could only ever render ONE state, so every test
  that drove a single state passed while the surface was inert. Every
  assertion here therefore drives at least two states and asserts they
  DIFFER, or drives one signal and asserts a second, independent signal
  is unaffected by it.

  Both signals are exercised through their real producers: the real
  `IntentQueue` for `:computing`, and a real `chat_participants` row for
  the `Chat.Participant.id -> Agents.Agent.id` bridge that `:typing`
  needs. No hand-rolled payloads of a shape the code merely hopes for.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks.Project

  setup do
    space = create_space()
    meeting = create_meeting(space)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)
    {:ok, meeting: meeting, space: space}
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Activity Space #{System.unique_integer([:positive])}",
        slug: "activity-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_meeting(space) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Activity Project #{System.unique_integer([:positive])}",
        slug: "activity-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Platform.Meetings.Meeting{id: meeting_id}
      |> Platform.Meetings.Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "activity-#{System.unique_integer([:positive])}",
        name: "Activity",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  # `status: "active"` mirrors `seed_meeting_presence/3` in
  # `meeting_live_test.exs`, which hardcodes it — so every agent in this
  # suite is GLOBALLY ACTIVE by default. That is the positive control for
  # the global-column assertion below: if per-meeting activity were
  # silently reading `agents.status`, these agents would never resolve
  # `:idle` at all.
  defp create_agent(name \\ "Helper") do
    Repo.insert!(%Agent{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: name,
      status: "active"
    })
  end

  # The `{:agent_typing, …}` payload carries a `chat_participants` row
  # id; every meeting surface keys agents by `agents.id`. This is the row
  # the bridge reads.
  defp seat_agent_in_chat(space, agent) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp dispatch_intent(meeting, agent_id) do
    {:ok, _pid} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 600_000)

    {:ok, row} =
      IntentQueue.enqueue(meeting.id, %{
        target_agent_id: agent_id,
        target_role: "designer",
        confidence: 0.9,
        chunk_excerpt: "somebody take this",
        dedupe_key: "dk-#{System.unique_integer([:positive])}"
      })

    {:ok, row} = IntentQueue.transition(meeting.id, row.id, :dispatched, %{})
    row
  end

  describe "one agent, two activities" do
    test "the SAME agent resolves two DIFFERENT states from the two real signals",
         %{meeting: meeting, space: space} do
      agent = create_agent()
      chat_participant = seat_agent_in_chat(space, agent)

      # Signal 1 — an in-flight intent row targeting this agent.
      dispatch_intent(meeting, agent.id)
      computing = AgentActivity.hydrate(meeting.id)
      assert AgentActivity.for_agent(computing, agent.id) == :computing

      # Signal 2 — `{:agent_typing, …}`, bridged from its chat
      # participant id, folded onto the same value.
      assert AgentActivity.agent_id_for_chat_participant(chat_participant.id) == agent.id
      typing = AgentActivity.put(computing, :typing, agent.id, true)

      # THE ASSERTION THIS TASK EXISTS FOR: two states, and they differ.
      # One state rendering correctly proved nothing when the defect was
      # that only one state was ever reachable.
      assert AgentActivity.for_agent(typing, agent.id) == :typing

      refute AgentActivity.for_agent(typing, agent.id) ==
               AgentActivity.for_agent(computing, agent.id)
    end

    test "dropping the typing signal falls BACK to :computing, not to :idle",
         %{meeting: meeting} do
      agent = create_agent()
      dispatch_intent(meeting, agent.id)

      activity =
        meeting.id
        |> AgentActivity.hydrate()
        |> AgentActivity.put(:typing, agent.id, true)
        |> AgentActivity.put(:typing, agent.id, false)

      # An intent is still in flight. A resolver that stored one value per
      # agent instead of one set per signal would answer `:idle` here.
      assert AgentActivity.for_agent(activity, agent.id) == :computing
    end
  end

  describe "two agents in one meeting" do
    test "resolve independently — one computing, one typing, one idle", %{
      meeting: meeting,
      space: space
    } do
      computing_agent = create_agent("Computer")
      typing_agent = create_agent("Typist")
      idle_agent = create_agent("Bystander")
      typing_participant = seat_agent_in_chat(space, typing_agent)

      dispatch_intent(meeting, computing_agent.id)

      activity =
        AgentActivity.put(
          AgentActivity.hydrate(meeting.id),
          :typing,
          AgentActivity.agent_id_for_chat_participant(typing_participant.id),
          true
        )

      assert AgentActivity.for_agent(activity, computing_agent.id) == :computing
      assert AgentActivity.for_agent(activity, typing_agent.id) == :typing
      assert AgentActivity.for_agent(activity, idle_agent.id) == :idle

      # And as a map: three seated agents, two entries. Idle agents are
      # absent rather than mapped, so a resolver that had smeared one
      # shared state across every agent would show three.
      assert AgentActivity.resolve(activity) == %{
               computing_agent.id => :computing,
               typing_agent.id => :typing
             }
    end
  end

  describe "the global agents.status column" do
    test "an agent that is globally `active` but has no activity in THIS meeting is :idle",
         %{meeting: meeting} do
      agent = create_agent()
      assert agent.status == "active"

      # Nothing has happened in this meeting.
      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :idle

      # ANTI-VACUITY: the same agent in the same meeting is NOT
      # permanently idle — give it an intent and it moves. Without this
      # the assertion above is satisfied by a resolver that returns
      # `:idle` unconditionally.
      dispatch_intent(meeting, agent.id)
      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :computing
    end
  end

  describe "hydration" do
    test "a value built AFTER the intent was dispatched still sees it", %{meeting: meeting} do
      agent = create_agent()

      # Ordering is the whole point: the signal happens first, the
      # consumer appears second. This is the late-joining socket.
      dispatch_intent(meeting, agent.id)

      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :computing
    end

    test "a terminal transition takes the agent back out of :computing", %{meeting: meeting} do
      agent = create_agent()
      row = dispatch_intent(meeting, agent.id)
      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :computing

      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :completed, %{})

      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :idle
    end

    test "hydration is scoped to ONE meeting", %{meeting: meeting, space: space} do
      other = create_meeting(space)
      on_exit(fn -> IntentQueue.stop(other.id) end)

      agent = create_agent()
      dispatch_intent(other, agent.id)

      assert AgentActivity.for_agent(AgentActivity.hydrate(meeting.id), agent.id) == :idle
      assert AgentActivity.for_agent(AgentActivity.hydrate(other.id), agent.id) == :computing
    end
  end

  describe "the meeting SHELL topic broadcast" do
    test "an in-flight transition publishes on `meeting:<id>`, and a terminal one clears it",
         %{meeting: meeting} do
      agent = create_agent()
      :ok = MeetingsPubSub.subscribe_meeting(meeting.id)

      row = dispatch_intent(meeting, agent.id)

      assert_receive {:agent_activity,
                      %{
                        meeting_id: meeting_id,
                        agent_id: agent_id,
                        signal: :computing,
                        active?: true
                      }}

      assert meeting_id == meeting.id
      assert agent_id == agent.id

      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :completed, %{})

      assert_receive {:agent_activity, %{agent_id: ^agent_id, signal: :computing, active?: false}}
    end

    test "an intent with no target agent publishes nothing", %{meeting: meeting} do
      :ok = MeetingsPubSub.subscribe_meeting(meeting.id)
      {:ok, _pid} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 600_000)

      {:ok, row} =
        IntentQueue.enqueue(meeting.id, %{
          target_role: "designer",
          confidence: 0.5,
          dedupe_key: "dk-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatched, %{})

      refute_receive {:agent_activity, _}, 100

      # ANTI-VACUITY: the subscription is live and the topic is right —
      # the same transition on a TARGETED row does arrive. The untargeted
      # row is completed first because the queue holds ONE in-flight
      # intent per meeting on a serial cursor.
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :completed, %{})
      refute_receive {:agent_activity, _}, 100

      dispatch_intent(meeting, create_agent().id)
      assert_receive {:agent_activity, %{signal: :computing, active?: true}}
    end
  end

  describe "the Chat.Participant <-> Agent bridge" do
    test "resolves an agent participant and refuses a human one", %{space: space} do
      agent = create_agent()
      agent_participant = seat_agent_in_chat(space, agent)

      {:ok, human_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "A Person",
          joined_at: DateTime.utc_now()
        })

      assert AgentActivity.agent_id_for_chat_participant(agent_participant.id) == agent.id

      # A human typing in the meeting chat must never light an agent tile.
      assert AgentActivity.agent_id_for_chat_participant(human_participant.id) == nil
      assert AgentActivity.agent_id_for_chat_participant(nil) == nil
    end

    test "the bridge is not the identity function", %{space: space} do
      agent = create_agent()
      participant = seat_agent_in_chat(space, agent)

      # Both are UUIDs of the same shape and both are called
      # "participant id" somewhere in this codebase. Feeding the tile the
      # wrong one renders nothing and looks exactly like "no activity".
      refute participant.id == agent.id
      assert AgentActivity.agent_id_for_chat_participant(participant.id) == agent.id
    end
  end

  # ── :failed — the "Couldn't" cap (agent dock) ───────────────────────────

  describe "a failure terminal" do
    # The load-bearing test. Before `:failed` existed, `:timed_out` and
    # `:completed` were the SAME event on this topic — both fall outside
    # `in_flight_statuses/0`, so both cleared `:computing` and the agent
    # went quietly idle. Asserting only "a timeout resolves :failed"
    # would pass against a version that resolved :failed for every
    # terminal, which would paint a red cap over completed work. So the
    # two are driven side by side and asserted to DIFFER.
    test "is told apart from a completion, which is the whole point",
         %{meeting: meeting} do
      failing = create_agent("Failing")
      finishing = create_agent("Finishing")

      MeetingsPubSub.subscribe_meeting(meeting.id)

      # Sequentially: the serial cursor holds at most one in-flight row
      # per meeting, so each has to reach a terminal before the next
      # goes out. That is the real dispatch shape, not a test artefact.
      failing_row = dispatch_intent(meeting, failing.id)
      {:ok, _} = IntentQueue.transition(meeting.id, failing_row.id, :timed_out, %{})

      finishing_row = dispatch_intent(meeting, finishing.id)
      {:ok, _} = IntentQueue.transition(meeting.id, finishing_row.id, :completed, %{})

      activity = drain_activity(AgentActivity.new())

      assert AgentActivity.for_agent(activity, failing.id) == :failed
      assert AgentActivity.for_agent(activity, finishing.id) == :idle
    end

    # A human pressing stop is the system obeying, not breaking. If
    # cancellation raised the fault cap, people would learn to ignore it.
    test "a cancellation is NOT a failure", %{meeting: meeting} do
      agent = create_agent()
      row = dispatch_intent(meeting, agent.id)

      MeetingsPubSub.subscribe_meeting(meeting.id)
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :cancelled, %{})

      activity = drain_activity(AgentActivity.new())

      assert AgentActivity.for_agent(activity, agent.id) == :idle
      refute :cancelled in IntentQueue.failure_statuses()
      refute :cancelled_late in IntentQueue.failure_statuses()
      refute :completed in IntentQueue.failure_statuses()
    end

    # `:failed` outranks the working signals so a stale `:typing` cannot
    # paint over the news. Without the precedence entry this is green
    # only by luck of map ordering, so it is asserted directly.
    test "outranks a concurrent typing signal", %{meeting: meeting} do
      agent = create_agent()
      row = dispatch_intent(meeting, agent.id)

      MeetingsPubSub.subscribe_meeting(meeting.id)
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatch_failed, %{})

      activity =
        AgentActivity.new()
        |> drain_activity()
        |> AgentActivity.put(:typing, agent.id, true)

      assert AgentActivity.for_agent(activity, agent.id) == :failed
    end

    # Without this the cap is permanent for the life of the socket:
    # `:failed` outranks `:computing`, so an agent that failed once
    # would read "Couldn't" while visibly working on the next request.
    test "a NEW in-flight intent retires the previous failure", %{meeting: _meeting} do
      agent = create_agent()

      activity =
        AgentActivity.new()
        |> AgentActivity.put(:failed, agent.id, true)

      assert AgentActivity.for_agent(activity, agent.id) == :failed

      activity = AgentActivity.put(activity, :computing, agent.id, true)

      assert AgentActivity.for_agent(activity, agent.id) == :computing
    end

    # The control for the test above: a chat typing signal must NOT
    # erase a real failure, because it can fire for reasons unrelated
    # to the intent that failed.
    test "a typing signal does NOT retire the failure", %{meeting: _meeting} do
      agent = create_agent()

      activity =
        AgentActivity.new()
        |> AgentActivity.put(:failed, agent.id, true)
        |> AgentActivity.put(:typing, agent.id, true)

      assert AgentActivity.for_agent(activity, agent.id) == :failed
    end
  end

  describe "hydrating a failure" do
    # A remounting viewer must see what is true NOW. "Has failed at some
    # point today" would give every agent a permanent red cap by
    # mid-afternoon, so only the agent's LATEST row is consulted.
    test "seeds from the latest row, not from any row", %{meeting: meeting} do
      agent = create_agent()

      first = dispatch_intent(meeting, agent.id)
      {:ok, _} = IntentQueue.transition(meeting.id, first.id, :timed_out, %{})

      assert meeting.id |> AgentActivity.hydrate() |> AgentActivity.for_agent(agent.id) ==
               :failed

      # A later, successful row supersedes it.
      second = dispatch_intent(meeting, agent.id)
      {:ok, _} = IntentQueue.transition(meeting.id, second.id, :completed, %{})

      assert meeting.id |> AgentActivity.hydrate() |> AgentActivity.for_agent(agent.id) ==
               :idle
    end

    # Hydration and the live path have to agree, or a remount silently
    # changes the screen. In flight after a failure resolves :computing
    # in both.
    test "an in-flight row after a failure hydrates as computing, matching the live path",
         %{meeting: meeting} do
      agent = create_agent()

      failed = dispatch_intent(meeting, agent.id)
      {:ok, _} = IntentQueue.transition(meeting.id, failed.id, :no_ack_spawn_failed, %{})
      _in_flight = dispatch_intent(meeting, agent.id)

      hydrated = AgentActivity.hydrate(meeting.id)

      live =
        AgentActivity.new()
        |> AgentActivity.put(:failed, agent.id, true)
        |> AgentActivity.put(:computing, agent.id, true)

      assert AgentActivity.for_agent(hydrated, agent.id) == :computing
      assert AgentActivity.for_agent(live, agent.id) == :computing
    end
  end

  # Fold every `{:agent_activity, _}` currently in the mailbox into an
  # activity value, in arrival order — the same thing MeetingLive's
  # handle_info does, so these tests exercise the real consumer path
  # rather than a hand-built struct.
  defp drain_activity(activity) do
    receive do
      {:agent_activity, %{signal: signal, agent_id: agent_id, active?: active?}} ->
        activity
        |> AgentActivity.put(signal, agent_id, active?)
        |> drain_activity()
    after
      200 -> activity
    end
  end

  describe ":listening" do
    test "is a declared state with no producer, and stays unreachable", %{meeting: meeting} do
      # Recorded as an assertion rather than a comment so that adding a
      # producer forces a deliberate edit here.
      assert :listening in AgentActivity.states()
      refute :listening in AgentActivity.signals()

      agent = create_agent()
      dispatch_intent(meeting, agent.id)

      activity =
        meeting.id
        |> AgentActivity.hydrate()
        |> AgentActivity.put(:typing, agent.id, true)

      refute AgentActivity.for_agent(activity, agent.id) == :listening

      assert activity
             |> AgentActivity.resolve()
             |> Map.values()
             |> Enum.all?(&(&1 != :listening))
    end
  end

  # ── The read-time ceiling (task 01a06e07 stage 1) ──────────────────────────
  #
  # The stuck state this closes is the one this module's own moduledoc
  # already described: a queue owner that stops mid-flight broadcasts no
  # terminal, so a live socket held an agent `:computing` forever. The
  # fix is a bound derived at READ time from `entered_at` and a `now`
  # handed in — so every test here builds its aged value out of two
  # `DateTime`s and runs with no timer, no sleep and no process.
  describe "the read-time ceiling" do
    setup do
      # A bare id: `put_at/5` only requires `is_binary`, and using a real
      # agent row here would suggest the ceiling consults one. It does not.
      {:ok, t0: ~U[2026-09-04 12:00:00Z], agent_id: Platform.Types.UUIDv7.generate()}
    end

    # THE subtle one. `:computing` is mirrored from every intent-row
    # transition and `:typing` from every producer toggle, so a working
    # agent re-asserts the same signal repeatedly. If a repeat restamped,
    # the age would reset on every repeat and the ceiling could never
    # fire for a producer that is still emitting — it would only ever
    # catch total silence.
    #
    # Asserted twice over: the stamp itself is unmoved, AND the
    # consequence — the repeat has not bought another two minutes.
    test "re-asserting a held signal does not restamp it", %{t0: t0, agent_id: agent_id} do
      at_60 = DateTime.add(t0, 60, :second)
      at_130 = DateTime.add(t0, 130, :second)

      first = AgentActivity.put_at(AgentActivity.new(), :computing, agent_id, true, t0)
      repeated = AgentActivity.put_at(first, :computing, agent_id, true, at_60)

      assert %{^agent_id => %{state: :computing, entered_at: ^t0, age_s: 60}} =
               AgentActivity.resolve_at(repeated, at_60)

      assert %{^agent_id => %{state: :failed}} = AgentActivity.resolve_at(repeated, at_130)

      # The control, and it is the SAME call sequence bar one `false`:
      # an agent that actually LEFT the signal and re-entered it does
      # take the new stamp, and so is still working at 130s. Without
      # this pair, "never restamp" and "restamp on the false" both pass.
      reentered =
        first
        |> AgentActivity.put_at(:computing, agent_id, false, at_60)
        |> AgentActivity.put_at(:computing, agent_id, true, at_60)

      assert %{^agent_id => %{state: :computing, entered_at: ^at_60, age_s: 70}} =
               AgentActivity.resolve_at(reentered, at_130)
    end

    # The bound itself, on both working signals, either side of the edge.
    test "under the ceiling still works; at and over it resolves :failed",
         %{t0: t0, agent_id: agent_id} do
      assert AgentActivity.ceiling_seconds() == 120

      for signal <- [:computing, :typing] do
        activity = AgentActivity.put_at(AgentActivity.new(), signal, agent_id, true, t0)

        assert %{^agent_id => %{state: ^signal, age_s: 119}} =
                 AgentActivity.resolve_at(activity, DateTime.add(t0, 119, :second))

        assert %{^agent_id => %{state: :failed, age_s: 120}} =
                 AgentActivity.resolve_at(activity, DateTime.add(t0, 120, :second))

        assert %{^agent_id => %{state: :failed}} =
                 AgentActivity.resolve_at(activity, DateTime.add(t0, 600, :second))
      end
    end

    # `:failed`, NOT `:idle`. Idle agents are absent from the resolved
    # map, so "expires to idle" and "expires to failed" differ in two
    # ways — the key is still there, and its state names a fault. Both
    # are asserted, because dropping the key is the failure mode that a
    # `state == :failed` assertion alone would not catch.
    test "an expired working signal is a fault, not a disappearance",
         %{t0: t0, agent_id: agent_id} do
      resolved =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, agent_id, true, t0)
        |> AgentActivity.resolve_at(DateTime.add(t0, 300, :second))

      assert Map.has_key?(resolved, agent_id)
      assert resolved[agent_id].state == :failed
      assert resolved[agent_id].age_s == 300
    end

    # `:failed` keeps its precedence, and is not itself aged out: an
    # aged failure is still the last true thing that happened.
    test ":failed outranks the working signals and never expires",
         %{t0: t0, agent_id: agent_id} do
      activity =
        AgentActivity.new()
        |> AgentActivity.put_at(:failed, agent_id, true, t0)
        |> AgentActivity.put_at(:typing, agent_id, true, DateTime.add(t0, 200, :second))

      assert %{^agent_id => %{state: :failed, entered_at: ^t0, age_s: 210}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 210, :second))
    end

    # Clock skew between the row that stamped and the socket that reads
    # must not manufacture a failure.
    test "a `now` that predates the stamp does not cap", %{t0: t0, agent_id: agent_id} do
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, agent_id, true, t0)

      assert %{^agent_id => %{state: :computing, age_s: -30}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, -30, :second))
    end

    # The no-process claim, made checkable rather than asserted in prose.
    #
    # A value round-tripped through `term_to_binary/1` carries no pid,
    # no reference and no timer — anything scheduled would not survive
    # the copy. That copy expires identically, so the ceiling is a
    # function of the two `DateTime`s and nothing else.
    test "the ceiling survives serialisation, so nothing live is behind it",
         %{t0: t0, agent_id: agent_id} do
      revived =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, agent_id, true, t0)
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      assert %{^agent_id => %{state: :failed}} =
               AgentActivity.resolve_at(revived, DateTime.add(t0, 130, :second))

      # And the module is still a value module. Turning it into a
      # GenServer to sweep the ceiling is the change this forbids.
      refute function_exported?(AgentActivity, :init, 1)
      refute function_exported?(AgentActivity, :handle_info, 2)
    end

    # Through the REAL producer, and the reason the ceiling exists: an
    # in-flight row whose queue owner never reports a terminal. The
    # stamp comes off the row's `dispatched_at`, not off the hydrating
    # socket's clock — otherwise a remount would reset the age and the
    # stuck agent would stay `:computing` across every reconnect.
    test "a hydrated in-flight row ages from the ROW's clock", %{meeting: meeting} do
      agent = create_agent()
      row = dispatch_intent(meeting, agent.id)

      activity = AgentActivity.hydrate(meeting.id)

      assert %{state: :computing} =
               AgentActivity.resolve_at(activity, row.dispatched_at)[agent.id]

      assert %{state: :failed} =
               AgentActivity.resolve_at(activity, DateTime.add(row.dispatched_at, 130, :second))[
                 agent.id
               ]
    end

    # `resolve/1` and `for_agent/2` are the pre-ceiling reads and stay
    # that way this stage; the render path moves later. Pinned so the
    # move is a deliberate edit rather than a silent one.
    test "resolve/1 and for_agent/2 are unchanged by the ceiling",
         %{t0: t0, agent_id: agent_id} do
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, agent_id, true, t0)

      assert AgentActivity.resolve(activity) == %{agent_id => :computing}
      assert AgentActivity.for_agent(activity, agent_id) == :computing
    end
  end

  # ── `:heard` (task 01a06e07 stage 2) ────────────────────────────────────────
  #
  # `:listening` was removed from this rail (canvas `01a05b11-54ff`, ratified
  # by Harper 2026-09-03) because every agent in a call is always listening,
  # so a badge on for everyone all the time takes a row from a state that
  # actually turns over. `:heard` is legitimate only because it decays — the
  # load-bearing test below is the one that pins that decay, not the ones
  # that pin the badge lighting up in the first place.
  describe ":heard" do
    setup do
      {:ok, t0: ~U[2026-09-04 12:00:00Z], agent_id: Platform.Types.UUIDv7.generate()}
    end

    # THE load-bearing test. If `:heard` ever stopped decaying — latched
    # like `:computing`/`:typing`, or simply left out of `resolve_at/2`'s
    # aging — this is `:listening` again, under a new name, and it would
    # have to be removed a second time for the identical reason.
    test "two seconds after the stamp the agent is NOT :heard", %{t0: t0, agent_id: agent_id} do
      assert AgentActivity.heard_decay_seconds() == 2

      activity = AgentActivity.put_at(AgentActivity.new(), :heard, agent_id, true, t0)

      assert %{^agent_id => %{state: :heard, entered_at: ^t0, age_s: 0}} =
               AgentActivity.resolve_at(activity, t0)

      assert %{^agent_id => %{state: :heard, age_s: 1}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 1, :second))

      resolved_at_2 = AgentActivity.resolve_at(activity, DateTime.add(t0, 2, :second))
      refute match?(%{^agent_id => %{state: :heard}}, resolved_at_2)
      # Nothing else is held, so the underlying state is idle — absent.
      refute Map.has_key?(resolved_at_2, agent_id)

      resolved_at_10 = AgentActivity.resolve_at(activity, DateTime.add(t0, 10, :second))
      refute match?(%{^agent_id => %{state: :heard}}, resolved_at_10)
    end

    # `:heard` reverts to the agent's OTHER signal, not to idle
    # unconditionally — decay REMOVES it from consideration rather than
    # capping it to a fixed target, unlike the ceiling above.
    test "after decay the agent reads as its underlying state, not idle",
         %{t0: t0, agent_id: agent_id} do
      activity =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, agent_id, true, t0)
        |> AgentActivity.put_at(:heard, agent_id, true, t0)

      assert %{^agent_id => %{state: :heard}} = AgentActivity.resolve_at(activity, t0)

      assert %{^agent_id => %{state: :computing, entered_at: ^t0}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 2, :second))
    end

    # While live, `:heard` overlays even a `:failed` agent — it is a
    # receipt about THIS delivery, not a claim that the agent's prior
    # work succeeded. After decay the failure is exactly as it was.
    test "while live, :heard overlays :failed; decayed, :failed is unchanged",
         %{t0: t0, agent_id: agent_id} do
      activity =
        AgentActivity.new()
        |> AgentActivity.put_at(:failed, agent_id, true, t0)
        |> AgentActivity.put_at(:heard, agent_id, true, DateTime.add(t0, 5, :second))

      assert %{^agent_id => %{state: :heard}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 5, :second))

      assert %{^agent_id => %{state: :failed, entered_at: ^t0}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 8, :second))
    end

    # The opposite of the ceiling's no-restamp rule, and load-bearing for
    # the opposite reason: `:heard` is a per-UTTERANCE event, so a second
    # delivered segment arriving inside the first one's decay window must
    # restart the window rather than being absorbed by it.
    test "a second heard stamp before decay restarts the window",
         %{t0: t0, agent_id: agent_id} do
      at_1 = DateTime.add(t0, 1, :second)

      activity =
        AgentActivity.new()
        |> AgentActivity.put_at(:heard, agent_id, true, t0)
        |> AgentActivity.put_at(:heard, agent_id, true, at_1)

      # Still heard at t0+2s (only 1s since the SECOND stamp).
      assert %{^agent_id => %{state: :heard, entered_at: ^at_1, age_s: 1}} =
               AgentActivity.resolve_at(activity, DateTime.add(t0, 2, :second))

      # Decayed by t0+3s (2s since the second stamp).
      refute match?(
               %{^agent_id => %{state: :heard}},
               AgentActivity.resolve_at(activity, DateTime.add(t0, 3, :second))
             )
    end

    # `resolve/1` and `for_agent/2` — the pre-ceiling reads — never see
    # `:heard` at all, on purpose: neither has a way to age it out, so
    # surfacing it there would latch it forever the first time any agent
    # heard anything. See `AgentActivity`'s moduledoc and the comment on
    # `@precedence`.
    test "resolve/1 and for_agent/2 never surface :heard", %{t0: t0, agent_id: agent_id} do
      activity = AgentActivity.put_at(AgentActivity.new(), :heard, agent_id, true, t0)

      assert AgentActivity.resolve(activity) == %{}
      assert AgentActivity.for_agent(activity, agent_id) == :idle
    end

    test ":heard is in signals/0 and states/0, now that it has a producer" do
      assert :heard in AgentActivity.signals()
      assert :heard in AgentActivity.states()
    end

    # The generic shell-topic broadcast, exercised with :heard the same
    # way the intent-transition tests above exercise :computing.
    test "broadcasting :heard publishes on the meeting shell topic and folds via put/4",
         %{meeting: meeting} do
      agent = create_agent()
      :ok = MeetingsPubSub.subscribe_meeting(meeting.id)

      :ok = AgentActivity.broadcast(meeting.id, :heard, agent.id, true)

      assert_receive {:agent_activity,
                      %{meeting_id: meeting_id, agent_id: agent_id, signal: :heard, active?: true}}

      assert meeting_id == meeting.id
      assert agent_id == agent.id

      folded = AgentActivity.put(AgentActivity.new(), :heard, agent.id, true)

      assert %{^agent_id => %{state: :heard}} =
               AgentActivity.resolve_at(folded, DateTime.utc_now())
    end
  end

  # ── Pushed state (task 01a07400 stage 1) ────────────────────────────────────
  #
  # `:thinking` and `:composing` are the only two states an agent may declare
  # about itself, and the ONLY thing that makes declaring them safe is that
  # the server expires them. Ticket `01a06e07` put it exactly right — "a state
  # the agent must remember to emit is a state it will forget to clear" — so
  # the load-bearing test in this block is not the one where a push shows up.
  # It is `"a pushed state that is never refreshed expires to :idle"`: if that
  # ever passes for the wrong reason, this feature is a badge that latches on
  # the first crash and stays on.
  #
  # ## Why `@far_future` and not a time near today's
  #
  # These tests write to the REAL `:meeting_agent_pushed_state` table, which a
  # live sweep is walking every `pushed_sweep_interval_ms/0` against
  # `DateTime.utc_now/0`. A row stamped at a plausible "now" would be older
  # than its ttl in wall-clock terms the moment it was written, and the sweep
  # could delete it between the push and the read — which would make the
  # expiry assertions pass with the read-path check deleted, i.e. vacuously.
  # Stamping far in the future keeps every row live as far as the sweep is
  # concerned (`live?/2` reads a negative age as live), so the only thing that
  # can expire a row in these tests is the `now` the test hands the reader.
  # The sweep gets its own test, which drives `sweep_pushed/1` directly.
  describe "pushed state" do
    setup do
      {:ok,
       far_future: ~U[2099-03-01 12:00:00Z],
       agent_id: Platform.Types.UUIDv7.generate(),
       other_agent_id: Platform.Types.UUIDv7.generate()}
    end

    # THE anti-vacuity test for this stage.
    #
    # The ttl is small (5s) and stated in the test rather than inherited from
    # config, and the margins on both sides are wide on purpose: live is
    # asserted at 1s against a 5s ttl, expiry at 60s — twelve times the ttl.
    # A boundary-hugging assertion here would be measuring nothing but which
    # side of a rounding step the clock landed on.
    #
    # The resolved state is asserted by IDENTITY (`== :idle`), not by
    # `!= :thinking`. "Not what I pushed" is satisfied by a crash, a typo in
    # the agent id, an empty map for any reason at all — every way of
    # returning nothing passes it. `== :idle` is satisfied by exactly one
    # outcome.
    #
    # Named mutation: delete the `live?/2` check from `pushed/3` and
    # `pushed_all/2` (the read path) and this test goes red at the 60s
    # assertion, while "a live pushed state resolves" below stays green.
    test "a pushed state that is never refreshed expires to :idle",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      ttl_ms = 5_000

      {:ok, entry} =
        AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: ttl_ms, now: t0)

      assert entry.ttl_ms == ttl_ms

      # Well inside the ttl: one fifth of it.
      assert pushed_state_of(meeting.id, agent_id, t0) == :thinking
      assert pushed_state_of(meeting.id, agent_id, DateTime.add(t0, 1, :second)) == :thinking

      # Nothing refreshes it. Nothing calls back. Nothing is cleaned up. The
      # runtime, as far as this test is concerned, died.
      at_60s = DateTime.add(t0, 60, :second)

      assert pushed_state_of(meeting.id, agent_id, at_60s) == :idle
      refute pushed_state_of(meeting.id, agent_id, at_60s) == :thinking

      # The three readers agree, so the expiry cannot be hiding in one of them.
      assert AgentActivity.pushed(meeting.id, agent_id, at_60s) == nil
      assert AgentActivity.pushed_all(meeting.id, at_60s) == %{}
      assert AgentActivity.resolve_at(AgentActivity.new(), meeting.id, at_60s) == %{}
    end

    # The green half of the mutation pair: a push read back inside its ttl
    # resolves. If the mutation above also broke this, the red would not be
    # evidence of anything.
    test "a live pushed state resolves, with its reason and its own age",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      {:ok, _} =
        AgentActivity.push(meeting.id, agent_id, :composing,
          ttl_ms: 5_000,
          reason: "drafting the summary",
          now: t0
        )

      at_2s = DateTime.add(t0, 2, :second)

      assert %{^agent_id => %{state: :composing, entered_at: ^t0, age_s: 2}} =
               AgentActivity.resolve_at(AgentActivity.new(), meeting.id, at_2s)

      assert %{state: :composing, reason: "drafting the summary", ttl_ms: 5_000} =
               AgentActivity.pushed(meeting.id, agent_id, at_2s)
    end

    test "only :thinking and :composing can be pushed",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      assert AgentActivity.pushed_states() == [:thinking, :composing]

      for state <- AgentActivity.pushed_states() do
        assert {:ok, %{state: ^state}} =
                 AgentActivity.push(meeting.id, agent_id, state, ttl_ms: 5_000, now: t0)
      end

      # Every other declared state is core's to observe, `:failed` most
      # importantly: a runtime that could assert it could paint over the one
      # reading that says something went wrong.
      for state <- AgentActivity.states() -- AgentActivity.pushed_states() do
        assert AgentActivity.push(meeting.id, agent_id, state, ttl_ms: 5_000, now: t0) ==
                 {:error, {:unsupported_state, state}}
      end

      # And the refusal wrote nothing: the last accepted push still stands.
      assert %{state: :composing} = AgentActivity.pushed(meeting.id, agent_id, t0)
    end

    # `put_at/5`'s no-restamp rule and this one are opposites, deliberately.
    # There the age must survive a repeat or the 120s ceiling could never
    # fire; here the repeat IS the liveness signal.
    test "refreshing restarts the ttl; the absence of a refresh is what expires it",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      ttl_ms = 5_000
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: ttl_ms, now: t0)

      at_4s = DateTime.add(t0, 4, :second)
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: ttl_ms, now: at_4s)

      # 8s after the FIRST push — long past its ttl — but only 4s after the
      # second, so the claim still stands and its age runs from the refresh.
      at_8s = DateTime.add(t0, 8, :second)
      assert pushed_state_of(meeting.id, agent_id, at_8s) == :thinking
      assert %{pushed_at: ^at_4s} = AgentActivity.pushed(meeting.id, agent_id, at_8s)

      # Then the refreshes stop, and 60s later — twelve ttls — it is gone.
      assert pushed_state_of(meeting.id, agent_id, DateTime.add(t0, 64, :second)) == :idle
    end

    test "clear_pushed/2 withdraws a live declaration",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 60_000, now: t0)
      assert pushed_state_of(meeting.id, agent_id, t0) == :thinking

      assert :ok == AgentActivity.clear_pushed(meeting.id, agent_id)
      assert pushed_state_of(meeting.id, agent_id, t0) == :idle
    end

    test "a reason is trimmed, capped, and blank means absent",
         %{meeting: meeting, far_future: t0, agent_id: agent_id} do
      cap = AgentActivity.pushed_reason_max_chars()

      {:ok, long} =
        AgentActivity.push(meeting.id, agent_id, :thinking,
          ttl_ms: 5_000,
          reason: String.duplicate("x", cap + 50),
          now: t0
        )

      assert String.length(long.reason) == cap

      {:ok, blank} =
        AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 5_000, reason: "   ", now: t0)

      assert blank.reason == nil
    end

    # ── Precedence ──────────────────────────────────────────────────────────
    #
    # `:failed` > `:typing` > pushed > `:computing`, with `:heard` overlaid.
    # Each test below drives the pushed state AND the signal it is being
    # ranked against, and asserts the pair resolves differently from the same
    # pushed state alone — so a precedence rule that silently stopped being
    # applied could not pass by resolving to the pushed state either way.

    test "a pushed state outranks :computing", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id
    } do
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, agent_id, true, t0)

      # Without the push, the same value resolves :computing.
      assert %{^agent_id => %{state: :computing}} =
               AgentActivity.resolve_at(activity, meeting.id, t0)

      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 60_000, now: t0)

      assert %{^agent_id => %{state: :thinking}} =
               AgentActivity.resolve_at(activity, meeting.id, t0)
    end

    test ":typing and :failed both outrank a pushed state", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id,
      other_agent_id: other_agent_id
    } do
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :composing, ttl_ms: 60_000, now: t0)

      {:ok, _} =
        AgentActivity.push(meeting.id, other_agent_id, :thinking, ttl_ms: 60_000, now: t0)

      activity =
        AgentActivity.new()
        |> AgentActivity.put_at(:typing, agent_id, true, t0)
        |> AgentActivity.put_at(:failed, other_agent_id, true, t0)

      resolved = AgentActivity.resolve_at(activity, meeting.id, t0)

      assert %{^agent_id => %{state: :typing}} = resolved
      assert %{^other_agent_id => %{state: :failed}} = resolved
    end

    test "a live :heard overlays a pushed state, and a decayed one does not", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id
    } do
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 60_000, now: t0)
      activity = AgentActivity.put_at(AgentActivity.new(), :heard, agent_id, true, t0)

      assert %{^agent_id => %{state: :heard}} =
               AgentActivity.resolve_at(activity, meeting.id, t0)

      # Past `heard_decay_seconds/0` it falls back to the underlying state,
      # which is now the pushed one rather than idle.
      at_5s = DateTime.add(t0, 5, :second)
      assert AgentActivity.heard_decay_seconds() < 5

      assert %{^agent_id => %{state: :thinking}} =
               AgentActivity.resolve_at(activity, meeting.id, at_5s)
    end

    # The point of the whole stage. A genuinely long turn stops reading as a
    # failure — but only while the runtime keeps saying so.
    test "a live pushed state pre-empts the 120-second ceiling; a lapsed one does not", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id
    } do
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, agent_id, true, t0)
      past_ceiling = DateTime.add(t0, AgentActivity.ceiling_seconds() + 10, :second)

      # Baseline: with nothing declared, the ceiling caps it.
      assert %{^agent_id => %{state: :failed}} =
               AgentActivity.resolve_at(activity, meeting.id, past_ceiling)

      # Refreshed right up to the read, the agent reads as thinking instead.
      {:ok, _} =
        AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 5_000, now: past_ceiling)

      assert %{^agent_id => %{state: :thinking}} =
               AgentActivity.resolve_at(activity, meeting.id, past_ceiling)

      # And the reprieve is bounded by the ttl, not open-ended: 60s later,
      # with no further push, the ceiling is back.
      assert %{^agent_id => %{state: :failed}} =
               AgentActivity.resolve_at(
                 activity,
                 meeting.id,
                 DateTime.add(past_ceiling, 60, :second)
               )
    end

    # `resolve/1`, `for_agent/2` and `resolve_at/2` take no meeting and no
    # store. If a pushed state ever surfaced through them it could never be
    # aged out by them — the identical latching argument that keeps `:heard`
    # out of `@precedence`.
    test "the store-blind readers never surface a pushed state", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id
    } do
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 60_000, now: t0)

      assert AgentActivity.resolve(AgentActivity.new()) == %{}
      assert AgentActivity.for_agent(AgentActivity.new(), agent_id) == :idle
      assert AgentActivity.resolve_at(AgentActivity.new(), t0) == %{}

      # …while the store-aware reader does, so the difference is the reader
      # and not an empty store.
      assert %{^agent_id => %{state: :thinking}} =
               AgentActivity.resolve_at(AgentActivity.new(), meeting.id, t0)
    end

    test "pushed_all/2 is meeting-scoped", %{
      meeting: meeting,
      space: space,
      far_future: t0,
      agent_id: agent_id
    } do
      other_meeting = create_meeting(space)

      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 60_000, now: t0)

      {:ok, _} =
        AgentActivity.push(other_meeting.id, agent_id, :composing, ttl_ms: 60_000, now: t0)

      assert %{^agent_id => %{state: :thinking}} = AgentActivity.pushed_all(meeting.id, t0)
      assert %{^agent_id => %{state: :composing}} = AgentActivity.pushed_all(other_meeting.id, t0)
    end

    # The other half of "expires on read AND sweep". The read path is already
    # correct without this; what the sweep adds is that the row stops
    # occupying the table.
    #
    # The RETURN COUNT is deliberately not asserted. `sweep_pushed/1` is
    # global — it walks every meeting's rows, and this module is
    # `async: true`, so a concurrent test's rows land in the same table and
    # the number is whatever the scheduler produced. An earlier draft
    # asserted `== 1` here and saw 13. A count that only holds when nothing
    # else is running is not a measurement of this sweep.
    #
    # What IS asserted is deletion, and it is asserted at `t0` — a clock at
    # which the lapsed row would still read as LIVE if it were still in the
    # table. So its absence at `t0` cannot be the read-path expiry hiding
    # it; the row is gone. That is the property the sweep is for, and it is
    # independent of anything else in the table.
    test "sweep_pushed/1 deletes lapsed rows and leaves live ones", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id,
      other_agent_id: other_agent_id
    } do
      {:ok, _} = AgentActivity.push(meeting.id, agent_id, :thinking, ttl_ms: 5_000, now: t0)

      {:ok, _} =
        AgentActivity.push(meeting.id, other_agent_id, :thinking, ttl_ms: 600_000, now: t0)

      # Both rows are live at t0, and a sweep at t0 finds neither of them
      # lapsed, so both survive it.
      AgentActivity.sweep_pushed(t0)
      assert %{^agent_id => _, ^other_agent_id => _} = AgentActivity.pushed_all(meeting.id, t0)

      # 60s on, the 5s row has lapsed and the 600s row has not.
      AgentActivity.sweep_pushed(DateTime.add(t0, 60, :second))

      # Read back at t0, where a surviving 5s row would still be live.
      assert AgentActivity.pushed(meeting.id, agent_id, t0) == nil
      assert %{state: :thinking} = AgentActivity.pushed(meeting.id, other_agent_id, t0)
      assert Map.keys(AgentActivity.pushed_all(meeting.id, t0)) == [other_agent_id]
    end

    # The structural half of the safety argument, made checkable.
    #
    # `agent_activity_test.exs`'s ceiling block already forbids
    # `AgentActivity` from exporting `init/1` or `handle_info/2`; this
    # states the other side of that split — the process exists, it is a
    # different module, and it is what owns the table.
    test "the table has a lifecycle owner, and it is not AgentActivity itself" do
      refute function_exported?(AgentActivity, :init, 1)
      assert function_exported?(AgentActivity.Store, :init, 1)

      assert is_pid(Process.whereis(AgentActivity.Store))
      assert :ets.info(AgentActivity.pushed_table()) != :undefined
    end

    test ":thinking and :composing are in states/0 but are not signals", %{} do
      for state <- [:thinking, :composing] do
        assert state in AgentActivity.states()
        refute state in AgentActivity.signals()
      end
    end

    # `:listening` is untouched by this stage, and must stay that way: it is
    # deliberately unreachable (canvas `01a05b11-54ff`, ratified by Harper
    # 2026-09-03), and giving a runtime a way to declare it would rebuild
    # the always-on badge that decision removed.
    test ":listening gained no producer here", %{
      meeting: meeting,
      far_future: t0,
      agent_id: agent_id
    } do
      assert :listening in AgentActivity.states()
      refute :listening in AgentActivity.signals()
      refute :listening in AgentActivity.pushed_states()

      assert AgentActivity.push(meeting.id, agent_id, :listening, now: t0) ==
               {:error, {:unsupported_state, :listening}}
    end
  end

  # `resolve_at/3` answers `:idle` by ABSENCE, as every reader in this module
  # does. Collapsing that to the atom here is what lets the expiry assertions
  # be identity comparisons rather than `refute match?`.
  defp pushed_state_of(meeting_id, agent_id, now) do
    case Map.get(AgentActivity.resolve_at(AgentActivity.new(), meeting_id, now), agent_id) do
      %{state: state} -> state
      nil -> :idle
    end
  end
end
