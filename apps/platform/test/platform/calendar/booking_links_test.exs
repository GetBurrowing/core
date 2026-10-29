defmodule Platform.Calendar.BookingLinksTest do
  use Platform.DataCase, async: false
  alias Platform.{Calendar, Repo}
  alias Platform.Calendar.{BookingLinks, Booking, Subscription}
  alias Platform.Access.Scope
  alias Platform.Accounts.User

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

  defp attrs(extra \\ %{}) do
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
    token = url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
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
end
