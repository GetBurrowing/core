defmodule Platform.Repo.Migrations.AddScheduledTimesToMeetings do
  use Ecto.Migration

  @moduledoc """
  Task `019fb953`: give a meeting an INTENDED time, distinct from the
  actuals it already records.

  `meetings` carries `status ∈ scheduled | live | ended` plus `started_at`
  and `ended_at` — both of which are stamped by
  `Platform.Meetings.start_meeting/1` and `end_meeting/1` when a meeting
  actually happens. So "scheduled" has meant nothing more than "has not
  started yet": there is no time on the row saying when it was *meant* to
  happen, which is exactly why there is no calendar. Nothing to place on a
  grid.

  ## Why both endpoints rather than a start plus a duration

  iCal's `VEVENT` wants `DTEND` directly, and a duration would otherwise
  be recomputed independently in three places — the calendar grid, the
  .ics renderer, and the notification copy — which is three opportunities
  to drift. Storing both endpoints means each of those reads one source.
  Deliberately NO `duration` / `duration_minutes` column: with two
  endpoints already present a third value is redundant, and the redundant
  one goes stale on the first edit that misses it.

  ## Why NULLable, with no default and no backfill

  `Platform.Meetings.create_meeting/1` builds an explicit whitelist of
  attributes, and its callers — the meetings-index FAB, the MCP
  `meeting_create` tool, and every test fixture — pass only a project and
  a name. That ad-hoc "start a meeting now" flow must keep working, so a
  `null: false` column or a required-field validation is out.

  A backfill from `started_at` is rejected too. Every row currently in
  `scheduled` has `started_at == nil`, so there is nothing to copy for
  precisely the rows a calendar wants; and for rows that did start, copying
  the actual would assert an intent that never existed. NULL therefore
  MEANS "ad hoc — started, never scheduled". That is a legitimate,
  load-bearing state, not missing data awaiting repair.

  ## The index

  `scheduled_start_at` is range-scanned by the half-open window query the
  calendar places rows with, so it gets a btree index. Unscoped, matching
  the cross-project shape of that query.
  """

  def change do
    alter table(:meetings) do
      add(:scheduled_start_at, :utc_datetime_usec)
      add(:scheduled_end_at, :utc_datetime_usec)
    end

    create(index(:meetings, [:scheduled_start_at]))
  end
end
