defmodule PlatformWeb.MeetingLive.CalendarWindow do
  @moduledoc """
  Pure date/time arithmetic behind the meetings calendar (task 019fb954-8ead).

  Deliberately holds NO LiveView imports and touches no socket: every
  function here is a total function of its arguments, so the week maths
  and the placement maths are unit-testable without mounting anything.
  `PlatformWeb.MeetingLive` is the only caller; it owns the assigns, this
  module owns the arithmetic.

  ## The week starts on Monday

  Sourced from the design canvas, not assumed: the desktop frame's day
  header reads `Mon 3 / Tue 4 / … / Sun 9` under the label `Aug 3 - 9,
  2026`, and 2026-08-03 is a Monday. Both mobile frames repeat it.
  `Date.beginning_of_week/2` already defaults to `:monday`, so no
  `:sunday` argument is passed ANYWHERE in this module — a weekend anchor
  is the only thing that distinguishes the two conventions, which is why
  the tests anchor on a Saturday and a Sunday rather than midweek.

  ## Ranges are half-open

  `week_bounds/2` and `day_bounds/2` return `{from, to}` meaning
  `[from, to)`, matching `Platform.Meetings.list_meetings_in_range/3`'s
  documented contract. A meeting starting at exactly `to` belongs to the
  NEXT window, never both.

  ## Percentages, not pixels

  `place/4` returns `top` / `height` as percentages of the rendered hour
  window so the template does no pixel arithmetic and the same numbers
  drive the desktop grid and the mobile single-column day view, whose
  hour rows are different heights.
  """

  alias Platform.Meetings.Meeting

  # Which statuses may occupy a slot in the grid. An ALLOWLIST, chosen
  # over `status != "cancelled"` deliberately: a denylist would silently
  # PLACE a fifth status the day one lands, and placing an unclassified
  # meeting is a worse failure than omitting it. This fails closed. The
  # test file pins `Meeting.statuses() -- placeable_statuses()` to exact
  # equality so the closure is loud rather than silent.
  @placeable_statuses ~w(scheduled live ended)

  # Frame 1's gutter runs 8 AM through 5 PM over a 520px body — ten 52px
  # hour rows — so the window is [8, 18). It WIDENS (never clamps) around
  # meetings outside it: drawing a 7 AM meeting in the 8 AM row would
  # render a lie, whereas a taller grid is merely taller.
  @default_first_hour 8
  @default_last_hour 18

  # A meeting with no intended end is drawn as a half hour. `nil` here
  # means "the host never said", not "zero minutes".
  @default_duration_minutes 30

  # Floor so a 5-minute meeting is still a tappable target at 375px
  # rather than a 1px hairline.
  @min_height_percent 3.0

  # Any instant works to ask Tzdata whether a zone exists; a fixed one
  # keeps `resolve_time_zone/1` free of a clock read.
  @zone_probe ~U[2026-01-01 00:00:00Z]

  @doc """
  The single choke point for untrusted IANA time-zone input.

  The browser hands us `Intl.DateTimeFormat().resolvedOptions().timeZone`
  through the LiveSocket connect params, which is client-controlled data
  and therefore validated exactly once, here, against the real Tzdata
  database rather than a regex.

  Returns the binary when the zone resolves, and `nil` for `nil`, a
  non-binary, `""`, or an unknown zone like `"Mars/Olympus"`.

  Returning `nil` rather than `"UTC"` is the load-bearing choice, and it
  is a contract rather than quiet degradation: the CALLER decides what an
  unknown zone means. For the disconnected render the right answer is
  "place nothing" — placing meetings in UTC and then reflowing them into
  different day columns one beat later is a visibly wrong answer, whereas
  one beat of empty grid is merely an incomplete one.
  """
  @spec resolve_time_zone(term()) :: String.t() | nil
  def resolve_time_zone(time_zone) when is_binary(time_zone) and time_zone != "" do
    case DateTime.shift_zone(@zone_probe, time_zone) do
      {:ok, _shifted} -> time_zone
      {:error, _reason} -> nil
    end
  end

  def resolve_time_zone(_other), do: nil

  @doc """
  The seven dates, Monday through Sunday, of the week containing `anchor`.
  """
  @spec week_days(Date.t()) :: [Date.t()]
  def week_days(%Date{} = anchor) do
    monday = Date.beginning_of_week(anchor)
    Enum.map(0..6, &Date.add(monday, &1))
  end

  @doc """
  Half-open `[from, to)` UTC bounds of the week containing `anchor`,
  where "week" means local midnight Monday in `time_zone` through local
  midnight the FOLLOWING Monday.

  Both endpoints come back as UTC `DateTime`s because that is what the
  range query compares against; the time zone only decides WHERE the
  boundaries fall, not how they are represented.
  """
  @spec week_bounds(Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def week_bounds(%Date{} = anchor, time_zone) when is_binary(time_zone) do
    monday = Date.beginning_of_week(anchor)
    {start_of_day(monday, time_zone), start_of_day(Date.add(monday, 7), time_zone)}
  end

  @doc """
  Half-open `[from, to)` UTC bounds of a single local day. Same contract
  as `week_bounds/2`, one day wide.
  """
  @spec day_bounds(Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def day_bounds(%Date{} = date, time_zone) when is_binary(time_zone) do
    {start_of_day(date, time_zone), start_of_day(Date.add(date, 1), time_zone)}
  end

  @doc """
  The statuses a meeting may hold and still occupy a slot in the grid.

  See `@placeable_statuses` for why this is an allowlist.
  """
  @spec placeable_statuses() :: [String.t()]
  def placeable_statuses, do: @placeable_statuses

  @doc """
  Whether this meeting can be drawn at all.

  Two independent conjuncts, each excluding a different row:

    * status is on the allowlist — a cancelled meeting is off, and
      drawing it would tell the viewer it is still happening.
    * `scheduled_start_at` is set — an ad-hoc meeting was never intended
      for a time, so there is no column and no offset to draw it at.
  """
  @spec placeable?(Meeting.t()) :: boolean()
  def placeable?(%Meeting{status: status, scheduled_start_at: scheduled_start_at}) do
    status in @placeable_statuses and not is_nil(scheduled_start_at)
  end

  @doc """
  The `{first_hour, last_hour}` the hour gutter renders for `meetings`.

  Starts at the canvas default of `{8, 18}` and WIDENS to contain every
  placeable meeting's local start hour and ceiling'd local end hour.
  Widening rather than clamping is the whole point: a window that cannot
  contain a row would otherwise force that row into a slot it does not
  belong in, and a grid that is an hour taller is lossless where a
  misplaced meeting is not.

  A meeting whose intended end spills past local midnight widens the
  window to 24 rather than wrapping to a small next-day hour.
  """
  @spec hour_window([Meeting.t()], String.t()) :: {integer(), integer()}
  def hour_window(meetings, time_zone) when is_list(meetings) and is_binary(time_zone) do
    meetings
    |> Enum.filter(&placeable?/1)
    |> Enum.reduce({@default_first_hour, @default_last_hour}, fn meeting, {first, last} ->
      start_local = to_zone(meeting.scheduled_start_at, time_zone)
      end_local = to_zone(end_at(meeting), time_zone)

      {min(first, start_local.hour), max(last, ceiling_end_hour(start_local, end_local))}
    end)
  end

  @doc """
  Where to draw `meeting` inside `date`'s column, as percentages of the
  `{first_hour, last_hour}` window.

  Returns `:skip` when the meeting is not placeable at all, or when its
  local start date is not `date` — the caller maps over seven day columns
  and one week's meetings, so most pairs legitimately do not match. `:skip`
  is an expected answer here, not a failure.

  `top` is intentionally NOT clamped into `[0, 100]`: the window this is
  called with comes from `hour_window/2`, which has already widened to
  contain every meeting, so a value outside the box means the caller
  passed a window that does not match its meetings, and silently pinning
  the row to the top edge would hide that.
  """
  @spec place(Meeting.t(), Date.t(), String.t(), {integer(), integer()}) ::
          {:ok, %{top: float(), height: float()}} | :skip
  def place(%Meeting{} = meeting, %Date{} = date, time_zone, {first_hour, last_hour})
      when is_binary(time_zone) and is_integer(first_hour) and is_integer(last_hour) and
             last_hour > first_hour do
    if placeable?(meeting) do
      start_local = to_zone(meeting.scheduled_start_at, time_zone)

      if Date.compare(DateTime.to_date(start_local), date) == :eq do
        end_local = to_zone(end_at(meeting), time_zone)
        window_minutes = (last_hour - first_hour) * 60

        offset_minutes = (start_local.hour - first_hour) * 60 + start_local.minute
        # Diffed on the underlying instants, so a meeting spanning a DST
        # transition gets its true wall-clock length rather than the
        # difference of two local clock readings.
        duration_minutes = DateTime.diff(end_local, start_local, :second) / 60

        {:ok,
         %{
           top: offset_minutes / window_minutes * 100,
           height: max(duration_minutes / window_minutes * 100, @min_height_percent)
         }}
      else
        :skip
      end
    else
      :skip
    end
  end

  # Local midnight of `date` in `time_zone`, returned as UTC.
  #
  # The DST returns are handled explicitly rather than `!`-d through,
  # because both of them really happen at midnight in real zones (Chile
  # and Lebanon spring forward AT midnight, so 00:00 does not exist that
  # day) and a raise would take the whole calendar down twice a year.
  defp start_of_day(%Date{} = date, time_zone) do
    case DateTime.new(date, ~T[00:00:00], time_zone) do
      {:ok, datetime} ->
        to_utc(datetime)

      # Fall-back: local midnight happens twice. Take the EARLIER one so
      # the half-open window still covers every instant of the day.
      {:ambiguous, earlier, _later} ->
        to_utc(earlier)

      # Spring-forward: local midnight never happens. `just_after` is the
      # first instant that does, which is when the day actually begins.
      {:gap, _just_before, just_after} ->
        to_utc(just_after)

      {:error, reason} ->
        # Unreachable via the LiveView: every zone reaching this module
        # has been through `resolve_time_zone/1`. Raising rather than
        # defaulting keeps a bypassed choke point loud.
        raise ArgumentError,
              "cannot build local midnight for #{inspect(date)} in #{inspect(time_zone)}: " <>
                inspect(reason)
    end
  end

  defp to_utc(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")

  # Safe to `!` — a UTC instant maps to exactly one local time in any
  # zone, so neither the ambiguous nor the gap return is reachable from
  # this direction.
  defp to_zone(%DateTime{} = datetime, time_zone),
    do: DateTime.shift_zone!(datetime, time_zone)

  defp end_at(%Meeting{scheduled_end_at: nil, scheduled_start_at: start_at}),
    do: DateTime.add(start_at, @default_duration_minutes, :minute)

  defp end_at(%Meeting{scheduled_end_at: end_at}), do: end_at

  defp ceiling_end_hour(%DateTime{} = start_local, %DateTime{} = end_local) do
    cond do
      # Spills into the next local day — the column it was drawn in runs
      # to midnight, so that is where the gutter has to reach.
      Date.compare(DateTime.to_date(end_local), DateTime.to_date(start_local)) == :gt -> 24
      end_local.minute == 0 and end_local.second == 0 -> end_local.hour
      true -> min(end_local.hour + 1, 24)
    end
  end
end
