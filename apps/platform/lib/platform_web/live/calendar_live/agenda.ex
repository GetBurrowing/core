defmodule PlatformWeb.CalendarLive.Agenda do
  @moduledoc """
  The phone calendar's data (canvas 01a2111c, "Calendar on a phone"): the
  agenda rows, the Day view's 24-hour layout and the week strip's dots.

  Pure functions over `Platform.Calendar.list_entries/4` entries, so the
  LiveView loads one window of entries and every phone part reads from it.
  Below `lg` the page shows these instead of the phone week and month grids.
  """

  alias PlatformWeb.CalendarLive, as: Cal

  @hour_px 48
  @max_lanes 2

  def hour_px, do: @hour_px
  def day_px, do: 24 * @hour_px

  @doc """
  The agenda rows for `from..to`, in order. A day with entries is a `:day`
  row; a run of empty days collapses into one `:empty` row. Today is always
  its own `:day` row, even when empty, and `connect?` puts the "Connect a
  calendar" card right before it.
  """
  def rows(entries, %Date{} = from, %Date{} = to, zone, %Date{} = today, opts \\ []) do
    connect? = Keyword.get(opts, :connect?, false)

    Date.range(from, to)
    |> Enum.map(&day(entries, &1, zone, today))
    |> Enum.chunk_while(
      [],
      fn day, acc ->
        cond do
          day.empty? and not day.today? and match?([%{empty?: true, today?: false} | _], acc) ->
            {:cont, [day | acc]}

          acc == [] ->
            {:cont, [day]}

          true ->
            {:cont, Enum.reverse(acc), [day]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.flat_map(fn
      [%{empty?: true, today?: false} = first | _] = run ->
        last = List.last(run)

        [
          %{
            id: "m-agenda-empty-#{first.date}",
            type: :empty,
            from: first.date,
            to: last.date
          }
        ]

      [%{today?: true} = day] when connect? ->
        [%{id: "m-agenda-connect", type: :connect, from: day.date, to: day.date}, day]

      [day] ->
        [day]
    end)
  end

  defp day(entries, date, zone, today) do
    list = Cal.entries_on(entries, date, zone)
    {pinned, timed} = Enum.split_with(list, &pinned?(&1, zone))

    %{
      id: "m-agenda-day-#{date}",
      type: :day,
      date: date,
      from: date,
      to: date,
      today?: date == today,
      empty?: list == [],
      pinned: Enum.map(pinned, &%{entry: &1, span: span_label(&1, date, zone)}),
      timed:
        timed
        |> Enum.map(fn entry ->
          {s, e} = Cal.day_minutes(entry, date, zone)
          %{entry: entry, s: s, e: e, tz: zone_tag(entry, zone)}
        end)
        |> Enum.sort_by(&{&1.s, &1.e})
    }
  end

  @doc """
  Whether an entry sits in the pinned row under the day header: all-day
  events, and timed events that cover more than one local day.
  """
  def pinned?(%{all_day: true}, _zone), do: true

  def pinned?(entry, zone) do
    {first, last} = local_days(entry, zone)
    Date.compare(first, last) == :lt
  end

  @doc "`Day 2 of 3` for an entry covering more than one day, else nil."
  def span_label(entry, date, zone) do
    {first, last} = local_days(entry, zone)
    total = Date.diff(last, first) + 1

    if total > 1,
      do: "Day #{Date.diff(date, first) + 1} of #{total}",
      else: nil
  end

  # The local days an entry covers. An all-day event's end date is
  # exclusive; a timed end at midnight does not cover the next day.
  defp local_days(%{all_day: true, event: %{start_date: %Date{} = s, end_date: %Date{} = e}}, _),
    do: {s, Date.add(e, -1)}

  defp local_days(entry, zone) do
    starts = DateTime.shift_zone!(entry.starts_at, zone)
    ends = DateTime.shift_zone!(entry.ends_at || DateTime.add(entry.starts_at, 1800), zone)
    last = DateTime.to_date(DateTime.add(ends, -1))
    first = DateTime.to_date(starts)
    {first, if(Date.compare(last, first) == :lt, do: first, else: last)}
  end

  @doc """
  The small timezone tag (`PST`) for an event authored in another zone than
  the viewer's, or nil. Times are always shown in the viewer's zone.
  """
  def zone_tag(%{kind: :event, all_day: false, event: %{time_zone: tz}, starts_at: at}, zone)
      when is_binary(tz) and tz != "" do
    with {:ok, theirs} <- DateTime.shift_zone(at, tz),
         {:ok, mine} <- DateTime.shift_zone(at, zone),
         true <- theirs.zone_abbr != mine.zone_abbr or theirs.utc_offset != mine.utc_offset do
      theirs.zone_abbr
    else
      _ -> nil
    end
  end

  def zone_tag(_, _), do: nil

  @doc "`Thu 26 – Sat 28` or `Thu 26 Nov` for one day."
  def range_label(from, to) when from == to, do: Calendar.strftime(from, "%a %-d %b")

  def range_label(from, to),
    do: Calendar.strftime(from, "%a %-d") <> " – " <> Calendar.strftime(to, "%a %-d %b")

  @doc """
  The Day view's 24-hour layout for `date`: timed chips with px offsets at
  #{@hour_px}px an hour, at most #{@max_lanes} side by side per overlapping
  cluster, and one `+N` per cluster for the rest.
  """
  def day_layout(entries, date, zone) do
    placed =
      entries
      |> Cal.entries_on(date, zone)
      |> Enum.reject(&pinned?(&1, zone))
      |> Enum.map(fn entry ->
        {s, e} = Cal.day_minutes(entry, date, zone)
        %{entry: entry, s: s, e: max(e, s + 15), tz: zone_tag(entry, zone)}
      end)
      |> Enum.sort_by(&{&1.s, -&1.e})

    placed
    |> clusters()
    |> Enum.reduce(%{chips: [], more: []}, fn cluster, acc ->
      {laned, lanes} = assign_lanes(cluster)
      shown_lanes = min(lanes, @max_lanes)
      {shown, hidden} = Enum.split_with(laned, &(&1.lane < @max_lanes))

      chips =
        Enum.map(shown, fn chip ->
          Map.merge(chip, %{
            lanes: shown_lanes,
            top: chip.s / 60 * @hour_px,
            height: max(22, (chip.e - chip.s) / 60 * @hour_px - 2),
            compact: (chip.e - chip.s) / 60 * @hour_px < 34
          })
        end)

      more =
        if hidden == [],
          do: [],
          else: [
            %{
              id: "m-day-more-#{date}-#{hd(cluster).s}",
              top: hd(cluster).s / 60 * @hour_px,
              entries: Enum.map(hidden, & &1.entry)
            }
          ]

      %{chips: acc.chips ++ chips, more: acc.more ++ more}
    end)
  end

  # Overlapping entries as connected runs (sorted by start).
  defp clusters(placed) do
    placed
    |> Enum.reduce([], fn chip, acc ->
      case acc do
        [{cluster, ends} | rest] when chip.s < ends ->
          [{[chip | cluster], max(ends, chip.e)} | rest]

        _ ->
          [{[chip], chip.e} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {cluster, _} -> Enum.reverse(cluster) end)
  end

  defp assign_lanes(cluster) do
    {laned, columns} =
      Enum.map_reduce(cluster, [], fn chip, columns ->
        case Enum.find_index(columns, &(&1 <= chip.s)) do
          nil -> {Map.put(chip, :lane, length(columns)), columns ++ [chip.e]}
          lane -> {Map.put(chip, :lane, lane), List.replace_at(columns, lane, chip.e)}
        end
      end)

    {laned, length(columns)}
  end

  @doc "The now line's px offset on a 24-hour Day view."
  def now_px(zone) do
    local = DateTime.utc_now() |> DateTime.shift_zone!(zone)
    (local.hour * 60 + local.minute) / 60 * @hour_px
  end

  @doc "The set of dates in `days` that have at least one entry."
  def busy_days(entries, days, zone) do
    days
    |> Enum.filter(&(Cal.entries_on(entries, &1, zone) != []))
    |> MapSet.new()
  end

  @doc "A 6-week month grid starting on the Monday on or before the 1st."
  def month_days(month), do: Cal.mini_days(month)
end
