defmodule Platform.Meetings.AskFloorTest do
  @moduledoc """
  Tests for `Platform.Meetings.AskFloor` — per-agent floor ownership for
  push-to-talk (task 01a0cf5c stage 1).

  Async-false because the module owns a single named ETS table started
  under `Platform.Application`'s supervision tree, matching
  `Platform.Meetings.PressWindowTest`.
  """

  use ExUnit.Case, async: false

  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @alice "user:11111111-1111-7111-8111-111111111111"
  @bob "user:22222222-2222-7222-8222-222222222222"

  setup context do
    # Namespace by test so a shared table can't leak state between them,
    # matching `PressWindowTest`.
    meeting_id = "meeting-#{inspect(context.test)}" |> :erlang.phash2() |> Integer.to_string()
    agent_id = "agent-#{inspect(context.test)}" |> :erlang.phash2() |> Integer.to_string()

    on_exit(fn -> AskFloor.clear_meeting(meeting_id) end)

    {:ok, meeting_id: meeting_id, agent_id: agent_id}
  end

  # The stuck-claim timer's own message, injected directly — the same
  # technique `press_card_test.exs` uses for `PressWindow`'s
  # `:grace_elapsed` timer, so the anti-vacuity claims below stay well
  # under `AskFloor.stuck_claim_ms/0` (120s) without sleeping through it.
  defp elapse_stuck_claim(meeting_id, agent_id, pressed_at, room_id, space_id \\ nil) do
    send(AskFloor, {:stuck_claim_elapsed, meeting_id, agent_id, pressed_at, room_id, space_id})
    # Synchronise on the GenServer so handle_info has run before the
    # caller asserts on the table or polls for a broadcast.
    :sys.get_state(AskFloor)
    :ok
  end

  describe "the atomic claim" do
    test "an unheld agent is claimed outright", %{meeting_id: m, agent_id: a} do
      assert AskFloor.holder(m, a) == :none

      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice")
      assert holder.identity == @alice
      assert holder.display_name == "Alice"
      assert holder.agent_id == a
      assert holder.meeting_id == m

      assert {:ok, ^holder} = AskFloor.holder(m, a)
    end

    test "a repeat claim by the SAME identity is idempotent and keeps the original pressed_at",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, first} = AskFloor.claim(m, a, @alice, "Alice")
      # A little air so a bug that overwrote pressed_at would be
      # reachable rather than accidentally passing on timing noise.
      Process.sleep(5)
      assert {:ok, second} = AskFloor.claim(m, a, @alice, "Alice")

      assert second.pressed_at == first.pressed_at
    end

    @tag :anti_vacuity
    test "a claim by a DIFFERENT identity is refused, and the original holder is unchanged",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, alice_claim} = AskFloor.claim(m, a, @alice, "Alice")

      # Reachability guard: the floor genuinely IS held, so the refusal
      # below cannot pass vacuously.
      assert {:ok, %{identity: @alice}} = AskFloor.holder(m, a)

      assert AskFloor.claim(m, a, @bob, "Bob") ==
               {:error, {:held_by, alice_claim}}

      # Bob's refused attempt did not disturb Alice's claim.
      assert {:ok, %{identity: @alice, pressed_at: pressed_at}} = AskFloor.holder(m, a)
      assert pressed_at == alice_claim.pressed_at
    end

    test "an invalid identity is refused outright", %{meeting_id: m, agent_id: a} do
      assert AskFloor.claim(m, a, nil, "Nobody") == {:error, :invalid_identity}
      assert AskFloor.claim(m, a, "", "Nobody") == {:error, :invalid_identity}
      assert AskFloor.claim(m, a, "   ", "Nobody") == {:error, :invalid_identity}
      assert AskFloor.holder(m, a) == :none
    end

    test "claims do not leak across meetings or across agents",
         %{meeting_id: m, agent_id: a} do
      other_meeting = m <> "-other"
      other_agent = a <> "-other"
      on_exit(fn -> AskFloor.clear_meeting(other_meeting) end)

      assert {:ok, _} = AskFloor.claim(m, a, @alice, "Alice")

      assert AskFloor.holder(other_meeting, a) == :none
      assert AskFloor.holder(m, other_agent) == :none
      # A different agent in the SAME meeting is free for Bob.
      assert {:ok, _} = AskFloor.claim(m, other_agent, @bob, "Bob")
    end

    test "claim/4 (no room id) still claims — the stuck-claim timer just cannot self-announce",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice")
      assert holder.identity == @alice
    end
  end

  describe "release" do
    test "the holder can release their own claim", %{meeting_id: m, agent_id: a} do
      assert {:ok, _} = AskFloor.claim(m, a, @alice, "Alice")
      assert AskFloor.release(m, a, @alice) == :ok
      assert AskFloor.holder(m, a) == :none
    end

    test "a release from someone who does NOT hold the floor is refused, and the real holder keeps it",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, alice_claim} = AskFloor.claim(m, a, @alice, "Alice")

      assert AskFloor.release(m, a, @bob) == {:error, :not_holder}
      assert {:ok, ^alice_claim} = AskFloor.holder(m, a)
    end

    test "releasing an agent with no claim at all answers :no_claim",
         %{meeting_id: m, agent_id: a} do
      assert AskFloor.release(m, a, @alice) == {:error, :no_claim}
    end

    test "after a release, a different identity can claim the same agent",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, _} = AskFloor.claim(m, a, @alice, "Alice")
      assert AskFloor.release(m, a, @alice) == :ok

      assert {:ok, bob_claim} = AskFloor.claim(m, a, @bob, "Bob")
      assert bob_claim.identity == @bob
    end
  end

  describe "list_meeting/1" do
    test "lists every held floor in the meeting, and nothing from another meeting",
         %{meeting_id: m, agent_id: a} do
      other_agent = a <> "-other"
      other_meeting = m <> "-other"
      on_exit(fn -> AskFloor.clear_meeting(other_meeting) end)

      assert AskFloor.list_meeting(m) == []

      {:ok, _} = AskFloor.claim(m, a, @alice, "Alice")
      {:ok, _} = AskFloor.claim(m, other_agent, @bob, "Bob")
      {:ok, _} = AskFloor.claim(other_meeting, a, @alice, "Alice")

      held_agent_ids = m |> AskFloor.list_meeting() |> Enum.map(& &1.agent_id) |> Enum.sort()
      assert held_agent_ids == Enum.sort([a, other_agent])
    end
  end

  describe "the stuck-claim timeout" do
    test "mirrors PressWindow.max_hold_ms/0", _context do
      assert AskFloor.stuck_claim_ms() == PressWindow.max_hold_ms()
    end

    test "an elapsed stuck claim is evicted and broadcasts :ask_floor_released on the room topic",
         %{meeting_id: m, agent_id: a} do
      room_id = "room-#{m}"
      MeetingsPubSub.subscribe_room(room_id)

      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice", room_id)

      elapse_stuck_claim(m, a, holder.pressed_at, room_id)

      assert AskFloor.holder(m, a) == :none
      assert_received {:ask_floor_released, %{agent_id: ^a}}
    end

    test "a stale timer message for a claim that was already released is a no-op",
         %{meeting_id: m, agent_id: a} do
      room_id = "room-#{m}"
      MeetingsPubSub.subscribe_room(room_id)

      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice", room_id)
      assert AskFloor.release(m, a, @alice) == :ok

      # The timer armed by the ORIGINAL claim fires after the release —
      # it must not touch (or broadcast about) whatever holds the floor
      # now, because there IS nothing to release any more.
      elapse_stuck_claim(m, a, holder.pressed_at, room_id)

      refute_received {:ask_floor_released, %{agent_id: ^a}}
    end

    test "a stale timer message for a claim that was already RENEWED (released and reclaimed) does not evict the new claim",
         %{meeting_id: m, agent_id: a} do
      room_id = "room-#{m}"
      MeetingsPubSub.subscribe_room(room_id)

      assert {:ok, alice_claim} = AskFloor.claim(m, a, @alice, "Alice", room_id)
      assert AskFloor.release(m, a, @alice) == :ok
      assert {:ok, bob_claim} = AskFloor.claim(m, a, @bob, "Bob", room_id)

      # Alice's now-stale timer fires. Its `pressed_at` no longer
      # matches the CURRENT claim (Bob's), so the guard in
      # `AskFloor.handle_info/2` must refuse to evict it.
      elapse_stuck_claim(m, a, alice_claim.pressed_at, room_id)

      assert {:ok, ^bob_claim} = AskFloor.holder(m, a)
      refute_received {:ask_floor_released, %{agent_id: ^a}}
    end

    test "an elapsed stuck claim with no room id evicts silently (nothing to broadcast to)",
         %{meeting_id: m, agent_id: a} do
      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice")

      elapse_stuck_claim(m, a, holder.pressed_at, nil)

      assert AskFloor.holder(m, a) == :none
    end

    test "the eviction un-sticks the agent for a new claimant", %{meeting_id: m, agent_id: a} do
      assert {:ok, holder} = AskFloor.claim(m, a, @alice, "Alice")

      # Alice's socket drops — nobody ever calls release/3.
      elapse_stuck_claim(m, a, holder.pressed_at, nil)

      assert {:ok, bob_claim} = AskFloor.claim(m, a, @bob, "Bob")
      assert bob_claim.identity == @bob
    end
  end
end
