defmodule Platform.Meetings.MeetingSaySpeakingTest do
  @moduledoc """
  `:speaking` through the REAL call sites — `Platform.Meetings.say/4` and
  `Platform.Meetings.record_agent_say_ack/2` (task `01a07400` stage 2).

  ## Why this file exists alongside the unit tests

  `agent_activity_speaking_delayed_test.exs` proves that
  `AgentActivity.mark_speaking/4` sets the state and
  `AgentActivity.clear_speaking/3` clears it. Every one of those tests
  passes against a `meetings.ex` that never calls either function — which
  is the whole feature missing. This file drives the two public entry
  points instead, so the two inserted lines in `meetings.ex` are the thing
  under test.

  ## The pair that has to hold

  Set at dispatch AND cleared on the ack, asserted in one test. A test that
  only checked the state appears would pass against an implementation that
  never cleared it, and an agent pinned as permanently speaking is
  `:listening` under a new word — the failure canvas `01a05b11-54ff`
  removed that state for.

  The ttl is deliberately NOT what ends the state in these tests: the row
  for a five-character utterance is live for seconds, and every read here
  happens immediately. If the ack were not clearing it, these assertions
  would see `:speaking`.

  `async: false` — LiveKit config lives in app env, and both `SayRegistry`
  and the `:speaking` store are single named ETS tables.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  # ── Fixtures ─────────────────────────────────────────────────────────────
  #
  # Same shape as `meeting_say_test.exs`, plus the one thing that file does
  # not need: a live `meetings` row. `AgentActivity` keys on `meetings.id`,
  # so without it there is no rail to paint and `SpeakingWindow` is a
  # deliberate no-op — which the last test in this file pins directly.

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "say-speaking-#{n}@example.com",
      name: "Say Speaking #{n}",
      oidc_sub: "oidc-say-speaking-#{n}"
    })
  end

  defp agent_with_runtime! do
    n = System.unique_integer([:positive])
    owner = user!()

    agent =
      Repo.insert!(%Agent{
        slug: "say-speaking-agent-#{n}",
        name: "Say Speaking Agent #{n}",
        status: "active"
      })

    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "say-speaking-rt-#{n}"})
    {:ok, activated, _raw} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Say Speaking Space #{n}",
        slug: "say-speaking-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp live_meeting!(space, room) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "Say Speaking Project #{n}",
        slug: "say-speaking-project-#{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })
      |> Repo.insert()

    {:ok, meeting} =
      %Meeting{id: Platform.Types.UUIDv7.generate()}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "say-speaking-meeting-#{n}",
        name: "Say Speaking Meeting",
        livekit_room_name: room.livekit_room_name,
        status: "live"
      })
      |> Repo.insert()

    meeting
  end

  # A seated, chat-member agent with a linked runtime, in a room whose
  # space has a LIVE meeting row.
  defp seated_agent!(opts \\ []) do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    %{agent: agent, runtime: runtime} = agent_with_runtime!()
    {:ok, _} = Chat.add_agent_participant(space.id, agent)

    {:ok, _participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    meeting = if Keyword.get(opts, :meeting?, true), do: live_meeting!(space, room)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{
      space: space,
      room: room,
      agent: agent,
      meeting: meeting,
      room_name: room.livekit_room_name
    }
  end

  defp speaking_state(nil, _agent_id), do: :idle

  defp speaking_state(%Meeting{id: meeting_id}, agent_id) do
    case AgentActivity.resolve_at(AgentActivity.new(), meeting_id, DateTime.utc_now()) do
      %{^agent_id => %{state: state}} -> state
      _ -> :idle
    end
  end

  # Polling, and ONLY on the set side.
  #
  # `say/4` broadcasts the `meeting_say` frame and opens the window on the
  # next line, in that order — the state is "core has sent the audio", and
  # a broadcast that failed sent nothing. When `say/4` runs in a `Task`
  # (which it must, because it then blocks on the ack), `assert_receive`
  # wakes this process on the broadcast, one line early. That is a race in
  # the TEST, not in the feature.
  #
  # The clear side is never polled. `record_agent_say_ack/2` runs in the
  # test process, so by the time it returns the window is either closed or
  # it is not, and the assertion after it is exact. A polled clear would be
  # the vacuous version of this test: it would pass on an implementation
  # that cleared eventually for any reason, expiry included.
  defp await_speaking!(%Meeting{} = meeting, agent_id) do
    assert_eventually(fn -> AgentActivity.speaking(meeting.id, agent_id) end)
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

  # ── The pair ─────────────────────────────────────────────────────────────

  describe "say/4 and record_agent_say_ack/2" do
    # THE anti-vacuity test for this stage's `:speaking` half, at the call
    # sites.
    #
    # Both ends asserted, both by identity. Named mutation, run: delete the
    # `SpeakingWindow.acked/2` line from `record_agent_say_ack/2`. The
    # second half goes RED (the agent stays `:speaking`) while "the
    # dispatch opens the window" below stays green. The mutant did not
    # survive. Deleting the `SpeakingWindow.dispatched/4` line instead
    # turns BOTH red, which is the other direction of the same pair.
    test "the dispatch opens the window and the ack closes it" do
      %{agent: agent, meeting: meeting, room_name: room_name} = seated_agent!()

      assert speaking_state(meeting, agent.id) == :idle

      task =
        Task.async(fn -> Meetings.say(agent, room_name, "hello there", ack_timeout_ms: 5_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: utterance_id}
                     },
                     2_000

      # SET — by the dispatch, and nothing else has happened yet.
      assert %{utterance_id: ^utterance_id, state: :speaking} =
               await_speaking!(meeting, agent.id)

      assert speaking_state(meeting, agent.id) == :speaking

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => utterance_id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 0.9
               })

      assert {:ok, %{status: "spoken"}} = Task.await(task)

      # CLEARED — by the ack. The row's ttl is seconds long and none of it
      # has elapsed, so expiry cannot account for this.
      assert speaking_state(meeting, agent.id) == :idle
      assert AgentActivity.speaking(meeting.id, agent.id) == nil
    end

    # A `"failed"` receipt means the audio is not playing either. Leaving
    # the window open on it would show the one state that is definitely
    # false.
    test "a failed ack closes the window too" do
      %{agent: agent, meeting: meeting, room_name: room_name} = seated_agent!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "hi", ack_timeout_ms: 5_000) end)

      assert_receive %Phoenix.Socket.Broadcast{payload: %{utterance_id: utterance_id}}, 2_000
      assert %{state: :speaking} = await_speaking!(meeting, agent.id)

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "failed",
        "error" => "tts_unavailable"
      })

      assert {:ok, %{status: "failed"}} = Task.await(task)
      assert speaking_state(meeting, agent.id) == :idle
    end

    # The same guard `post_spoken_utterance/2` applies before putting text
    # in chat, for the smaller version of the same problem.
    test "an ack from a DIFFERENT agent does not close the window" do
      %{agent: agent, meeting: meeting, room_name: room_name} = seated_agent!()
      %{agent: impostor} = agent_with_runtime!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "mine", ack_timeout_ms: 800) end)

      assert_receive %Phoenix.Socket.Broadcast{payload: %{utterance_id: utterance_id}}, 2_000
      assert %{state: :speaking} = await_speaking!(meeting, agent.id)

      Meetings.record_agent_say_ack(impostor.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "spoken"
      })

      assert speaking_state(meeting, agent.id) == :speaking
      Task.await(task, 3_000)

      # The real agent's own ack still works.
      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => utterance_id,
        "room_name" => room_name,
        "status" => "spoken"
      })

      assert speaking_state(meeting, agent.id) == :idle
    end

    # `no_ack` is the case the ttl exists for. The window stays open — the
    # audio may well be playing — and the row carries a bound derived from
    # the length of the text, so it cannot latch forever.
    test "no_ack leaves the window open, bounded by a ttl scaled to the text" do
      %{agent: agent, meeting: meeting, room_name: room_name} = seated_agent!()

      long = String.duplicate("a", 1_000)

      assert {:ok, %{status: "no_ack"}} =
               Meetings.say(agent, room_name, long, ack_timeout_ms: 150)

      assert speaking_state(meeting, agent.id) == :speaking

      entry = AgentActivity.speaking(meeting.id, agent.id)
      assert entry.ttl_ms == AgentActivity.speaking_ttl_ms(1_000)

      # Magnitude, not sign: a thousand characters buys more than a minute
      # over the floor, so a dropped or zeroed rate would fail here rather
      # than sit inside the noise.
      assert entry.ttl_ms - AgentActivity.speaking_ttl_ms(0) >= 60_000

      # And the bound is real: the row is gone once it elapses, with no ack
      # and nothing swept.
      well_past = DateTime.add(entry.started_at, 10 * div(entry.ttl_ms, 1_000), :second)
      assert AgentActivity.speaking(meeting.id, agent.id, well_past) == nil

      AgentActivity.clear_speaking(meeting.id, agent.id, entry.utterance_id)
    end

    # A refusal returns before the broadcast, so nothing was ever
    # dispatched and nothing may claim the agent is talking.
    test "a say that is refused before dispatch opens no window" do
      %{agent: agent, meeting: meeting} = seated_agent!()

      assert {:error, :room_not_found} =
               Meetings.say(agent, "no-such-room-#{System.unique_integer([:positive])}", "hi")

      assert speaking_state(meeting, agent.id) == :idle
      assert AgentActivity.speaking(meeting.id, agent.id) == nil
    end

    # A bare LiveKit room with no `meetings` row has no shell topic and no
    # rail. `SpeakingWindow` is a silent no-op there — a say must never
    # fail over a state that is at most a UI nicety.
    test "a room with no live meeting row still says, and writes no state" do
      %{agent: agent, room_name: room_name} = seated_agent!(meeting?: false)

      assert {:ok, %{status: "no_ack"}} =
               Meetings.say(agent, room_name, "no meeting here", ack_timeout_ms: 150)

      assert_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}

      assert AgentActivity.speaking_all(Platform.Types.UUIDv7.generate(), DateTime.utc_now()) ==
               %{}
    end
  end
end
