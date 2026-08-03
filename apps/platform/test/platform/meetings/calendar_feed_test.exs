defmodule Platform.Meetings.CalendarFeedTest do
  @moduledoc """
  Tests for `Platform.Meetings.CalendarFeed`.

  ## How these tests are written, and why

  `render/1` is guarded by several *independent* mechanisms at once —
  CRLF joining, 75-octet folding, TEXT escaping, microsecond truncation,
  UTC formatting, property ordering. A single "does the document parse"
  assertion is satisfied as long as *any one* of them holds, so it
  proves *none* of them. Every mechanism below is therefore exercised
  with the others held constant.

  Assertions go through a parser, never a regex over the payload:

    * `ICalendar.from_ics/1` (test-only dep) for the `VEVENT` — it
      unfolds and unescapes, so it sees what a calendar client sees.
    * `PlatformTest.ICSContentLines` for everything `from_ics/1` cannot
      see: calendar-level properties (`METHOD`, `PRODID`, `VERSION`,
      `CALSCALE`), `DTSTAMP`, the raw escaped wire form, property order,
      and physical line lengths.

  ## Two things `ICalendar.from_ics/1` does that these tests work around

    * `:status` is **downcased** by the library, so `event.status` is
      `"confirmed"` and cannot distinguish the RFC-legal `CONFIRMED`
      token from a lowercase one. The uppercase wire form is pinned
      separately through `ICSContentLines`.
    * `:sequence` is returned as a **string**, not an integer.

  Both are asserted at their real types below rather than papered over —
  an assertion against the type the library does not produce would have
  been a silent `nil == nil`.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformTest.ICSContentLines

  @meeting_id "0198f1c0-0000-7000-8000-000000000001"
  @scheduled_start ~U[2026-08-15 14:00:00.000000Z]
  @scheduled_end ~U[2026-08-15 15:00:00.000000Z]
  @updated_at ~U[2026-08-10 09:30:00.000000Z]

  @fold_limit 75

  defp meeting(attrs \\ %{}) do
    struct!(
      %Meeting{
        id: @meeting_id,
        name: "Kickoff",
        status: "scheduled",
        scheduled_start_at: @scheduled_start,
        scheduled_end_at: @scheduled_end,
        inserted_at: @updated_at,
        updated_at: @updated_at
      },
      attrs
    )
  end

  defp render!(attrs \\ %{}) do
    assert {:ok, body} = CalendarFeed.render(meeting(attrs))
    body
  end

  defp one_event!(body) do
    events = ICalendar.from_ics(body)
    assert length(events) == 1
    hd(events)
  end

  describe "render/1 — the VEVENT as a client sees it" do
    test "the document carries exactly one event" do
      body = render!()

      # `length(events) == 1`, not `hd(events)`: a renderer that emitted
      # the VEVENT twice would put two entries on a calendar, and
      # `hd/1` cannot see the second one.
      assert length(ICalendar.from_ics(body)) == 1
    end

    test "dtstart and dtend round-trip to the seeded instants" do
      event = one_event!(render!())

      assert DateTime.compare(event.dtstart, @scheduled_start) == :eq
      assert DateTime.compare(event.dtend, @scheduled_end) == :eq
    end

    test "the summary round-trips through escaping and unescaping" do
      name = "Q3 planning; budget, scope"

      event = one_event!(render!(%{name: name}))

      # Equality, not `=~`: the wrong value can contain the right one.
      assert event.summary == name

      # MEASURED LIMIT of this assertion: deleting `escape/1` from the
      # renderer leaves this test GREEN. `desanitized/1` strips
      # backslashes unconditionally, and the library takes the value as
      # everything after the first colon, so an unescaped `;` or `,` in
      # a SUMMARY round-trips just as cleanly as an escaped one. The
      # raw-wire assertions under "TEXT escaping" are the only
      # detectors; this one proves the unescaping side, not the
      # escaping side.
    end

    test "STATUS and SEQUENCE are readable on the uncancelled path" do
      event = one_event!(render!())

      # The library downcases STATUS and keeps SEQUENCE as a string.
      # Asserting `"CONFIRMED"` or `0` here would fail; asserting the
      # wire form is the job of the content-line test below.
      assert event.status == "confirmed"
      assert event.sequence == "0"
    end
  end

  describe "render/1 — UID" do
    test "the UID is the meeting id with a `meeting-` prefix, and reaches the parser intact" do
      body = render!()

      assert CalendarFeed.uid(meeting()) == "meeting-" <> @meeting_id
      assert one_event!(body).uid == "meeting-" <> @meeting_id
      assert ICSContentLines.value!(body, "UID") == "meeting-" <> @meeting_id
    end

    test "the UID is a function of the meeting id ALONE" do
      # ONE MEETING, ONE UID. Two invitees fetching two different links
      # for the same meeting must land on the same calendar entry, so
      # nothing request-scoped, invite-scoped or mutable may feed the
      # UID. Vary every other field and hold the id constant.
      base = meeting()

      variant =
        meeting(%{
          name: "Renamed",
          slug: "some-other-slug",
          livekit_room_name: "meeting-something-else",
          scheduled_start_at: ~U[2027-01-01 08:00:00.000000Z],
          scheduled_end_at: ~U[2027-01-01 09:00:00.000000Z],
          updated_at: ~U[2027-01-01 07:00:00.000000Z]
        })

      assert CalendarFeed.uid(variant) == CalendarFeed.uid(base)

      other_meeting = meeting(%{id: "0198f1c0-0000-7000-8000-000000000002"})
      refute CalendarFeed.uid(other_meeting) == CalendarFeed.uid(base)
    end
  end

  describe "render/1 — DATE-TIME formatting" do
    test "microseconds are truncated, not rendered and not rounded" do
      body =
        render!(%{
          scheduled_start_at: ~U[2026-08-15 14:00:00.123456Z],
          scheduled_end_at: ~U[2026-08-15 15:00:00.999999Z]
        })

      # Exact equality on the content-line VALUE. Fractional seconds are
      # illegal in an iCalendar DATE-TIME and `:utc_datetime_usec`
      # carries them, so `20260815T140000.123456Z` is the failure this
      # pins. `.999999` also pins truncation rather than rounding — a
      # rounding implementation would emit `150001Z`.
      assert ICSContentLines.value!(body, "DTSTART") == "20260815T140000Z"
      assert ICSContentLines.value!(body, "DTEND") == "20260815T150000Z"
    end

    test "times are UTC form-2 with a Z suffix and carry no TZID parameter" do
      body = render!()

      for name <- ~w(DTSTAMP DTSTART DTEND) do
        line = ICSContentLines.fetch_one!(body, name)

        # A TZID parameter is only legal alongside a VTIMEZONE component,
        # which this document does not (and should not) carry.
        assert line.params == %{}
        assert String.ends_with?(line.value, "Z")
        assert byte_size(line.value) == byte_size("20260815T140000Z")
      end
    end
  end

  describe "render/1 — DTSTAMP is a function of the row" do
    test "DTSTAMP is the row's updated_at, not the wall clock" do
      body = render!()

      # Deterministic detector for a `DateTime.utc_now/0` DTSTAMP: the
      # seeded `updated_at` is a fixed date in the past, so a clock-read
      # implementation produces today's date and this equality fails
      # with a diff. The idempotence test below is NOT a reliable
      # detector of that mutation — two renders inside the same wall
      # second agree.
      assert ICSContentLines.value!(body, "DTSTAMP") == "20260810T093000Z"
    end

    test "a changed updated_at advances the stamp" do
      before = render!()
      later = render!(%{updated_at: ~U[2026-08-11 09:30:00.000000Z]})

      assert ICSContentLines.value!(before, "DTSTAMP") == "20260810T093000Z"
      assert ICSContentLines.value!(later, "DTSTAMP") == "20260811T093000Z"
    end

    test "rendering the same struct twice is byte-identical" do
      # MEASURED LIMIT: this test does NOT detect a `DateTime.utc_now/0`
      # DTSTAMP. Swapping `meeting.updated_at` for the clock leaves it
      # green, because both renders land in the same wall second and the
      # stamp has second resolution. It pins idempotence and nothing
      # more — the deterministic detectors are the DTSTAMP equality test
      # above and the import-table test below, both of which did go red
      # under that mutation.
      subject = meeting()

      assert {:ok, first} = CalendarFeed.render(subject)
      assert {:ok, second} = CalendarFeed.render(subject)
      assert first == second
    end

    test "the module makes no call to Repo or to DateTime.utc_now/0" do
      # Static, from the compiled BEAM's import table — the structural
      # form of the purity claim. A behavioural test can only observe
      # impurity when it happens to change the output; this observes the
      # call itself.
      {:ok, {CalendarFeed, [imports: imports]}} =
        :beam_lib.chunks(:code.which(CalendarFeed), [:imports])

      refute {DateTime, :utc_now, 0} in imports
      refute {DateTime, :utc_now, 1} in imports
      assert Enum.filter(imports, fn {module, _fun, _arity} -> module == Repo end) == []

      assert Enum.filter(imports, fn {module, _fun, _arity} ->
               module |> Atom.to_string() |> String.contains?("Repo")
             end) == []
    end
  end

  describe "render/1 — TEXT escaping (RFC 5545 §3.3.11)" do
    test "semicolon and comma are escaped on the wire" do
      body = render!(%{name: "Q3 planning; budget, scope"})

      assert ICSContentLines.value!(body, "SUMMARY") == ~S(Q3 planning\; budget\, scope)
    end

    test "a backslash is escaped BEFORE the other characters" do
      # `ICalendar.from_ics/1` cannot check this: its `desanitized/1`
      # strips every backslash unconditionally, so it maps both the
      # correct and the double-escaped form onto the same string. The
      # raw wire value is the only place the ordering is visible.
      #
      # Input:    a \ ; b
      # Correct:  a \ \ \ ; b   (backslash doubled, then semicolon escaped)
      # Wrong order would escape the backslash this function itself
      # introduced.
      body = render!(%{name: ~S(a\;b)})

      assert ICSContentLines.value!(body, "SUMMARY") == ~S(a\\\;b)
    end

    test "newlines in a name become the literal \\n escape" do
      body = render!(%{name: "line one\nline two"})

      assert ICSContentLines.value!(body, "SUMMARY") == ~S(line one\nline two)

      # And the escape must not have introduced a real line break: the
      # SUMMARY stays one content line.
      assert Enum.count(ICSContentLines.names(body), &(&1 == "SUMMARY")) == 1
    end
  end

  describe "render/1 — folding (RFC 5545 §3.1)" do
    # 66 ASCII octets puts the 75-octet boundary of the `SUMMARY:` line
    # (8 octets of property name and colon) squarely inside the first
    # two-octet character, which is the case a naive `binary_part/3`
    # fold corrupts.
    @long_name String.duplicate("a", 66) <> String.duplicate("é", 40) <> " tail"

    test "a long multi-byte name round-trips through the parser intact" do
      event = one_event!(render!(%{name: @long_name}))

      assert event.summary == @long_name
    end

    test "no physical line exceeds 75 octets" do
      body = render!(%{name: @long_name})
      lines = ICSContentLines.physical_lines(body)

      over_limit = Enum.filter(lines, &(byte_size(&1) > @fold_limit))

      assert over_limit == []

      # Anti-vacuity: the assertion above is satisfied by a document
      # that was never long enough to need folding. This name is, so
      # the SUMMARY must actually have been split.
      assert Enum.count(lines, &String.starts_with?(&1, " ")) >= 2
    end

    test "no fold lands inside a multi-byte sequence" do
      body = render!(%{name: @long_name})

      # Folding counts octets, but must not split a codepoint: a client
      # unfolds by deleting CRLF plus one space, so a mid-sequence split
      # yields bytes that are no longer valid UTF-8 once rejoined.
      invalid = Enum.reject(ICSContentLines.physical_lines(body), &String.valid?/1)

      assert invalid == []
    end

    test "a continuation line spends one of its 75 octets on the leading space" do
      body = render!(%{name: String.duplicate("z", 300)})

      [_first | continuations] =
        body
        |> ICSContentLines.physical_lines()
        |> Enum.filter(&(String.starts_with?(&1, "SUMMARY:") or String.starts_with?(&1, " ")))

      assert continuations != []

      for line <- continuations do
        assert String.starts_with?(line, " ")
        assert byte_size(line) <= @fold_limit
      end
    end
  end

  describe "render/1 — line endings" do
    test "every line break is CRLF and the document ends with one" do
      # Asserted at the BYTE level on purpose. `ICalendar.from_ics/1`
      # splits on "\n" and trims a trailing "\r", so it parses an
      # LF-joined document perfectly happily — no parser-based assertion
      # in this file can see the difference. Calendar clients are less
      # forgiving than that library.
      body = render!(%{name: @long_name})

      lf_count = length(:binary.matches(body, "\n"))
      crlf_count = length(:binary.matches(body, "\r\n"))

      assert lf_count > 0
      assert lf_count == crlf_count
      refute Regex.match?(~r/(?<!\r)\n/, body)
      assert String.ends_with?(body, "\r\n")
    end
  end

  describe "render/1 — calendar-level properties and property order" do
    test "properties are emitted in the RFC order, with METHOD outside the VEVENT" do
      body = render!()
      lines = ICSContentLines.parse(body)

      assert Enum.map(lines, & &1.name) == ~w(
               BEGIN VERSION PRODID CALSCALE METHOD
               BEGIN UID DTSTAMP DTSTART DTEND SUMMARY STATUS SEQUENCE TRANSP END
               END
             )

      pairs = Enum.map(lines, &{&1.name, &1.value})

      assert Enum.at(pairs, 0) == {"BEGIN", "VCALENDAR"}
      assert {"VERSION", "2.0"} in pairs
      assert {"PRODID", "-//Startup Suite//Meetings//EN"} in pairs
      assert {"CALSCALE", "GREGORIAN"} in pairs
      assert {"TRANSP", "OPAQUE"} in pairs

      # METHOD:PUBLISH, not REQUEST — RFC 5546 §3.2.1 PUBLISH needs no
      # ATTENDEE list, and emitting one would disclose every invitee to
      # a bearer of the URL. `ICalendar.from_ics/1` drops calendar-level
      # properties entirely, so this is only checkable through the
      # content-line grammar. Position matters as much as presence: a
      # METHOD inside the VEVENT is illegal, and `body =~ "METHOD:PUBLISH"`
      # cannot tell the two apart.
      assert Enum.find_index(pairs, &(&1 == {"METHOD", "PUBLISH"})) <
               Enum.find_index(pairs, &(&1 == {"BEGIN", "VEVENT"}))
    end

    test "STATUS and SEQUENCE carry their RFC-cased wire values" do
      body = render!()

      assert ICSContentLines.value!(body, "STATUS") == "CONFIRMED"
      assert ICSContentLines.value!(body, "SEQUENCE") == "0"
    end

    test "the disclosing and unusable properties are absent" do
      # ORGANIZER/ATTENDEE would leak the invitee list to anyone holding
      # the bearer URL; URL would turn a forwarded calendar entry into
      # room admission. The meeting name is chosen to contain all five
      # tokens, so this cannot pass by the document simply not
      # mentioning them — it passes because none of them is a PROPERTY.
      body =
        render!(%{name: "ORGANIZER and ATTENDEE sync; URL, DESCRIPTION and LOCATION TBD"})

      names = ICSContentLines.names(body)

      for forbidden <- ~w(ORGANIZER ATTENDEE URL DESCRIPTION LOCATION) do
        refute forbidden in names
      end

      event = one_event!(body)
      assert event.organizer == nil
      assert event.attendees == []
      assert event.url == nil
      assert event.description == nil
      assert event.location == nil
    end
  end

  describe "render/1 — unscheduled meetings" do
    test "both intended-time columns nil returns {:error, :unscheduled}" do
      # The ad-hoc "start a meeting now" row. No intended time means no
      # event: synthesising one from `started_at` would put a wrong
      # entry on someone's calendar, and this is not the cancellation
      # case — nothing was ever published, so there is nothing to ghost.
      subject =
        meeting(%{
          scheduled_start_at: nil,
          scheduled_end_at: nil,
          started_at: ~U[2026-08-15 14:03:00.000000Z]
        })

      assert CalendarFeed.render(subject) == {:error, :unscheduled}
    end

    test "a start with no end returns {:error, :unscheduled}, on a row the DB really accepts" do
      project = create_project()
      {:ok, seed} = Meetings.create_meeting(%{project_id: project.id, name: "Seed"})

      id = Platform.Types.UUIDv7.generate()
      stamp = DateTime.utc_now()

      # `Meeting.changeset/2` rejects this pair, but that is
      # changeset-level only — there is no DB check constraint, so
      # direct SQL can still produce the row. `insert_all/2` bypasses
      # the changeset and demonstrates exactly that, which is why the
      # renderer needs an explicit clause instead of trusting the
      # changeset.
      assert {1, nil} =
               Repo.insert_all(Meeting, [
                 %{
                   id: id,
                   project_id: project.id,
                   chat_space_id: seed.chat_space_id,
                   slug: "half-scheduled",
                   name: "Half scheduled",
                   status: "scheduled",
                   livekit_room_name: "meeting-#{id}",
                   scheduled_start_at: @scheduled_start,
                   scheduled_end_at: nil,
                   inserted_at: stamp,
                   updated_at: stamp
                 }
               ])

      subject = Repo.get!(Meeting, id)

      assert subject.scheduled_start_at != nil
      assert subject.scheduled_end_at == nil
      assert CalendarFeed.render(subject) == {:error, :unscheduled}
    end

    test "an end with no start returns {:error, :unscheduled}" do
      subject = meeting(%{scheduled_start_at: nil})

      assert CalendarFeed.render(subject) == {:error, :unscheduled}
    end
  end

  describe "render/1 — a meeting created through the context" do
    test "renders from a persisted row without any further loading" do
      project = create_project()

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Roadmap review",
          scheduled_start_at: @scheduled_start,
          scheduled_end_at: @scheduled_end
        })

      assert {:ok, body} = CalendarFeed.render(meeting)

      event = one_event!(body)
      assert event.uid == "meeting-" <> meeting.id
      assert event.summary == "Roadmap review"
      assert DateTime.compare(event.dtstart, @scheduled_start) == :eq

      # The persisted `updated_at` carries microseconds; the wire form
      # must not.
      assert ICSContentLines.value!(body, "DTSTAMP") ==
               meeting.updated_at
               |> DateTime.truncate(:second)
               |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    end
  end

  defp create_project(attrs \\ %{}) do
    default = %{name: "Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end
end
