defmodule Platform.Meetings.IntentQueue.MirrorError do
  @moduledoc """
  Raised when the durable candidate mirror fails and fatality is armed
  (task 01a04a36).

  A distinct exception type, rather than `RuntimeError`, so a test can
  assert it was THIS that went wrong. `assert_raise RuntimeError` would
  also be satisfied by the mirror body raising for an unrelated reason,
  which is precisely the confusion this switch exists to remove: the
  point of arming fatality is to tell "the mirror could not write" apart
  from "nothing tried to write at all", and an exception that anything
  could have produced tells neither.

  Never raised in `:prod`. See `Platform.Meetings.IntentQueue.Server`'s
  `mirror_fatal?/0` for why the swallow is right there and wrong here.
  """
  defexception [:message]
end
