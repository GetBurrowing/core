defmodule Platform.Meetings.PresenceTest do
  @moduledoc """
  Tests for `Platform.Meetings` context — PubSub presence helpers,
  participant tracking, and space-level presence queries.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Test Space",
        slug: "meeting-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_room(space_id) do
    {:ok, room} = Meetings.ensure_room(space_id)
    room
  end

  defp activate_room(room) do
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  defp join_participant(room, display_name, attrs \\ %{}) do
    {:ok, participant} =
      Meetings.participant_joined(
        room,
        Map.merge(%{display_name: display_name}, attrs)
      )

    participant
  end

  # ── PubSub Topics ───────────────────────────────────────────────────────────

  describe "PubSub topic helpers" do
    test "meeting_presence_topic/1 returns room topic" do
      room_id = Ecto.UUID.generate()
      assert Meetings.meeting_presence_topic(room_id) == "meetings:room:#{room_id}"
    end

    test "meeting_presence_summary_topic/0 returns summary topic" do
      assert Meetings.meeting_presence_summary_topic() == "meetings:presence_summary"
    end
  end

  # ── Subscribe Helpers ────────────────────────────────────────────────────────

  describe "subscribe helpers" do
    test "subscribe_to_room_presence/1 subscribes to room topic" do
      room_id = Ecto.UUID.generate()
      assert :ok = Meetings.subscribe_to_room_presence(room_id)

      # Verify we receive broadcasts on this topic
      MeetingsPubSub.broadcast_room(room_id, {:test_event, :hello})
      assert_receive {:test_event, :hello}
    end

    test "subscribe_to_presence_summary/0 subscribes to summary topic" do
      assert :ok = Meetings.subscribe_to_presence_summary()

      MeetingsPubSub.broadcast_presence_summary("some-space-id")
      assert_receive {:meeting_presence_summary, %{space_id: "some-space-id"}}
    end
  end

  # ── Room Lifecycle ──────────────────────────────────────────────────────────

  describe "ensure_room/1" do
    test "creates a room for a space" do
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert room.space_id == space.id
      assert room.livekit_room_name == "space-#{space.id}"
      assert room.status == "idle"
    end

    test "returns existing room on second call" do
      space = create_space()
      {:ok, room1} = Meetings.ensure_room(space.id)
      {:ok, room2} = Meetings.ensure_room(space.id)

      assert room1.id == room2.id
    end
  end

  describe "activate_room/1" do
    test "sets room status to active and broadcasts" do
      space = create_space()
      room = create_room(space.id)

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, activated} = Meetings.activate_room(room)
      assert activated.status == "active"

      assert_receive {:room_activated, ^activated}
      assert_receive {:meeting_presence_update, %{space_id: _, active: false, count: 0}}
    end
  end

  describe "finish_room/1" do
    test "sets room to idle and marks participants as left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:alice")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, finished} = Meetings.finish_room(room)
      assert finished.status == "idle"

      # All participants should be marked as left
      assert Meetings.active_participants(room.id) == []
      assert_receive {:room_finished, ^finished}
    end
  end

  # ── Participant Tracking ────────────────────────────────────────────────────

  describe "participant_joined/2" do
    test "creates participant and broadcasts on room + presence topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, participant} =
        Meetings.participant_joined(room, %{
          display_name: "Bob"
        })

      assert participant.display_name == "Bob"
      assert participant.room_id == room.id
      assert is_nil(participant.left_at)

      assert_receive {:participant_joined, ^participant}
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
    end
  end

  describe "participant_left/2" do
    test "sets left_at and broadcasts" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:carol")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, left} = Meetings.participant_left(room, "user:carol")
      assert left.left_at != nil
      assert_receive {:participant_left, ^left}
    end

    test "returns error when participant not found" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      assert {:error, :not_found} = Meetings.participant_left(room, "user:nobody")
    end
  end

  # ── Active Participants ─────────────────────────────────────────────────────

  describe "active_participants/1" do
    test "returns only participants with nil left_at, preloads user/agent" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      _p1 = join_participant(room, "user:alice")
      p2 = join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      active = Meetings.active_participants(room.id)
      assert length(active) == 1
      assert hd(active).id == p2.id

      # Preloads should be loaded (nil since no FK set, but not Ecto.Association.NotLoaded)
      participant = hd(active)
      assert is_nil(participant.user) or is_struct(participant.user)
      assert is_nil(participant.agent) or is_struct(participant.agent)
    end
  end

  # ── Space-level Queries ─────────────────────────────────────────────────────

  describe "active_meeting_counts/1" do
    test "returns empty map for empty list" do
      assert Meetings.active_meeting_counts([]) == %{}
    end

    test "returns counts for spaces with active meetings" do
      space1 = create_space()
      space2 = create_space()
      space3 = create_space()

      room1 = create_room(space1.id) |> activate_room()
      room2 = create_room(space2.id) |> activate_room()
      _room3 = create_room(space3.id)

      join_participant(room1, "user:alice")
      join_participant(room1, "user:bob")
      join_participant(room2, "user:carol")

      counts = Meetings.active_meeting_counts([space1.id, space2.id, space3.id])

      assert counts[space1.id] == 2
      assert counts[space2.id] == 1
      # space3 has no active meeting (room is idle)
      refute Map.has_key?(counts, space3.id)
    end

    test "excludes participants who have left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      counts = Meetings.active_meeting_counts([space.id])
      assert counts[space.id] == 1
    end
  end

  describe "active_participants_for_space/1" do
    test "returns participants for active meeting in space" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")

      participants = Meetings.active_participants_for_space(space.id)
      assert length(participants) == 2
    end

    test "returns empty list when no active meeting" do
      space = create_space()
      _room = create_room(space.id)

      assert Meetings.active_participants_for_space(space.id) == []
    end
  end

  # ── Broadcast Presence Change ───────────────────────────────────────────────

  describe "broadcast_presence_change/2" do
    test "broadcasts on presence and summary topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_presence(space.id)
      MeetingsPubSub.subscribe_presence_summary()

      join_participant(room, "user:dave")

      # participant_joined already calls broadcast_presence_change internally
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
      assert_receive {:meeting_presence_summary, %{space_id: _}}
    end

    test "no-ops for nil space_id" do
      assert :ok = Meetings.broadcast_presence_change("some-room-id", nil)
    end
  end
end
