defmodule Platform.Meetings.InviteMailTest do
  @moduledoc """
  `Platform.Meetings.InviteMail.build/4` (task 01a1a933 stage 2): subjects,
  the zone-aware time block, the join link, the card's colours and
  escaping, and the calendar part each kind carries.
  """
  use ExUnit.Case, async: true

  alias Platform.Branding.InstallBranding
  alias Platform.Branding.Palette
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
    guest_url: "https://guest.example.com",
    calendar_url: "https://app.example.com/meetings/abc/invite.ics?token=t"
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

  describe "the action and the join link" do
    test "the button is Add to calendar; the member's join link is plain text beneath it" do
      built = InviteMail.build(:invitation, meeting(), @member, @ctx)
      url = "https://app.example.com/meetings/roadmap"
      calendar = @ctx.calendar_url

      assert built.html_body =~
               ~r/background-color:#[0-9a-f]{6};border-radius:9px;">\s*<a class="im-button-text" href="#{Regex.escape(calendar)}"[^>]*>Add to calendar<\/a>/

      assert built.html_body =~ ~s(Join the meeting: <a class="im-link" href="#{url}")
      refute built.html_body =~ "Join meeting<"
      assert built.body =~ "Add to calendar: #{calendar}\nJoin the meeting: #{url}"
      refute built.html_body =~ "Join code"
    end

    test "a guest gets their /g/<code> short link and its join code" do
      built = InviteMail.build(:invitation, meeting(), @guest, @ctx)
      url = "https://guest.example.com/g/abc123"

      assert built.html_body =~ ~s(href="#{url}")
      assert built.html_body =~ "Join code: abc123"
      assert built.body =~ "Join the meeting: #{url}\nJoin code: abc123"
      refute built.html_body =~ "/meetings/roadmap"
    end

    test "no calendar link, no button; no base, no join line" do
      built = InviteMail.build(:invitation, meeting(), @member, Map.delete(@ctx, :calendar_url))
      refute built.html_body =~ "Add to calendar"
      refute built.html_body =~ "im-button"
      assert built.html_body =~ "Join the meeting"

      built = InviteMail.build(:invitation, meeting(), @member, Map.delete(@ctx, :app_url))
      refute built.html_body =~ "Join the meeting"
      refute built.body =~ "Join the meeting"
    end
  end

  describe "attendees and reason" do
    test "attendees read as a short list, capped at five" do
      two =
        InviteMail.build(
          :invitation,
          meeting(),
          @member,
          Map.put(@ctx, :attendees, ["Ann", "Bo"])
        )

      assert two.html_body =~ "With Ann and Bo"
      assert two.body =~ "With Ann and Bo"

      one = InviteMail.build(:invitation, meeting(), @member, Map.put(@ctx, :attendees, ["Ann"]))
      assert one.body =~ "With Ann\n"

      seven = Enum.map(1..7, &"Person #{&1}")
      many = InviteMail.build(:invitation, meeting(), @member, Map.put(@ctx, :attendees, seven))

      assert many.body =~
               "With Person 1, Person 2, Person 3, Person 4, Person 5 and 2 others"
    end

    test "a reason renders when given, and nothing does when it is not" do
      with_reason =
        InviteMail.build(
          :invitation,
          meeting(),
          @member,
          Map.put(@ctx, :reason, "Quarterly plan")
        )

      assert with_reason.html_body =~ "Quarterly plan"
      assert with_reason.body =~ "Quarterly plan"

      plain = InviteMail.build(:invitation, meeting(), @member, @ctx)
      refute plain.html_body =~ "With "
      refute plain.body =~ "With "
      refute plain.html_body =~ ~s(margin:6px 0 0 0)
    end
  end

  describe "the card" do
    setup do
      %{built: InviteMail.build(:invitation, meeting(), @member, @ctx)}
    end

    test "with no brand passed, the shipped palette's primary appears exactly once: the button",
         %{built: built} do
      light = Palette.derive(:light, Palette.suite_defaults().light)
      primary = light["--color-primary"]

      assert count(String.downcase(built.html_body), primary) == 1
      assert built.html_body =~ "background-color:#{primary};border-radius:9px"
      assert built.html_body =~ "color:#{light["--color-primary-content"]}"
    end

    test "uses the palette's edge, the Public Sans stack and a 560px card", %{built: built} do
      light = Palette.derive(:light, Palette.suite_defaults().light)
      assert built.html_body =~ "border:1px solid #{light["--edge"]}"
      assert built.html_body =~ "max-width:560px"
      assert built.html_body =~ "font-family:'Public Sans', system-ui"
    end

    test "declares a dark scheme and a prefers-color-scheme: dark block", %{built: built} do
      dark = Palette.derive(:dark, Palette.suite_defaults().dark)
      assert built.html_body =~ ~s(<meta name="color-scheme" content="light dark">)
      [_, style] = String.split(built.html_body, "@media (prefers-color-scheme: dark)", parts: 2)
      assert style =~ "background-color: #{dark["--color-base-100"]} !important"
      assert style =~ "background-color: #{dark["--color-primary"]} !important"
    end

    test "no image without a brand icon, no emoji, no in-body response buttons", %{built: built} do
      refute built.html_body =~ "<img"
      refute built.html_body =~ ~r/Accept|Decline|Maybe/
      assert built.html_body |> String.to_charlist() |> Enum.all?(&(&1 < 128))
    end

    test "inviter and footer lines", %{built: built} do
      assert built.html_body =~ "Host One invited you"
      assert built.html_body =~ "Sent from Example Org."
      assert built.html_body =~ "Reply to reach Host One."
    end

    test "the plain-text part carries title, time and zone, inviter and URL", %{built: built} do
      for fact <- [
            "Roadmap review",
            "Wed 11 Nov - 7:00-7:30 AM",
            "America/Denver, MST",
            "Host One invited you.",
            "https://app.example.com/meetings/roadmap",
            "Sent from Example Org."
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
      assert built.html_body =~ "Sent from A &amp; B."
    end
  end

  describe "install branding" do
    # A second install, nothing like the shipped one: its own name, an
    # uploaded icon (so a versioned path) and its own colours.
    @other_install %InstallBranding{
      app_name: "Northwind Labs",
      source_storage_key: "branding/0123456789ab/source.png",
      version: "0123456789ab",
      light_action: "#1d4ed8",
      light_surface: "#f8fafc",
      dark_action: "#60a5fa",
      dark_surface: "#0f172a"
    }

    # The shipped palette's own action and surface hexes, light and dark.
    @shipped ~w(#ad4b07 #fbfaf9 #f47721 #191b20)

    setup do
      brand = InviteMail.brand(@other_install, "https://app.example.com")
      ctx = Map.put(@ctx, :brand, brand)
      %{built: InviteMail.build(:invitation, meeting(), @guest, ctx), brand: brand}
    end

    test "the header carries the install's name and its icon from the install host",
         %{built: built} do
      assert built.html_body =~ "Northwind Labs"

      assert [[src]] =
               Regex.scan(~r/<img src="([^"]+)"/, built.html_body, capture: :all_but_first)

      assert src == "https://app.example.com/branding/0123456789ab/icon_192"
    end

    test "the install's palette paints the card, light inline and dark in the block",
         %{built: built} do
      light = Palette.derive(:light, %{action: "#1d4ed8", surface: "#f8fafc", accent: nil})
      dark = Palette.derive(:dark, %{action: "#60a5fa", surface: "#0f172a", accent: nil})

      [inline, style] =
        String.split(built.html_body, "@media (prefers-color-scheme: dark)", parts: 2)

      assert built.html_body =~ "background-color:#1d4ed8;border-radius:9px"
      assert built.html_body =~ "background-color:#f8fafc"
      assert built.html_body =~ "border:1px solid #{light["--edge"]}"
      assert inline =~ "<title>"
      assert style =~ "background-color: #0f172a !important"
      assert style =~ "background-color: #60a5fa !important"
      assert style =~ "border-color: #{dark["--edge"]} !important"
    end

    test "none of the shipped palette's hexes appear", %{built: built} do
      html = String.downcase(built.html_body)

      for hex <- @shipped do
        refute html =~ hex, "shipped colour #{hex} leaked into another install's email"
      end
    end

    test "the footer names this install, and nothing says Burrow", %{built: built} do
      assert built.html_body =~ "Sent from Example Org on Northwind Labs."
      assert built.body =~ "Sent from Example Org on Northwind Labs."
      refute built.html_body =~ "Burrow"
      refute built.body =~ "Burrow"
    end

    test "brand/2 reads the row's name, icon and both palettes", %{brand: brand} do
      assert brand.app_name == "Northwind Labs"
      assert brand.light.primary == "#1d4ed8"
      assert brand.light.base_100 == "#f8fafc"
      assert brand.dark.primary == "#60a5fa"
      assert brand.dark.base_100 == "#0f172a"
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
      refute cancelled.html_body =~ "Add to calendar"
      refute cancelled.html_body =~ "Join the meeting"
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
