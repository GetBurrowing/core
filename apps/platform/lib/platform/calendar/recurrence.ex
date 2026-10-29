defmodule Platform.Calendar.Recurrence do
  @moduledoc "Bounded query-time daily/weekly/monthly recurrence in the event's local zone."

  def parse(nil), do: {:ok, nil}
  def parse(""), do: {:ok, nil}

  def parse(rule) when is_binary(rule) do
    parts = String.split(rule, ";")
    entries = Enum.map(parts, &String.split(&1, "=", parts: 2))

    with true <- Enum.all?(entries, &(length(&1) == 2)),
         map <- Map.new(entries, fn [key, value] -> {key, value} end),
         true <- map_size(map) == length(entries),
         true <- Enum.all?(Map.keys(map), &(&1 in ~w(FREQ INTERVAL COUNT UNTIL))),
         freq when freq in ~w(DAILY WEEKLY MONTHLY) <- map["FREQ"],
         {:ok, interval} <- positive(map["INTERVAL"] || "1", 365),
         {:ok, count} <- optional_count(map["COUNT"]),
         {:ok, until_date} <- until_date(map["UNTIL"]) do
      {:ok, %{frequency: freq, interval: interval, count: count, until: until_date}}
    else
      _ -> {:error, :unsupported_rule}
    end
  end

  def parse(_), do: {:error, :unsupported_rule}

  defp positive(value, max) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= max -> {:ok, n}
      _ -> {:error, :invalid_number}
    end
  end

  defp optional_count(nil), do: {:ok, nil}
  defp optional_count(value), do: positive(value, 10_000)
  defp until_date(nil), do: {:ok, nil}

  defp until_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>),
    do: Date.from_iso8601(y <> "-" <> m <> "-" <> d)

  defp until_date(_), do: {:error, :invalid_until}

  def occurrences(event, from, to) do
    case parse(event.recurrence) do
      {:ok, nil} -> if overlaps?(event.starts_at, event.ends_at, from, to), do: [event], else: []
      {:ok, rule} -> expand(event, rule, from, to)
      _ -> []
    end
  end

  def overlaps?(start_at, end_at, from, to),
    do: DateTime.compare(start_at, to) == :lt and DateTime.compare(end_at, from) == :gt

  defp expand(event, rule, from, to) do
    first = DateTime.shift_zone!(event.starts_at, event.time_zone)
    last = DateTime.shift_zone!(event.ends_at, event.time_zone)
    first_date = DateTime.to_date(first)
    last_date = DateTime.to_date(last)
    end_date = to |> DateTime.shift_zone!(event.time_zone) |> DateTime.to_date()

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take_while(&(is_nil(rule.count) or &1 < rule.count))
    |> Stream.map(fn n -> occurrence_date(first_date, rule, n) end)
    |> Stream.take_while(fn date ->
      is_nil(date) or
        (Date.compare(date, end_date) != :gt and
           (is_nil(rule.until) or Date.compare(date, rule.until) != :gt))
    end)
    |> Enum.flat_map(fn
      nil ->
        []

      date ->
        days = Date.diff(date, first_date)

        with false <- date in event.exception_dates,
             {:ok, start_at} <- DateTime.new(date, DateTime.to_time(first), event.time_zone),
             {:ok, end_at} <-
               DateTime.new(Date.add(last_date, days), DateTime.to_time(last), event.time_zone),
             true <- overlaps?(start_at, end_at, from, to) do
          [
            %{
              event
              | starts_at: DateTime.shift_zone!(start_at, "Etc/UTC"),
                ends_at: DateTime.shift_zone!(end_at, "Etc/UTC"),
                start_date: if(event.all_day, do: date, else: nil),
                end_date: if(event.all_day, do: Date.add(last_date, days), else: nil)
            }
          ]
        else
          _ -> []
        end
    end)
  end

  defp occurrence_date(first, %{frequency: "DAILY", interval: i}, n), do: Date.add(first, i * n)

  defp occurrence_date(first, %{frequency: "WEEKLY", interval: i}, n),
    do: Date.add(first, 7 * i * n)

  defp occurrence_date(first, %{frequency: "MONTHLY", interval: i}, n) do
    month = first.year * 12 + first.month - 1 + i * n

    case Date.new(div(month, 12), rem(month, 12) + 1, first.day) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
