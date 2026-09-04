defmodule Platform.Chat.MeetingSpacesTest do
  @moduledoc """
  Covers the partition helper the "Add Agent to Space" picker uses to
  collapse meeting-kind spaces into their own group instead of flooding
  the `<select>` with them.

  Two load-bearing properties:

    * **Both meeting kinds.** `guest_meeting` is the externally-joinable
      variant and floods the same picker as plain `meeting` spaces. An
      implementation that only recognizes `"meeting"` leaves half the
      problem unfixed.

    * **Conservation.** Every input space lands in exactly one bucket —
      `others` or `meetings` — never both, never neither. Asserted on the
      union of ids, not just on bucket lengths, so a duplicate-and-drop
      bug in the same input cannot cancel out unnoticed.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.MeetingSpaces
  alias Platform.Chat.Space

  defp space(name, kind, inserted_at \\ nil) do
    %Space{
      id: Ecto.UUID.generate(),
      name: name,
      slug: name,
      kind: kind,
      inserted_at: inserted_at
    }
  end

  defp at(offset_seconds) do
    DateTime.add(~U[2026-09-04 12:00:00.000000Z], offset_seconds, :second)
  end

  describe "meeting_kind?/1" do
    test "true for meeting and guest_meeting" do
      assert MeetingSpaces.meeting_kind?(space("standup", "meeting"))
      assert MeetingSpaces.meeting_kind?(space("guest-call", "guest_meeting"))
    end

    test "false for every non-meeting kind" do
      refute MeetingSpaces.meeting_kind?(space("gen", "channel"))
      refute MeetingSpaces.meeting_kind?(space("rowan", "dm"))
      refute MeetingSpaces.meeting_kind?(space("crew", "group"))
      refute MeetingSpaces.meeting_kind?(space("task-exec", "execution"))
      refute MeetingSpaces.meeting_kind?(space("sys", "system"))
    end
  end

  describe "partition_for_picker/1" do
    test "returns {[], []} for an empty list" do
      assert MeetingSpaces.partition_for_picker([]) == {[], []}
    end

    test "puts a channel-kind space in others, not meetings" do
      channel = space("gen", "channel")

      assert MeetingSpaces.partition_for_picker([channel]) == {[channel], []}
    end

    test "puts both a meeting and a guest_meeting space in meetings" do
      meeting = space("standup", "meeting", at(0))
      guest = space("guest-call", "guest_meeting", at(1))

      {others, meetings} = MeetingSpaces.partition_for_picker([meeting, guest])

      assert others == []
      assert MapSet.new(meetings, & &1.id) == MapSet.new([meeting.id, guest.id])
    end

    test "others preserves input order" do
      a = space("a", "channel")
      b = space("b", "group")
      c = space("c", "execution")
      d = space("d", "system")

      {others, _meetings} = MeetingSpaces.partition_for_picker([a, b, c, d])

      assert others == [a, b, c, d]
    end

    test "meetings is ordered newest inserted_at first" do
      oldest = space("standup-1", "meeting", at(0))
      middle = space("guest-1", "guest_meeting", at(10))
      newest = space("standup-2", "meeting", at(20))

      {_others, meetings} = MeetingSpaces.partition_for_picker([oldest, middle, newest])

      assert meetings == [newest, middle, oldest]
    end

    test "conservation: partitions a mixed input exactly, nothing dropped or duplicated" do
      channel = space("gen", "channel")
      group = space("crew", "group")
      system = space("sys", "system")
      meeting = space("standup", "meeting", at(0))
      guest = space("guest-call", "guest_meeting", at(1))

      spaces = [channel, group, system, meeting, guest]
      {others, meetings} = MeetingSpaces.partition_for_picker(spaces)

      assert length(others) + length(meetings) == length(spaces)

      input_ids = MapSet.new(spaces, & &1.id)
      output_ids = MapSet.new(others ++ meetings, & &1.id)
      assert output_ids == input_ids

      # Nothing duplicated across buckets.
      assert MapSet.new(others, & &1.id) |> MapSet.disjoint?(MapSet.new(meetings, & &1.id))

      # And the kind split is correct, not just the counts.
      assert MapSet.new(others, & &1.id) == MapSet.new([channel, group, system], & &1.id)
      assert MapSet.new(meetings, & &1.id) == MapSet.new([meeting, guest], & &1.id)
    end
  end
end
