defmodule Platform.Meetings.InviteIcsTest do
  @moduledoc """
  `Platform.Meetings.InviteIcs` (task 01a1a933 stage 2): the iTIP
  REQUEST/CANCEL document an invite email carries, plus the
  `CalendarFeed` SEQUENCE regression the new `ical_sequence` column must
  not disturb.

  Assertions go through `PlatformTest.ICSContentLines`, never a substring
  match (see `Platform.Meetings.CalendarFeedTest` for why).
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.InviteIcs
  alias Platform.Meetings.Meeting
  alias PlatformTest.ICSContentLines, as: Lines

  @meeting_id "0198f1c0-0000-7000-8000-0000000000aa"
  @start ~U[2026-11-11 14:00:00.123456Z]
  @finish ~U[2026-11-11 14:30:00.000000Z]
  @updated_at ~U[2026-11-05 09:30:00.000000Z]

  @parties %{
    organizer: {"Example Org", "meetings@example.com"},
    attendee: {"Guest Person", "guest@example.com"},
    location: "https://guest.example.com/g/abc123"
  }

  defp meeting(attrs \\ %{}) do
    struct!(
      %Meeting{
        id: @meeting_id,
        slug: "roadmap",
        name: "Roadmap review",
        status: "scheduled",
        scheduled_start_at: @start,
        scheduled_end_at: @finish,
        inserted_at: @updated_at,
        updated_at: @updated_at
      },
      attrs
    )
  end

  defp render!(meeting, method, parties \\ @parties) do
    {:ok, body} = InviteIcs.render(meeting, method, parties)
    body
  end

  describe "METHOD, STATUS and SEQUENCE" do
    test "a request is METHOD:REQUEST, STATUS:CONFIRMED, SEQUENCE = ical_sequence" do
      body = render!(meeting(), :request)

      assert Lines.value!(body, "METHOD") == "REQUEST"
      assert Lines.value!(body, "STATUS") == "CONFIRMED"
      assert Lines.value!(body, "SEQUENCE") == "0"
      assert Lines.value!(body, "TRANSP") == "OPAQUE"
    end

    test "a cancel is METHOD:CANCEL, STATUS:CANCELLED, SEQUENCE above the request's" do
      request = render!(meeting(), :request)
      cancel = render!(meeting(), :cancel)

      assert Lines.value!(cancel, "METHOD") == "CANCEL"
      assert Lines.value!(cancel, "STATUS") == "CANCELLED"

      assert String.to_integer(Lines.value!(cancel, "SEQUENCE")) >
               String.to_integer(Lines.value!(request, "SEQUENCE"))
    end

    test "a rescheduled meeting's request outranks the original, and its cancel outranks both" do
      original = render!(meeting(), :request)
      updated = render!(meeting(%{ical_sequence: 1}), :request)
      cancel = render!(meeting(%{ical_sequence: 1}), :cancel)

      seq = &String.to_integer(Lines.value!(&1, "SEQUENCE"))
      assert seq.(original) == 0
      assert seq.(updated) == 1
      assert seq.(cancel) == 2
    end

    test "METHOD sits at calendar level, outside the VEVENT" do
      names = Lines.names(render!(meeting(), :request))
      method = Enum.find_index(names, &(&1 == "METHOD"))
      vevent = index_of_vevent(names)
      assert method < vevent
    end
  end

  defp index_of_vevent(names) do
    names
    |> Enum.with_index()
    |> Enum.filter(fn {name, _} -> name == "BEGIN" end)
    |> Enum.at(1)
    |> elem(1)
  end

  describe "UID" do
    test "is CalendarFeed.uid/1 of the meeting, for request and cancel alike" do
      uid = CalendarFeed.uid(meeting())
      assert uid == "meeting-" <> @meeting_id

      assert Lines.value!(render!(meeting(), :request), "UID") == uid
      assert Lines.value!(render!(meeting(), :cancel), "UID") == uid
      assert Lines.value!(render!(meeting(%{ical_sequence: 4}), :request), "UID") == uid
    end

    test "does not depend on the recipient or their link" do
      other = %{
        @parties
        | attendee: {"Other", "other@example.com"},
          location: "https://x.example.com/g/zzz"
      }

      assert Lines.value!(render!(meeting(), :request, other), "UID") ==
               Lines.value!(render!(meeting(), :request), "UID")
    end
  end

  describe "ORGANIZER, ATTENDEE, LOCATION" do
    test "ORGANIZER is the sending account address passed in, with its display name" do
      line = Lines.fetch_one!(render!(meeting(), :request), "ORGANIZER")
      assert line.value == "mailto:meetings@example.com"
      assert line.params == %{"CN" => "Example Org"}

      other = %{@parties | organizer: {"Second Org", "calendar@example.org"}}

      assert Lines.value!(render!(meeting(), :request, other), "ORGANIZER") ==
               "mailto:calendar@example.org"
    end

    test "ATTENDEE is the invitee, asked to respond" do
      line = Lines.fetch_one!(render!(meeting(), :request), "ATTENDEE")
      assert line.value == "mailto:guest@example.com"

      assert line.params == %{
               "CN" => "Guest Person",
               "ROLE" => "REQ-PARTICIPANT",
               "PARTSTAT" => "NEEDS-ACTION",
               "RSVP" => "TRUE"
             }
    end

    test "a quote in a display name cannot break out of the CN parameter" do
      parties = %{@parties | attendee: {~s(Guest "Q" Person), "guest@example.com"}}
      line = Lines.fetch_one!(render!(meeting(), :request, parties), "ATTENDEE")
      assert line.params["CN"] == "Guest Q Person"
      assert line.value == "mailto:guest@example.com"
    end

    test "LOCATION is the join URL" do
      assert Lines.value!(render!(meeting(), :request), "LOCATION") ==
               "https://guest.example.com/g/abc123"
    end
  end

  describe "times and line mechanics" do
    test "DTSTART/DTEND are UTC Z form, DTSTAMP is updated_at" do
      body = render!(meeting(), :request)
      assert Lines.value!(body, "DTSTART") == "20261111T140000Z"
      assert Lines.value!(body, "DTEND") == "20261111T143000Z"
      assert Lines.value!(body, "DTSTAMP") == "20261105T093000Z"
    end

    test "every line is CRLF-terminated and folded at 75 octets" do
      long = String.duplicate("Quarterly planning ", 12)
      body = render!(meeting(%{name: long}), :request)

      # physical_lines/1 raises unless the document ends in CRLF.
      lines = Lines.physical_lines(body)
      assert Enum.all?(lines, &(byte_size(&1) <= 75))
      assert Enum.any?(lines, &String.starts_with?(&1, " ")), "a long SUMMARY must fold"
      refute body |> String.replace("\r\n", "") |> String.contains?("\n")
      refute String.contains?(body, "\r\r")
    end

    test "an unscheduled meeting has no document" do
      assert InviteIcs.render(
               meeting(%{scheduled_start_at: nil, scheduled_end_at: nil}),
               :request,
               @parties
             ) ==
               {:error, :unscheduled}

      assert InviteIcs.render(meeting(%{scheduled_end_at: nil}), :cancel, @parties) ==
               {:error, :unscheduled}
    end
  end

  describe "CalendarFeed SEQUENCE regression" do
    test "default ical_sequence still renders 0 live and 1 cancelled" do
      {:ok, live} = CalendarFeed.render(meeting())
      {:ok, cancelled} = CalendarFeed.render(meeting(%{status: "cancelled"}))

      assert Lines.value!(live, "SEQUENCE") == "0"
      assert Lines.value!(cancelled, "SEQUENCE") == "1"
    end

    test "the feed follows ical_sequence, so it and the emailed event advance together" do
      {:ok, live} = CalendarFeed.render(meeting(%{ical_sequence: 3}))
      {:ok, cancelled} = CalendarFeed.render(meeting(%{ical_sequence: 3, status: "cancelled"}))

      assert Lines.value!(live, "SEQUENCE") == "3"
      assert Lines.value!(cancelled, "SEQUENCE") == "4"
      assert Lines.value!(live, "UID") == Lines.value!(render!(meeting(), :request), "UID")
    end
  end
end
