defmodule Platform.Chat.PinnedSpacesTest do
  @moduledoc """
  Covers the partition helper the chat rail uses to lift pinned
  conversations out of their home sections into the Pinned block.

  Two load-bearing properties:

    * **Kind-agnostic.** A DM and a channel are both `chat_spaces` rows and
      must partition identically. An implementation that filters on `kind`
      anywhere passes every channel-only test and silently drops every
      pinned DM out of the block.

    * **Skip-unknown.** Pin ids live in preferences JSONB and outlive the
      spaces they name. A pinned id matching no space in the input appears
      in neither half and does not raise.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.PinnedSpaces
  alias Platform.Chat.Space

  defp space(name, kind \\ "channel") do
    %Space{id: Ecto.UUID.generate(), name: name, slug: name, kind: kind}
  end

  describe "partition/2" do
    test "returns {[], spaces} when the pin list is empty" do
      a = space("alpha")
      b = space("bravo")

      assert PinnedSpaces.partition([a, b], []) == {[], [a, b]}
    end

    test "returns {[], []} when spaces is empty" do
      assert PinnedSpaces.partition([], [Ecto.UUID.generate()]) == {[], []}
    end

    test "lifts pinned spaces out of the unpinned half" do
      keep = space("keep")
      lift = space("lift")

      assert PinnedSpaces.partition([keep, lift], [lift.id]) == {[lift], [keep]}
    end

    test "orders the pinned half by PIN order, not by input order" do
      # The block's order is the order the user pinned things in, so the
      # partition cannot just preserve the incoming list order.
      [a, b, c] = Enum.map(["a", "b", "c"], &space/1)

      assert PinnedSpaces.partition([a, b, c], [c.id, a.id]) == {[c, a], [b]}
    end

    test "preserves input order within the unpinned half" do
      [a, b, c, d] = Enum.map(["a", "b", "c", "d"], &space/1)

      assert PinnedSpaces.partition([a, b, c, d], [b.id]) == {[b], [a, c, d]}
    end

    test "a pin id naming a space that no longer exists is skipped, not raised" do
      # Deleting or archiving a space must never require a cleanup pass over
      # preferences JSONB. The stale id resolves to nothing on read.
      live = space("live")
      stale = Ecto.UUID.generate()

      {pinned, unpinned} = PinnedSpaces.partition([live], [stale, live.id])

      assert pinned == [live]
      assert unpinned == []
      assert length(pinned) == 1
    end

    test "a DM partitions identically to a channel" do
      # Anti-vacuity. Both are chat_spaces rows differing only by `kind`; an
      # implementation that filters on kind passes every channel-only test
      # above and empties the Pinned block of people.
      channel = space("gen-migration", "channel")
      dm = space("alex", "dm")
      group = space("crew", "group")

      assert PinnedSpaces.partition([channel, dm, group], [dm.id]) ==
               {[dm], [channel, group]}

      assert PinnedSpaces.partition([channel, dm, group], [group.id]) ==
               {[group], [channel, dm]}

      assert PinnedSpaces.partition([channel, dm, group], [dm.id, channel.id, group.id]) ==
               {[dm, channel, group], []}
    end

    test "every space pinned returns {all_in_pin_order, []}" do
      a = space("a")
      b = space("b")

      assert PinnedSpaces.partition([a, b], [b.id, a.id]) == {[b, a], []}
    end

    test "accepts a MapSet for callers that only need the split" do
      # The render path holds a MapSet for O(1) exclusion. Passing one keeps
      # the pinned half in input order, since a set carries no pin order.
      [a, b, c] = Enum.map(["a", "b", "c"], &space/1)

      assert PinnedSpaces.partition([a, b, c], MapSet.new([c.id, a.id])) == {[a, c], [b]}
    end
  end

  # Task 01a1557b stage 1 (f): the anchor rule that keeps unrendered ids.
  describe "destination_index/3" do
    test "anchors on the next rendered neighbour, so a ghost id keeps its place" do
      # G is stored but not rendered (an archived space). Moving C to the top
      # of the rendered run [A, B, C] anchors on A.
      stored = ["a", "g", "b", "c"]
      assert PinnedSpaces.destination_index(stored, "c", ["c", "a", "b"]) == 0

      # Between A and B: the anchor is B, index 2 in [a, g, b].
      assert PinnedSpaces.destination_index(stored, "c", ["a", "c", "b"]) == 2
    end

    test "with no anchor after it the move appends" do
      stored = ["a", "b", "g", "c"]
      assert PinnedSpaces.destination_index(stored, "a", ["b", "c", "a"]) == 3
    end

    test "a space that is not stored gives nil" do
      assert PinnedSpaces.destination_index(["a", "b"], "z", ["z", "a", "b"]) == nil
    end
  end
end
