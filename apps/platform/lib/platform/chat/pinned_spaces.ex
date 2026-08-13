defmodule Platform.Chat.PinnedSpaces do
  @moduledoc """
  Partition a list of `%Platform.Chat.Space{}` structs against a user's pin
  list, returning `{pinned, unpinned}`, the read side of the sidebar's
  Pinned block.

  Sibling of `Platform.Chat.HiddenChannels`, and deliberately the same
  shape. The difference is ORDER: a hidden channel keeps its input position
  in the partition it lands in, while a pinned conversation renders in the
  order the user pinned it, so the pinned half is resorted by pin order.

  ## Lifted, not copied

  A pinned conversation appears in the Pinned block and NOT in its home
  section. That is why this returns a partition rather than a filter: the
  caller renders the first half in the block and feeds the second half to
  the section resolver, so a conversation cannot land in both.

  ## Kind-agnostic

  Nothing here looks at `kind`. Channels and direct messages are both
  `chat_spaces` rows, the Pinned block holds them in one flat list, and a
  `kind` check anywhere in the pin path would empty the block of people
  while passing every channel-only test.

  ## Skip-unknown

  Pin ids live in `users.preferences` JSONB and outlive the spaces they
  name. A pinned id matching no space in `spaces` appears in neither half.
  Deleting or archiving a space therefore never requires a cleanup pass
  over preferences. `HiddenChannels` states the same property in its own
  moduledoc.

  Persistence lives in `Platform.Chat.Sidebar` (`list_pinned_space_ids/1`,
  `pinned_space_ids/1`, `set_space_pinned/3`).
  """

  alias Platform.Chat.Space

  @doc """
  Partition `spaces` into `{pinned, unpinned}`.

  `pins` is either the user's ordered pin list (from
  `Sidebar.list_pinned_space_ids/1`) or a `MapSet` (from
  `Sidebar.pinned_space_ids/1`) for callers that only need the split.

  With a list, the pinned half comes back in PIN order, which is the order
  the block renders. With a `MapSet` it comes back in input order, because
  a set carries no pin order to sort by.

  Order within the unpinned half is always preserved.
  """
  @spec partition([Space.t()], [String.t()] | MapSet.t(String.t())) ::
          {[Space.t()], [Space.t()]}
  def partition(spaces, pins) when is_list(spaces) and is_list(pins) do
    {pinned, unpinned} = split(spaces, MapSet.new(pins))

    {order_by_pins(pinned, pins), unpinned}
  end

  def partition(spaces, %MapSet{} = pins) when is_list(spaces) do
    split(spaces, pins)
  end

  defp split(spaces, pin_set) do
    Enum.split_with(spaces, fn %Space{id: id} -> MapSet.member?(pin_set, id) end)
  end

  # Sort the pinned half by position in the pin list. Every element is
  # present in `pins` by construction (it is how it got into this half), so
  # the lookup cannot miss.
  defp order_by_pins(pinned, pins) do
    rank = pins |> Enum.with_index() |> Map.new()

    Enum.sort_by(pinned, fn %Space{id: id} -> Map.fetch!(rank, id) end)
  end
end
