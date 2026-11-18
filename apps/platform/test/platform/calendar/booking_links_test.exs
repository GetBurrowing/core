defmodule Platform.Calendar.BookingLinksTest do
  use Platform.DataCase, async: false
  alias Platform.{Calendar, Repo}
  alias Platform.Calendar.{BookingLinks, Booking, Subscription}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Calendar.{BookingHosts, BookingLinkHost}
  import Ecto.Query

  doctest Platform.Calendar.BookingConfirmation

  defp scope do
    n = System.unique_integer([:positive])

    Scope.for_user(
      Repo.insert!(%User{
        email: "booking#{n}@example.com",
        oidc_sub: "booking#{n}",
        name: "Owner"
      })
    )
  end

  defp attrs(extra) do
    date = Date.add(Date.utc_today(), 7)

    Map.merge(
      %{
        title: "Office hours",
        time_zone: "Etc/UTC",
        duration_minutes: 30,
        start_date: date,
        end_date: Date.add(date, 30),
        windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]
      },
      extra
    )
  end

  defp create(owner, extra \\ %{}) do
    {:ok, link} = BookingLinks.create(owner, attrs(extra))
    link
  end

  defp guest(slot, extra \\ %{}),
    do:
      Map.merge(
        %{
          "name" => "Booker",
          "email" => "guest@example.com",
          "starts_at" => DateTime.to_iso8601(slot.starts_at)
        },
        extra
      )

  test "owner policy validation, private settings, revocation and malformed input" do
    owner = scope()
    other = scope()
    link = create(owner)
    assert [] == BookingLinks.list(other)
    assert {:error, :not_found} = BookingLinks.revoke(other, link.id)
    assert {:error, _} = BookingLinks.create(owner, attrs(%{time_zone: "fake/zone"}))
    assert {:error, _} = BookingLinks.create(owner, attrs(%{duration_minutes: 0}))

    assert {:error, _} =
             BookingLinks.create(owner, attrs(%{end_date: Date.add(Date.utc_today(), 800)}))

    assert {:error, _} =
             BookingLinks.create(
               owner,
               attrs(%{windows: [%{"weekday" => 8, "start" => "09:00", "end" => "10:00"}]})
             )

    assert {:error, :not_found} = BookingLinks.slots("invalid", link.start_date)
    assert {:ok, []} = BookingLinks.slots(link.token, Date.add(link.end_date, 1))
    assert {:ok, _} = BookingLinks.revoke(owner, link.id)
    assert {:error, :not_found} = BookingLinks.slots(link.token, link.start_date)
  end

  test "only offered slots book, native conflicts and both buffers block, replay does not duplicate" do
    owner = scope()
    link = create(owner, %{buffer_before_minutes: 15, buffer_after_minutes: 15})
    {:ok, [first | _]} = BookingLinks.slots(link.token, link.start_date)

    {:ok, booked} =
      BookingLinks.book(
        link.token,
        guest(first, %{"create_meeting" => "true", "project_id" => "forged"}),
        "first-key-00000000"
      )

    assert booked.event_id
    refute booked.meeting_id
    assert {:ok, replay} = BookingLinks.book(link.token, guest(first), "first-key-00000000")
    assert replay.id == booked.id
    assert Repo.aggregate(Booking, :count) == 1

    assert {:error, :idempotency_conflict} =
             BookingLinks.book(
               link.token,
               guest(first, %{"name" => "Other"}),
               "first-key-00000000"
             )

    assert {:error, :slot_unavailable} =
             BookingLinks.book(link.token, guest(first), "second-key-0000000")

    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(DateTime.diff(&1.starts_at, first.starts_at) in [0, 1800]))

    assert {:ok, event} =
             Calendar.create_event(owner, %{
               title: "Secret",
               starts_at: DateTime.add(first.starts_at, 7200),
               ends_at: DateTime.add(first.starts_at, 9000)
             })

    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(&1.starts_at == event.starts_at))
    off_grid = %{first | starts_at: DateTime.add(first.starts_at, 7)}

    assert {:error, :slot_unavailable} =
             BookingLinks.book(link.token, guest(off_grid), "off-grid-key-00000")

    assert {:error, :invalid_guest} =
             BookingLinks.book(
               link.token,
               guest(first, %{"email" => "not-email"}),
               "invalid-guest-key"
             )
  end

  test "reservations conflict across separate links and stale external feeds fail closed" do
    owner = scope()
    first_link = create(owner)
    second_link = create(owner)
    {:ok, [slot | _]} = BookingLinks.slots(first_link.token, first_link.start_date)
    assert {:ok, _} = BookingLinks.book(first_link.token, guest(slot), "cross-link-key-000")

    assert {:error, :slot_unavailable} =
             BookingLinks.book(second_link.token, guest(slot), "cross-link-key-001")

    Repo.insert!(%Subscription{
      owner_id: owner.actor.id,
      name: "Not refreshed",
      url: "https://example.com/feed.ics"
    })

    assert {:error, :external_coverage_unknown} =
             BookingLinks.slots(second_link.token, second_link.start_date)
  end

  test "a fresh but partial external calendar makes slots unknown" do
    owner = scope()
    link = create(owner)

    {:ok, snapshot, 0} =
      Platform.Calendar.ICal.parse(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:partial-1@example.invalid\r\n" <>
          "DTSTART:20200101T100000Z\r\nDTEND:20200101T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
      )

    sub =
      Repo.insert!(%Subscription{
        owner_id: owner.actor.id,
        name: "Partial",
        url: "https://example.com/feed.ics",
        snapshot: snapshot,
        refreshed_at: DateTime.utc_now(),
        error: nil,
        skipped_count: 1
      })

    assert {:error, :external_coverage_unknown} = BookingLinks.slots(link.token, link.start_date)

    Repo.update!(Ecto.Changeset.change(sub, skipped_count: 0))
    assert {:ok, _} = BookingLinks.slots(link.token, link.start_date)
  end

  test "DST gap and repeated wall times are omitted; actual duration is fixed" do
    owner = scope()

    year = Date.utc_today().year + 1
    march = Date.new!(year, 3, 1)
    november = Date.new!(year, 11, 1)
    spring = Date.add(march, rem(7 - Date.day_of_week(march), 7) + 7)
    autumn = Date.add(november, rem(7 - Date.day_of_week(november), 7))

    for date <- [spring, autumn] do
      link =
        create(owner, %{
          start_date: date,
          end_date: date,
          time_zone: "America/Chicago",
          windows: [%{"weekday" => 7, "start" => "00:00", "end" => "05:00"}]
        })

      {:ok, slots} = BookingLinks.slots(link.token, date)
      assert slots != []
      assert Enum.all?(slots, &(DateTime.diff(&1.ends_at, &1.starts_at) == 1800))
      local = Enum.map(slots, &DateTime.shift_zone!(&1.starts_at, "America/Chicago"))
      refute Enum.any?(local, &(&1.hour == if(date.month == 3, do: 2, else: 1)))
    end
  end

  test "Meetings disabled refuses owner policy and rechecks persisted policy" do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, false)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)
    owner = scope()

    assert {:error, :meetings_unavailable} =
             BookingLinks.create(owner, attrs(%{create_meeting: true}))

    link = create(owner)
    Repo.update!(Ecto.Changeset.change(link, create_meeting: true))
    assert {:error, :meetings_unavailable} = BookingLinks.slots(link.token, link.start_date)
  end

  test "hourly booking limit is counted under the owner lock across links" do
    owner = scope()
    link = create(owner)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    for n <- 1..20 do
      Repo.insert!(%Booking{
        link_id: link.id,
        owner_id: owner.actor.id,
        idempotency_key: "existing-#{n}",
        name: "Existing",
        starts_at: DateTime.add(slot.starts_at, -86400),
        ends_at: DateTime.add(slot.ends_at, -86400),
        reserved_start: DateTime.add(slot.starts_at, -86400),
        reserved_end: DateTime.add(slot.ends_at, -86400)
      })
    end

    assert {:error, :rate_limited} =
             BookingLinks.book(link.token, guest(slot), "over-limit-key-000")
  end

  test "meeting booking requires email, creates one meeting and a valid scoped guest invite, and exposes email failure" do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)
    owner = scope()
    org_id = Platform.TenancyFixtures.acme_org_id()

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.actor.id,
      org_id: org_id,
      role: "member"
    })

    owner = Scope.for_user(Platform.Accounts.get_user(owner.actor.id))

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Bookings",
        slug: "bookings-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    link = create(owner, %{create_meeting: true, project_id: project.id})
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    assert {:error, :email_required} =
             BookingLinks.book(link.token, guest(slot, %{"email" => ""}), "meeting-no-email-0")

    assert {:ok, booking} =
             BookingLinks.book(
               link.token,
               guest(slot, %{"create_meeting" => "false"}),
               "meeting-with-email"
             )

    assert booking.meeting_id
    refute booking.event_id
    assert booking.delivery_error =~ "Confirmation email unavailable"
    meeting = Repo.get!(Platform.Meetings.Meeting, booking.meeting_id)
    assert Platform.Meetings.host_user_id(meeting) == owner.actor.id

    invite =
      Repo.get_by!(Platform.Meetings.Invite, meeting_id: meeting.id, email: "guest@example.com")

    url = Platform.Meetings.guest_invite_link(meeting, invite)
    # The link is the short form (task 01a18d0a-ec37); the token behind it is
    # re-minted from the row by resolve_guest_short_code/1.
    assert "/g/" <> code = url |> URI.parse() |> Map.fetch!(:path)
    assert {:ok, %{token: token}} = Platform.Meetings.resolve_guest_short_code(code)
    assert {:ok, _} = Platform.Meetings.resolve_guest_invite(meeting.slug, token)
    assert {:error, _} = Platform.Meetings.resolve_guest_invite("another-meeting", token)

    assert {:ok, replay} =
             BookingLinks.book(
               link.token,
               guest(slot, %{"create_meeting" => "false"}),
               "meeting-with-email"
             )

    assert replay.id == booking.id
    assert length(BookingLinks.receipts(owner)) == 1
    assert [] == BookingLinks.receipts(scope())
  end

  test "attempt limits count refused submissions and policy updates are owner-only" do
    owner = scope()
    link = create(owner)
    assert {:error, :not_found} = BookingLinks.update(scope(), link.id, %{title: "Forged"})
    assert {:ok, changed} = BookingLinks.update(owner, link.id, %{title: "New title"})
    assert changed.title == "New title"

    for _ <- 1..30 do
      assert {:error, :invalid_booking} =
               BookingLinks.book(link.token, %{"starts_at" => 123}, "attempt-key-000000")
    end

    assert {:error, :rate_limited} = BookingLinks.book(link.token, %{}, "attempt-key-000000")
  end

  test "availability blocks a long meeting that began before the expanded booking window" do
    owner = scope()
    org_id = Platform.TenancyFixtures.acme_org_id()

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.actor.id,
      org_id: org_id,
      role: "member"
    })

    owner = Scope.for_user(Platform.Accounts.get_user(owner.actor.id))

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Long meetings",
        slug: "long-book-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    link = create(owner)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{
        project_id: project.id,
        name: "Conference",
        scheduled_start_at: DateTime.add(slot.starts_at, -3 * 86400),
        scheduled_end_at: DateTime.add(slot.ends_at, 86400)
      })

    {:ok, _} = Platform.Meetings.invite_user(meeting, owner.actor.id)
    assert {:ok, []} = BookingLinks.slots(link.token, link.start_date)

    assert {:error, :slot_unavailable} =
             BookingLinks.book(link.token, guest(slot), "long-meeting-key-00")
  end

  # Task 01a1a933 stage 3: a booking sends only its own `Booking confirmed:`
  # email. The owner is not mailed an invite to their own meeting and the
  # booker gets no second, `Invitation:` message, even with meetings and
  # mail on and a `meetings` sender configured for the org.
  test "a booked meeting sends exactly one Booking confirmed: and no invite email" do
    keys = [:meetings_enabled, :mail_enabled, :calendar_booking_mail_senders]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}
    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :mail_enabled, true)
    Application.delete_env(:platform, :calendar_booking_mail_senders)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    owner = scope()
    org_id = Platform.TenancyFixtures.acme_org_id()

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.actor.id,
      org_id: org_id,
      role: "member"
    })

    owner = Scope.for_user(Platform.Accounts.get_user(owner.actor.id))

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Bookings mail",
        slug: "bookings-mail-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    account =
      Repo.insert!(%Platform.Mail.Account{
        org_id: org_id,
        name: "Meetings sender #{System.unique_integer([:positive])}",
        smtp_host: "smtp.example.com",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Platform.Mail.Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com"
    })

    link = create(owner, %{create_meeting: true, project_id: project.id})
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    assert {:ok, booking} = BookingLinks.book(link.token, guest(slot), "booking-mail-key-0")
    assert booking.meeting_id
    assert booking.delivery_id

    by_responsibility =
      Platform.Mail.Delivery
      |> Repo.all()
      |> Enum.group_by(& &1.responsibility)

    assert [confirmed] = Map.get(by_responsibility, "calendar.booking_confirmation")
    assert confirmed.subject =~ "Booking confirmed:"
    assert confirmed.recipients == ["guest@example.com"]
    assert Map.get(by_responsibility, "meetings.invite_email", []) == []

    for invite <- Platform.Meetings.list_invites(booking.meeting_id) do
      assert invite.mail_error == nil
      assert invite.mail_delivery_id == nil
    end
  end

  test "configured confirmation queues via exact audited sender; later delivery failure is visible" do
    old_mail = Application.get_env(:platform, :mail_enabled)
    old_senders = Application.get_env(:platform, :calendar_booking_mail_senders)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      Application.put_env(:platform, :mail_enabled, old_mail)

      if old_senders,
        do: Application.put_env(:platform, :calendar_booking_mail_senders, old_senders),
        else: Application.delete_env(:platform, :calendar_booking_mail_senders)
    end)

    owner = scope()
    org_id = Platform.TenancyFixtures.acme_org_id()

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.actor.id,
      org_id: org_id,
      role: "member"
    })

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Confirmation",
        slug: "confirm-book-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    account =
      Repo.insert!(%Platform.Mail.Account{
        org_id: org_id,
        name: "Booking sender #{System.unique_integer([:positive])}",
        smtp_host: "smtp.test",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Platform.Mail.Sender{
      account_id: account.id,
      key: "booking",
      address: "calendar@example.com"
    })

    Application.put_env(:platform, :calendar_booking_mail_senders, %{
      org_id => %{account_id: account.id, sender_key: "booking"}
    })

    slot = %{starts_at: DateTime.add(DateTime.utc_now(), 3600)}
    meeting = %Platform.Meetings.Meeting{project_id: project.id, name: "Booking"}

    assert {id, nil} =
             Platform.Calendar.BookingConfirmation.enqueue(
               meeting,
               owner.actor.id,
               %{"email" => "guest@example.com"},
               slot,
               "https://meet.test.local/guest/signed-token"
             )

    assert id
    delivery = Repo.get!(Platform.Mail.Delivery, id)
    assert delivery.status == "queued"
    assert delivery.recipients == ["guest@example.com"]
    assert delivery.account_id == account.id
    assert delivery.body =~ "https://meet.test.local/guest/signed-token"
    link = create(owner)
    {:ok, [first | _]} = BookingLinks.slots(link.token, link.start_date)
    {:ok, booking} = BookingLinks.book(link.token, guest(first), "mail-status-key-00")
    Repo.update!(Ecto.Changeset.change(booking, delivery_id: id))
    Repo.update!(Ecto.Changeset.change(delivery, status: "failed", error: "SMTP unavailable"))
    assert [%{delivery_error: error}] = BookingLinks.receipts(owner)
    assert error =~ "delivery failed"
    Repo.update!(Ecto.Changeset.change(account, internal_only: true))

    assert {refused_id, reason} =
             Platform.Calendar.BookingConfirmation.enqueue(
               meeting,
               owner.actor.id,
               %{"email" => "outsider@example.com"},
               slot,
               "https://meet.test.local/guest/signed-token"
             )

    assert refused_id
    assert reason =~ "refused"
  end

  # ── Minimum notice, preview and open days (task 01a18d9f stage 3) ──────

  defp all_day_windows,
    do: for(day <- 1..7, do: %{"weekday" => day, "start" => "00:00", "end" => "23:30"})

  test "minimum notice is one of the v4 choices and defaults to none" do
    owner = scope()
    link = create(owner)
    assert link.minimum_notice_minutes == 0
    assert {:error, cs} = BookingLinks.create(owner, attrs(%{minimum_notice_minutes: 30}))
    assert Keyword.has_key?(cs.errors, :minimum_notice_minutes)

    for minutes <- [120, 240, 1440, 2880] do
      assert {:ok, %{minimum_notice_minutes: ^minutes}} =
               BookingLinks.update(owner, link.id, %{minimum_notice_minutes: minutes})
    end
  end

  test "minimum notice excludes slots that start too soon, for slots/2 and book/3" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    tomorrow = Date.add(Date.utc_today(), 1)

    link =
      create(owner, %{
        start_date: Date.utc_today(),
        end_date: Date.add(Date.utc_today(), 7),
        windows: all_day_windows()
      })

    assert {:ok, [first | _] = open} = BookingLinks.slots(link.token, tomorrow)
    assert length(open) > 0

    {:ok, link} = BookingLinks.update(owner, link.id, %{minimum_notice_minutes: 2880})
    earliest = DateTime.add(DateTime.utc_now(), 2880 * 60)
    # Every start on tomorrow lies within 48 hours of now.
    assert {:ok, []} = BookingLinks.slots(link.token, tomorrow)

    assert {:ok, later} = BookingLinks.slots(link.token, Date.add(tomorrow, 2))
    assert Enum.all?(later, &(DateTime.compare(&1.starts_at, earliest) == :gt))

    assert {:error, :slot_unavailable} =
             BookingLinks.book(link.token, guest(first, %{"email" => ""}), "notice-key-0000001")
  end

  test "preview is owner-scoped and open_days counts each day's open slots" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    other = scope()
    date = Date.add(Date.utc_today(), 7)
    link = create(owner)

    assert {:ok, preview} = BookingLinks.preview(owner, link.id, date, 1)
    assert {:ok, ^preview} = BookingLinks.slots(link.token, date)
    assert length(preview) == 6
    assert {:error, :not_found} = BookingLinks.preview(other, link.id, date, 1)

    assert {:ok, open} = BookingLinks.open_days(link.token, date)
    assert open[date] == 6
    assert Enum.all?(Map.keys(open), &(&1.month == date.month))

    {:ok, _} = BookingLinks.revoke(owner, link.id)
    assert {:error, :not_found} = BookingLinks.preview(owner, link.id, date, 1)
    assert {:error, :not_found} = BookingLinks.open_days(link.token, date)
  end

  # ── Shared links: every host's calendar, every host's lock ─────────────
  # Task 01a1eff0-6880 stage 2.

  defp host_user!(name, org_id) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "shared-host-#{n}@example.com",
        oidc_sub: "shared-host-#{n}",
        name: name
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    Platform.Accounts.get_user(user.id)
  end

  defp cohost!(owner, link, cohost) do
    {:ok, host} = BookingHosts.invite(Scope.for_user(owner), link.id, cohost.id)
    {:ok, host} = BookingHosts.accept(Scope.for_user(cohost), host.id)
    host
  end

  defp shared_setup(extra \\ %{}) do
    Platform.Calendar.BookingRateLimit.reset()
    org_id = Platform.TenancyFixtures.acme_org_id()
    ryan = host_user!("Ryan Milvenan", org_id)
    jordan = host_user!("Jordan Coombs", org_id)
    link = create(Scope.for_user(ryan), extra)
    cohost!(ryan, link, jordan)
    %{org_id: org_id, ryan: ryan, jordan: jordan, link: link}
  end

  defp event_count, do: Repo.aggregate(Calendar.Event, :count)

  test "a time free for the owner but busy for a co-host is hidden and cannot be forged" do
    %{jordan: jordan, link: link} = shared_setup()
    {:ok, [first, second | _] = before} = BookingLinks.slots(link.token, link.start_date)
    assert length(before) == 6

    {:ok, _} =
      Calendar.create_event(Scope.for_user(jordan), %{
        title: "Jordan busy",
        starts_at: first.starts_at,
        ends_at: first.ends_at
      })

    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(&1.starts_at == first.starts_at))
    assert Enum.any?(slots, &(&1.starts_at == second.starts_at))
    # Same public shape as a single-owner link: start and end only.
    assert Enum.all?(slots, &(Map.keys(&1) |> Enum.sort() == [:ends_at, :starts_at]))

    events = event_count()

    assert {:error, :slot_unavailable} =
             BookingLinks.book(link.token, guest(first, %{"email" => ""}), "forged-shared-key-1")

    assert Repo.aggregate(Booking, :count) == 0
    assert event_count() == events
  end

  test "a pending, declined or left co-host fails slots, open_days, preview and book closed" do
    %{ryan: ryan, link: link} = shared_setup()
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    [host] = BookingHosts.list_for_link(link)

    for status <- ~w(pending declined left) do
      Repo.update!(Ecto.Changeset.change(host, status: status))
      assert {:error, :hosts_not_ready} = BookingLinks.slots(link.token, link.start_date)
      assert {:error, :hosts_not_ready} = BookingLinks.open_days(link.token, link.start_date)

      assert {:error, :hosts_not_ready} =
               BookingLinks.preview(Scope.for_user(ryan), link.id, link.start_date, 1)

      assert {:error, :hosts_not_ready} = BookingLinks.public_policy(link.token)

      assert {:error, :hosts_not_ready} =
               BookingLinks.book(
                 link.token,
                 guest(slot, %{"email" => ""}),
                 "not-ready-#{status}-0"
               )
    end

    assert Repo.aggregate(Booking, :count) == 0
  end

  test "a pending co-host's stale subscription is never read: :hosts_not_ready, not coverage" do
    %{jordan: jordan, link: link} = shared_setup()

    Repo.insert!(%Subscription{
      owner_id: jordan.id,
      name: "Not refreshed",
      url: "https://example.com/feed.ics"
    })

    # Accepted: the co-host's calendar is read and its stale feed fails closed.
    assert {:error, :external_coverage_unknown} =
             BookingLinks.slots(link.token, link.start_date)

    Repo.update_all(from(h in BookingLinkHost, where: h.link_id == ^link.id),
      set: [status: "pending"]
    )

    assert {:error, :hosts_not_ready} = BookingLinks.slots(link.token, link.start_date)
  end

  test "a booking on a shared link blocks that slot on the co-host's own single-owner link" do
    %{jordan: jordan, ryan: ryan, link: link} = shared_setup()
    own = create(Scope.for_user(jordan))
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    assert {:ok, booking} =
             BookingLinks.book(link.token, guest(slot, %{"email" => ""}), "shared-cross-key-01")

    assert Enum.sort(booking.host_user_ids) == Enum.sort([ryan.id, jordan.id])
    # The co-host's busy event alone would also hide the slot; remove it so
    # only the reservation row's host_user_ids can block it.
    Repo.delete_all(from(e in Calendar.Event, where: e.owner_id == ^jordan.id))

    {:ok, own_slots} = BookingLinks.slots(own.token, own.start_date)
    refute Enum.any?(own_slots, &(&1.starts_at == slot.starts_at))

    assert {:error, :slot_unavailable} =
             BookingLinks.book(own.token, guest(slot, %{"email" => ""}), "shared-cross-key-02")
  end

  test "a co-host's reservation on their own link, widened by that link's buffer, blocks the shared link" do
    %{jordan: jordan, link: link} = shared_setup()
    own = create(Scope.for_user(jordan), %{buffer_after_minutes: 30})
    {:ok, [first, second | _]} = BookingLinks.slots(link.token, link.start_date)

    assert {:ok, booking} =
             BookingLinks.book(own.token, guest(first, %{"email" => ""}), "own-buffer-key-0001")

    assert booking.reserved_end == second.ends_at
    Repo.delete_all(from(e in Calendar.Event, where: e.owner_id == ^jordan.id))

    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(&1.starts_at in [first.starts_at, second.starts_at]))
  end

  test "a shared booking creates one busy event in every host's own calendar" do
    %{jordan: jordan, ryan: ryan, link: link} = shared_setup()
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    assert {:ok, booking} =
             BookingLinks.book(link.token, guest(slot, %{"email" => ""}), "shared-events-key-1")

    assert [owner_event_id, cohost_event_id] = booking.host_event_ids
    assert booking.event_id == owner_event_id
    assert booking.owner_id == ryan.id
    assert Repo.get!(Calendar.Event, owner_event_id).owner_id == ryan.id
    cohost_event = Repo.get!(Calendar.Event, cohost_event_id)
    assert cohost_event.owner_id == jordan.id
    assert cohost_event.visibility == "busy"
    assert cohost_event.starts_at == slot.starts_at
    assert Booking.owns_event?(owner_event_id)
    assert Booking.owns_event?(cohost_event_id)
  end

  test "the hourly cap counts every host's bookings" do
    %{jordan: jordan, link: link} = shared_setup()
    own = create(Scope.for_user(jordan))
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    for n <- 1..20 do
      Repo.insert!(%Booking{
        link_id: own.id,
        owner_id: jordan.id,
        idempotency_key: "cohost-existing-#{n}",
        name: "Existing",
        starts_at: DateTime.add(slot.starts_at, -86400),
        ends_at: DateTime.add(slot.ends_at, -86400),
        reserved_start: DateTime.add(slot.starts_at, -86400),
        reserved_end: DateTime.add(slot.ends_at, -86400)
      })
    end

    assert {:error, :rate_limited} =
             BookingLinks.book(link.token, guest(slot, %{"email" => ""}), "cohost-cap-key-0001")
  end

  test "public_policy names every host, owner first, and says the link is shared" do
    %{link: link} = shared_setup()
    assert {:ok, policy} = BookingLinks.public_policy(link.token)
    assert policy.host_names == ["Ryan Milvenan", "Jordan Coombs"]
    assert policy.shared
    assert policy.owner_name == "Ryan Milvenan"
  end

  test "a single-owner link is unchanged: one host, its own event, not shared" do
    owner = scope()
    link = create(owner)
    assert {:ok, %{shared: false, host_names: ["Owner"]}} = BookingLinks.public_policy(link.token)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    assert {:ok, booking} = BookingLinks.book(link.token, guest(slot), "single-owner-key-01")
    assert booking.host_user_ids == [owner.actor.id]
    assert booking.host_event_ids == [booking.event_id]
  end

  test "a shared meeting booking invites every host and mails no co-host" do
    keys = [:meetings_enabled, :mail_enabled, :calendar_booking_mail_senders]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}
    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :mail_enabled, true)
    Application.delete_env(:platform, :calendar_booking_mail_senders)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Shared bookings",
        slug: "shared-bookings-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    account =
      Repo.insert!(%Platform.Mail.Account{
        org_id: org_id,
        name: "Shared sender #{System.unique_integer([:positive])}",
        smtp_host: "smtp.example.com",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Platform.Mail.Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com"
    })

    %{ryan: ryan, jordan: jordan, link: link} =
      shared_setup(%{create_meeting: true, project_id: project.id})

    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    assert {:ok, booking} = BookingLinks.book(link.token, guest(slot), "shared-meeting-key1")
    assert booking.meeting_id
    assert booking.host_user_ids == [ryan.id, jordan.id]
    meeting = Repo.get!(Platform.Meetings.Meeting, booking.meeting_id)
    assert Platform.Meetings.host_user_id(meeting) == ryan.id

    invited =
      booking.meeting_id
      |> Platform.Meetings.list_invites()
      |> Enum.map(& &1.user_id)

    assert ryan.id in invited
    assert jordan.id in invited

    assert Repo.exists?(
             from(p in Platform.Chat.Participant,
               where:
                 p.space_id == ^meeting.chat_space_id and p.participant_type == "user" and
                   p.participant_id == ^jordan.id
             )
           )

    deliveries = Repo.all(Platform.Mail.Delivery)
    refute Enum.any?(deliveries, &(jordan.email in &1.recipients))
    refute Enum.any?(deliveries, &(ryan.email in &1.recipients))
    assert [confirmed] = Enum.filter(deliveries, &(&1.recipients == ["guest@example.com"]))
    assert confirmed.body =~ "With Ryan Milvenan and Jordan Coombs."
  end

  # Task 01a1eff0 stage 1: the bookable-date range is a server-side contract.
  # Slot generation, open_days/2, preview/4 and book/3 all honour
  # start_date..end_date; a one-day link offers exactly that day.

  # The first date on or after `from` whose ISO weekday is `weekday`.
  defp next_weekday(from, weekday),
    do: Date.add(from, rem(weekday - Date.day_of_week(from) + 7, 7))

  defp local_date(slot, zone),
    do: slot.starts_at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp owner_event_count(owner),
    do:
      Repo.aggregate(
        from(e in Calendar.Event, where: e.owner_id == ^owner.actor.id),
        :count
      )

  defp one_day_link(owner, date, extra \\ %{}) do
    create(
      owner,
      Map.merge(
        %{
          start_date: date,
          end_date: date,
          windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]
        },
        extra
      )
    )
  end

  test "a one-day link offers only that day" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    today = Date.utc_today()
    # Ten days out: clear of minimum notice and "now", and D-7 is still future.
    day = Date.add(today, 10)
    link = one_day_link(owner, day)

    assert {:ok, [_ | _] = offered} = BookingLinks.slots(link.token, day)
    assert Enum.all?(offered, &(local_date(&1, "Etc/UTC") == day))
    assert {:ok, []} = BookingLinks.slots(link.token, Date.add(day, 7))

    if Date.compare(Date.add(day, -7), today) != :lt,
      do: assert({:ok, []} = BookingLinks.slots(link.token, Date.add(day, -7)))

    assert {:ok, open} = BookingLinks.open_days(link.token, day)
    assert Map.keys(open) == [day]
    assert open[day] == length(offered)

    next_month = Date.add(Date.end_of_month(day), 1)
    assert {:ok, %{} = later} = BookingLinks.open_days(link.token, next_month)
    assert later == %{}

    assert {:ok, preview} = BookingLinks.preview(owner, link.id, today, 62)
    assert preview == offered
    assert Enum.map(preview, &local_date(&1, "Etc/UTC")) |> Enum.uniq() == [day]
  end

  test "time-zone boundary: a Chicago evening slot that is Thursday in UTC stays on its Wednesday" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    zone = "America/Chicago"
    wednesday = next_weekday(Date.add(Date.utc_today(), 8), 3)

    # 17:00-20:00 rather than 17:00-19:00 so a slot crosses UTC midnight in
    # both CST (UTC-6, 18:00 -> 00:00Z) and CDT (UTC-5, 19:00 -> 00:00Z).
    link =
      create(owner, %{
        time_zone: zone,
        start_date: wednesday,
        end_date: wednesday,
        windows: [%{"weekday" => 3, "start" => "17:00", "end" => "20:00"}]
      })

    assert {:ok, offered} = BookingLinks.slots(link.token, wednesday)

    assert Enum.map(
             offered,
             &(&1.starts_at |> DateTime.shift_zone!(zone) |> Elixir.Calendar.strftime("%H:%M"))
           ) ==
             ~w(17:00 17:30 18:00 18:30 19:00 19:30)

    six_pm = DateTime.new!(wednesday, ~T[18:00:00], zone)
    assert Enum.any?(offered, &(DateTime.compare(&1.starts_at, six_pm) == :eq))
    assert Enum.all?(offered, &(local_date(&1, zone) == wednesday))

    thursday_utc = Date.add(wednesday, 1)
    assert Enum.any?(offered, &(DateTime.to_date(&1.starts_at) == thursday_utc))

    assert {:ok, open} = BookingLinks.open_days(link.token, wednesday)
    assert open == %{wednesday => length(offered)}
    assert {:ok, []} = BookingLinks.slots(link.token, thursday_utc)
  end

  test "an out-of-range start is refused server-side and creates nothing" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    day = Date.add(Date.utc_today(), 10)
    link = one_day_link(owner, day, %{time_zone: "America/Chicago"})
    bookings = Repo.aggregate(Booking, :count)
    events = owner_event_count(owner)

    forge = fn date, time, key ->
      start = DateTime.new!(date, time, link.time_zone)

      BookingLinks.book(
        link.token,
        %{"name" => "Forger", "email" => "", "starts_at" => DateTime.to_iso8601(start)},
        key
      )
    end

    assert {:error, :slot_unavailable} =
             forge.(Date.add(day, 7), ~T[09:00:00], "forged-after-range-01")

    assert {:error, :slot_unavailable} =
             forge.(Date.add(day, -7), ~T[09:00:00], "forged-before-range-1")

    # In range, but one minute off the 30-minute grid.
    assert {:error, :slot_unavailable} = forge.(day, ~T[09:01:00], "forged-off-grid-0001")

    assert Repo.aggregate(Booking, :count) == bookings
    assert owner_event_count(owner) == events

    # Positive control: the on-grid in-range start books and the counts move.
    assert {:ok, booked} = forge.(day, ~T[09:00:00], "in-range-on-grid-001")
    assert booked.event_id
    assert Repo.aggregate(Booking, :count) == bookings + 1
    assert owner_event_count(owner) == events + 1
  end

  test "a three-week link has open days on exactly its three Wednesdays" do
    Platform.Calendar.BookingRateLimit.reset()
    owner = scope()
    first = next_weekday(Date.add(Date.utc_today(), 8), 3)
    last = Date.add(first, 20)

    link =
      create(owner, %{
        start_date: first,
        end_date: last,
        windows: [%{"weekday" => 3, "start" => "09:00", "end" => "12:00"}]
      })

    # Every month that holds a Wednesday just outside the range on either
    # side, so a lost clamp shows up whichever month it lands in.
    months =
      [Date.add(first, -7), first, last, Date.add(first, 21)]
      |> Enum.map(&Date.beginning_of_month/1)
      |> Enum.uniq()

    days =
      Enum.flat_map(months, fn month ->
        {:ok, open} = BookingLinks.open_days(link.token, month)
        Map.keys(open)
      end)

    assert Enum.sort(days, Date) == [first, Date.add(first, 7), Date.add(first, 14)]
  end
end
