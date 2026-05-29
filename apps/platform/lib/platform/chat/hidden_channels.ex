defmodule Platform.Chat.HiddenChannels do
  @moduledoc """
  Partition a list of `%Platform.Chat.Space{}` structs against a user's
  hidden-channel `MapSet`, returning `{visible, hidden}`.

  The hidden set is tolerant of stale ids — UUIDs that don't match any
  space in the input list are silently dropped from the partition (the
  surfaced "Hidden (N)" count reflects only matched spaces). This means
  deleting a channel never requires a cleanup pass over user.preferences
  JSONB; the filter handles drift on every read.

  Persistence lives in `Platform.Accounts` (`get_hidden_channel_ids/1`,
  `hide_channel/2`, `unhide_channel/2`); this module is the read-side
  consumer used by the chat-rail render path.
  """

  alias Platform.Chat.Space

  @doc """
  Partition `spaces` into `{visible, hidden}` based on the user's hidden
  MapSet of `space.id`. Order within each partition is preserved.

  Stale ids in `hidden_ids` that don't match any space in `spaces` are
  silently ignored — they don't appear in either partition and don't
  crash the render path.
  """
  @spec filter([Space.t()], MapSet.t(String.t())) :: {[Space.t()], [Space.t()]}
  def filter(spaces, hidden_ids) when is_list(spaces) do
    Enum.split_with(spaces, fn %Space{id: id} -> not MapSet.member?(hidden_ids, id) end)
  end
end
