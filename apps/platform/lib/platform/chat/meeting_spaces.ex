defmodule Platform.Chat.MeetingSpaces do
  @moduledoc """
  Partition a list of `%Platform.Chat.Space{}` structs by meeting-kind,
  returning `{others, meetings}` — the read side of the "Add Agent to
  Space" picker's meeting group.

  ## Why this exists

  `control_center_live.ex`'s `show_add_space_modal` handler calls
  `Platform.Chat.list_spaces/1` with `:kind` omitted, which returns every
  non-archived, non-execution space — channels, groups, DMs excluded by the
  caller separately, and both meeting kinds. Meeting spaces mint one per
  call and accumulate fast, so the picker's `<select>` floods with them.
  This module does not change what gets created or what `list_spaces/1`
  returns; it only gives the picker a way to group what it already has.

  The product lead's ruling: "Keep them but collapse them until we need to do
  something better" — a browsing problem, not a data problem, and a
  deliberate holding pattern.

  ## Kind-scoped, not kind-agnostic

  Unlike `PinnedSpaces`, this module looks at exactly one field: `kind`.
  That is the point of it — `meeting` and `guest_meeting` are already
  labelled on the space, so no migration and no backfill are needed to
  group them.

  Persistence lives in `Platform.Chat` (`list_spaces/1`) and
  `Platform.Meetings` (`create_meeting/1`, `create_guest_chat_space/2`);
  this module is a pure read-side consumer used by the "Add Agent to
  Space" picker's render path.
  """

  alias Platform.Chat.Space

  @meeting_kinds ~w(meeting guest_meeting)

  @doc """
  True when `space.kind` is `"meeting"` or `"guest_meeting"`. Named with a
  `?` suffix, not an `is_` prefix — that prefix is reserved for guards.
  """
  @spec meeting_kind?(Space.t()) :: boolean()
  def meeting_kind?(%Space{kind: kind}), do: kind in @meeting_kinds

  @doc """
  Partition `spaces` into `{others, meetings}`.

  `others` holds every non-meeting space in its INPUT order, unchanged, so
  the picker's existing behaviour for channels and groups is untouched.

  `meetings` holds every meeting-kind space (`kind` in `"meeting"` or
  `"guest_meeting"`), NEWEST FIRST. Callers feed this a list from
  `Platform.Chat.list_spaces/1`, which orders `asc: s.inserted_at`, so the
  meeting bucket is reversed relative to input — the meeting a person just
  had should be first in the group.

  Every input space appears in exactly one bucket and none is dropped:
  `length(others) + length(meetings) == length(spaces)` holds for any
  input.
  """
  @spec partition_for_picker([Space.t()]) :: {[Space.t()], [Space.t()]}
  def partition_for_picker(spaces) when is_list(spaces) do
    {meetings, others} = Enum.split_with(spaces, &meeting_kind?/1)

    {others, Enum.reverse(meetings)}
  end
end
