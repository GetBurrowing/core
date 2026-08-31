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
end
