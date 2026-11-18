defmodule PlatformWeb.BookingLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.BookingLinks
  alias Platform.Access.Scope

  doctest PlatformWeb.PublicBookingLive

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
    # The page has no app shell (layout: false), so its root is its own
    # scroll container (app.css `.cal-guest-wrap`, task 01a1eff0 stage 3).
    assert has_element?(view, "main.cal-guest-wrap[data-page=public-booking]")
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
      |> element("button.cal-seg[phx-value-field=#{field}][phx-value-minutes='#{value}']")
      |> render_click()

      assert has_element?(
               view,
               "button.cal-seg[phx-value-field=#{field}][phx-value-minutes='#{value}'][aria-pressed=true]"
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

  # The browser's click payload, not LiveViewTest's. LiveView's JS
  # (`View.extractMeta`, phoenix_live_view view.js) copies every
  # `phx-value-*` attribute and THEN sets `meta.value = el.value` for any
  # element with a `.value` property. A <button> without a `value` attribute
  # has `.value == ""`, so a `phx-value-value` on a button is always
  # overwritten with "" in a real browser. LiveViewTest only sends `value`
  # when the attribute is present, so this passes the element's real
  # `.value` explicitly: the attribute, or "" without one.
  defp browser_click(view, selector, text) do
    el = element(view, selector, ~r/^\s*#{Regex.escape(text)}\s*$/)

    dom_value =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.find(&(&1 |> LazyHTML.text() |> String.trim() == text))
      |> LazyHTML.attribute("value")
      |> List.first()

    render_click(el, %{"value" => dom_value || ""})
  end

  test "every Length, Buffer and Minimum notice button saves its value on a browser click", %{
    auth: conn,
    scope: scope,
    link: link
  } do
    {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")

    cases = [
      {"duration_minutes",
       [{"15 min", 15}, {"45 min", 45}, {"60 min", 60}, {"90 min", 90}, {"30 min", 30}]},
      {"buffer_before_minutes",
       [{"5 min", 5}, {"10 min", 10}, {"15 min", 15}, {"30 min", 30}, {"None", 0}]},
      {"buffer_after_minutes",
       [{"5 min", 5}, {"10 min", 10}, {"15 min", 15}, {"30 min", 30}, {"None", 0}]},
      {"minimum_notice_minutes",
       [{"2 hours", 120}, {"1 day", 1440}, {"2 days", 2880}, {"4 hours", 240}]}
    ]

    for {field, buttons} <- cases, {label, minutes} <- buttons do
      browser_click(view, "button.cal-seg[phx-value-field=#{field}]", label)
      saved = Enum.find(BookingLinks.list(scope), &(&1.id == link.id))

      assert Map.fetch!(saved, String.to_existing_atom(field)) == minutes,
             "#{field} #{label}: saved #{inspect(Map.fetch!(saved, String.to_existing_atom(field)))}"
    end
  end

  test "an empty or unoffered seg value is an error, not a silent no-op", %{
    auth: conn,
    scope: scope,
    link: link
  } do
    {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")

    for params <- [
          %{"field" => "duration_minutes", "minutes" => ""},
          %{"field" => "duration_minutes"},
          %{"field" => "buffer_after_minutes", "minutes" => "7"},
          %{"field" => "minimum_notice_minutes", "minutes" => "soon"}
        ] do
      html = render_click(view, "set", params)
      assert html =~ "that choice is not one of the options.", inspect(params)
    end

    assert %{duration_minutes: 30, buffer_after_minutes: 0, minimum_notice_minutes: 0} =
             Enum.find(BookingLinks.list(scope), &(&1.id == link.id))
  end

  describe "bookable dates" do
    defp stored_range(link) do
      row = Repo.get!(Platform.Calendar.BookingLink, link.id)
      {row.start_date, row.end_date}
    end

    test "start and end on the same day persist from the dates form", %{auth: conn, link: link} do
      today = Date.utc_today()
      {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")

      html =
        view
        |> element("#booking-link-dates")
        |> render_change(%{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(today)
        })

      assert html =~ "Bookable dates saved"
      assert stored_range(link) == {today, today}
      assert has_element?(view, "#booking-link-start-date[value='#{today}']")
      assert has_element?(view, "#booking-link-end-date[value='#{today}']")
    end

    # A browser change event can carry only the input that changed.
    test "a payload with only end_date saves it and keeps the stored start", %{
      auth: conn,
      link: link
    } do
      {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")
      last = Date.add(link.start_date, 3)

      assert render_change(view, "dates", %{"end_date" => Date.to_iso8601(last)}) =~
               "Bookable dates saved"

      assert stored_range(link) == {link.start_date, last}

      first = Date.add(link.start_date, 1)
      render_change(view, "dates", %{"_target" => ["start_date"], "start_date" => "#{first}"})
      assert stored_range(link) == {first, last}
    end

    test "an end before the start is an error and leaves the row unchanged", %{
      auth: conn,
      link: link
    } do
      {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")
      before = stored_range(link)

      html =
        view
        |> element("#booking-link-dates")
        |> render_change(%{"end_date" => Date.to_iso8601(Date.add(link.start_date, -1))})

      assert html =~ "Until must be on or after Bookable from."
      refute html =~ "Bookable dates saved"
      assert stored_range(link) == before
    end

    test "a blank date is an error and leaves the row unchanged", %{auth: conn, link: link} do
      {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")
      before = stored_range(link)

      html = view |> element("#booking-link-dates") |> render_change(%{"end_date" => ""})
      assert html =~ "Until needs a date."
      assert stored_range(link) == before

      assert render_change(view, "dates", %{"start_date" => "  "}) =~
               "Bookable from needs a date."

      assert stored_range(link) == before
    end

    test "the link card shows the stored range, and a one-day range by name", %{
      auth: conn,
      link: link
    } do
      {:ok, view, _} = live(conn, "/calendar/booking?link=#{link.id}")
      first = link.start_date
      last = link.end_date

      range =
        Elixir.Calendar.strftime(first, "%-d %b") <>
          " – " <>
          Elixir.Calendar.strftime(last, "%-d %b %Y")

      assert has_element?(view, ".cal-linkcard small", "30 min · 1 day a week · " <> range)

      view
      |> element("#booking-link-dates")
      |> render_change(%{"start_date" => "#{first}", "end_date" => "#{first}"})

      one_day = Elixir.Calendar.strftime(first, "%a %-d %b") <> " only"
      assert has_element?(view, ".cal-linkcard small", "30 min · 1 day a week · " <> one_day)
    end
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

  describe "co-hosts in booking settings (task 01a1eff0-6880 stage 3)" do
    alias Platform.Calendar.BookingHosts
    alias Platform.Tenancy.OrgMembership

    defp host_user!(name, org_id, extra \\ %{}) do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%Platform.Accounts.User{
          email: "booking-cohost-#{n}@example.com",
          name: name,
          oidc_sub: "booking-cohost-#{n}"
        })

      if org_id,
        do:
          Repo.insert!(
            struct(%OrgMembership{user_id: user.id, org_id: org_id, role: "member"}, extra)
          )

      user
    end

    defp as(user), do: init_test_session(build_conn(), current_user_id: user.id)

    defp hosts_scope(user), do: Scope.for_user(Repo.get!(Platform.Accounts.User, user.id))

    setup do
      n = System.unique_integer([:positive])
      org = Platform.TenancyFixtures.tenant_org_id("booking_cohosts_ui_#{n}")
      other_org = Platform.TenancyFixtures.tenant_org_id("booking_cohosts_other_#{n}")
      ryan = host_user!("Ryan Milvenan", org)
      jordan = host_user!("Jordan Quill", org)
      nathan = host_user!("Nathan Quill", org)
      outsider = host_user!("Outside Quill", other_org)
      external = host_user!("Guest Quill", org, %{external: true})
      date = Date.add(Date.utc_today(), 7)

      {:ok, link} =
        BookingLinks.create(hosts_scope(ryan), %{
          title: "Intro call",
          time_zone: "Etc/UTC",
          duration_minutes: 30,
          start_date: date,
          end_date: Date.add(date, 7),
          windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]
        })

      %{
        ryan: ryan,
        jordan: jordan,
        nathan: nathan,
        outsider: outsider,
        external: external,
        shared: link
      }
    end

    test "a single-owner link shows the owner row and renders no blocked strip", ctx do
      {:ok, view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")

      assert has_element?(
               view,
               "[data-role=booking-editor] [data-role=booking-hosts] h3",
               "Hosts"
             )

      assert has_element?(view, "[data-role=booking-host-owner]", "You (owner)")
      assert has_element?(view, "[data-role=booking-host-owner]", "Owner")
      refute has_element?(view, "[data-role=booking-host-row]")
      refute has_element?(view, "[data-role=booking-hosts-blocked]")
      refute has_element?(view, "[data-role=booking-cohosted]")
    end

    test "+ Add co-host invites from the picker; the row shows Pending (info) and the strip",
         ctx do
      {:ok, view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")

      view |> element("[data-role=booking-host-add]", "+ Add co-host") |> render_click()
      assert has_element?(view, "[data-role=booking-host-picker] input[name=q]")
      view |> form("#booking-host-search", %{"q" => "Jordan"}) |> render_change()

      view
      |> element("[data-role=booking-host-candidate][phx-value-user='#{ctx.jordan.id}']")
      |> render_click()

      assert [%{status: "pending", user_id: user_id}] = BookingHosts.list_for_link(ctx.shared)
      assert user_id == ctx.jordan.id
      refute has_element?(view, "[data-role=booking-host-picker]")

      assert has_element?(view, "[data-role=booking-host-row]", "Jordan Quill")
      assert has_element?(view, "[data-role=booking-host-row] .badge.badge-info", "Pending")
      assert has_element?(view, "[data-role=booking-host-row] button", "Remove")

      assert has_element?(
               view,
               "[data-role=booking-hosts-blocked]",
               "Not offering times until Jordan accepts"
             )

      # Two pending co-hosts are both named, first names only.
      view |> element("[data-role=booking-host-add]") |> render_click()
      view |> form("#booking-host-search", %{"q" => "Nathan"}) |> render_change()

      view
      |> element("[data-role=booking-host-candidate][phx-value-user='#{ctx.nathan.id}']")
      |> render_click()

      assert has_element?(
               view,
               "[data-role=booking-hosts-blocked]",
               "Not offering times until Jordan and Nathan accept"
             )
    end

    test "the picker offers org members only: never a non-org user, an external member, the owner or an existing co-host",
         ctx do
      {:ok, view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")
      view |> element("[data-role=booking-host-add]") |> render_click()
      html = view |> form("#booking-host-search", %{"q" => "Quill"}) |> render_change()

      assert has_element?(
               view,
               "[data-role=booking-host-candidate][phx-value-user='#{ctx.jordan.id}']"
             )

      refute html =~ "Outside Quill"
      refute html =~ "Guest Quill"
      refute has_element?(view, "[phx-value-user='#{ctx.outsider.id}']")
      refute has_element?(view, "[phx-value-user='#{ctx.external.id}']")

      view |> form("#booking-host-search", %{"q" => "Ryan"}) |> render_change()
      refute has_element?(view, "[phx-value-user='#{ctx.ryan.id}']")

      {:ok, _} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.shared.id, ctx.jordan.id)

      assert [%{id: id}] =
               BookingHosts.search_candidates(hosts_scope(ctx.ryan), "Quill",
                 link_id: ctx.shared.id
               )

      assert id == ctx.nathan.id
    end

    test "Accept on the invite card clears the Pending badge and the strip on the owner's open page",
         ctx do
      {:ok, host} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.shared.id, ctx.jordan.id)
      {:ok, owner_view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")
      assert has_element?(owner_view, "[data-role=booking-host-row] .badge-info", "Pending")
      assert has_element?(owner_view, "[data-role=booking-hosts-blocked]")

      {:ok, view, _} = live(as(ctx.jordan), "/calendar/booking?cohost=#{host.id}")

      assert has_element?(
               view,
               "[data-role=booking-cohost-invite]",
               "Your free/busy times will be used to offer slots on Ryan's link. Guests never see your calendar."
             )

      assert has_element?(view, "[data-role=booking-cohost-invite] button.bg-primary", "Accept")
      assert has_element?(view, "[data-role=booking-cohost-invite] button", "Decline")

      view |> element("[data-role=booking-cohost-invite] button", "Accept") |> render_click()
      refute has_element?(view, "[data-role=booking-cohost-invite]")

      assert has_element?(
               view,
               "[data-role=booking-cohosted-row][data-status=accepted]",
               "Intro call"
             )

      # The owner's page hears it over PubSub, no reload.
      assert has_element?(owner_view, "[data-role=booking-host-row][data-status=accepted]")
      refute has_element?(owner_view, "[data-role=booking-host-row] .badge", "Pending")
      refute has_element?(owner_view, "[data-role=booking-hosts-blocked]")
    end

    test "Leave from Links you co-host brings the strip back with Left; Remove clears it", ctx do
      {:ok, host} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.shared.id, ctx.jordan.id)
      {:ok, _} = BookingHosts.accept(hosts_scope(ctx.jordan), host.id)
      {:ok, owner_view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")
      refute has_element?(owner_view, "[data-role=booking-hosts-blocked]")

      {:ok, view, _} = live(as(ctx.jordan), "/calendar/booking")
      assert has_element?(view, "[data-role=booking-cohosted] h3", "Links you co-host")
      assert has_element?(view, "[data-role=booking-cohosted-row]", "Ryan Milvenan’s link")
      view |> element("[data-role=booking-cohosted-row] button", "Leave") |> render_click()
      assert Repo.get!(Platform.Calendar.BookingLinkHost, host.id).status == "left"
      refute has_element?(view, "[data-role=booking-cohosted]")

      assert has_element?(owner_view, "[data-role=booking-host-row] .badge-neutral", "Left")
      assert has_element?(owner_view, "[data-role=booking-host-row] button", "Invite again")

      assert has_element?(
               owner_view,
               "[data-role=booking-hosts-blocked]",
               "Not offering times until you remove or re-invite Jordan"
             )

      owner_view |> element("[data-role=booking-host-row] button", "Remove") |> render_click()
      refute has_element?(owner_view, "[data-role=booking-host-row]")
      refute has_element?(owner_view, "[data-role=booking-hosts-blocked]")
      assert BookingHosts.list_for_link(ctx.shared) == []
    end

    test "Decline from the invite card leaves the owner a Declined row and the D2 strip", ctx do
      {:ok, host} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.shared.id, ctx.jordan.id)
      {:ok, view, _} = live(as(ctx.jordan), "/calendar/booking?cohost=#{host.id}")
      view |> element("[data-role=booking-cohost-invite] button", "Decline") |> render_click()
      refute has_element?(view, "[data-role=booking-cohost-invite]")

      {:ok, owner_view, _} = live(as(ctx.ryan), "/calendar/booking?link=#{ctx.shared.id}")
      assert has_element?(owner_view, "[data-role=booking-host-row] .badge-neutral", "Declined")

      owner_view
      |> element("[data-role=booking-host-row] button", "Invite again")
      |> render_click()

      assert has_element?(owner_view, "[data-role=booking-host-row] .badge-info", "Pending")

      assert has_element?(
               owner_view,
               "[data-role=booking-hosts-blocked]",
               "Not offering times until Jordan accepts"
             )
    end

    test "an invite card for someone else's invite is not shown", ctx do
      {:ok, host} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.shared.id, ctx.jordan.id)
      {:ok, view, _} = live(as(ctx.nathan), "/calendar/booking?cohost=#{host.id}")
      refute has_element?(view, "[data-role=booking-cohost-invite]")
    end
  end

  describe "shared links on the public page (task 01a1eff0-6880 stage 4)" do
    alias Platform.Calendar.BookingHosts

    setup do
      n = System.unique_integer([:positive])
      org = Platform.TenancyFixtures.tenant_org_id("booking_shared_public_#{n}")
      ryan = host_user!("Ryan Milvenan", org)
      jordan = host_user!("Jordan Coombs", org)
      nathan = host_user!("Nathan Quill", org)
      date = Date.add(Date.utc_today(), 7)

      {:ok, link} =
        BookingLinks.create(hosts_scope(ryan), %{
          title: "Intro call",
          time_zone: "Etc/UTC",
          duration_minutes: 30,
          start_date: date,
          end_date: Date.add(date, 7),
          windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]
        })

      {:ok, host} = BookingHosts.invite(hosts_scope(ryan), link.id, jordan.id)
      {:ok, _} = BookingHosts.accept(hosts_scope(jordan), host.id)
      %{ryan: ryan, jordan: jordan, nathan: nathan, link: link, date: date}
    end

    defp to_month(view, date) do
      if date.month == Date.utc_today().month,
        do: :ok,
        else: render_click(view, "month", %{"direction" => "next"})
    end

    defp busy!(user, from, to, title) do
      {:ok, _} =
        Calendar.create_event(hosts_scope(user), %{title: title, starts_at: from, ends_at: to})
    end

    defp add_accepted!(ctx, user) do
      {:ok, host} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.link.id, user.id)
      {:ok, _} = BookingHosts.accept(hosts_scope(user), host.id)
    end

    test "two hosts: one host row under the title, Ryan & Jordan, with the org", ctx do
      {:ok, view, html} = live(build_conn(), "/book/#{ctx.link.token}")
      assert has_element?(view, ".cal-guest-host h1", "Intro call")
      assert has_element?(view, ".cal-guest-host h1 + [data-role=booking-host-row]")
      assert has_element?(view, "[data-role=booking-host-row] .truncate", "Ryan & Jordan")
      assert has_element?(view, "[data-role=booking-host-row] .cal-guest-avatar.ring-base-100")

      assert length(
               Floki.find(
                 Floki.parse_document!(html),
                 "[data-role=booking-host-row] .cal-guest-avatar"
               )
             ) == 2

      # The single-owner avatar and name line are not rendered beside it.
      refute has_element?(view, ".cal-guest-host > .cal-guest-avatar")
      refute has_element?(view, ".cal-guest-host > .cal-guest-who")

      assert has_element?(
               view,
               ".cal-hint",
               "Busy time on everyone's calendars is already taken out."
             )
    end

    test "three hosts read Ryan, Jordan & 1 other", ctx do
      add_accepted!(ctx, ctx.nathan)
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      assert has_element?(view, "[data-role=booking-host-row]", "Ryan, Jordan & 1 other")
      refute has_element?(view, "[data-role=booking-host-row]", "Nathan")
    end

    test "the Book button names the time and the hosts; the notes label asks both", ctx do
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      to_month(view, ctx.date)
      pick(view, ctx.date)
      {:ok, [slot | _]} = BookingLinks.slots(ctx.link.token, ctx.date)
      choose(view, slot)

      assert has_element?(
               view,
               "#public-booking-form button[type=submit][aria-label='Book 09:00 with Ryan & Jordan']"
             )

      assert has_element?(
               view,
               "#public-booking-form button .shrink-0.whitespace-nowrap",
               "Book 09:00"
             )

      assert has_element?(
               view,
               "#public-booking-form button .min-w-0.truncate",
               "with Ryan & Jordan"
             )

      refute has_element?(view, "#public-booking-form button", "Confirm booking")
      assert has_element?(view, ".cal-field", "Anything Ryan & Jordan should know?")
    end

    test "a month with no shared free time shows the everyone empty state, never a busy name",
         ctx do
      from = DateTime.new!(ctx.date, ~T[00:00:00])
      busy!(ctx.jordan, from, DateTime.add(from, 9 * 86_400, :second), "Offsite")
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      to_month(view, ctx.date)

      assert has_element?(
               view,
               "[data-role=booking-empty]",
               "No times when everyone is free in this range."
             )

      refute render(view) =~ ~r/Jordan is busy|Ryan is busy/
    end

    test "a month with an open day shows no empty state", ctx do
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      to_month(view, ctx.date)
      refute has_element?(view, "[data-role=booking-empty]")
    end

    test "a pending co-host closes the link with no host name and no title", ctx do
      {:ok, _} = BookingHosts.invite(hosts_scope(ctx.ryan), ctx.link.id, ctx.nathan.id)
      {:ok, view, html} = live(build_conn(), "/book/#{ctx.link.token}")

      assert has_element?(
               view,
               ".cal-guest-card-empty [role=alert]",
               "This link isn't taking bookings right now."
             )

      for word <- ["Nathan", "Jordan", "Ryan", "Intro call", "Availability cannot be confirmed"],
          do: refute(html =~ word)

      refute has_element?(view, "[data-role=booking-host-row]")
    end

    test "the confirmation lists every host and the .ics names them", ctx do
      add_accepted!(ctx, ctx.nathan)
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      to_month(view, ctx.date)
      pick(view, ctx.date)
      {:ok, [slot | _]} = BookingLinks.slots(ctx.link.token, ctx.date)
      choose(view, slot)
      view |> form("#public-booking-form", guest: %{"name" => "Guest"}) |> render_submit()

      assert has_element?(
               view,
               ".cal-guest-done p",
               "Booked with Ryan Milvenan, Jordan Coombs and Nathan Quill"
             )

      assert has_element?(
               view,
               ".cal-guest-done",
               "Ryan, Jordan and Nathan have it on their calendars."
             )

      [href] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("a[download='booking.ics']", "href")

      assert URI.decode(href) =~ "SUMMARY:Intro call with Ryan\\, Jordan & 1 other"
    end

    test "two-host confirmation: Booked with Ryan Milvenan and Jordan Coombs", ctx do
      {:ok, view, _} = live(build_conn(), "/book/#{ctx.link.token}")
      to_month(view, ctx.date)
      pick(view, ctx.date)
      {:ok, [slot | _]} = BookingLinks.slots(ctx.link.token, ctx.date)
      choose(view, slot)
      view |> form("#public-booking-form", guest: %{"name" => "Guest"}) |> render_submit()

      assert has_element?(
               view,
               ".cal-guest-done p",
               "Booked with Ryan Milvenan and Jordan Coombs"
             )

      assert has_element?(view, ".cal-guest-done", "Ryan and Jordan have it on their calendars.")
    end

    test "no attribution: with Jordan busy, neither the HTML nor any diff names whose time it is",
         ctx do
      at = DateTime.new!(ctx.date, ~T[09:00:00])
      busy!(ctx.jordan, at, DateTime.add(at, 3600, :second), "Jordan dentist appointment")

      busy!(
        ctx.ryan,
        DateTime.add(at, 7200, :second),
        DateTime.add(at, 9000, :second),
        "Ryan quarterly review"
      )

      secrets = [
        ctx.jordan.email,
        ctx.jordan.id,
        ctx.ryan.email,
        ctx.ryan.id,
        "dentist",
        "quarterly"
      ]

      hint = "Busy time on everyone's calendars is already taken out."

      # Every leak found in `text`, as a list, so a failure names it.
      leaks = fn text ->
        # The hint as written and as HTML-escaped (a LiveView render
        # escapes the apostrophe).
        text = String.replace(text, [hint, String.replace(hint, "'", "&#39;")], "")
        words = Regex.scan(~r/.{0,40}(?:busy|blocked).{0,40}/is, text) |> List.flatten()
        Enum.filter(secrets, &String.contains?(text, &1)) ++ words
      end

      dead = build_conn() |> get("/book/#{ctx.link.token}") |> html_response(200)
      assert dead =~ hint
      assert [] == leaks.(dead)

      {:ok, view, html} = live(build_conn(), "/book/#{ctx.link.token}")
      assert [] == leaks.(html)
      :erlang.trace(view.pid, true, [:send])

      to_month(view, ctx.date)
      pick(view, ctx.date)
      {:ok, slots} = BookingLinks.slots(ctx.link.token, ctx.date)

      assert Enum.map(slots, &(&1.starts_at |> DateTime.to_time() |> Time.truncate(:second))) == [
               ~T[10:00:00],
               ~T[10:30:00],
               ~T[11:30:00]
             ]

      refute has_element?(view, ".cal-guest-slot", "09:00")
      picked = render(view)
      assert [] == leaks.(picked)

      # Slot buttons carry only phx-value-start; no data-* on them at all.
      for button <- Floki.find(Floki.parse_document!(picked), ".cal-guest-slot"),
          {name, _} <- elem(button, 1),
          do: refute(String.starts_with?(name, "data-"), "slot button carries #{name}")

      choose(view, hd(slots))
      assert [] == leaks.(render(view))
      view |> form("#public-booking-form", guest: %{"name" => "Guest"}) |> render_submit()
      assert has_element?(view, ".cal-guest-done")
      assert [] == leaks.(render(view))
      :erlang.trace(view.pid, false, [:send])

      # Every push and reply the LiveView sent its client after mount.
      diffs =
        view.pid
        |> collect_sends([])
        |> Enum.filter(
          &(match?(%Phoenix.Socket.Message{}, &1) or match?(%Phoenix.Socket.Reply{}, &1))
        )

      assert Enum.any?(diffs, &(inspect(&1, limit: :infinity) =~ "Booked with")),
             "the trace caught no diff: the check below would be vacuous"

      for diff <- diffs,
          do: assert([] == leaks.(inspect(diff, limit: :infinity, printable_limit: :infinity)))
    end

    defp collect_sends(pid, acc) do
      receive do
        {:trace, ^pid, :send, msg, _to} -> collect_sends(pid, [msg | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end
  end

  test "a single-owner page keeps its one-host copy", %{conn: conn, link: link} do
    {:ok, view, html} = live(conn, "/book/#{link.token}")
    assert has_element?(view, ".cal-guest-host > .cal-guest-avatar", "B")
    assert has_element?(view, ".cal-guest-host > .cal-guest-who", "Booking owner")
    assert html =~ "Busy time on Booking’s calendars is already taken out."
    refute html =~ "everyone"
    refute has_element?(view, "[data-role=booking-host-row]")

    if link.start_date.month == Date.utc_today().month,
      do: :ok,
      else: render_click(view, "month", %{"direction" => "next"})

    refute has_element?(view, "[data-role=booking-empty]")
    pick(view, link.start_date)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    choose(view, slot)
    assert has_element?(view, "#public-booking-form button[type=submit]", "Confirm booking")
    assert has_element?(view, ".cal-field", "Anything Booking should know?")
    refute has_element?(view, "#public-booking-form button[aria-label]")
  end
end
