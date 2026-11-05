defmodule Platform.Repo.Migrations.AddIcalSequenceToMeetings do
  @moduledoc """
  Task 01a1a933 stage 2 (meeting invite email).

  Adds `meetings.ical_sequence`, the iCalendar SEQUENCE of the meeting's
  current schedule. An emailed iTIP REQUEST that changes the time must carry
  a SEQUENCE greater than the one the invitee's calendar already holds, or
  Google and Outlook discard it as stale, and a value derived from the row's
  status (0 live, 1 cancelled) cannot grow across reschedules.

  Not null, default 0, so every existing meeting renders exactly what it
  rendered before: SEQUENCE 0 live, 1 cancelled.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add(:ical_sequence, :integer, null: false, default: 0)
    end
  end
end
