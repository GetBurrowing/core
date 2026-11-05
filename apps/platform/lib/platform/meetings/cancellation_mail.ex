defmodule Platform.Meetings.CancellationMail do
  @moduledoc """
  Emails a cancelled meeting's invitees that it is off (task 01a19e7f stage
  2; task 01a1a933 stage 3).

  Since task 01a1a933 this is a thin entry point onto
  `Platform.Meetings.InviteMailer.send_cancellations/1`: each recipient gets
  a `Cancelled: <title>` email whose calendar part is `METHOD:CANCEL` for the
  same UID as the invitation, with SEQUENCE `ical_sequence + 1`, so the event
  comes off their calendar. The audience is every live invite that got an
  invitation email plus every guest with an address (booking guests
  included). The sender is the org's meeting sender from
  `Platform.Mail.OrgSender.resolve/2`; with none configured, or mail
  disabled, nothing is sent and one line is logged.

  Called only from `Platform.Meetings.MeetingNotifier`, inside the
  `mark_cancellation_notified/1` claim, so a meeting's invitees are mailed
  at most once. A failure for one recipient is logged and the rest still
  get theirs.
  """

  alias Platform.Meetings.InviteMailer
  alias Platform.Meetings.Meeting

  @doc """
  Queue one cancellation email per recipient of `meeting`. Returns the number
  queued. Never raises for an expected condition.
  """
  @spec deliver(Meeting.t()) :: non_neg_integer()
  def deliver(%Meeting{} = meeting), do: InviteMailer.send_cancellations(meeting)

  @doc "The responsibility recorded on every cancellation draft and delivery."
  @spec responsibility() :: String.t()
  def responsibility, do: InviteMailer.responsibility(:cancelled)
end
