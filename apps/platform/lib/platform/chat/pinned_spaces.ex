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

  @doc """
  The `to_index` for `Platform.Chat.Sidebar.move_pinned_space/3` that puts
  `space_id` where the user dropped it in the RENDERED list.

  `stored_ids` is the pin list as stored (`Sidebar.list_pinned_space_ids/1`).
  `rendered_ids_after_move` is the rendered conversation run with the move
  already applied.

  Anchor rule: `rest` is `stored_ids` without `space_id`. The anchor is the
  first id AFTER `space_id` in `rendered_ids_after_move` that is also in
  `rest`, and the result is the anchor's index in `rest`, so the pin lands
  just in front of it. With no anchor (dropped last) the result is
  `length(rest)`, the end. `nil` when `space_id` is not stored at all.

  Why an anchor and not the rendered order written wholesale: the stored
  list can hold ids the list does not render (an archived space, a space in
  an org the user has left; see `## Skip-unknown`). Those keep their place
  and are never dropped, because only the moved id changes position.
  """
  @spec destination_index([String.t()], String.t(), [String.t()]) :: non_neg_integer() | nil
  def destination_index(stored_ids, space_id, rendered_ids_after_move)
      when is_list(stored_ids) and is_list(rendered_ids_after_move) do
    if space_id in stored_ids do
      rest = Enum.reject(stored_ids, &(&1 == space_id))

      anchor =
        rendered_ids_after_move
        |> Enum.drop_while(&(&1 != space_id))
        |> Enum.drop(1)
        |> Enum.find(&(&1 in rest))

      if anchor, do: Enum.find_index(rest, &(&1 == anchor)), else: length(rest)
    end
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
