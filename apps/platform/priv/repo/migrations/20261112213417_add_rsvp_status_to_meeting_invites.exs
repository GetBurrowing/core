defmodule Platform.Repo.Migrations.AddRsvpStatusToMeetingInvites do
  @moduledoc """
  An invitee's answer to a meeting invite: `invited` (no answer yet),
  `accepted`, `tentative` or `declined`, and when they gave it.

  It now has readers: the invite list in the meeting details, and the
  ATTENDEE `PARTSTAT` the calendar feed and the emailed invite carry, which
  is what Apple Calendar, Google and Outlook show next to each invitee.

  Existing rows backfill to `invited` through the column default.
  """
  use Ecto.Migration

  def change do
    alter table(:meeting_invites) do
      add(:rsvp_status, :string, null: false, default: "invited")
      add(:rsvp_at, :utc_datetime_usec)
    end

    create(
      constraint(:meeting_invites, :meeting_invites_rsvp_status_check,
        check: "rsvp_status IN ('invited', 'accepted', 'tentative', 'declined')"
      )
    )
  end
end
