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
    * one `ATTENDEE;CN=<name>;ROLE=REQ-PARTICIPANT;PARTSTAT=<status>;
      RSVP=TRUE:mailto:<address>` per invitee when the caller passes
      `parties.attendees` (`Platform.Meetings.calendar_attendees/1`), so
      the recipient's calendar shows who is invited and who has accepted or
      declined, as Google and Outlook invites do. The recipient is always
      among them. Without `attendees`, only the recipient is listed;
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
  alias Platform.Meetings.IcsAttendees
  alias Platform.Meetings.Meeting

  @prodid "-//Burrow//Meetings//EN"

  @type person :: {String.t() | nil, String.t()}
  @type parties :: %{
          required(:organizer) => person(),
          required(:attendee) => person(),
          required(:location) => String.t() | nil,
          optional(:attendees) => [IcsAttendees.attendee()]
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

    lines =
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
        IcsAttendees.organizer_line(organizer)
      ] ++
        Enum.map(attendees(attendee, Map.get(parties, :attendees)), &IcsAttendees.attendee_line/1) ++
        [
          "STATUS:" <> status,
          "SEQUENCE:" <> Integer.to_string(sequence),
          "LAST-MODIFIED:" <> ICal.utc_stamp(meeting.updated_at),
          "TRANSP:OPAQUE",
          "END:VEVENT",
          "END:VCALENDAR"
        ]

    document =
      lines
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&[ICal.fold(&1), "\r\n"])
      |> IO.iodata_to_binary()

    {:ok, document}
  end

  defp location(url) when is_binary(url) and url != "", do: "LOCATION:" <> ICal.escape(url)
  defp location(_url), do: nil

  # The whole invitee list when the caller passes it, with this recipient's
  # line always present: a recipient missing from `attendees` (the list was
  # read before their row) is added as NEEDS-ACTION, so a client always
  # finds itself among the attendees and offers Accept/Decline.
  defp attendees({name, address}, list) when is_list(list) and list != [] do
    if Enum.any?(list, &IcsAttendees.same_address?(&1.address, address)) do
      list
    else
      [%{name: name, address: String.trim(address), partstat: "NEEDS-ACTION"} | list]
    end
  end

  defp attendees({name, address}, _list),
    do: [%{name: name, address: String.trim(address), partstat: "NEEDS-ACTION"}]
end
