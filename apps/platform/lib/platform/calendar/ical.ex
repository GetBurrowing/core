defmodule Platform.Calendar.ICal do
  @moduledoc """
  Conservative bounded RFC5545 import. Supports UTC/IANA TZID date-times, DATE,
  DAILY/WEEKLY/MONTHLY rules supported by Recurrence and DATE EXDATEs. Floating
  times, VTIMEZONE definitions, overrides, RDATE, complex rules and unknown event
  semantics reject the complete snapshot, preserving an explicit unavailable state.
  The existing icalendar test parser discards unsupported recurrence semantics and
  is therefore unsuitable as the availability authority.
  """
  alias Platform.Calendar.{Event, Recurrence}
  @max_bytes 1_048_576
  @metadata ~w(DTSTAMP CREATED LAST-MODIFIED SEQUENCE DESCRIPTION LOCATION URL ORGANIZER ATTENDEE CATEGORIES CLASS PRIORITY RESOURCES CONTACT COMMENT X-MICROSOFT-CDO-BUSYSTATUS)

  def parse(body) when is_binary(body) and byte_size(body) <= @max_bytes do
    with true <- String.valid?(body),
         lines <-
           body |> String.replace(~r/\r?\n[ \t]/, "") |> String.split(~r/\r?\n/, trim: true),
         ["BEGIN:VCALENDAR" | _] <- lines,
         "END:VCALENDAR" <- List.last(lines),
         {:ok, rows} <- collect(lines, nil, []),
         true <- length(rows) <= 2000 do
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        Map.update(acc, row["uid"], row, fn old ->
          cond do
            row["sequence"] > old["sequence"] -> row
            row["sequence"] < old["sequence"] -> old
            row == old -> old
            true -> raise ArgumentError, "ambiguous duplicate UID"
          end
        end)
      end)
      |> Map.values()
      |> Enum.reject(& &1["cancelled"])
      |> then(&{:ok, &1})
    else
      _ -> {:error, :unsupported_or_malformed_feed}
    end
  rescue
    _ -> {:error, :unsupported_or_malformed_feed}
  end

  def parse(_), do: {:error, :too_large}

  defp collect([], nil, rows), do: {:ok, rows}
  defp collect(["BEGIN:VEVENT" | rest], nil, rows), do: collect(rest, [], rows)

  defp collect(["END:VEVENT" | rest], props, rows) when is_list(props) do
    with {:ok, row} <- event(Enum.reverse(props)), do: collect(rest, nil, [row | rows])
  end

  defp collect([line | rest], props, rows) do
    cond do
      String.starts_with?(line, "BEGIN:") and line != "BEGIN:VCALENDAR" ->
        {:error, :unsupported_component}

      is_list(props) ->
        collect(rest, [line | props], rows)

      line in [
        "BEGIN:VCALENDAR",
        "END:VCALENDAR",
        "VERSION:2.0",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH"
      ] or String.starts_with?(line, "PRODID:") or String.starts_with?(line, "X-WR-") ->
        collect(rest, nil, rows)

      true ->
        {:error, :unsupported_component}
    end
  end

  defp event(lines) do
    pairs =
      Enum.map(lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        [name | params] = String.split(key, ";")
        {name, {params, value}}
      end)

    props = Map.new(pairs)

    with true <- map_size(props) == length(pairs),
         {[], uid} when byte_size(uid) in 1..1024 <- props["UID"],
         true <-
           Enum.all?(
             Map.keys(props),
             &(&1 in (~w(UID SUMMARY DTSTART DTEND RRULE EXDATE STATUS TRANSP) ++ @metadata))
           ),
         sequence <- sequence(props["SEQUENCE"]) do
      if props["STATUS"] == {[], "CANCELLED"} do
        {:ok, %{"uid" => uid, "sequence" => sequence, "cancelled" => true}}
      else
        with {:ok, first, zone, date} <- datetime(props["DTSTART"]),
             {:ok, last, end_zone, end_date} <- datetime(props["DTEND"]),
             true <- zone == end_zone and is_nil(date) == is_nil(end_date),
             true <- DateTime.compare(first, last) == :lt,
             rule <- value(props["RRULE"]),
             {:ok, recurrence} <- Recurrence.parse(rule),
             true <- supported_recurrence?(recurrence, zone, first),
             {:ok, exceptions} <- exceptions(props["EXDATE"]),
             true <- props["STATUS"] in [nil, {[], "CONFIRMED"}, {[], "TENTATIVE"}],
             true <- props["TRANSP"] in [nil, {[], "OPAQUE"}, {[], "TRANSPARENT"}] do
          {:ok,
           %{
             "uid" => uid,
             "sequence" => sequence,
             "title" => unescape(value(props["SUMMARY"]) || "Busy"),
             "starts_at" => DateTime.to_iso8601(first),
             "ends_at" => DateTime.to_iso8601(last),
             "time_zone" => zone,
             "all_day" => not is_nil(date),
             "start_date" => date && Date.to_iso8601(date),
             "end_date" => end_date && Date.to_iso8601(end_date),
             "recurrence" => rule,
             "exception_dates" => exceptions,
             "transparent" => props["TRANSP"] == {[], "TRANSPARENT"}
           }}
        else
          _ -> {:error, :unsupported_event}
        end
      end
    else
      _ -> {:error, :unsupported_event}
    end
  end

  defp supported_recurrence?(nil, _, _), do: true

  # A conservative year bound keeps the native expansion inside Date's domain,
  # including monthly rules that skip nonexistent days before counting.
  defp supported_recurrence?(%{count: count, interval: interval, until: nil}, "Etc/UTC", first)
       when is_integer(count) and count <= 1000,
       do: first.year + (count - 1) * interval <= 9999

  defp supported_recurrence?(_, _, _), do: false
  defp sequence(nil), do: 0

  defp sequence({[], value}) do
    {n, ""} = Integer.parse(value)
    if n < 0, do: raise(ArgumentError), else: n
  end

  defp value(nil), do: nil
  defp value({[], value}), do: value
  defp value(_), do: raise(ArgumentError)

  defp unescape(value),
    do:
      value
      |> String.replace(~r/\\[nN]/, "\n")
      |> String.replace("\\,", ",")
      |> String.replace("\\;", ";")
      |> String.replace("\\\\", "\\")
      |> String.slice(0, 300)

  defp datetime({["VALUE=DATE"], value}) do
    with {:ok, date} <- date(value),
         {:ok, at} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC"),
         do: {:ok, at, "Etc/UTC", date}
  end

  defp datetime({[], <<value::binary-size(15), "Z">>}), do: local(value, "Etc/UTC")
  defp datetime({["TZID=" <> zone], value}), do: local(value, zone)
  defp datetime(_), do: {:error, :unsupported_time}

  defp local(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           min::binary-size(2), s::binary-size(2)>>,
         zone
       ) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{min}:#{s}"),
         {:ok, at} <- DateTime.from_naive(naive, zone),
         do: {:ok, DateTime.shift_zone!(at, "Etc/UTC"), zone, nil}
  end

  defp local(_, _), do: {:error, :unsupported_time}

  defp date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>),
    do: Date.from_iso8601("#{y}-#{m}-#{d}")

  defp date(_), do: {:error, :invalid_date}
  defp exceptions(nil), do: {:ok, []}

  defp exceptions({["VALUE=DATE"], value}) do
    dates = String.split(value, ",")

    if Enum.all?(dates, &match?({:ok, _}, date(&1))),
      do:
        {:ok,
         Enum.map(dates, fn v ->
           {:ok, d} = date(v)
           Date.to_iso8601(d)
         end)},
      else: {:error, :invalid_exception}
  end

  defp exceptions(_), do: {:error, :unsupported_exception}

  def event(row, subscription_id) do
    {:ok, first, _} = DateTime.from_iso8601(row["starts_at"])
    {:ok, last, _} = DateTime.from_iso8601(row["ends_at"])

    %Event{
      id: subscription_id <> ":" <> row["uid"],
      title: row["title"],
      starts_at: first,
      ends_at: last,
      time_zone: row["time_zone"],
      all_day: row["all_day"],
      recurrence: row["recurrence"],
      start_date: parse_date(row["start_date"]),
      end_date: parse_date(row["end_date"]),
      exception_dates: Enum.map(row["exception_dates"], &Date.from_iso8601!/1)
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(value), do: Date.from_iso8601!(value)
end
