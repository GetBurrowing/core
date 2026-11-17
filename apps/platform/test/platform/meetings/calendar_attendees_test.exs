defmodule Platform.Meetings.CalendarAttendeesTest do
  @moduledoc """
  Attendees with their RSVP in the iCalendar a calendar client reads:
  ORGANIZER plus one ATTENDEE per invitee with PARTSTAT, in the per-user
  subscription feed and the emailed invite, and an RSVP advancing
  SEQUENCE / DTSTAMP / LAST-MODIFIED so a client refreshes.

  Assertions go through `PlatformTest.ICSContentLines` (see
  `Platform.Meetings.CalendarFeedTest` for why not substrings).
  """
  use Platform.DataCase, async: true

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteIcs
  alias Platform.Meetings.Meeting
  alias PlatformTest.ICSContentLines, as: Lines

  @start ~U[2026-11-20 15:00:00.000000Z]
  @finish ~U[2026-11-20 16:00:00.000000Z]
  @long_ago ~U[2026-11-01 09:00:00.000000Z]

  defp struct_meeting(attrs \\ %{}) do
    struct!(
      %Meeting{
        id: "0198f1c0-0000-7000-8000-0000000000bb",
        slug: "planning",
        name: "Planning",
        status: "scheduled",
        scheduled_start_at: @start,
        scheduled_end_at: @finish,
        inserted_at: @long_ago,
        updated_at: @long_ago
      },
      attrs
    )
  end

  defp attendees(body), do: body |> Lines.parse() |> Enum.filter(&(&1.name == "ATTENDEE"))

  describe "CalendarFeed.render/2 with parties" do
    setup do
      parties = %{
        organizer: {"Olive Organizer", "olive@example.com"},
        updated_at: @long_ago,
        attendees: [
          %{name: "Ann Invited", address: "ann@example.com", partstat: "NEEDS-ACTION"},
          %{name: "Bob Yes", address: "bob@example.com", partstat: "ACCEPTED"},
          %{name: "Cy Maybe", address: "cy@example.com", partstat: "TENTATIVE"},
          %{name: "Di No", address: "di@example.com", partstat: "DECLINED"}
        ]
      }

      {:ok, parties: parties}
    end

    test "carries ORGANIZER and one ATTENDEE per invitee with PARTSTAT", %{parties: parties} do
      {:ok, body} = CalendarFeed.render(struct_meeting(), parties: parties)

      organizer = Lines.fetch_one!(body, "ORGANIZER")
      assert organizer.value == "mailto:olive@example.com"
      assert organizer.params == %{"CN" => "Olive Organizer"}

      assert [
               {"mailto:ann@example.com", "NEEDS-ACTION", "Ann Invited"},
               {"mailto:bob@example.com", "ACCEPTED", "Bob Yes"},
               {"mailto:cy@example.com", "TENTATIVE", "Cy Maybe"},
               {"mailto:di@example.com", "DECLINED", "Di No"}
             ] ==
               Enum.map(attendees(body), &{&1.value, &1.params["PARTSTAT"], &1.params["CN"]})

      for line <- attendees(body) do
        assert line.params["ROLE"] == "REQ-PARTICIPANT"
        assert line.params["RSVP"] == "TRUE"
      end

      assert Lines.value!(body, "LAST-MODIFIED") == "20261101T090000Z"
      # Still a valid VEVENT: properties sit between BEGIN and END.
      names = Lines.names(body)

      assert Enum.find_index(names, &(&1 == "ATTENDEE")) >
               Enum.find_index(names, &(&1 == "BEGIN"))
    end

    test "render/1 (the bearer invite.ics) still carries no invitee list" do
      {:ok, body} = CalendarFeed.render(struct_meeting())

      for forbidden <- ~w(ORGANIZER ATTENDEE) do
        refute forbidden in Lines.names(body)
      end
    end

    test "names with quotes, commas, semicolons and colons stay inside the CN", %{
      parties: parties
    } do
      tricky = %{
        name: ~s(O"Brien, Pat; Ops: Lead),
        address: "pat@example.com",
        partstat: "ACCEPTED"
      }

      {:ok, body} =
        CalendarFeed.render(struct_meeting(), parties: %{parties | attendees: [tricky]})

      [line] = attendees(body)
      assert line.params["CN"] == "OBrien, Pat; Ops: Lead"
      assert line.params["PARTSTAT"] == "ACCEPTED"
      assert line.value == "mailto:pat@example.com"
    end

    test "long attendee lines fold at 75 octets without splitting a character", %{
      parties: parties
    } do
      long = %{
        name: String.duplicate("Zoë Ångström-Ñúñez ", 6),
        address: "a-very-long-mailbox-name-for-folding@subdomain.example.com",
        partstat: "DECLINED"
      }

      {:ok, body} =
        CalendarFeed.render(struct_meeting(), parties: %{parties | attendees: [long]})

      for physical <- Lines.physical_lines(body) do
        assert byte_size(physical) <= 75
        assert String.valid?(physical)
      end

      [line] = attendees(body)
      assert line.params["CN"] == String.trim(long.name)
      assert line.value == "mailto:" <> long.address
    end

    test "an addressless guest is listed by CN with a urn:uuid", %{parties: parties} do
      guest = %{name: "Walk-in", address: "urn:uuid:0198f1c0-0000-7000-8000-0000000000cc"}

      {:ok, body} =
        CalendarFeed.render(struct_meeting(),
          parties: %{parties | attendees: [Map.put(guest, :partstat, "NEEDS-ACTION")]}
        )

      [line] = attendees(body)
      assert line.value == "urn:uuid:0198f1c0-0000-7000-8000-0000000000cc"
      assert line.params["CN"] == "Walk-in"
    end
  end

  describe "Invite.rsvp_partstat/1" do
    test "maps invited/accepted/tentative/declined" do
      assert Invite.rsvp_partstat("invited") == "NEEDS-ACTION"
      assert Invite.rsvp_partstat("accepted") == "ACCEPTED"
      assert Invite.rsvp_partstat("tentative") == "TENTATIVE"
      assert Invite.rsvp_partstat("declined") == "DECLINED"
      assert Invite.rsvp_partstat(nil) == "NEEDS-ACTION"
    end
  end

  describe "InviteIcs with the invitee list" do
    @parties %{
      organizer: {"Example Org", "meetings@example.com"},
      attendee: {"Guest Person", "guest@example.com"},
      location: nil
    }

    test "lists every invitee with their status, the recipient among them" do
      list = [
        %{name: "Bob Yes", address: "bob@example.com", partstat: "ACCEPTED"},
        %{name: "Guest Person", address: "Guest@Example.com", partstat: "NEEDS-ACTION"}
      ]

      {:ok, body} =
        InviteIcs.render(struct_meeting(), :request, Map.put(@parties, :attendees, list))

      assert [
               {"mailto:bob@example.com", "ACCEPTED"},
               {"mailto:Guest@Example.com", "NEEDS-ACTION"}
             ] ==
               Enum.map(attendees(body), &{&1.value, &1.params["PARTSTAT"]})
    end

    test "adds the recipient when the list predates their invite" do
      list = [%{name: "Di No", address: "di@example.com", partstat: "DECLINED"}]

      {:ok, body} =
        InviteIcs.render(struct_meeting(), :request, Map.put(@parties, :attendees, list))

      assert ["mailto:guest@example.com", "mailto:di@example.com"] ==
               Enum.map(attendees(body), & &1.value)
    end
  end

  describe "respond_to_invite/3 and the per-user feed" do
    setup do
      org_id = Platform.TenancyFixtures.acme_org_id()
      n = System.unique_integer([:positive])

      member = user!("member-#{n}", "Mia Member")
      creator = user!("creator-#{n}", "Cora Creator")

      for u <- [member, creator] do
        Repo.insert!(%Platform.Tenancy.OrgMembership{
          user_id: u.id,
          org_id: org_id,
          role: "member"
        })
      end

      project =
        Repo.insert!(%Platform.Tasks.Project{
          name: "RSVP #{n}",
          slug: "rsvp-#{n}",
          org_id: org_id
        })

      {:ok, space} =
        Platform.Chat.create_space(%{name: "rsvp-#{n}", slug: "rsvp-space-#{n}", kind: "channel"})

      id = Platform.Types.UUIDv7.generate()

      meeting =
        %Meeting{id: id}
        |> Meeting.changeset(%{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "rsvp-#{n}",
          name: "Quarterly, planning; Q4",
          livekit_room_name: "meeting-#{id}",
          status: "scheduled",
          scheduled_start_at: @start,
          scheduled_end_at: @finish,
          created_by_user_id: creator.id
        })
        |> Repo.insert!()

      member_invite = invite!(%{meeting_id: meeting.id, user_id: member.id})

      guest_invite =
        invite!(%{meeting_id: meeting.id, display_name: "Gail Guest", email: "gail@example.com"})

      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
        set: [updated_at: @long_ago]
      )

      {:ok,
       meeting: Repo.get!(Meeting, meeting.id),
       member: member,
       creator: creator,
       member_invite: member_invite,
       guest_invite: guest_invite}
    end

    test "the feed names organizer and invitees, and an answer updates PARTSTAT and bumps SEQUENCE",
         %{meeting: meeting, member: member, creator: creator} do
      before = feed_event(member, meeting)

      assert Lines.value!(before, "ORGANIZER") == "mailto:" <> creator.email

      assert [
               {"mailto:" <> member.email, "NEEDS-ACTION", "Mia Member"},
               {"mailto:gail@example.com", "NEEDS-ACTION", "Gail Guest"}
             ] == Enum.map(attendees(before), &{&1.value, &1.params["PARTSTAT"], &1.params["CN"]})

      assert Lines.value!(before, "SEQUENCE") == "0"
      assert Lines.value!(before, "DTSTAMP") == "20261101T090000Z"
      assert Lines.value!(before, "SUMMARY") == "Quarterly\\, planning\\; Q4"

      assert {:ok, "accepted"} = Meetings.respond_to_invite(meeting, member, "accepted")

      after_accept = feed_event(member, meeting)
      [mine, _gail] = attendees(after_accept)
      assert mine.params["PARTSTAT"] == "ACCEPTED"
      assert Lines.value!(after_accept, "SEQUENCE") == "1"
      refute Lines.value!(after_accept, "DTSTAMP") == "20261101T090000Z"

      assert Lines.value!(after_accept, "LAST-MODIFIED") ==
               Lines.value!(after_accept, "DTSTAMP")

      assert {:ok, "declined"} = Meetings.respond_to_invite(meeting, member, "declined")
      after_decline = feed_event(member, meeting)
      assert hd(attendees(after_decline)).params["PARTSTAT"] == "DECLINED"
      assert Lines.value!(after_decline, "SEQUENCE") == "2"
    end

    test "the same answer twice writes nothing", %{meeting: meeting, member: member} do
      assert {:ok, "tentative"} = Meetings.respond_to_invite(meeting, member, "tentative")
      assert {:ok, "tentative"} = Meetings.respond_to_invite(meeting, member, "tentative")
      assert Repo.get!(Meeting, meeting.id).ical_sequence == 1
      assert Meetings.invite_rsvp(meeting, member) == "tentative"
    end

    test "refuses someone with no invite and an unknown answer", %{
      meeting: meeting,
      member: member,
      creator: creator
    } do
      assert {:error, :not_invited} = Meetings.respond_to_invite(meeting, creator, "accepted")
      assert {:error, :invalid_status} = Meetings.respond_to_invite(meeting, member, "invited")
      assert {:error, :invalid_status} = Meetings.respond_to_invite(meeting, member, "bogus")
      assert Meetings.invite_rsvp(meeting, creator) == nil
      assert Meetings.invite_rsvp(meeting, member) == "invited"
      assert Repo.get!(Meeting, meeting.id).ical_sequence == 0
    end

    test "an address-only invite answers for the account that signs in with that email", %{
      meeting: meeting
    } do
      n = System.unique_integer([:positive])
      later = user!("later-#{n}", "Lee Later")
      invite!(%{meeting_id: meeting.id, display_name: "Lee", email: String.upcase(later.email)})

      assert {:ok, "accepted"} = Meetings.respond_to_invite(meeting, later, "accepted")
      assert Meetings.invite_rsvp(meeting, later) == "accepted"
    end

    test "a revoked invitee drops off the attendee list", %{
      meeting: meeting,
      member: member,
      guest_invite: guest_invite
    } do
      {:ok, _} = Meetings.revoke_invite(guest_invite)

      assert ["mailto:" <> member.email] ==
               member |> feed_event(meeting) |> attendees() |> Enum.map(& &1.value)
    end
  end

  # The meeting's VEVENT out of `member`'s subscription feed.
  defp feed_event(%User{} = user, %Meeting{} = meeting) do
    feed = Platform.Calendar.Feed.render(Scope.for_user(Platform.Accounts.get_user(user.id)))
    uid = "UID:" <> CalendarFeed.uid(meeting) <> "\r\n"

    [event] =
      feed
      |> String.split("BEGIN:VEVENT\r\n")
      |> Enum.filter(&String.starts_with?(&1, uid))

    [event, _] = String.split(event, "END:VEVENT\r\n", parts: 2)
    "BEGIN:VEVENT\r\n" <> event <> "END:VEVENT\r\n"
  end

  defp user!(key, name) do
    Repo.insert!(%User{email: "#{key}@example.com", name: name, oidc_sub: key})
  end

  defp invite!(attrs), do: %Invite{} |> Invite.changeset(attrs) |> Repo.insert!()
end
