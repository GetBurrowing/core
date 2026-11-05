defmodule Platform.Meetings.InviteIcs do
  @moduledoc """
  The iCalendar document an invite email carries (task 01a1a933 stage 2):
  an RFC 5546 iTIP `REQUEST` (invitation, reschedule) or `CANCEL`.

  A pure function of its arguments, like `Platform.Meetings.CalendarFeed`,
  whose encoding helpers (`Platform.ICal`) and UID (`CalendarFeed.uid/1`) it
  reuses. The shared UID is the point: the emailed event, a later
  cancellation or update, and the subscription feed are ONE event to a
  calendar client, so a cancel clears what the invitation added.

  ## Differences from the feed, and why

  The feed is a `METHOD:PUBLISH` document for anyone holding a bearer URL,
  so it omits ORGANIZER, ATTENDEE and LOCATION. An invite email goes to one
  named person and is an iTIP scheduling message, which RFC 5546 §3.2.2 and
  §3.2.5 require to name the ORGANIZER and the ATTENDEE. So this document
  carries:

    * `ORGANIZER;CN=<name>:mailto:<address>` — the SENDING account's
      address, passed in by the caller; never a platform address. A
      client's Accept/Decline reply goes to it;
    * `ATTENDEE;CN=<name>;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;
      RSVP=TRUE:mailto:<invitee>` — this recipient only, never the list;
    * `LOCATION` — the recipient's own join URL.

  ## SEQUENCE

  `REQUEST` carries `meetings.ical_sequence`, `CANCEL` carries it plus one,
  exactly as the feed does (`CalendarFeed.sequence/1`). A reschedule bumps
  the column, so an update outranks the invitation the client holds.

  Times are UTC `Z` form and DTSTAMP is `updated_at`, for the reasons the
  feed's moduledoc gives. Lines are CRLF-terminated and folded at 75
  octets.
  """

  alias Platform.ICal
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.Meeting

  @prodid "-//Burrow//Meetings//EN"

  @type person :: {String.t() | nil, String.t()}
  @type parties :: %{
          required(:organizer) => person(),
          required(:attendee) => person(),
          required(:location) => String.t() | nil
        }

  @doc """
  Render `meeting` as an iTIP `:request` or `:cancel` for one attendee.

  Returns `{:error, :unscheduled}` when the meeting has no scheduled
  start/end pair: there is no event to put on a calendar.
  """
  @spec render(Meeting.t(), :request | :cancel, parties()) ::
          {:ok, binary()} | {:error, :unscheduled}
  def render(%Meeting{scheduled_start_at: nil}, _method, _parties), do: {:error, :unscheduled}
  def render(%Meeting{scheduled_end_at: nil}, _method, _parties), do: {:error, :unscheduled}

  def render(%Meeting{} = meeting, method, %{organizer: organizer, attendee: attendee} = parties)
      when method in [:request, :cancel] do
    {method_name, status, sequence} =
      case method do
        :request -> {"REQUEST", "CONFIRMED", CalendarFeed.sequence(meeting)}
        :cancel -> {"CANCEL", "CANCELLED", CalendarFeed.sequence(meeting) + 1}
      end

    document =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:" <> @prodid,
        "CALSCALE:GREGORIAN",
        "METHOD:" <> method_name,
        "BEGIN:VEVENT",
        "UID:" <> CalendarFeed.uid(meeting),
        "DTSTAMP:" <> ICal.utc_stamp(meeting.updated_at),
        "DTSTART:" <> ICal.utc_stamp(meeting.scheduled_start_at),
        "DTEND:" <> ICal.utc_stamp(meeting.scheduled_end_at),
        "SUMMARY:" <> ICal.escape(meeting.name || ""),
        location(Map.get(parties, :location)),
        "ORGANIZER" <> cn(organizer) <> ":mailto:" <> address(organizer),
        "ATTENDEE" <>
          cn(attendee) <>
          ";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:" <> address(attendee),
        "STATUS:" <> status,
        "SEQUENCE:" <> Integer.to_string(sequence),
        "TRANSP:OPAQUE",
        "END:VEVENT",
        "END:VCALENDAR"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&[ICal.fold(&1), "\r\n"])
      |> IO.iodata_to_binary()

    {:ok, document}
  end

  defp location(url) when is_binary(url) and url != "", do: "LOCATION:" <> ICal.escape(url)
  defp location(_url), do: nil

  # RFC 5545 §3.2.2 CN is a param-value: quoted, and a DQUOTE cannot appear
  # inside a quoted-string at all, so it is dropped along with controls.
  defp cn({name, _address}) when is_binary(name) do
    case name |> String.replace(~r/["\x00-\x1F\x7F]/u, "") |> String.trim() do
      "" -> ""
      clean -> ";CN=\"" <> clean <> "\""
    end
  end

  defp cn(_person), do: ""

  defp address({_name, address}) when is_binary(address), do: String.trim(address)
end
