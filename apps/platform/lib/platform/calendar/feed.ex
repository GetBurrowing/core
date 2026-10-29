defmodule Platform.Calendar.Feed do
  @moduledoc "Aggregate private calendar serialization, sharing content-line rules with meeting invites."
  alias Platform.ICal

  def render(scope) do
    events = Enum.flat_map(Platform.Calendar.feed_events(scope), &series_lines/1)

    meetings =
      if Platform.Access.can?(scope, "meetings.join") do
        Platform.Meetings.list_meetings_for_user(scope.actor)
        |> Enum.flat_map(fn meeting ->
          case Platform.Meetings.CalendarFeed.render(meeting) do
            {:ok, document} ->
              # The meeting serializer owns UID, cancellation and invite privacy.
              [_before, event] = String.split(document, "BEGIN:VEVENT\r\n", parts: 2)

              [
                String.replace_suffix(event, "END:VCALENDAR\r\n", "")
                |> then(&("BEGIN:VEVENT\r\n" <> &1))
              ]

            _ ->
              []
          end
        end)
      else
        []
      end

    [
      encode([
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Burrow//Calendar//EN",
        "CALSCALE:GREGORIAN"
      ]),
      events,
      meetings,
      "END:VCALENDAR\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  # Expand a rolling three-year recurrence window in the source timezone.
  # UTC RRULEs would shift wall-clock time across DST; each occurrence instead
  # has a stable series/date UID and a real UTC instant. Subscription refreshes
  # advance coverage. The UI reports this window beside the feed URL.
  defp series_lines(%{recurrence: rule} = event) when rule not in [nil, ""] do
    now = DateTime.utc_now()
    from = DateTime.add(now, -366 * 86_400)
    to = DateTime.add(now, 2 * 366 * 86_400)

    Platform.Calendar.Recurrence.occurrences(event, from, to)
    |> Enum.flat_map(fn occurrence ->
      date = occurrence.starts_at |> DateTime.shift_zone!(event.time_zone) |> DateTime.to_date()

      event_lines(%{
        occurrence
        | id: event.id <> "-" <> Date.to_iso8601(date),
          recurrence: nil,
          exception_dates: []
      })
    end)
  end

  defp series_lines(event), do: event_lines(event)

  defp event_lines(event) do
    window =
      if event.all_day do
        [
          "DTSTART;VALUE=DATE:" <> Calendar.strftime(event.start_date, "%Y%m%d"),
          "DTEND;VALUE=DATE:" <> Calendar.strftime(event.end_date, "%Y%m%d")
        ]
      else
        ["DTSTART:" <> ICal.utc_stamp(event.starts_at), "DTEND:" <> ICal.utc_stamp(event.ends_at)]
      end

    recurrence = if event.recurrence in [nil, ""], do: [], else: ["RRULE:" <> event.recurrence]

    exceptions =
      Enum.map(event.exception_dates, fn date ->
        if event.all_day do
          "EXDATE;VALUE=DATE:" <> Calendar.strftime(date, "%Y%m%d")
        else
          local = DateTime.shift_zone!(event.starts_at, event.time_zone)

          case DateTime.new(date, DateTime.to_time(local), event.time_zone) do
            {:ok, at} -> "EXDATE:" <> ICal.utc_stamp(at)
            _ -> nil
          end
        end
      end)
      |> Enum.reject(&is_nil/1)

    [
      encode(
        ["BEGIN:VEVENT", "UID:event-" <> event.id, "DTSTAMP:" <> ICal.utc_stamp(event.updated_at)] ++
          window ++
          [
            "SUMMARY:" <> ICal.escape(event.title),
            "STATUS:" <> if(event.cancelled_at, do: "CANCELLED", else: "CONFIRMED"),
            "SEQUENCE:" <> Integer.to_string(event.sequence),
            "TRANSP:OPAQUE"
          ] ++
          recurrence ++ exceptions ++ ["END:VEVENT"]
      )
    ]
  end

  defp encode(lines), do: Enum.map(lines, &[ICal.fold(&1), "\r\n"])
end
