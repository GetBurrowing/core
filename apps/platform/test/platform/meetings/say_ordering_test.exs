defmodule Platform.Meetings.SayOrderingTest do
  @moduledoc """
  Task 01a07401 stage 1 — an agent's spoken line carries an ordering key that
  reflects when it was SPOKEN, not when its ack came back.

  ## Why this is not covered by `MeetingSayTest`

  That suite drives the rendezvous with an ack that answers immediately, so
  dispatch time and insert time are indistinguishable there. The defect this
  file guards lives in the gap between them: `record_agent_say_ack/2` can run
  seconds after the dispatch (the 15 s rendezvous) or minutes after it (the
  `SayRegistry` back-fill window is five minutes), and the chat row's own
  `inserted_at` is stamped at THAT moment. Ordering a meeting by `inserted_at`
  therefore files a slowly-acked line after everything said while it was in
  flight.

  ## What each assertion is worth

  The first test deliberately delays the ack and then asserts three separate
  things about `metadata["spoken_at"]`: that it EQUALS the `dispatched_at`
  the registry recorded at broadcast time, that it is STRICTLY EARLIER than
  the row's `inserted_at`, and that the gap is at least as wide as the delay
  the test introduced. Asserting only that the field is non-nil would pass on
  a value copied from insertion — which is precisely the bug — so it is not
  asserted that way anywhere here.

  The second test is the guard on `SayRegistry.delete/1` at the stamp site:
  the entry is consumed by the first matching ack, so a replayed or duplicated
  ack finds nothing and posts nothing. Restructuring the stamp must not cost
  us that.

  `async: false` — LiveKit lives in app env and `SayRegistry` is a single
  named ETS table, same as `MeetingSayTest`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.SayRegistry
  alias Platform.Repo

  # How long the ack is held back. Big enough that a `spoken_at` copied from
  # the row's own `inserted_at` cannot squeak under the "strictly earlier"
  # bar by clock jitter, small enough not to slow the suite. A plain sleep is
  # the right tool: the thing under test IS elapsed wall time between two
  # events, not a process reaching a state we could monitor for.
  @ack_delay_ms 40

  # ── Fixtures (same shapes as MeetingSayTest) ─────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "say-order-#{n}@example.com",
      name: "Say Order #{n}",
      oidc_sub: "oidc-say-order-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "say-order-agent-#{n}",
      name: "Say Order Agent #{n}",
      status: "active"
    })
  end

  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "say-order-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Say Order Space #{n}",
        slug: "say-order-space-#{n}",
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

  defp seated_agent! do
    %{space: space, room: room} = room!()
    %{agent: agent, runtime: runtime} = agent_with_runtime!()

    {:ok, _row} = Chat.add_agent_participant(space.id, agent)

    {:ok, _participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{space: space, room: room, agent: agent, room_name: room.livekit_room_name}
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

  # ── The ordering key ─────────────────────────────────────────────────────

  describe "a spoken line acked late" do
    test "is stamped with the dispatch time, strictly earlier than its own inserted_at" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "hello", ack_timeout_ms: 5_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      # Read the recorded dispatch time straight out of the registry, before
      # the ack consumes the entry. This is the value the stamp must equal.
      assert %{dispatched_at: %DateTime{} = dispatched_at} = SayRegistry.get(id)

      # The runtime takes its time answering. This is the whole scenario.
      Process.sleep(@ack_delay_ms)

      assert :ok =
               Meetings.record_agent_say_ack(agent.id, %{
                 "utterance_id" => id,
                 "room_name" => room_name,
                 "status" => "spoken",
                 "duration_s" => 0.4
               })

      assert {:ok, %{status: "spoken", utterance_id: ^id}} = Task.await(task)

      assert [%Message{content: "hello", metadata: metadata} = message] = say_messages(space.id)

      # 1. The stamp IS the recorded dispatch time, not some other clock read.
      assert metadata["spoken_at"] == DateTime.to_iso8601(dispatched_at)

      # 2. It is an approximation, and it says so in the row.
      assert metadata["spoken_at_source"] == "dispatch"

      {:ok, spoken_at, 0} = DateTime.from_iso8601(metadata["spoken_at"])

      # 3. Strictly earlier than the row's own insert time. A `spoken_at`
      #    copied from insertion would be EQUAL and would fail here.
      assert DateTime.compare(spoken_at, message.inserted_at) == :lt

      # 4. And earlier by at least the delay we introduced — so it tracks the
      #    dispatch, rather than merely being a hair ahead of the insert.
      skew_us = DateTime.diff(message.inserted_at, spoken_at, :microsecond)
      assert skew_us >= @ack_delay_ms * 1_000
    end
  end

  # ── The replay guard ─────────────────────────────────────────────────────

  describe "the same spoken ack delivered twice" do
    test "posts exactly one message" do
      %{space: space, agent: agent, room_name: room_name} = seated_agent!()

      task = Task.async(fn -> Meetings.say(agent, room_name, "once", ack_timeout_ms: 5_000) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      ack = %{
        "utterance_id" => id,
        "room_name" => room_name,
        "status" => "spoken"
      }

      assert :ok = Meetings.record_agent_say_ack(agent.id, ack)
      assert :ok = Meetings.record_agent_say_ack(agent.id, ack)

      assert {:ok, %{status: "spoken", utterance_id: ^id}} = Task.await(task)

      # The registry entry is consumed by the first ack, so the replay has no
      # text to post — and the ordering stamp it would have carried is gone
      # with it.
      assert SayRegistry.get(id) == nil
      assert [%Message{content: "once"}] = say_messages(space.id)
    end
  end
end
