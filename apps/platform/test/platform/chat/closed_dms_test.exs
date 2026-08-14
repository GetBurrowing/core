defmodule Platform.Chat.ClosedDmsTest do
  @moduledoc """
  Covers the partition helper behind the DM "Close" action.

  The load-bearing property is the RETURN, not the close. A test that only
  proves the row disappears would pass just as well for a rail that dropped
  DMs entirely, so every close assertion below is paired IN THE SAME TEST
  with the return that follows a newer message.

  The second load-bearing property is fail-open. A missing, malformed or
  unparsable timestamp on either side leaves the conversation visible.
  Losing a conversation is far worse than failing to hide one.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.ClosedDms
  alias Platform.Chat.Space

  @epoch ~U[2026-08-13 12:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@epoch, seconds, :second)

  defp dm(last_activity_at) do
    %Space{
      id: Ecto.UUID.generate(),
      kind: "dm",
      is_direct: true,
      last_activity_at: last_activity_at
    }
  end

  describe "filter/2 close-and-return" do
    test "a DM closed at its last activity hides, and the SAME DM returns one second later" do
      closed_at = at(0)
      space = dm(closed_at)
      closed = %{space.id => closed_at}

      assert ClosedDms.filter([space], closed) == {[], [space]}

      # The interesting half: a new message lands in that DM, so its
      # last_activity_at is now strictly newer than the close.
      returned = %{space | last_activity_at: at(1)}
      assert ClosedDms.filter([returned], closed) == {[returned], []}
    end

    test "a DM whose last activity predates the close stays hidden until a newer message" do
      closed_at = at(10)
      space = dm(at(5))
      closed = %{space.id => closed_at}

      assert ClosedDms.filter([space], closed) == {[], [space]}

      returned = %{space | last_activity_at: at(11)}
      assert ClosedDms.filter([returned], closed) == {[returned], []}
    end

    test "a microsecond newer is newer enough to return" do
      closed_at = at(0)
      space = dm(closed_at)
      closed = %{space.id => closed_at}

      assert ClosedDms.filter([space], closed) == {[], [space]}

      returned = %{space | last_activity_at: DateTime.add(closed_at, 1, :microsecond)}
      assert ClosedDms.filter([returned], closed) == {[returned], []}
    end

    test "closing one DM leaves the others alone, and its return does not disturb them" do
      keep = dm(at(0))
      close_me = dm(at(0))
      other = dm(at(0))
      closed = %{close_me.id => at(0)}

      assert ClosedDms.filter([keep, close_me, other], closed) == {[keep, other], [close_me]}

      returned = %{close_me | last_activity_at: at(1)}

      assert ClosedDms.filter([keep, returned, other], closed) ==
               {[keep, returned, other], []}
    end

    test "preserves order within each partition" do
      [a, b, c, d] = Enum.map(1..4, fn _ -> dm(at(0)) end)
      closed = %{b.id => at(0), d.id => at(0)}

      assert ClosedDms.filter([a, b, c, d], closed) == {[a, c], [b, d]}

      returned_b = %{b | last_activity_at: at(1)}
      returned_d = %{d | last_activity_at: at(1)}

      assert ClosedDms.filter([a, returned_b, c, returned_d], closed) ==
               {[a, returned_b, c, returned_d], []}
    end
  end

  describe "filter/2 fails open" do
    test "a nil last_activity_at stays visible even with a closed_at on record" do
      space = dm(nil)

      assert ClosedDms.filter([space], %{space.id => at(0)}) == {[space], []}
    end

    test "a non-DateTime last_activity_at stays visible" do
      space = dm("2026-08-13T12:00:00Z")

      assert ClosedDms.filter([space], %{space.id => at(0)}) == {[space], []}
    end

    test "a non-DateTime stored closed_at leaves the DM visible" do
      space = dm(at(0))

      assert ClosedDms.filter([space], %{space.id => "not-a-timestamp"}) == {[space], []}
      assert ClosedDms.filter([space], %{space.id => nil}) == {[space], []}
    end

    test "a closed_at id matching no space in the list changes nothing" do
      a = dm(at(0))
      b = dm(at(0))
      closed = %{Ecto.UUID.generate() => at(5)}

      assert ClosedDms.filter([a, b], closed) == {[a, b], []}
    end

    test "an empty closed map returns everything visible" do
      a = dm(at(0))
      b = dm(nil)

      assert ClosedDms.filter([a, b], %{}) == {[a, b], []}
    end

    test "an empty space list returns two empty lists" do
      assert ClosedDms.filter([], %{Ecto.UUID.generate() => at(0)}) == {[], []}
    end
  end
end
