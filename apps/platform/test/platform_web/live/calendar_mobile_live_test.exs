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

    %{conn: conn, scope: Scope.for_user(user), user: user, today: today()}
  end

  defp today, do: DateTime.utc_now() |> DateTime.to_date()

  defp text(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # The [+] sheet's phone blocks, in document order.
  defp create_sheet_order(view) do
    view
    |> element("[data-role=m-create]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=m-new-event], [data-role=m-create-no-agent], #quick-plan")
    |> Enum.map(fn node ->
      case LazyHTML.attribute(node, "id") do
        ["quick-plan"] -> "quick-plan"
        _ -> node |> LazyHTML.attribute("data-role") |> hd()
      end
    end)
  end

  # An agent the user granted `create`, as calendar_agent_draft_test sets up.
  defp draft_agent!(user, scope) do
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Platform.Agents.Agent{name: "Scheduler #{n}", slug: "cal-mobile-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "cal-mobile-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Scheduler"
      })

    Repo.insert!(%Platform.Access.RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions:
        Platform.Access.RuntimeProfiles.translated_permissions(["context_read"])
    })

    {:ok, _} = Platform.Calendar.AgentAccess.grant(scope, agent.id, %{read: true, create: true})
    agent
  end

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
      assert has_element?(view, "[data-role=calendar-day-strip][data-week='#{monday}']")

      assert has_element?(
               view,
               "[data-role=calendar-day-strip] button[aria-current=date][data-date='#{today}']"
             )

      # The old phone header, section chips and phone grids are gone; the
      # new strip keeps the `calendar-day-strip` role the extensions use.
      refute has_element?(view, "[data-role=calendar-phone-header]")
      refute has_element?(view, "[data-role=calendar-section-tabs]")
      refute has_element?(view, "[data-role=calendar-month-phone]")
    end

    test "the strip's dots mark the days that have events", %{conn: conn, scope: scope} do
      today = today()
      event!(scope, today, 9, 30, "Standup")
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=calendar-day-strip] button[data-date='#{today}'] [data-role=m-strip-dot]"
             )

      empty = today |> PlatformWeb.CalendarLive.week_days() |> Enum.find(&(&1 != today))

      refute has_element?(
               view,
               "[data-role=calendar-day-strip] button[data-date='#{empty}'] [data-role=m-strip-dot]"
             )
    end
  end

  describe "agenda" do
    test "opens on today: its header, all-day and timed rows, and the timezone tag",
         %{conn: conn, scope: scope, today: today} do
      all_day!(scope, today, 1, "Alex out")
      all_day!(scope, Date.add(today, -1), 3, "Offsite")
      event!(scope, today, 14, 60, "Design sync", minute: 30)
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

      assert has_element?(view, "#{row} [data-role=m-agenda-pinned]", "Alex out")
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

    test "scrolling near the top loads back to the previous event, at least four weeks",
         %{conn: conn, scope: scope, today: today} do
      past = Date.add(today, -50)
      event!(scope, past, 9, 60, "Old review")
      {:ok, view, _} = live(conn, "/calendar")
      first = Date.add(Date.beginning_of_week(today), -14)
      assert has_element?(view, "#m_agenda-m-agenda-empty-#{first}")
      refute has_element?(view, "[data-role=m-agenda-item]", "Old review")

      render_hook(view, "m_agenda_more", %{"direction" => "earlier"})
      assert has_element?(view, "#m_agenda-m-agenda-day-#{past}", "Old review")
      assert has_element?(view, "#m_agenda-m-agenda-empty-#{Date.add(past, -6)}")
      # The run that started the list merged into a longer one, not doubled.
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
               "[data-role=calendar-day-strip][data-week='#{Date.beginning_of_week(ahead)}']"
             )

      view |> element("[data-role=m-today]") |> render_click()
      assert_push_event(view, "m-agenda-scroll", %{date: date})
      assert date == Date.to_iso8601(today)
      refute has_element?(view, "[data-role=m-today]")

      assert has_element?(
               view,
               "[data-role=calendar-day-strip][data-week='#{Date.beginning_of_week(today)}']"
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
      # Placed in hour units: 02:00 is two `--m-hour` rows down.
      assert has_element?(
               view,
               "#m-day .cal-ev[style*='top: calc(var(--m-hour) * 2.0)']",
               "Night ops"
             )
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
      assert has_element?(view, "[data-role=calendar-day-strip][data-week='#{next}']")
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

      assert has_element?(
               view,
               "[data-role=calendar-day-strip][data-week='#{Date.beginning_of_week(far)}']"
             )
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
      # Filters only (review H): the pages are in the title menu.
      refute has_element?(view, "#m-calendars-sheet a")
      assert has_element?(view, "#m-calendars-sheet [data-sheet-seam=people]")

      assert has_element?(view, "[data-role=m-agenda-item]", "Standup")

      view
      |> element("#m-calendars-sheet button[data-calendar-key=native]")
      |> render_click()

      refute has_element?(view, "[data-role=m-agenda-item]", "Standup")
      assert has_element?(view, "[data-role=m-calendars-button][aria-label='1 calendar shown']")

      render_keydown(view, "escape", %{"key" => "Escape"})
      refute has_element?(view, "#m-calendars-sheet.sheet-open")
    end

    test "[+] with no agent: New event leads, quick-plan is one line to Settings",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-new]") |> render_click()
      assert has_element?(view, "[data-role=m-create][data-open=true][data-covers-tab-bar]")

      # New event first; the full quick-plan box after it is lg-only.
      assert create_sheet_order(view) == ["m-new-event", "m-create-no-agent", "quick-plan"]

      assert has_element?(
               view,
               "[data-role=m-new-event][data-primary][phx-value-date='#{today}']"
             )

      assert has_element?(
               view,
               "[data-role=m-create-no-agent] a[href='/calendar/settings']",
               "Calendar settings"
             )

      assert view |> element("[data-role=m-create-no-agent]") |> render() |> text() =~
               "No agent can draft events for you yet. Give one access in Calendar settings"

      # The full box stays for lg (one DOM copy), hidden below it.
      assert has_element?(view, "[data-role=m-create] .max-lg\\:hidden #quick-plan")

      view |> element("[data-role=m-new-event]") |> render_click()
      assert has_element?(view, "[data-role=m-create][data-open=false]")
      assert has_element?(view, "[data-role=calendar-editor]")
    end

    test "[+] with an agent that can draft: quick-plan on top, New event below",
         %{conn: conn, scope: scope, user: user} do
      draft_agent!(user, scope)
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-new]") |> render_click()

      assert create_sheet_order(view) == ["quick-plan", "m-new-event"]
      refute has_element?(view, "[data-role=m-create-no-agent]")
      refute has_element?(view, "[data-role=m-new-event][data-primary]")
      refute has_element?(view, "[data-role=m-create] .max-lg\\:hidden #quick-plan")
      assert has_element?(view, "#quick-plan input[data-role=quick-plan-text]:not([disabled])")
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

  describe "review 2 (build 377b2da1)" do
    test "E: the strip and month start on the locale's first weekday", %{conn: conn, today: today} do
      conn = put_connect_params(conn, %{"timezone" => @zone, "week_start" => "7"})
      {:ok, view, _} = live(conn, "/calendar")
      sunday = Date.beginning_of_week(today, :sunday)
      assert has_element?(view, "[data-role=calendar-day-strip][data-week='#{sunday}']")

      view |> element("[data-role=m-month-button]") |> render_click()

      letters =
        view
        |> element("#m-month")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[role=grid] > span")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert letters == ~w(S M T W T F S)
    end

    test "E: a missing or bad week_start is Monday", %{conn: conn, today: today} do
      conn = put_connect_params(conn, %{"timezone" => @zone, "week_start" => "9"})
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=calendar-day-strip][data-week='#{Date.beginning_of_week(today)}']"
             )
    end

    test "G: loading later runs on through an empty stretch to the next event",
         %{conn: conn, scope: scope, today: today} do
      far = Date.add(today, 200)
      event!(scope, far, 10, 60, "Far future")
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "[data-role=m-agenda-item]", "Far future")

      render_hook(view, "m_agenda_more", %{"direction" => "later"})
      assert has_element?(view, "#m_agenda-m-agenda-day-#{far}", "Far future")

      # Everything between is ONE collapsed row, not four-week pieces.
      runs =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#m-agenda [data-role=m-agenda-row][data-type=empty]")
        |> Enum.filter(
          &(LazyHTML.attribute(&1, "data-to") == [Date.to_iso8601(Date.add(far, -1))])
        )

      assert [run] = runs
      assert LazyHTML.text(run) =~ "No events"
    end

    test "G: with nothing ahead a load still moves the window forward",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      render_hook(view, "m_agenda_more", %{"direction" => "later"})
      render_hook(view, "m_agenda_more", %{"direction" => "later"})

      last =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#m-agenda [data-role=m-agenda-row]")
        |> Enum.to_list()
        |> List.last()
        |> LazyHTML.attribute("data-to")
        |> hd()
        |> Date.from_iso8601!()

      assert Date.diff(last, today) > 2 * 365
    end

    test "D: a Day view block names its zone in its label, not on the block",
         %{conn: conn, scope: scope, today: today} do
      {:ok, _} =
        Calendar.create_event(scope, %{
          title: "NY partner call",
          starts_at: at(today, 15),
          ends_at: at(today, 16),
          time_zone: "America/New_York"
        })

      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()

      assert has_element?(
               view,
               "#m-day .cal-ev[aria-label$='times in your zone, event set in EST']",
               "NY partner call"
             )

      refute has_element?(view, "#m-day [data-role=m-tz]")

      view |> element("#m-day .cal-ev", "NY partner call") |> render_click()

      assert has_element?(
               view,
               "[data-role=calendar-details] [data-role=calendar-detail-zone]",
               "Set in America/New_York (EST)"
             )

      assert has_element?(view, "[data-role=calendar-detail-zone]", "10:00–11:00 there")
    end

    test "D: an event in the viewer's own zone has no zone row", %{
      conn: conn,
      scope: scope,
      today: today
    } do
      event!(scope, today, 9, 30, "Standup")
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-view-switch] button[data-view=day]") |> render_click()
      view |> element("#m-day .cal-ev", "Standup") |> render_click()
      assert has_element?(view, "[data-role=calendar-details]")
      refute has_element?(view, "[data-role=calendar-detail-zone]")
    end

    test "B: the title menu carries Agenda | Day for a compact row 1", %{conn: conn} do
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("#phone-top-bar-title-menu") |> render_click()
      # Shown by app.css only under `data-row1-compact`.
      assert has_element?(
               view,
               "#m-title-menu .m-menu-views button[data-view=agenda][aria-pressed=true]"
             )

      view |> element("#m-title-menu button[data-view=day]") |> render_click()
      assert has_element?(view, "#m-day")
      refute has_element?(view, "#m-title-menu")
    end

    test "C: the month has a scrim for its sheet form; picking a date closes it",
         %{conn: conn, today: today} do
      {:ok, view, _} = live(conn, "/calendar")
      view |> element("[data-role=m-month-button]") |> render_click()
      assert has_element?(view, "#m-month-slot .m-month-scrim[phx-click=m_month_toggle]")
      refute has_element?(view, "#m-month[class*='max-h']")

      render_click(view, "m_pick", %{"date" => Date.to_iso8601(Date.add(today, 3))})
      refute has_element?(view, "#m-month")
      refute has_element?(view, ".m-month-scrim")
    end

    test "F: the date button is filled like the other row 1 controls", %{conn: conn} do
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "[data-role=m-month-button][class*='bg-base-200'][class*='rounded-[var(--radius-field)]']"
             )
    end

    test "the title menu is the calendar's alone; other pages keep the plain title",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/calendar")
      assert has_element?(view, "button#phone-top-bar-title-menu[data-role=phone-top-bar-title]")

      {:ok, inbox, _} = live(conn, "/inbox")
      refute has_element?(inbox, "#phone-top-bar-title-menu")
      assert has_element?(inbox, "span[data-role=phone-top-bar-title]")
    end
  end

  describe "the agenda's end (review 3)" do
    test "two empty years ahead: no loading lines, the last row reads After <day>",
         %{conn: conn, scope: scope, today: today} do
      last = Date.add(today, 3)
      event!(scope, last, 9, 30, "Last thing")
      {:ok, view, _} = live(conn, "/calendar")

      assert has_element?(
               view,
               "#m-agenda[data-end-later=false] [data-role=m-agenda-later-lines]"
             )

      render_hook(view, "m_agenda_more", %{"direction" => "later"})

      refute has_element?(view, "[data-role=m-agenda-later-lines]")
      assert has_element?(view, "#m-agenda[data-end-later=true]")

      label = "After " <> Elixir.Calendar.strftime(last, "%a %-d %b")

      assert has_element?(
               view,
               "#m_agenda-m-agenda-empty-#{Date.add(last, 1)} p[data-ending=true]"
             )

      assert view
             |> element("#m_agenda-m-agenda-empty-#{Date.add(last, 1)}")
             |> render()
             |> text() == label <> " · No events"

      # Data changing reopens the end: something could be out there now.
      event!(scope, Date.add(today, 400), 9, 30, "Next year")
      send(view.pid, {:event_changed, %{}})
      assert has_element?(view, "[data-role=m-agenda-later-lines]")
      assert has_element?(view, "#m-agenda[data-end-later=false]")
    end

    test "the earlier end drops its loading lines too", %{conn: conn} do
      {:ok, view, _} = live(conn, "/calendar")
      refute has_element?(view, "#m-agenda-earlier.hidden")
      render_hook(view, "m_agenda_more", %{"direction" => "earlier"})
      assert has_element?(view, "#m-agenda-earlier.hidden")
      assert has_element?(view, "#m-agenda[data-end-earlier=true]")
    end
  end

  describe "extension days (Social review)" do
    test "an extension-only day is its own row with neutral wording" do
      monday = ~D[2026-11-23]
      day = Date.add(monday, 3)

      rows =
        Agenda.rows([], monday, Date.add(monday, 6), @zone, monday,
          extension_days: MapSet.new([day])
        )

      assert %{type: :day, ext_only?: true} = Enum.find(rows, &(&1[:date] == day))
      # The days around it still collapse, and never across it.
      assert Enum.any?(rows, &(&1.type == :empty and &1.to == Date.add(day, -1)))
      assert Enum.any?(rows, &(&1.type == :empty and &1.from == Date.add(day, 1)))
    end

    test "the strip count is sized in rem so it scales with the text size" do
      html =
        render_component(&PlatformWeb.CalendarLive.Mobile.controls/1,
          view: "agenda",
          focus: ~D[2026-11-25],
          sel_day: ~D[2026-11-25],
          today: ~D[2026-11-25],
          show_today: false,
          shown_count: 2,
          month_open: false,
          busy: %{},
          ext: %{~D[2026-11-26] => %{count: 3, label: "3 Social items"}}
        )

      [count] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role=calendar-day-strip] [data-role=calendar-extension-count]")
        |> Enum.to_list()

      [class] = LazyHTML.attribute(count, "class")
      assert class =~ "text-[0.6875rem]"
      refute class =~ ~r/text-\[\d+px\]/
      assert LazyHTML.text(count) =~ "3"
    end

    test "extension_counts and the cell label read the extension entries" do
      day = ~D[2026-11-25]

      counts =
        Agenda.extension_counts([
          %{day: day, key: "social", label: "Social", items: [1, 2, 3]},
          %{day: day, key: "other", label: "Other", items: []}
        ])

      assert counts == %{day => %{count: 3, label: "3 Social items"}}
    end
  end

  describe "Agenda week helpers" do
    test "week_first/week_days/weekday_letters follow the week start" do
      wed = ~D[2026-11-25]
      assert Agenda.week_first(wed) == ~D[2026-11-23]
      assert Agenda.week_first(wed, 7) == ~D[2026-11-22]
      assert Agenda.week_first(wed, 6) == ~D[2026-11-21]
      assert hd(Agenda.week_days(wed, 7)) == ~D[2026-11-22]
      assert Agenda.weekday_letters(7) == ~w(S M T W T F S)
      assert Agenda.weekday_letters(1) == ~w(M T W T F S S)
      assert Agenda.week_start("7") == 7
      assert Agenda.week_start(nil) == 1
      assert Agenda.week_start("0") == 1
      assert hd(Agenda.month_days(~D[2026-11-01], 7)) == ~D[2026-11-01]
    end

    test "range_label names the months, and the years on a long run" do
      assert Agenda.range_label(~D[2026-11-26], ~D[2026-11-28]) == "Thu 26 – Sat 28 Nov"
      assert Agenda.range_label(~D[2026-12-15], ~D[2027-01-11]) == "Tue 15 Dec – Mon 11 Jan"
      assert Agenda.range_label(~D[2026-11-26], ~D[2026-11-26]) == "Thu 26 Nov"

      assert Agenda.range_label(~D[2026-12-10], ~D[2028-12-09]) ==
               "Thu 10 Dec 2026 – Sat 9 Dec 2028"
    end
  end
end
