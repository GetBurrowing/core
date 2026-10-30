defmodule PlatformWeb.MeetingLive.CalendarWindow do
  @moduledoc """
  Pure date/time arithmetic behind the meetings calendar (task 019fb954-8ead).

  Deliberately holds NO LiveView imports and touches no socket: every
  function here is a total function of its arguments, so the week maths
  and the placement maths are unit-testable without mounting anything.
  `PlatformWeb.MeetingLive` and `PlatformWeb.CalendarLive` own their assigns;
  this module owns the shared arithmetic.

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

  This is also why the minimum drawn size is expressed in MINUTES rather
  than pixels. A pixel floor inside a proportional box is a contradiction:
  any floor larger than the slot's own share necessarily reaches into the
  next slot, and the block below it then renders its text on top of the
  block above. Stating the floor as "no block is drawn shorter than half
  an hour" keeps the floor in the same currency as the placement, so the
  two can no longer disagree.

  ## Lanes

  `assign_lanes/1` is the second half of "two blocks never sit on top of
  each other". Placement alone answers WHEN, which is not enough: two
  meetings at the same time get the same `top` and `height`, so without a
  horizontal split they are the same box and their labels overprint. Lanes
  are computed from the DRAWN geometry rather than the scheduled times, so
  a pair pushed into contact by the half-hour floor is separated on exactly
  the same rule as a pair that genuinely overlaps.
  """

  alias Platform.Meetings.Meeting

  @typedoc "Where a block sits vertically, as percentages of the drawn window."
  @type placement :: %{top: float(), height: float()}

  @typedoc "A placement that also knows how wide it is and which lane it took."
  @type laid_out :: %{
          top: float(),
          height: float(),
          lane: non_neg_integer(),
          lanes: pos_integer(),
          left: float(),
          width: float()
        }

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

  # Floor so a 5-minute meeting is still a tappable target at 375px rather
  # than a 1px hairline — stated in MINUTES, not pixels or percent, because
  # the drawn box is proportional and a floor in any other unit competes
  # with the placement instead of participating in it. Half an hour is the
  # number the mobile day view's row height is chosen against: at 5.5rem an
  # hour, thirty drawn minutes is exactly the 44px touch target, so the
  # floor is met by the geometry and nothing has to override it in CSS.
  @min_drawn_minutes 30

  # Placement percentages are floats, and `top + height` for one block is
  # two divisions summed where the next block's `top` is one — the same
  # boundary can therefore land a few ulps apart. Compared bare, two
  # back-to-back meetings occasionally read as overlapping and get split
  # into lanes for no reason a viewer can see. Well below any real overlap
  # (a single minute of a 24-hour window is still 0.07%).
  @overlap_epsilon 1.0e-9

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
          {:ok, placement()} | :skip
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
           height: max(duration_minutes, @min_drawn_minutes) / window_minutes * 100
         }}
      else
        :skip
      end
    else
      :skip
    end
  end

  @doc """
  Splits one day's placements into side-by-side lanes so that no two drawn
  boxes occupy the same space.

  Takes and returns `{term, placement}` pairs — the caller's term is opaque
  here, which keeps this module free of `Meeting` for the layout half. Each
  returned placement gains `:lane` (0-based), `:lanes` (how many the block
  shares its cluster with), and the `:left` / `:width` percentages the two
  are shorthand for. A block with no neighbour comes back `lane: 0, lanes:
  1, left: 0.0, width: 100.0` — full width, exactly as before lanes existed.

  Overlap is decided on the DRAWN interval `[top, top + height)`, not on
  the scheduled times, and that is the point: `place/4`'s half-hour floor
  can push a five-minute meeting into the block below it, and a viewer
  cannot tell that collision apart from a real double-booking. Deciding on
  what is actually drawn covers both with one rule.

  Half-open, so back-to-back meetings share no boundary and stay full
  width — a 09:00–09:30 followed by a 09:30–10:00 is not a conflict and
  must not be drawn as one.

  Lanes are counted per CLUSTER of transitively-overlapping blocks, so a
  10:00 meeting that merely follows a crowded 09:00 does not inherit that
  crowd's width.
  """
  @spec assign_lanes([{term(), placement()}]) :: [{term(), laid_out()}]
  def assign_lanes(placements) when is_list(placements) do
    placements
    # Longest first among blocks that start together, so the widest
    # commitment takes lane 0 and the reading order down a cluster is
    # stable rather than dependent on insertion order.
    |> Enum.sort_by(fn {_term, %{top: top, height: height}} -> {top, -height} end)
    |> cluster()
    |> Enum.flat_map(&lay_out_cluster/1)
  end

  # Groups the sorted placements into runs of transitively-overlapping
  # blocks. `max_bottom` rather than the previous block's bottom: a long
  # block keeps its cluster open across shorter ones nested inside it.
  defp cluster(sorted) do
    sorted
    |> Enum.reduce([], fn {_term, placement} = entry, acc ->
      bottom = placement.top + placement.height

      case acc do
        [{members, max_bottom} | rest] ->
          if overlapping?(placement.top, max_bottom) do
            [{[entry | members], max(max_bottom, bottom)} | rest]
          else
            [{[entry], bottom} | acc]
          end

        [] ->
          [{[entry], bottom}]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {members, _max_bottom} -> Enum.reverse(members) end)
  end

  defp lay_out_cluster(members) do
    {laned, lane_bottoms} =
      Enum.map_reduce(members, [], fn {term, placement}, lane_bottoms ->
        lane = first_free_lane(lane_bottoms, placement.top)

        {{term, placement, lane},
         put_lane_bottom(lane_bottoms, lane, placement.top + placement.height)}
      end)

    lanes = length(lane_bottoms)
    width = 100 / lanes

    Enum.map(laned, fn {term, placement, lane} ->
      {term, Map.merge(placement, %{lane: lane, lanes: lanes, left: lane * width, width: width})}
    end)
  end

  # Reuse the leftmost lane whose last block has already ended, so a
  # cluster of three staggered meetings is three lanes wide only while all
  # three genuinely coincide.
  defp first_free_lane(lane_bottoms, top) do
    case Enum.find_index(lane_bottoms, fn bottom -> not overlapping?(top, bottom) end) do
      nil -> length(lane_bottoms)
      index -> index
    end
  end

  defp put_lane_bottom(lane_bottoms, lane, bottom) do
    if lane < length(lane_bottoms) do
      List.replace_at(lane_bottoms, lane, bottom)
    else
      lane_bottoms ++ [bottom]
    end
  end

  defp overlapping?(top, bottom), do: top + @overlap_epsilon < bottom

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
