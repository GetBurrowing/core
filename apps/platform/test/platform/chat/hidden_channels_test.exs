defmodule Platform.Chat.HiddenChannelsTest do
  @moduledoc """
  Covers the partition helper that the chat sidebar render path uses to
  split a list of channels into `{visible, hidden}` against the user's
  hidden-channel MapSet. Stale-id tolerance is the load-bearing property
  — channels can be deleted while still referenced in some user's
  preferences JSONB, and the render must not crash.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.HiddenChannels
  alias Platform.Chat.Space

  defp space(name) do
    %Space{id: Ecto.UUID.generate(), name: name, slug: name, kind: "channel"}
  end

  describe "filter/2" do
    test "returns {spaces, []} when hidden_ids is empty" do
      a = space("alpha")
      b = space("bravo")

      assert HiddenChannels.filter([a, b], MapSet.new()) == {[a, b], []}
    end

    test "returns {[], []} when spaces is empty" do
      assert HiddenChannels.filter([], MapSet.new([Ecto.UUID.generate()])) == {[], []}
    end

    test "partitions visible vs hidden by id" do
      keep = space("keep")
      drop = space("drop")
      hidden_ids = MapSet.new([drop.id])

      assert HiddenChannels.filter([keep, drop], hidden_ids) == {[keep], [drop]}
    end

    test "preserves order within each partition" do
      [a, b, c, d] = Enum.map(["a", "b", "c", "d"], &space/1)
      hidden_ids = MapSet.new([b.id, d.id])

      assert HiddenChannels.filter([a, b, c, d], hidden_ids) == {[a, c], [b, d]}
    end

    test "silently drops stale ids that do not match any space in the list" do
      keep = space("keep")
      drop = space("drop")
      stale = Ecto.UUID.generate()
      hidden_ids = MapSet.new([drop.id, stale])

      # The surfaced 'Hidden (N)' count comes from the second partition's
      # length — stale ids must NOT inflate it.
      {visible, hidden} = HiddenChannels.filter([keep, drop], hidden_ids)
      assert visible == [keep]
      assert hidden == [drop]
      assert length(hidden) == 1
    end

    test "every space hidden returns {[], all}" do
      a = space("a")
      b = space("b")
      hidden_ids = MapSet.new([a.id, b.id])

      assert HiddenChannels.filter([a, b], hidden_ids) == {[], [a, b]}
    end
  end
end
