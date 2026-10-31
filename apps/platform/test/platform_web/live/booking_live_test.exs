defmodule PlatformWeb.BookingLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.BookingLinks
  alias Platform.Access.Scope

  setup %{conn: conn} do
    Platform.Calendar.BookingRateLimit.reset()
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "booking-ui-#{n}@example.com",
        name: "Booking owner",
        oidc_sub: "booking-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    scope = Scope.for_user(user)
    date = Date.add(Date.utc_today(), 7)

    {:ok, link} =
      BookingLinks.create(scope, %{
        title: "Private owner policy",
        time_zone: "Etc/UTC",
        duration_minutes: 30,
        start_date: date,
        end_date: Date.add(date, 7),
        windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]
      })

    %{
      conn: conn,
      auth: init_test_session(conn, current_user_id: user.id),
      scope: scope,
      link: link
    }
  end

  defp pick(view, date),
    do: view |> element("[data-step=pick] button[phx-value-date='#{date}']") |> render_click()

  defp choose(view, slot),
    do:
      view
      |> element(".cal-guest-slot[phx-value-start='#{DateTime.to_iso8601(slot.starts_at)}']")
      |> render_click()

  test "public guest can book without account and cannot choose meeting policy", %{
    conn: conn,
    link: link,
    scope: scope
  } do
    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Confidential board discussion",
        starts_at: DateTime.new!(link.start_date, ~T[11:00:00]),
        ends_at: DateTime.new!(link.start_date, ~T[12:00:00])
      })

    {:ok, view, html} = live(conn, "/book/#{link.token}")
    refute html =~ "Confidential board discussion"
    # v4's guest card shows the link title and owner (booking.js hostHTML).
    assert has_element?(view, ".cal-guest-host h1", "Private owner policy")
    assert has_element?(view, ".cal-guest-who", "Booking owner")
    assert has_element?(view, ".cal-guest-ln", "30 minutes")
    assert has_element?(view, ".cal-guest-ln", "Calendar invite only")
    assert has_element?(view, ".cal-guest-times h2", "Times")
    assert has_element?(view, ".cal-guest-times", "Choose a day to see open times.")

    if link.start_date.month == Date.utc_today().month,
      do: :ok,
      else: render_click(view, "month", %{"direction" => "next"})

    pick(view, link.start_date)

    assert has_element?(
             view,
             ".cal-guest-times h2",
             PlatformWeb.PublicBookingLive.long_day(link.start_date)
           )

    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    refute has_element?(view, ".cal-guest-slot", "11:00")
    choose(view, slot)

    view
    |> form("#public-booking-form",
      guest: %{"name" => "Guest", "email" => "guest@example.com"}
    )
    |> render_submit(%{"guest" => %{"create_meeting" => "true", "project_id" => "forged"}})

    assert has_element?(view, ".cal-guest-done h1", "You’re booked")
    assert has_element?(view, ".cal-guest-done", "Private owner policy with Booking owner")
    assert has_element?(view, ".cal-guest-done", "Booking has it on their calendar.")

    assert has_element?(
             view,
             "a[download='booking.ics'][href^='data:text/calendar']",
             "Add to my calendar"
           )

    [receipt] = BookingLinks.receipts(scope)
    assert receipt.event_id
    refute receipt.meeting_id
    view |> element("button", "Book another time") |> render_click()
    assert has_element?(view, "[data-step=pick]")
  end

  test "guest form shows the v4 errors before booking", %{conn: conn, link: link} do
    {:ok, view, _} = live(conn, "/book/#{link.token}")

    if link.start_date.month == Date.utc_today().month,
      do: :ok,
      else: render_click(view, "month", %{"direction" => "next"})

    pick(view, link.start_date)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    choose(view, slot)
    assert has_element?(view, "#g-e-hint", "Only used to send you a confirmation.")

    view |> form("#public-booking-form", guest: %{"name" => ""}) |> render_submit()
    assert has_element?(view, "#g-n-err", "Add your name.")
    assert has_element?(view, "#g-n[aria-invalid=true]")

    view
    |> form("#public-booking-form", guest: %{"name" => "Guest", "email" => "not-an-email"})
    |> render_submit()

    assert has_element?(view, "#g-e-err", "That email doesn’t look right.")
    view |> element(".cal-guest-chosen button", "Change") |> render_click()
    assert has_element?(view, "[data-step=pick]")
  end

  test "unknown external coverage and revoked tokens never offer slots", %{
    conn: conn,
    scope: scope,
    link: link
  } do
    Repo.insert!(%Platform.Calendar.Subscription{
      owner_id: scope.actor.id,
      name: "Unrefreshed",
      url: "https://example.com/feed.ics"
    })

    {:ok, view, html} = live(conn, "/book/#{link.token}")
    assert html =~ "Availability cannot be confirmed"
    refute has_element?(view, "[data-step=pick] button.cal-open")
    refute has_element?(view, "#public-booking-form")
    {:ok, _} = BookingLinks.revoke(scope, link.id)
    {:ok, _, html} = live(conn, "/book/#{link.token}")
    assert html =~ "Availability cannot be confirmed"
  end

  test "owner renames and revokes links on the v4 page; failed delivery is visible", %{
    auth: conn,
    link: link,
    scope: scope
  } do
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)

    {:ok, receipt} =
      BookingLinks.book(
        link.token,
        %{"name" => "Guest", "starts_at" => DateTime.to_iso8601(slot.starts_at)},
        "booking-ui-receipt-key"
      )

    Repo.update!(Ecto.Changeset.change(receipt, delivery_error: "mail unavailable"))
    {:ok, view, html} = live(conn, "/calendar/booking")
    assert html =~ "Guest email delivery failed"
    assert has_element?(view, "h2", "Booking links")

    assert has_element?(
             view,
             ".cal-sub",
             "People outside Burrow pick a time; it lands on your calendar."
           )

    assert has_element?(view, ".cal-linkcard[aria-current=true]", "Private owner policy")
    assert has_element?(view, ".cal-linkcard small", "30 min · 1 day a week")
    assert has_element?(view, ".cal-linkcard small", "/book/#{link.token}")

    assert has_element?(
             view,
             "[data-role=calendar-list-pane] a[aria-current=true]",
             "Booking links"
           )

    view |> element("form[phx-change=rename]") |> render_change(%{"title" => "Revised policy"})
    assert Enum.any?(BookingLinks.list(scope), &(&1.title == "Revised policy"))
    view |> element("button", "Revoke link") |> render_click()
    assert [%{revoked_at: %DateTime{}}] = BookingLinks.list(scope)
    refute has_element?(view, ".cal-linkcard")
  end

  test "new link, length, buffers, notice and windows persist from the v4 editor", %{
    auth: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, "/calendar/booking")
    view |> element("button", "New link") |> render_click()
    assert render(view) =~ "Link created"
    new = Enum.find(BookingLinks.list(scope), &(&1.title == "Untitled link"))
    assert new.minimum_notice_minutes == 240
    assert length(new.windows) == 5
    assert has_element?(view, ".cal-linkcard[aria-current=true]", "Untitled link")
    assert has_element?(view, ".cal-linkcard small", "30 min · 5 days a week")

    for {field, value} <- [
          {"duration_minutes", 45},
          {"buffer_before_minutes", 10},
          {"buffer_after_minutes", 15},
          {"minimum_notice_minutes", 1440}
        ] do
      view
      |> element("button.cal-seg[phx-value-field=#{field}][phx-value-value='#{value}']")
      |> render_click()

      assert has_element?(
               view,
               "button.cal-seg[phx-value-field=#{field}][phx-value-value='#{value}'][aria-pressed=true]"
             )
    end

    # Saturday on, a second Monday window, then remove it; Friday off.
    view |> element("button[aria-label='Saturday available']") |> render_click()
    view |> element("[data-day='1'] button", "Window") |> render_click()

    view
    |> element("#booking-win-1-1")
    |> render_change(%{"day" => "1", "index" => "1", "start" => "12:00", "end" => "11:00"})

    link = Enum.find(BookingLinks.list(scope), &(&1.id == new.id))
    assert %{"weekday" => 1, "start" => "12:00", "end" => "12:30"} in link.windows

    view
    |> element("[data-day='1'] button[phx-value-index='1'][aria-label='Remove window']")
    |> render_click()

    view |> element("button[aria-label='Friday available']") |> render_click()
    assert has_element?(view, "[data-day='5']", "Unavailable")

    link = Enum.find(BookingLinks.list(scope), &(&1.id == new.id))
    assert link.duration_minutes == 45
    assert link.buffer_before_minutes == 10
    assert link.buffer_after_minutes == 15
    assert link.minimum_notice_minutes == 1440

    assert Enum.sort_by(link.windows, & &1["weekday"]) ==
             for(
               day <- [1, 2, 3, 4, 6],
               do: %{"weekday" => day, "start" => "09:00", "end" => "17:00"}
             )

    assert has_element?(
             view,
             "[data-role=booking-preview]",
             "Next open slots (what a guest sees)"
           )
  end

  test "the slot preview lists the next open days, or the v4 empty hint", %{
    auth: conn,
    scope: scope,
    link: link
  } do
    {:ok, _} =
      BookingLinks.update(scope, link.id, %{
        start_date: Date.utc_today(),
        end_date: Date.add(Date.utc_today(), 30),
        windows: for(day <- 1..7, do: %{"weekday" => day, "start" => "00:00", "end" => "23:30"})
      })

    {:ok, view, _} = live(conn, "/calendar/booking")
    assert has_element?(view, "[data-role=booking-preview] .cal-slots span", "+")

    {:ok, _} =
      BookingLinks.update(scope, link.id, %{
        start_date: Date.add(Date.utc_today(), 60),
        end_date: Date.add(Date.utc_today(), 61)
      })

    {:ok, view, _} = live(conn, "/calendar/booking")

    assert has_element?(
             view,
             "[data-role=booking-preview]",
             "No open slots in the next two weeks. Widen a window."
           )
  end

  test "public booking HTTP attempts are bounded before token lookup", %{conn: conn} do
    ip = {192, 0, 2, 91}
    :ok = Platform.Calendar.BookingRateLimit.check({:ip, ip}, 60, 60)
    conn = %{conn | remote_ip: ip} |> get("/book/not-a-valid-token")
    assert response(conn, 429) =~ "Too many requests"
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "UTC+14 date picker and slot selection use the same owner timezone", %{
    conn: conn,
    scope: scope,
    link: link
  } do
    {:ok, link} =
      BookingLinks.update(scope, link.id, %{
        time_zone: "Pacific/Kiritimati",
        windows: [
          %{"weekday" => Date.day_of_week(link.start_date), "start" => "00:00", "end" => "01:00"}
        ]
      })

    {:ok, view, _} = live(conn, "/book/#{link.token}")
    assert has_element?(view, ".cal-guest-ln", "Pacific/Kiritimati")
    today = DateTime.utc_now() |> DateTime.shift_zone!("Pacific/Kiritimati") |> DateTime.to_date()

    if link.start_date.month == today.month,
      do: :ok,
      else: render_click(view, "month", %{"direction" => "next"})

    pick(view, link.start_date)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    assert DateTime.to_date(slot.starts_at) == Date.add(link.start_date, -1)
    choose(view, slot)

    assert has_element?(
             view,
             ".cal-guest-chosen",
             PlatformWeb.PublicBookingLive.long_day(link.start_date) <> " · 00:00–00:30"
           )

    refute has_element?(view, "#g-e[aria-required=true]")
    view |> form("#public-booking-form", guest: %{"name" => "Island guest"}) |> render_submit()
    assert has_element?(view, ".cal-guest-box", "00:00–00:30 · Pacific/Kiritimati")
    [receipt] = BookingLinks.receipts(scope)
    assert DateTime.compare(receipt.starts_at, slot.starts_at) == :eq
  end

  test "meeting policy marks public email required before submission", %{
    conn: conn,
    scope: scope,
    link: link
  } do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Booking UI meetings",
        slug: "booking-ui-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, link} =
      BookingLinks.update(scope, link.id, %{create_meeting: true, project_id: project.id})

    {:ok, view, _} = live(conn, "/book/#{link.token}")
    assert has_element?(view, ".cal-guest-ln", "Burrow meeting, link sent by email")

    if link.start_date.month == Date.utc_today().month,
      do: :ok,
      else: render_click(view, "month", %{"direction" => "next"})

    pick(view, link.start_date)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    choose(view, slot)
    assert has_element?(view, "#g-e[aria-required=true]")
    assert has_element?(view, "#g-e-hint", "Required: we email you the Burrow meeting link.")
    view |> form("#public-booking-form", guest: %{"name" => "Guest"}) |> render_submit()

    assert has_element?(
             view,
             "#g-e-err",
             "Email is required for a meeting booking: the invite goes there."
           )

    assert [] == BookingLinks.receipts(scope)
  end

  test "the booking page's list pane and section tabs lead back to Calendar", %{auth: conn} do
    {:ok, view, _} = live(conn, "/calendar/booking")

    assert has_element?(
             view,
             "[data-role=calendar-section-tabs] a[aria-current=page]",
             "Booking links"
           )

    assert has_element?(view, "[data-role=calendar-list-pane] a[href='/calendar/settings']")

    assert {:error, {:live_redirect, %{to: "/calendar?new=1"}}} =
             view |> element("#calendar-new") |> render_click()

    {:ok, calendar, _} = live(conn, "/calendar?new=1")
    assert has_element?(calendar, "#calendar-editor h2", "New event")
  end

  test "Meetings disabled hides the meeting option and its card suffix", %{auth: conn} do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, false)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)
    {:ok, view, _} = live(conn, "/calendar/booking")
    refute has_element?(view, "[data-role=booking-meeting-option]")
    refute render(view) =~ "with Burrow meeting"
  end

  test "Meetings enabled shows the meeting option and toggles it", %{
    auth: conn,
    scope: scope,
    link: link
  } do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)

    Repo.insert!(%Platform.Tasks.Project{
      name: "Booking UI meetings",
      slug: "booking-ui-project-#{System.unique_integer([:positive])}",
      org_id: Platform.TenancyFixtures.acme_org_id()
    })

    {:ok, view, _} = live(conn, "/calendar/booking")

    assert has_element?(
             view,
             "[data-role=booking-meeting-option]",
             "Also create a Burrow meeting"
           )

    view |> element("button[aria-label='Also create a Burrow meeting']") |> render_click()
    assert render(view) =~ "Bookings will create a Burrow meeting"
    assert Enum.find(BookingLinks.list(scope), &(&1.id == link.id)).create_meeting

    assert has_element?(
             view,
             ".cal-linkcard small",
             "30 min · 1 day a week · with Burrow meeting"
           )
  end
end
