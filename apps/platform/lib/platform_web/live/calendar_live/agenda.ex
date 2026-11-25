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

  @doc """
  The agenda rows for `from..to`, in order. A day with entries is a `:day`
  row; a run of empty days collapses into one `:empty` row. Today is always
  its own `:day` row, even when empty, and `connect?` puts the "Connect a
  calendar" card right before it.

  `extension_days` (dates with extension entries, e.g. Social posts that
  need the viewer) are always their own `:day` row too, so their header and
  its chip exist; with no calendar entry such a row is `ext_only?`.
  """
  def rows(entries, %Date{} = from, %Date{} = to, zone, %Date{} = today, opts \\ []) do
    connect? = Keyword.get(opts, :connect?, false)
    ending? = Keyword.get(opts, :ending?, false)
    ext_days = Keyword.get(opts, :extension_days, MapSet.new())

    Date.range(from, to)
    |> Enum.map(&day(entries, &1, zone, today, MapSet.member?(ext_days, &1)))
    |> Enum.chunk_while(
      [],
      fn day, acc ->
        cond do
          day.run? and match?([%{run?: true} | _], acc) ->
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
    |> mark_ending(ending?)
    |> Enum.flat_map(fn
      [%{run?: true} = first | _] = run ->
        last = List.last(run)

        [
          %{
            id: "m-agenda-empty-#{first.date}",
            type: :empty,
            from: first.date,
            to: last.date,
            ending?: Map.get(last, :ending?, false)
          }
        ]

      [%{today?: true} = day] when connect? ->
        [%{id: "m-agenda-connect", type: :connect, from: day.date, to: day.date}, day]

      [day] ->
        [day]
    end)
  end

  # With nothing in the two years after it (`ending?`), the final empty run
  # is the agenda's end: it reads "After <day> · No events".
  defp mark_ending(groups, false), do: groups

  defp mark_ending(groups, true) do
    case List.last(groups) do
      [%{run?: true} | _] = run ->
        List.replace_at(groups, -1, List.update_at(run, -1, &Map.put(&1, :ending?, true)))

      _ ->
        groups
    end
  end

  defp day(entries, date, zone, today, ext?) do
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
      # Collapses into a "No events" run: no calendar entry, not today, and
      # nothing from an extension either.
      run?: list == [] and date != today and not ext?,
      ext_only?: list == [] and ext?,
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

  @doc """
  `Thu 26 Nov` for one day, `Thu 26 – Sat 28 Nov` within a month,
  `Mon 15 Dec – Sun 11 Jan` across months, and with years once a run is
  long enough (half a year) that the year is no longer obvious.
  """
  def range_label(from, to) when from == to, do: Calendar.strftime(from, "%a %-d %b")

  def range_label(from, to) do
    cond do
      Date.diff(to, from) > 183 ->
        Calendar.strftime(from, "%a %-d %b %Y") <> " – " <> Calendar.strftime(to, "%a %-d %b %Y")

      from.month == to.month and from.year == to.year ->
        Calendar.strftime(from, "%a %-d") <> " – " <> Calendar.strftime(to, "%a %-d %b")

      true ->
        Calendar.strftime(from, "%a %-d %b") <> " – " <> Calendar.strftime(to, "%a %-d %b")
    end
  end

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
              hour: hd(cluster).s / 60,
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

  @doc "Now as hours since midnight in `zone` (the Day view's now line)."
  def now_hours(zone) do
    local = DateTime.utc_now() |> DateTime.shift_zone!(zone)
    (local.hour * 60 + local.minute) / 60
  end

  @doc "Each date in `days` that has entries, with how many."
  def day_counts(entries, days, zone) do
    for day <- days,
        n = length(Cal.entries_on(entries, day, zone)),
        n > 0,
        into: %{},
        do: {day, n}
  end

  @doc """
  Extension entries (`Platform.Extensions.calendar_day_entries/4`) by date:
  `%{date => %{count: n, label: "3 Social items"}}` over the entries with
  items, for the strip and month markers and the cell labels.
  """
  def extension_counts(day_entries) do
    day_entries
    |> Enum.filter(&(&1.items != []))
    |> Enum.group_by(& &1.day)
    |> Map.new(fn {day, entries} ->
      label =
        Enum.map_join(entries, ", ", fn e ->
          n = length(e.items)
          "#{n} #{e.label} #{if n == 1, do: "item", else: "items"}"
        end)

      {day, %{count: Enum.sum(Enum.map(entries, &length(&1.items))), label: label}}
    end)
  end

  # ── week start (ISO 1 = Monday … 7 = Sunday, from the browser locale) ──

  @week_atoms %{
    1 => :monday,
    2 => :tuesday,
    3 => :wednesday,
    4 => :thursday,
    5 => :friday,
    6 => :saturday,
    7 => :sunday
  }

  @doc "The connect param `week_start` as 1..7; anything else is Monday."
  def week_start(value) when is_integer(value) and value in 1..7, do: value

  def week_start(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> week_start(n)
      _ -> 1
    end
  end

  def week_start(_), do: 1

  @doc "The first day of `date`'s week when weeks start on `ws`."
  def week_first(date, ws \\ 1), do: Date.beginning_of_week(date, Map.fetch!(@week_atoms, ws))

  @doc "The seven days of `date`'s week."
  def week_days(date, ws \\ 1) do
    first = week_first(date, ws)
    Enum.map(0..6, &Date.add(first, &1))
  end

  @doc "The weekday initials in week order, `M T W T F S S` from Monday."
  def weekday_letters(ws \\ 1) do
    letters = ~w(M T W T F S S)
    Enum.map(0..6, &Enum.at(letters, rem(ws - 1 + &1, 7)))
  end

  @doc "A 6-week month grid starting on the week start on or before the 1st."
  def month_days(month, ws \\ 1) do
    first = month |> Date.beginning_of_month() |> week_first(ws)
    Enum.map(0..41, &Date.add(first, &1))
  end
end
