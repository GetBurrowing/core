defmodule Platform.Meetings.InviteMailTest do
  @moduledoc """
  `Platform.Meetings.InviteMail.build/4` (task 01a1a933 stage 2): subjects,
  the zone-aware time block, the join link, the card's colours and
  escaping, and the calendar part each kind carries.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.InviteMail
  alias Platform.Meetings.Meeting
  alias PlatformTest.ICSContentLines, as: Lines

  # Wednesday 11 November 2026, 14:00-14:30 UTC. Denver is on MST (UTC-7).
  @start ~U[2026-11-11 14:00:00.000000Z]
  @finish ~U[2026-11-11 14:30:00.000000Z]

  @ctx %{
    organizer: {"Example Org", "meetings@example.com"},
    inviter: %{name: "Host One", time_zone: "America/Denver"},
    org_name: "Example Org",
    app_url: "https://app.example.com",
    guest_url: "https://guest.example.com"
  }

  @member %{name: "Member Two", email: "member@example.com", preferences: %{}}
  @guest %{name: "Guest Three", email: "guest@example.com", short_code: "abc123"}

  defp meeting(attrs \\ %{}) do
    struct!(
      %Meeting{
        id: "0198f1c0-0000-7000-8000-0000000000bb",
        slug: "roadmap",
        name: "Roadmap review",
        status: "scheduled",
        scheduled_start_at: @start,
        scheduled_end_at: @finish,
        updated_at: ~U[2026-11-05 09:00:00.000000Z]
      },
      attrs
    )
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1

  describe "subjects" do
    test "invitation names the title, short date and time in the resolved zone" do
      assert InviteMail.build(:invitation, meeting(), @member, @ctx).subject ==
               "Invitation: Roadmap review - Wed 11 Nov, 7:00 AM MST"
    end

    test "cancelled and updated name only the title" do
      assert InviteMail.build(:cancelled, meeting(), @member, @ctx).subject ==
               "Cancelled: Roadmap review"

      assert InviteMail.build(:updated, meeting(), @member, @ctx).subject ==
               "Updated: Roadmap review"
    end

    test "a newline in a meeting name cannot start a second header line" do
      subject =
        InviteMail.build(:invitation, meeting(%{name: "A\r\nBcc: x@example.com"}), @member, @ctx).subject

      refute subject =~ "\n"
      refute subject =~ "\r"
    end
  end

  describe "time zone" do
    test "the inviter's zone shifts the time and is named under it (14:00Z is 7:00 AM in Denver)" do
      built = InviteMail.build(:invitation, meeting(), @member, @ctx)

      assert built.body =~ "Wed 11 Nov - 7:00-7:30 AM\nAmerica/Denver, MST\n"
      assert built.html_body =~ "Wed 11 Nov - 7:00-7:30 AM"
      assert built.html_body =~ "America/Denver, MST"
      refute built.html_body =~ "your time zone"
    end

    test "the invitee's own zone wins and is marked as theirs" do
      member = %{@member | preferences: %{"time_zone" => "Europe/Berlin"}}
      built = InviteMail.build(:invitation, meeting(), member, @ctx)

      assert built.subject == "Invitation: Roadmap review - Wed 11 Nov, 3:00 PM CET"
      assert built.body =~ "Wed 11 Nov - 3:00-3:30 PM\nEurope/Berlin, CET (your time zone)\n"
    end

    test "an invalid invitee zone falls back to the inviter's" do
      member = %{@member | preferences: %{"time_zone" => "Mars/Olympus"}}
      assert InviteMail.resolve_zone(member, @ctx) == {"America/Denver", :inviter}
    end

    test "with no zone at all the time is UTC and says so" do
      ctx = %{@ctx | inviter: %{name: "Host One"}}
      built = InviteMail.build(:invitation, meeting(), @member, ctx)

      assert built.subject == "Invitation: Roadmap review - Wed 11 Nov, 2:00 PM UTC"
      assert built.body =~ "Wed 11 Nov - 2:00-2:30 PM\nUTC\n"
    end

    test "a range crossing noon names both meridiems" do
      m =
        meeting(%{
          scheduled_start_at: ~U[2026-11-11 18:30:00Z],
          scheduled_end_at: ~U[2026-11-11 19:30:00Z]
        })

      assert InviteMail.build(:invitation, m, @member, @ctx).body =~
               "Wed 11 Nov - 11:30 AM-12:30 PM"
    end
  end

  describe "join link" do
    test "a member gets the absolute /meetings/<slug> URL, as button and fallback line" do
      built = InviteMail.build(:invitation, meeting(), @member, @ctx)
      url = "https://app.example.com/meetings/roadmap"

      assert built.html_body =~ ~s(href="#{url}")
      assert built.html_body =~ "Join meeting"
      assert built.html_body =~ "or open: "
      assert built.body =~ "Join meeting: #{url}"
    end

    test "a guest gets their /g/<code> short link" do
      built = InviteMail.build(:invitation, meeting(), @guest, @ctx)
      url = "https://guest.example.com/g/abc123"

      assert built.html_body =~ ~s(href="#{url}")
      assert built.body =~ "Join meeting: #{url}"
      refute built.html_body =~ "/meetings/roadmap"
    end

    test "the host comes from ctx: no base, no button" do
      built = InviteMail.build(:invitation, meeting(), @member, Map.delete(@ctx, :app_url))
      refute built.html_body =~ "Join meeting"
      refute built.body =~ "Join meeting"
    end
  end

  describe "the card" do
    setup do
      %{built: InviteMail.build(:invitation, meeting(), @member, @ctx)}
    end

    test "the primary orange appears exactly once: the button", %{built: built} do
      assert count(String.downcase(built.html_body), "#ad4b07") == 1
      assert built.html_body =~ ~r/background-color:#ad4b07;border-radius:9px/
      assert built.html_body =~ "color:#fbfaf9"
    end

    test "uses the app.css light tokens and the Public Sans stack", %{built: built} do
      assert built.html_body =~ "border:1px solid #d9d3c9"
      assert built.html_body =~ "color:#635b53"
      assert built.html_body =~ "max-width:560px"
      assert built.html_body =~ "font-family:'Public Sans', system-ui"
    end

    test "no image, no emoji, no in-body response buttons", %{built: built} do
      refute built.html_body =~ "<img"
      refute built.html_body =~ ~r/Accept|Decline|Maybe/
      assert built.html_body |> String.to_charlist() |> Enum.all?(&(&1 < 128))
    end

    test "inviter and footer lines", %{built: built} do
      assert built.html_body =~ "Host One invited you"
      assert built.html_body =~ "Sent from Example Org on Burrow."
      assert built.html_body =~ "Reply to reach Host One."
    end

    test "the plain-text part carries title, time and zone, inviter and URL", %{built: built} do
      for fact <- [
            "Roadmap review",
            "Wed 11 Nov - 7:00-7:30 AM",
            "America/Denver, MST",
            "Host One invited you.",
            "https://app.example.com/meetings/roadmap",
            "Sent from Example Org on Burrow."
          ] do
        assert built.body =~ fact
      end

      refute built.body =~ "<"
    end

    test "every interpolated value is escaped" do
      built =
        InviteMail.build(
          :invitation,
          meeting(%{name: "<script>alert(1)</script>"}),
          @member,
          %{
            @ctx
            | inviter: %{name: "<b>Host</b>", time_zone: "America/Denver"},
              org_name: "A & B"
          }
        )

      refute built.html_body =~ "<script>"
      refute built.html_body =~ "<b>Host"
      assert built.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert built.html_body =~ "&lt;b&gt;Host&lt;/b&gt; invited you"
      assert built.html_body =~ "Sent from A &amp; B on Burrow."
    end
  end

  describe "kinds" do
    test "invitation and updated carry a REQUEST, cancelled a CANCEL, all with one UID" do
      uid = CalendarFeed.uid(meeting())

      for {kind, method} <- [invitation: "REQUEST", updated: "REQUEST", cancelled: "CANCEL"] do
        built = InviteMail.build(kind, meeting(), @guest, @ctx)
        assert built.calendar_method == method
        assert Lines.value!(built.calendar_ics, "METHOD") == method
        assert Lines.value!(built.calendar_ics, "UID") == uid
        assert Lines.value!(built.calendar_ics, "ORGANIZER") == "mailto:meetings@example.com"
        assert Lines.value!(built.calendar_ics, "ATTENDEE") == "mailto:guest@example.com"

        assert Lines.value!(built.calendar_ics, "LOCATION") ==
                 "https://guest.example.com/g/abc123"
      end
    end

    test "cancelled replaces the button with a line; updated says the time changed" do
      cancelled = InviteMail.build(:cancelled, meeting(), @member, @ctx)
      assert cancelled.html_body =~ "This meeting was cancelled."
      refute cancelled.html_body =~ "Join meeting"
      refute String.downcase(cancelled.html_body) =~ "#ad4b07"
      assert cancelled.body =~ "This meeting was cancelled."

      updated = InviteMail.build(:updated, meeting(%{ical_sequence: 1}), @member, @ctx)
      [before, _] = String.split(updated.html_body, "Wed 11 Nov - 7:00-7:30 AM", parts: 2)
      assert before =~ "Time changed"
      assert updated.body =~ "Time changed\nWed 11 Nov"
      assert Lines.value!(updated.calendar_ics, "SEQUENCE") == "1"

      original = InviteMail.build(:invitation, meeting(), @member, @ctx)
      assert Lines.value!(original.calendar_ics, "SEQUENCE") == "0"
      assert Lines.value!(cancelled.calendar_ics, "SEQUENCE") == "1"
    end

    test "an unscheduled meeting has no calendar part and is happening now" do
      built =
        InviteMail.build(
          :invitation,
          meeting(%{scheduled_start_at: nil, scheduled_end_at: nil}),
          @member,
          @ctx
        )

      assert built.calendar_method == nil
      assert built.calendar_ics == nil
      assert built.subject == "Invitation: Roadmap review"
      assert built.html_body =~ "Happening now"
      assert built.body =~ "Happening now"
    end
  end
end
