defmodule Platform.Meetings.MeetingSayBudgetTest do
  @moduledoc """
  Task 01a06672 stage 2 — the reply budget inside `Platform.Meetings.say/4`.

  Two rules, two errors, checked in `say/4` itself so every caller is
  covered:

    * R1 rate — at most 6 accepted says per (room, agent) per trailing
      minute: `:reply_budget_exhausted`.
    * R2 chain — no agent-to-agent chain deeper than 3 without a human
      segment between: `:agent_chain_too_deep`. Fed from the transcript
      (what the ticket names) AND from the say ledger (what closes the gap
      before STT lands the agents' own audio).

  ## Why the rate tests mark a human between says

  R1 and R2(b) interact by design: six accepted says by one agent with no
  human in between is exactly the chain R2 exists to cut, so the 4th would
  be refused as `:agent_chain_too_deep` before the rate rule could ever
  fire. The rate tests therefore note a human segment before each say
  (`SayRegistry.note_human_segment/2`, the same write a persisted final
  human segment makes), so that only R1 is in play.

  Every accepted say here is a real `say/4` with a real runtime topic,
  finishing as `no_ack` through the 50 ms app-env ack seam; nothing is
  stubbed between the budget and the broadcast.

  `async: false` — LiveKit and the ack seam live in app env, and
  `SayRegistry` is one pair of named ETS tables.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.SayRegistry
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  # ── Fixtures (from meeting_say_test.exs) ─────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "say-budget-#{n}@example.com",
      name: "Say Budget #{n}",
      oidc_sub: "oidc-say-budget-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "budget-agent-#{n}",
      name: "Budget Agent #{n}",
      status: "active"
    })
  end

  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "budget-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    runtime = Federation.get_runtime(activated.id)
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{agent: agent, runtime: runtime}
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Budget Space #{n}",
        slug: "budget-space-#{n}",
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

  defp seat_agent!(room, agent) do
    {:ok, participant} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    participant
  end

  defp transcript!(%{space: space, room: room}) do
    {:ok, %Transcript{} = transcript} =
      Meetings.ensure_transcript(%{room_id: room.livekit_room_name, space_id: space.id})

    transcript
  end

  defp segment(identity, text) do
    %{
      "participant_identity" => identity,
      "speaker_name" => identity,
      "text" => text,
      "start_time" => 0,
      "end_time" => 500,
      "final" => true
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A human spoke just now — the write `deliver_transcript_segment/2` makes
  # for a persisted final human segment, without the transcript round trip.
  defp human_spoke!(room), do: SayRegistry.note_human_segment(room.livekit_room_name, now_ms())

  defp say(agent, room, text \\ "hello"), do: Meetings.say(agent, room.livekit_room_name, text)

  defp ledger_row!(room, agent, at_ms) do
    SayRegistry.ledger_put(Platform.Types.UUIDv7.generate(), %{
      room_id: room.id,
      room_name: room.livekit_room_name,
      agent_id: agent.id,
      at_ms: at_ms
    })
  end

  setup do
    original_livekit = Application.get_env(:platform, :livekit, [])
    original_timeout = Application.get_env(:platform, :meeting_say_ack_timeout_ms)

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    # Six real `say/4` calls per test; without this seam each `no_ack`
    # would be a 15-second wait.
    Application.put_env(:platform, :meeting_say_ack_timeout_ms, 50)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_timeout do
        nil -> Application.delete_env(:platform, :meeting_say_ack_timeout_ms)
        v -> Application.put_env(:platform, :meeting_say_ack_timeout_ms, v)
      end
    end)

    :ok
  end

  # ── R1: rate ─────────────────────────────────────────────────────────────

  describe "the rate rule" do
    test "the seventh say inside one minute is refused as :reply_budget_exhausted and broadcasts nothing" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat_agent!(room, agent)

      for n <- 1..6 do
        human_spoke!(room)
        assert {:ok, %{status: "no_ack"}} = say(agent, room, "utterance #{n}")
        assert_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 500
      end

      human_spoke!(room)
      assert {:error, :reply_budget_exhausted} = say(agent, room, "utterance 7")
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "the budget is per agent per room" do
      %{room: room_a} = room!()
      %{room: room_b} = room!()
      %{agent: a} = agent_with_runtime!()
      %{agent: b} = agent_with_runtime!()
      seat_agent!(room_a, a)
      seat_agent!(room_a, b)
      seat_agent!(room_b, a)

      for n <- 1..6 do
        human_spoke!(room_a)
        assert {:ok, %{status: "no_ack"}} = say(a, room_a, "a #{n}")
      end

      assert {:error, :reply_budget_exhausted} = say(a, room_a, "a 7")

      # Same room, other agent: still allowed.
      assert {:ok, %{status: "no_ack"}} = say(b, room_a, "b 1")

      # Same agent, other room: still allowed.
      assert {:ok, %{status: "no_ack"}} = say(a, room_b, "a elsewhere")
    end

    test "rows older than the window no longer count" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat_agent!(room, agent)

      stale = now_ms() - 61_000
      for _ <- 1..6, do: ledger_row!(room, agent, stale)

      # The backdated rows are still inside the ledger ttl, so they would
      # also read as an agent chain; a human speaking after them (but still
      # outside the rate window) is what a real room would have.
      SayRegistry.note_human_segment(room.livekit_room_name, now_ms() - 30_000)

      assert {:ok, %{status: "no_ack"}} = say(agent, room, "fresh minute")
    end
  end

  # ── R2: chain ────────────────────────────────────────────────────────────

  describe "the agent-chain rule" do
    test "three agent segments with no human between are refused as :agent_chain_too_deep, one human segment re-allows" do
      %{room: room} = fixture = room!()
      %{agent: a} = agent_with_runtime!()
      %{agent: b} = agent_with_runtime!()
      seat_agent!(room, a)
      seat_agent!(room, b)
      transcript = transcript!(fixture)

      for {identity, text} <- [
            {"agent:#{a.slug}", "first"},
            {"agent:#{b.slug}", "second"},
            {"agent:#{a.slug}", "third"}
          ] do
        assert {:ok, %Transcript{}} =
                 Meetings.append_segment(transcript.id, segment(identity, text))
      end

      assert {:error, :agent_chain_too_deep} = say(a, room)
      assert {:error, :agent_chain_too_deep} = say(b, room)
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100

      assert {:ok, %Transcript{}} =
               Meetings.append_segment(
                 transcript.id,
                 segment("user:#{Ecto.UUID.generate()}", "a human, finally")
               )

      assert {:ok, %{status: "no_ack"}} = say(a, room)
    end

    test "three accepted says with no human segment since are refused even before the transcript catches up" do
      %{room: room} = fixture = room!()
      %{agent: a} = agent_with_runtime!()
      %{agent: b} = agent_with_runtime!()
      seat_agent!(room, a)
      seat_agent!(room, b)

      # No transcript segments at all: the transcript side of R2 is silent.
      assert {:ok, %{status: "no_ack"}} = say(a, room, "one")
      assert {:ok, %{status: "no_ack"}} = say(b, room, "two")
      assert {:ok, %{status: "no_ack"}} = say(a, room, "three")

      assert {:error, :agent_chain_too_deep} = say(b, room, "four")
      assert {:error, :agent_chain_too_deep} = say(a, room, "four again")

      transcript = transcript!(fixture)

      assert {:ok, %Transcript{}} =
               Meetings.append_segment(
                 transcript.id,
                 segment("user:#{Ecto.UUID.generate()}", "let me get a word in")
               )

      assert {:ok, %{status: "no_ack"}} = say(b, room, "after the human")
    end
  end

  # ── Order ────────────────────────────────────────────────────────────────

  describe "where the check sits" do
    test "a refusal happens before any token is minted or runtime resolved" do
      %{room: room} = room!()
      # No runtime linked: past the budget this agent would be :no_runtime.
      agent = agent!()
      seat_agent!(room, agent)

      for _ <- 1..6, do: ledger_row!(room, agent, now_ms())

      assert {:error, :reply_budget_exhausted} = say(agent, room)
    end

    test "an uninvited agent is still :not_in_room, not a budget refusal" do
      %{room: room} = room!()
      agent = agent!()

      for _ <- 1..6, do: ledger_row!(room, agent, now_ms())

      assert {:error, :not_in_room} = say(agent, room)
    end
  end
end
