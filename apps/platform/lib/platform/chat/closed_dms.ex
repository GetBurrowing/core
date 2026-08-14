defmodule Platform.Chat.ClosedDms do
  @moduledoc """
  Partition a list of `%Platform.Chat.Space{}` structs against a user's
  closed-DM map, returning `{visible, closed}`.

  ## The return rule

  A closed DM comes back on ANY message in it. There is no @mention special
  case, and that is deliberate. A DM is one-to-one, so every message in it is
  already directed at the user; an @mention rule would keep the DM hidden
  while someone was actively writing to you, which is the moment it most needs
  to be on screen. Close therefore means "not now". It carries no subscription
  change, so it ships with no undo surface, no hidden-DM list and nothing to
  maintain.

  A space is closed ONLY when both hold:

    * a `closed_at` `DateTime` exists for its id, and
    * its `last_activity_at` is a `DateTime` that is not strictly newer.

  ## Everything else fails open

  Every other case leaves the space visible: a nil `last_activity_at` (every
  read path other than `Platform.Chat.list_user_conversations/2` leaves the
  virtual field unset), a value of an unexpected shape on either side, an id
  matching no space in the list. Losing a conversation is far worse than
  failing to hide one, so the ambiguous case is always "show it".

  Stale ids are tolerated at read time the same way
  `Platform.Chat.HiddenChannels` tolerates them, so deleting a DM never needs
  a cleanup pass over `users.preferences`.

  Persistence lives in `Platform.Accounts` (`get_closed_dm_at/1`,
  `close_dm/2`, `reopen_dm/2`); this module is the read-side consumer for the
  chat-rail render path.

  Close and Hide stay two separate actions over two separate stores. A channel
  is a place you may want gone even while it is busy; a DM is a person, and
  people come back.
  """

  alias Platform.Chat.Space

  @doc """
  Partition `spaces` into `{visible, closed}` against a map of
  `space_id => closed_at`. Order within each partition is preserved.

  See the module doc for the return rule and the fail-open cases.
  """
  @spec filter([Space.t()], %{optional(String.t()) => DateTime.t()}) ::
          {[Space.t()], [Space.t()]}
  def filter(spaces, closed_at_by_space_id)
      when is_list(spaces) and is_map(closed_at_by_space_id) do
    Enum.split_with(spaces, fn %Space{id: id} = space ->
      not closed?(space, Map.get(closed_at_by_space_id, id))
    end)
  end

  defp closed?(%Space{last_activity_at: %DateTime{} = last_activity}, %DateTime{} = closed_at) do
    DateTime.compare(last_activity, closed_at) != :gt
  end

  defp closed?(_space, _closed_at), do: false
end
