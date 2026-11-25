defmodule PlatformWeb.CalendarMobileLiveTest do
  @moduledoc """
  The phone calendar (canvas 01a2111c, "Calendar on a phone"): below `lg`
  the page is two rows of controls, then the agenda or the Day view. The
  breakpoint itself is CSS; these tests drive the phone markup, which is
  always rendered (`lg:hidden`), through its events.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Calendar, Repo}
  alias Platform.Access.Scope
  alias PlatformWeb.CalendarLive.Agenda

  @zone "Etc/UTC"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "calendar-mobile-#{n}@example.com",
        name: "Phone user",
        oidc_sub: "calendar-mobile-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    conn =
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => @zone})

    %{conn: conn, scope: Scope.for_user(user), today: today()}
  end

  defp today, do: DateTime.utc_now() |> DateTime.to_date()

  defp at(date, hour, minute \\ 0), do: DateTime.new!(date, Time.new!(hour, minute, 0), @zone)

  defp event!(scope, date, hour, minutes, title, opts \\ []) do
    {minute, opts} = Keyword.pop(opts, :minute, 0)
    starts = at(date, hour, minute)

    {:ok, event} =
      Calendar.create_event(
        scope,
        Map.merge(
          %{
            title: title,
            starts_at: starts,
            ends_at: DateTime.add(starts, minutes * 60),
            time_zone: @zone
          },
          Map.new(opts)
        )
      )

    event
  end

  defp all_day!(scope, first, days, title) do
    {:ok, event} =
      Calendar.create_event(scope, %{
        title: title,
        all_day: true,
        start_date: first,
        end_date: Date.add(first, days),
        time_zone: @zone
      })

    event
  end

  describe "controls" do
    test "two rows: month, Agenda|Day, the calendar count and one [+]; then the week strip",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=m-row1] [data-role=m-month-button]",
               Elixir.Calendar.strftime(today, "%b %Y")
             )

      assert has_element?(
               view,
               "[data-role=m-view-switch] button[data-view=agenda][aria-selected=true]"
             )

      assert has_element?(
               view,
               "[data-role=m-view-switch] button[data-view=day][aria-selected=false]"
             )

      assert has_element?(view, "[data-role=m-calendars-button][aria-label='2 calendars shown']")

      assert [_] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("[data-role=m-new]")
               |> Enum.to_list()

      monday = Date.beginning_of_week(today)
      assert has_element?(view, "[data-role=m-strip][data-week='#{monday}']")

      assert has_element?(
               view,
               "[data-role=m-strip] button[aria-current=date][data-date='#{today}']"
             )

      # The old phone header, section chips and phone grids are gone.
      refute has_element?(view, "[data-role=calendar-phone-header]")
      refute has_element?(view, "[data-role=calendar-section-tabs]")
      refute has_element?(view, "[data-role=calendar-day-strip]")
      refute has_element?(view, "[data-role=calendar-month-phone]")
    end

    test "the strip's dots mark the days that have events", %{conn: conn, scope: scope} do
      today = today()
      event!(scope, today, 9, 30, "Standup")
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=m-strip] button[data-date='#{today}'] [data-role=m-strip-dot]"
             )

      empty = today |> PlatformWeb.CalendarLive.week_days() |> Enum.find(&(&1 != today))

      refute has_element?(
               view,
               "[data-role=m-strip] button[data-date='#{empty}'] [data-role=m-strip-dot]"
             )
    end
  end

  describe "agenda" do
    test "opens on today: its header, all-day and timed rows, and the timezone tag",
         %{conn: conn, scope: scope, today: today} do
      all_day!(scope, today, 1, "Ryan out")
      all_day!(scope, Date.add(today, -1), 3, "Offsite")
      event!(scope, today, 14, 60, "Ryan / Jordan sync", minute: 30)
      event!(scope, today, 9, 30, "Standup")

      {:ok, _} =
        Calendar.create_event(scope, %{
          title: "NY partner call",
          starts_at: at(today, 15),
          ends_at: at(today, 16),
          time_zone: "America/New_York"
        })

      {:ok, view, _} = live(conn, "/calendar")
      row = "#m_agenda-m-agenda-day-#{today}"

      assert has_element?(
               view,
               "#m-agenda #{row}[data-today=true] [data-role=m-agenda-day-header]",
               "Today"
             )

      assert has_element?(view, "#{row} [data-role=m-agenda-pinned]", "Ryan out")
      assert has_element?(view, "#{row} [data-role=m-agenda-pinned]", "Day 2 of 3")

      times =
        view
        |> element(row)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role=m-agenda-item]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> hd()))

      assert times == ["All", "All", "09:00", "14:30", "15:00"]
      assert has_element?(view, "#{row} [data-role=m-tz]", "EST")
    end

    test "a run of empty days collapses to one row; an empty today keeps its own",
         %{conn: conn, scope: scope, today: today} do
      event!(scope, Date.add(today, 4), 9, 30, "Later")
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "#m_agenda-m-agenda-day-#{today} [data-role=m-agenda-none]",
               "No events"
             )

      assert has_element?(
               view,
               "#m_agenda-m-agenda-empty-#{Date.add(today, 1)}[data-to='#{Date.add(today, 3)}']",
               "No events"
             )

      # No external calendar but an event: no connect card.
      refute has_element?(view, "[data-role=m-agenda-connect]")
    end

    test "no calendar connected and nothing scheduled shows the connect card", %{conn: conn} do
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=m-agenda-connect] a[href='/calendar/settings']",
               "Connect a calendar"
             )

      assert has_element?(view, "#m_agenda-m-agenda-day-#{today()} [data-role=m-agenda-none]")
    end

    test "scrolling near the top loads four more weeks above", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      first = Date.add(Date.beginning_of_week(today), -14)
      assert has_element?(view, "#m_agenda-m-agenda-empty-#{first}")

      render_hook(view, "m_agenda_more", %{"direction" => "earlier"})
      earlier = Date.add(first, -28)
      assert has_element?(view, "#m_agenda-m-agenda-empty-#{earlier}")
      # The run that started the list merged into the new one, not doubled.
      refute has_element?(view, "#m_agenda-m-agenda-empty-#{first}")
    end
  end

  describe "Today" do
    test "shows only while today is off screen, and brings it back", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "[data-role=m-today]")

      # The agenda hook reports the day at the top and today's visibility.
      ahead = Date.add(today, 14)

      render_hook(view, "m_agenda_focus", %{
        "date" => Date.to_iso8601(ahead),
        "today_visible" => false
      })

      assert has_element?(view, "[data-role=m-today]", "Today")

      assert has_element?(
               view,
               "[data-role=m-strip][data-week='#{Date.beginning_of_week(ahead)}']"
             )

      view |> element("[data-role=m-today]") |> render_click()
      assert_push_event(view, "m-agenda-scroll", %{date: date})
      assert date == Date.to_iso8601(today)
      refute has_element?(view, "[data-role=m-today]")

      assert has_element?(
               view,
               "[data-role=m-strip][data-week='#{Date.beginning_of_week(today)}']"
             )
    end

    test "in Day view it shows on any day but today", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()
      refute has_element?(view, "[data-role=m-today]")

      view |> element("[data-role=m-row1] button[aria-label='Previous day']") |> render_click()
      assert has_element?(view, "#m-day[data-day='#{Date.add(today, -1)}']")
      assert has_element?(view, "[data-role=m-today]")

      view |> element("[data-role=m-today]") |> render_click()
      assert has_element?(view, "#m-day[data-day='#{today}']")
      refute has_element?(view, "[data-role=m-today]")
    end
  end

  describe "Day view" do
    test "the toggle opens Day on today, with the now line; Agenda goes back",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "#m-day")
      refute has_element?(view, "#m-agenda.hidden")

      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()
      assert has_element?(view, "#m-day[data-day='#{today}'][data-swipe-event=m_step]")
      assert has_element?(view, "#m-day [data-role=m-now]")

      assert has_element?(
               view,
               "[data-role=m-view-switch] button[data-view=day][aria-selected=true]"
             )

      # The agenda stays mounted, hidden, so its scroll survives.
      assert has_element?(view, "#m-agenda.hidden")

      view |> element("[data-role=m-view-switch] button[data-view=agenda]") |> render_click()
      refute has_element?(view, "#m-day")
      assert_push_event(view, "m-agenda-scroll", %{date: _})
    end

    test "Day opens on the day the agenda was reading when today is off screen",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      ahead = Date.add(today, 9)

      render_hook(view, "m_agenda_focus", %{
        "date" => Date.to_iso8601(ahead),
        "today_visible" => false
      })

      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()
      assert has_element?(view, "#m-day[data-day='#{ahead}']")
      refute has_element?(view, "#m-day [data-role=m-now]")
    end

    test "overlaps sit at most two side by side, then +N lists the rest",
         %{conn: conn, scope: scope, today: today} do
      event!(scope, today, 11, 60, "Design review")
      event!(scope, today, 11, 45, "Customer call", minute: 15)
      event!(scope, today, 11, 60, "Hiring sync", minute: 30)
      event!(scope, today, 2, 30, "Night ops")

      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()

      chips = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#m-day .cal-ev")
      assert Enum.count(chips) == 3
      assert has_element?(view, "#m-day [data-role=m-day-more]", "+1")
      assert has_element?(view, "#m-day [data-role=m-day-more-list]", "Hiring sync")
      # 02:00 is outside the desktop's 07–21 grid; the Day view places it.
      assert has_element?(view, "#m-day .cal-ev[style*='top: 96.0px']", "Night ops")
    end

    test "a sideways swipe steps one day either way", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()
      render_hook(view, "m_step", %{"direction" => "next"})
      assert has_element?(view, "#m-day[data-day='#{Date.add(today, 1)}']")
      render_hook(view, "m_step", %{"direction" => "previous"})
      render_hook(view, "m_step", %{"direction" => "previous"})
      assert has_element?(view, "#m-day[data-day='#{Date.add(today, -1)}']")
    end
  end

  describe "week strip and month" do
    test "a strip swipe moves a week and the agenda follows", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      next = Date.add(Date.beginning_of_week(today), 7)
      render_hook(view, "m_strip_step", %{"direction" => "next"})
      assert has_element?(view, "[data-role=m-strip][data-week='#{next}']")
      assert_push_event(view, "m-agenda-scroll", %{date: date})
      assert date == Date.to_iso8601(next)
    end

    test "the month pushes open, and picking a far date moves the window there",
         %{conn: conn, scope: scope, today: today} do
      far = Date.add(today, 120)
      event!(scope, far, 10, 60, "Far away")
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "#m-month")

      view |> element("[data-role=m-month-button]") |> render_click()
      assert has_element?(view, "#m-month")
      assert has_element?(view, "[data-role=m-month-button][aria-expanded=true]")

      render_click(view, "m_pick", %{"date" => Date.to_iso8601(far)})
      refute has_element?(view, "#m-month")
      assert has_element?(view, "#m_agenda-m-agenda-day-#{far}", "Far away")
      assert has_element?(view, "[data-role=m-strip][data-week='#{Date.beginning_of_week(far)}']")
    end
  end

  describe "sheets" do
    test "N▾ opens the calendar sheet; its toggles filter the agenda",
         %{conn: conn, scope: scope, today: today} do
      event!(scope, today, 9, 30, "Standup")
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "#m-calendars-sheet.sheet-open")

      view |> element("[data-role=m-calendars-button]") |> render_click()
      assert has_element?(view, "#m-calendars-sheet.sheet-open [data-sheet-section=calendars]")
      assert has_element?(view, "#m-calendars-sheet [data-sheet-section=pages]")

      assert has_element?(view, "[data-role=m-agenda-item]", "Standup")

      view
      |> element("#m-calendars-sheet button[data-calendar-key=native]")
      |> render_click()

      refute has_element?(view, "[data-role=m-agenda-item]", "Standup")
      assert has_element?(view, "[data-role=m-calendars-button][aria-label='1 calendar shown']")

      render_keydown(view, "escape", %{"key" => "Escape"})
      refute has_element?(view, "#m-calendars-sheet.sheet-open")
    end

    test "[+] opens one sheet: the quick-plan box above New event", %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      assert has_element?(view, "[data-role=m-create][data-open=false] #quick-plan")

      view |> element("[data-role=m-new]") |> render_click()

      assert has_element?(
               view,
               "[data-role=m-create][data-open=true][data-covers-tab-bar] #quick-plan"
             )

      assert has_element?(
               view,
               "[data-role=m-create] [data-role=m-new-event][phx-value-date='#{today}']"
             )

      view |> element("[data-role=m-new-event]") |> render_click()
      assert has_element?(view, "[data-role=m-create][data-open=false]")
      assert has_element?(view, "[data-role=calendar-editor]")
    end
  end

  describe "Agenda.rows/6" do
    test "multi-day timed events pin with Day i of n; times stay in the viewer's zone" do
      monday = ~D[2026-11-23]
      starts = DateTime.new!(monday, ~T[20:00:00], @zone)

      entry = %{
        kind: :event,
        id: "e1",
        all_day: false,
        starts_at: starts,
        ends_at: DateTime.add(starts, 2 * 86_400),
        title: "Conference",
        event: %{time_zone: @zone, title: "Conference", tentative: false}
      }

      rows = Agenda.rows([entry], monday, Date.add(monday, 3), @zone, monday)
      days = Enum.filter(rows, &(&1.type == :day))
      assert Enum.map(days, & &1.date) == [monday, Date.add(monday, 1), Date.add(monday, 2)]
      assert Enum.map(days, &hd(&1.pinned).span) == ["Day 1 of 3", "Day 2 of 3", "Day 3 of 3"]
      assert [%{type: :empty, from: from}] = Enum.filter(rows, &(&1.type == :empty))
      assert from == Date.add(monday, 3)
    end
  end
end
