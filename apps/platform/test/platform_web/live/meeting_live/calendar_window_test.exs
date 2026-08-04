defmodule PlatformWeb.MeetingLive.CalendarWindowTest do
  @moduledoc """
  Tests for `PlatformWeb.MeetingLive.CalendarWindow` — the pure week /
  placement arithmetic behind the meetings calendar (task 019fb954-8ead).

  Mostly zero-DB, because the module is pure. The one `describe` that
  touches the repo is the half-open boundary, which is a JOINT claim
  about `week_bounds/2` and `Platform.Meetings.list_meetings_in_range/3`
  agreeing on `[from, to)`; asserting it against the real query is the
  only way it can actually fail.

  Anchor dates are deliberately on a WEEKEND. 2026-08-03 is a Monday and
  2026-08-09 the Sunday that closes the same week, so a Saturday or
  Sunday anchor lands on a different Monday under the two week-start
  conventions while any midweek anchor lands on the same one. A midweek
  fixture here would be vacuous.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Tasks
  alias PlatformWeb.MeetingLive.CalendarWindow

  # UTC-6 in winter / UTC-5 in summer, so a zone-blind implementation that
  # silently used UTC would produce visibly different hours and dates.
  @zone "America/Chicago"

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Project #{System.unique_integer([:positive])}"})

    project
  end

  defp scheduled_meeting(project, name, start_at, end_at) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: name,
        scheduled_start_at: start_at,
        scheduled_end_at: end_at
      })

    meeting
  end

  # A bare struct is enough for the pure functions: nothing in
  # `placeable?/1`, `hour_window/2` or `place/4` reads the database.
  defp meeting_struct(attrs) do
    struct!(
      %Meeting{status: "scheduled", scheduled_start_at: nil, scheduled_end_at: nil},
      attrs
    )
  end

  describe "resolve_time_zone/1" do
    test "returns the zone for a real IANA name" do
      assert CalendarWindow.resolve_time_zone("America/Chicago") == "America/Chicago"
    end

    test "returns nil for a well-formed but non-existent zone" do
      # The point of validating against Tzdata rather than a regex: this
      # string has the right SHAPE and is still not a zone.
      assert CalendarWindow.resolve_time_zone("Mars/Olympus") == nil
    end

    test "returns nil for nil, empty string, and non-binaries" do
      assert CalendarWindow.resolve_time_zone(nil) == nil
      assert CalendarWindow.resolve_time_zone("") == nil
      assert CalendarWindow.resolve_time_zone(123) == nil
      assert CalendarWindow.resolve_time_zone(%{"timezone" => "UTC"}) == nil
    end

    test "returns nil rather than falling back to UTC" do
      # Load-bearing: the caller distinguishes "unknown zone" from "UTC"
      # and places NOTHING for the former. A "UTC" fallback would make
      # the dead render place every meeting in the wrong day column.
      refute CalendarWindow.resolve_time_zone("Mars/Olympus") == "UTC"
    end
  end

  describe "week_days/1 — the week starts on Monday" do
    @monday ~D[2026-08-03]
    @saturday ~D[2026-08-08]
    @sunday ~D[2026-08-09]

    test "a Sunday anchor belongs to the week that STARTED five days earlier" do
      # Under a Sunday-start week this would be Aug 9..Aug 15 — a
      # different week entirely, sharing only the anchor itself.
      assert CalendarWindow.week_days(@sunday) == Enum.map(0..6, &Date.add(@monday, &1))
      assert List.first(CalendarWindow.week_days(@sunday)) == @monday
      assert List.last(CalendarWindow.week_days(@sunday)) == @sunday
    end

    test "a Saturday anchor lands on the same Monday" do
      # Under a Sunday-start week this would begin Aug 2.
      assert List.first(CalendarWindow.week_days(@saturday)) == @monday
    end

    test "Saturday and the Sunday after it are the SAME week" do
      # The weekend is not split. This is the direct consequence of a
      # Monday start and is false under a Sunday start, where Aug 9
      # opens a new week.
      assert CalendarWindow.week_days(@saturday) == CalendarWindow.week_days(@sunday)
    end

    test "the Sunday before belongs to the PREVIOUS week" do
      assert List.first(CalendarWindow.week_days(~D[2026-08-02])) == ~D[2026-07-27]
      refute CalendarWindow.week_days(~D[2026-08-02]) == CalendarWindow.week_days(@monday)
    end

    test "returns seven consecutive dates, Monday through Sunday" do
      days = CalendarWindow.week_days(~D[2026-08-05])

      assert length(days) == 7
      assert Enum.map(days, &Date.day_of_week/1) == [1, 2, 3, 4, 5, 6, 7]
    end
  end

  describe "week_bounds/2 and day_bounds/2" do
    test "spans local Monday midnight to the following local Monday midnight" do
      {from, to} = CalendarWindow.week_bounds(~D[2026-08-09], @zone)

      # Chicago is UTC-5 in August, so local Monday 00:00 is 05:00 UTC.
      assert from == ~U[2026-08-03 05:00:00Z]
      assert to == ~U[2026-08-10 05:00:00Z]
    end

    test "returns UTC datetimes regardless of the zone asked for" do
      {from, to} = CalendarWindow.week_bounds(~D[2026-08-09], @zone)

      assert from.time_zone == "Etc/UTC"
      assert to.time_zone == "Etc/UTC"
    end

    test "the boundary moves with the zone" do
      {utc_from, _} = CalendarWindow.week_bounds(~D[2026-08-05], "Etc/UTC")
      {chicago_from, _} = CalendarWindow.week_bounds(~D[2026-08-05], @zone)

      # Same calendar week, different instants — the whole reason the
      # zone has to reach the server before bucketing happens.
      assert DateTime.compare(chicago_from, utc_from) == :gt
      assert DateTime.diff(chicago_from, utc_from, :hour) == 5
    end

    test "day_bounds/2 is exactly 24 hours on an ordinary day" do
      {from, to} = CalendarWindow.day_bounds(~D[2026-08-05], @zone)

      assert DateTime.diff(to, from, :hour) == 24
    end

    test "day_bounds/2 is 23 hours across a spring-forward" do
      # 2026-03-08 is the US spring-forward. A naive +1 day would report
      # 24 hours and place every afternoon meeting an hour off.
      {from, to} = CalendarWindow.day_bounds(~D[2026-03-08], @zone)

      assert DateTime.diff(to, from, :hour) == 23
    end

    test "day_bounds/2 is 25 hours across a fall-back" do
      {from, to} = CalendarWindow.day_bounds(~D[2026-11-01], @zone)

      assert DateTime.diff(to, from, :hour) == 25
    end

    test "resolves a zone whose local midnight does not exist" do
      # Chile springs forward AT midnight, so 2026-09-06 00:00:00 is a
      # `{:gap, _, _}` return from `DateTime.new/4`. The day still has to
      # start somewhere; it starts when the clock resumes, at 01:00.
      {from, _to} = CalendarWindow.day_bounds(~D[2026-09-06], "America/Santiago")

      assert %DateTime{} = from
      assert DateTime.shift_zone!(from, "America/Santiago").hour == 1
    end
  end

  describe "placeable_statuses/0 and the cancellation allowlist" do
    test "cancelled is the only status excluded from the grid" do
      # THE FORCING FUNCTION. Exact equality, not a subset or a floor
      # assertion: a new status must be deliberately classified as
      # placeable or not, and this line is what makes that a decision
      # rather than an accident. A floor assertion would admit an
      # unclassified fifth status without ever going red, and the
      # allowlist would then silently stop drawing it with nobody
      # having chosen that.
      assert Meeting.statuses() -- CalendarWindow.placeable_statuses() == ["cancelled"]
    end

    test "placeable_statuses/0 is the allowlist itself" do
      assert CalendarWindow.placeable_statuses() == ~w(scheduled live ended)
    end
  end

  describe "placeable?/1" do
    test "true for each allowlisted status when a start time is set" do
      for status <- ~w(scheduled live ended) do
        meeting =
          meeting_struct(status: status, scheduled_start_at: ~U[2026-08-05 14:00:00Z])

        assert CalendarWindow.placeable?(meeting), "expected #{status} to be placeable"
      end
    end

    test "false for a cancelled meeting that is otherwise placeable" do
      # Varies ONLY the status against the passing case above: the start
      # time is set, so a failure here can only be the status conjunct.
      meeting =
        meeting_struct(status: "cancelled", scheduled_start_at: ~U[2026-08-05 14:00:00Z])

      refute CalendarWindow.placeable?(meeting)
    end

    test "false for a scheduled meeting with no intended start time" do
      # Varies ONLY the start time: the status is on the allowlist, so a
      # failure here can only be the nil-start conjunct. Together with
      # the test above this pins both halves of the conjunction
      # independently — one mutation cannot kill a conjunctive guard.
      meeting = meeting_struct(status: "scheduled", scheduled_start_at: nil)

      refute CalendarWindow.placeable?(meeting)
    end
  end

  describe "hour_window/2" do
    test "defaults to the canvas gutter when nothing falls outside it" do
      meeting =
        meeting_struct(
          # 10:00–11:00 local.
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 16:00:00Z]
        )

      assert CalendarWindow.hour_window([meeting], @zone) == {8, 18}
    end

    test "returns the default for an empty list" do
      assert CalendarWindow.hour_window([], @zone) == {8, 18}
    end

    test "widens DOWN for an early-morning meeting" do
      # 06:30 local — before the 8 AM default. Clamping it into the 8 AM
      # row would draw a meeting at a time it is not happening.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 11:30:00Z],
          scheduled_end_at: ~U[2026-08-05 12:00:00Z]
        )

      assert CalendarWindow.hour_window([meeting], @zone) == {6, 18}
    end

    test "widens UP and ceilings a ragged end hour" do
      # 19:00–20:15 local: the end ceilings to 21, not 20.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-06 00:00:00Z],
          scheduled_end_at: ~U[2026-08-06 01:15:00Z]
        )

      assert CalendarWindow.hour_window([meeting], @zone) == {8, 21}
    end

    test "does not widen when the end lands exactly on the hour" do
      # 19:00–20:00 local. An unconditional +1 would report 21.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-06 00:00:00Z],
          scheduled_end_at: ~U[2026-08-06 01:00:00Z]
        )

      assert CalendarWindow.hour_window([meeting], @zone) == {8, 20}
    end

    test "widens in both directions across several meetings" do
      early =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 11:30:00Z],
          scheduled_end_at: ~U[2026-08-05 12:00:00Z]
        )

      late =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-06 00:00:00Z],
          scheduled_end_at: ~U[2026-08-06 01:15:00Z]
        )

      assert CalendarWindow.hour_window([early, late], @zone) == {6, 21}
    end

    test "ignores meetings that cannot be placed" do
      cancelled =
        meeting_struct(
          status: "cancelled",
          scheduled_start_at: ~U[2026-08-05 11:30:00Z],
          scheduled_end_at: ~U[2026-08-05 12:00:00Z]
        )

      ad_hoc = meeting_struct(status: "live", scheduled_start_at: nil)

      # The cancelled 06:30 meeting must not drag the gutter open — an
      # off meeting should leave no trace in the layout.
      assert CalendarWindow.hour_window([cancelled, ad_hoc], @zone) == {8, 18}
    end

    test "a nil end widens by the default half hour" do
      # 17:45 local, no end: the implied 18:15 ceilings to 19.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 22:45:00Z],
          scheduled_end_at: nil
        )

      assert CalendarWindow.hour_window([meeting], @zone) == {8, 19}
    end
  end

  describe "place/4" do
    @window {8, 18}

    test "top and height are percentages of the hour window" do
      # 10:00–11:00 local in an 8–18 window: 2h in of 10h = 20%, 1h = 10%.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 16:00:00Z]
        )

      assert {:ok, %{top: top, height: height}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      assert_in_delta top, 20.0, 0.001
      assert_in_delta height, 10.0, 0.001
    end

    test "the window's first hour is top 0%" do
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 13:00:00Z],
          scheduled_end_at: ~U[2026-08-05 14:00:00Z]
        )

      assert {:ok, %{top: top}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      assert_in_delta top, 0.0, 0.001
    end

    test "a half-hour offset lands on the half row" do
      # 08:30 local = 30 min into a 600-min window = 5%.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 13:30:00Z],
          scheduled_end_at: ~U[2026-08-05 14:00:00Z]
        )

      assert {:ok, %{top: top}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      assert_in_delta top, 5.0, 0.001
    end

    test "a nil end is drawn as thirty minutes" do
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: nil
        )

      assert {:ok, %{height: height}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      # 30 min of a 600-min window.
      assert_in_delta height, 5.0, 0.001
    end

    test "a very short meeting still gets a tappable minimum height" do
      # Five minutes is 0.83% of the window — a hairline nobody can tap.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 15:05:00Z]
        )

      assert {:ok, %{height: height}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      assert height == 3.0
    end

    test "skips a meeting whose local date is a different day" do
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 16:00:00Z]
        )

      assert CalendarWindow.place(meeting, ~D[2026-08-06], @zone, @window) == :skip
    end

    test "buckets by LOCAL date, not UTC date" do
      # 2026-08-06 02:00 UTC is 2026-08-05 21:00 in Chicago. The row
      # belongs in Wednesday's column, not Thursday's — this is exactly
      # the decision that cannot be made in the browser.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-06 02:00:00Z],
          scheduled_end_at: ~U[2026-08-06 03:00:00Z]
        )

      assert {:ok, _placement} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window)

      assert CalendarWindow.place(meeting, ~D[2026-08-06], @zone, @window) == :skip
    end

    test "skips a cancelled meeting on its own day" do
      meeting =
        meeting_struct(
          status: "cancelled",
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 16:00:00Z]
        )

      assert CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window) == :skip
    end

    test "skips a meeting with no intended start" do
      meeting = meeting_struct(status: "scheduled", scheduled_start_at: nil)

      assert CalendarWindow.place(meeting, ~D[2026-08-05], @zone, @window) == :skip
    end

    test "a widened window rescales the same meeting" do
      # Identical meeting, window {6, 18} instead of {8, 18}: 10:00 is
      # now 4h into a 12h window = 33.3%, and the hour is 8.3%.
      meeting =
        meeting_struct(
          scheduled_start_at: ~U[2026-08-05 15:00:00Z],
          scheduled_end_at: ~U[2026-08-05 16:00:00Z]
        )

      assert {:ok, %{top: top, height: height}} =
               CalendarWindow.place(meeting, ~D[2026-08-05], @zone, {6, 18})

      assert_in_delta top, 100 * 4 / 12, 0.001
      assert_in_delta height, 100 * 1 / 12, 0.001
    end
  end

  describe "half-open [from, to) against the real range query" do
    setup do
      project = create_project()
      {from, to} = CalendarWindow.week_bounds(~D[2026-08-05], @zone)

      %{project: project, from: from, to: to}
    end

    test "includes a meeting starting at exactly `from`", %{
      project: project,
      from: from,
      to: to
    } do
      meeting =
        scheduled_meeting(project, "At From", from, DateTime.add(from, 30, :minute))

      ids = from |> Meetings.list_meetings_in_range(to) |> Enum.map(& &1.id)

      assert meeting.id in ids
    end

    test "excludes a meeting starting at exactly `to`", %{
      project: project,
      from: from,
      to: to
    } do
      meeting = scheduled_meeting(project, "At To", to, DateTime.add(to, 30, :minute))

      ids = from |> Meetings.list_meetings_in_range(to) |> Enum.map(& &1.id)

      refute meeting.id in ids
    end

    test "the meeting excluded at `to` is included by the NEXT week", %{
      project: project,
      to: to
    } do
      # Both halves of the boundary, so a window that dropped the row
      # entirely could not pass by accident. `to` is the next week's
      # `from`, which is what makes the partition exhaustive.
      meeting = scheduled_meeting(project, "Next Week", to, DateTime.add(to, 30, :minute))

      {next_from, next_to} = CalendarWindow.week_bounds(~D[2026-08-12], @zone)
      assert next_from == to

      ids = next_from |> Meetings.list_meetings_in_range(next_to) |> Enum.map(& &1.id)

      assert meeting.id in ids
    end

    test "excludes a meeting one microsecond before `from`", %{
      project: project,
      from: from,
      to: to
    } do
      just_before = DateTime.add(from, -1, :microsecond)

      meeting =
        scheduled_meeting(project, "Just Before", just_before, DateTime.add(from, 30, :minute))

      ids = from |> Meetings.list_meetings_in_range(to) |> Enum.map(& &1.id)

      refute meeting.id in ids
    end
  end
end
