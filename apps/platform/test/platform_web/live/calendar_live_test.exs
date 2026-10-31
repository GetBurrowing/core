defmodule PlatformWeb.CalendarLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Calendar, Repo}
  alias Platform.Access.Scope

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "calendar-ui-#{n}@example.com",
        name: "Calendar user",
        oidc_sub: "calendar-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      scope: Scope.for_user(user)
    }
  end

  test "agent access: v4 rows, the permission editor, revoke and grant again", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Platform.Agents.Agent{name: "UI grant agent", slug: "ui-grant-#{n}"})

    Repo.insert!(%Platform.Agents.AgentRuntime{
      runtime_id: "ui-grant-#{n}",
      owner_user_id: user.id,
      agent_id: agent.id,
      status: "active",
      display_name: "UI grant agent"
    })

    {:ok, _} = Platform.Calendar.AgentAccess.grant(scope, agent.id, %{read: true, create: true})
    {:ok, view, _} = live(conn, "/calendar/settings")
    assert has_element?(view, "[data-role=settings-agents] h3", "Agents with calendar access")

    assert has_element?(
             view,
             "[data-agent='#{agent.id}']",
             "Read free/busy, add tentative holds (each one needs your OK) · granted"
           )

    render_change(view, "choose_grant_agent", %{"grant" => %{"agent_id" => agent.id}})
    assert has_element?(view, "#grant_read[checked]")
    assert has_element?(view, "#grant_create[checked]")
    refute has_element?(view, "#grant_move[checked]")

    view
    |> form("#calendar-agent-grant-form",
      grant: %{agent_id: agent.id, read: true, create: true, move: true, preapprove: true}
    )
    |> render_submit()

    assert has_element?(view, "#grant_move[checked]")
    assert has_element?(view, "[data-agent='#{agent.id}']", "move events (preapproved)")
    view |> element("#calendar-revoke-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "[data-agent='#{agent.id}']", "Revoked · no calendar access")
    assert render(view) =~ "UI grant agent’s calendar access revoked"
    assert [%{revoked_at: revoked_at}] = Platform.Calendar.AgentAccess.list(scope)
    assert revoked_at

    view |> element("#calendar-grant-again-#{agent.id}") |> render_click()
    assert render(view) =~ "UI grant agent can read your calendar again"
    assert [%{revoked_at: nil, move: true}] = Platform.Calendar.AgentAccess.list(scope)
  end

  test "revoking an agent on the settings page removes its pending hold", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    zone = midday_zone()
    today = local_today(zone)
    seed_hold!(user, scope, zone, today)
    [%{agent_id: agent_id}] = Platform.Calendar.AgentAccess.list(scope)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar/settings")
    view |> element("#calendar-revoke-agent-#{agent_id}") |> render_click()
    assert [%{state: "revoked"}] = Repo.all(Calendar.Consent)
    assert has_element?(view, "[data-agent='#{agent_id}']", "Revoked · no calendar access")

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")
    refute has_element?(view, ".cal-ev[data-kind=tentative]")
  end

  test "event CRUD uses viewer-local time, and deletion removes the calendar entry", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(zoned(conn, "America/Chicago"), "/calendar")
    view |> element("#calendar-new") |> render_click()
    assert has_element?(view, "#calendar-editor h2", "New event")

    view
    |> form("#calendar-event-form",
      event: %{
        title: "Board preparation",
        date: "2026-10-29",
        start: "14:00",
        end: "15:00",
        repeat: "",
        visibility: "details"
      }
    )
    |> render_submit()

    [event] = Calendar.list_events(scope, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
    assert event.starts_at == ~U[2026-10-29 19:00:00.000000Z]
    assert event.time_zone == "America/Chicago"
    assert event.title == "Board preparation"
    refute has_element?(view, "#calendar-editor")
    assert render(view) =~ "Event created"
    # v4 opens the saved event's details (app.js `#f-save` sets S.sel).
    assert has_element?(view, "[data-role=calendar-details] h3", "Board preparation")

    view |> element("[data-role=calendar-details] button", "Edit") |> render_click()
    assert has_element?(view, "#calendar-editor h2", "Edit event")
    assert has_element?(view, "#calendar-event-form input[name='event[start]'][value='14:00']")

    view
    |> form("#calendar-event-form", event: %{title: "Board preparation revised"})
    |> render_submit()

    assert {:ok, %{title: "Board preparation revised"}} = Calendar.get_event(scope, event.id)
    assert render(view) =~ "Event saved"
    view |> element("[data-role=calendar-details] button", "Delete") |> render_click()
    assert [] == Calendar.list_events(scope, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
    refute has_element?(view, "[data-role=calendar-details]")
    assert render(view) =~ "Event deleted"
  end

  test "forged private event selection and deletion cannot affect another owner", %{conn: conn} do
    n = System.unique_integer([:positive])

    other =
      Repo.insert!(%Platform.Accounts.User{
        email: "other-calendar-#{n}@example.com",
        name: "Other",
        oidc_sub: "other-calendar-#{n}"
      })

    {:ok, event} =
      Calendar.create_event(Scope.for_user(other), %{
        title: "Private other",
        starts_at: ~U[2026-10-29 14:00:00.000000Z],
        ends_at: ~U[2026-10-29 15:00:00.000000Z]
      })

    {:ok, view, html} = live(conn, "/calendar")
    refute html =~ "Private other"
    html = render_click(view, "select", %{"id" => event.id, "kind" => "event"})
    refute html =~ "Private other"
    assert {:ok, _} = Calendar.get_event(Scope.for_user(other), event.id)
  end

  test "one-day all-day custom recurrence keeps the selected local dates across DST", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(zoned(conn, "America/Chicago"), "/calendar")
    render_click(view, "new_event")

    view
    |> form("#calendar-event-form", event: %{all_day: "true", repeat: "custom"})
    |> render_change()

    assert has_element?(view, "#calendar-event-form input[name='event[end_date]']")
    refute has_element?(view, "#calendar-event-form input[name='event[start]']")

    view
    |> form("#calendar-event-form",
      event: %{
        title: "Away",
        all_day: "true",
        date: "2026-11-01",
        end_date: "2026-11-01",
        custom_frequency: "WEEKLY",
        custom_interval: "2",
        custom_count: "3",
        custom_until: "",
        repeat: "custom",
        visibility: "details"
      }
    )
    |> render_submit()

    [first | _] = Calendar.list_events(scope, ~U[2026-11-01 00:00:00Z], ~U[2026-12-01 00:00:00Z])
    assert first.start_date == ~D[2026-11-01]
    assert first.end_date == ~D[2026-11-02]
    assert DateTime.diff(first.ends_at, first.starts_at, :hour) == 25
    assert first.recurrence == "FREQ=WEEKLY;INTERVAL=2;COUNT=3"
  end

  test "the feed revoke modal rotates the feed and shows the old-URL hint", %{
    conn: conn,
    scope: scope
  } do
    {:ok, old_token} = Calendar.rotate_feed(scope)
    {:ok, view, _} = live(conn, "/calendar/settings")
    # FeedToken stores only a hash, so the URL at rest is masked.
    assert has_element?(view, "#feed-url", "/calendar/feed/••••••.ics")
    assert has_element?(view, "[data-role=settings-feed] button", "Make a new URL")
    refute has_element?(view, "#calendar-copy-feed")

    view |> element("[data-role=feed-revoke]") |> render_click()
    assert has_element?(view, "#feed-modal-title", "Revoke this feed URL?")

    assert has_element?(
             view,
             "[data-role=feed-modal]",
             "Apps subscribed with it stop updating right away. You get a new private URL to re-subscribe with."
           )

    assert {:ok, _} = Calendar.feed_scope(old_token)
    view |> element("button", "Cancel") |> render_click()
    refute has_element?(view, "[data-role=feed-modal]")

    view |> element("[data-role=feed-revoke]") |> render_click()
    view |> element("button", "Revoke and make a new URL") |> render_click()
    assert {:error, :not_found} = Calendar.feed_scope(old_token)
    assert has_element?(view, "#calendar-copy-feed[data-clipboard-text]")
    assert render(view) =~ "Feed URL revoked · new URL ready"

    assert has_element?(
             view,
             "[data-role=feed-old]",
             "Old URL …/•••••….ics was revoked and has stopped working. Re-subscribe with the new one."
           )

    new_url = view |> element("#feed-url") |> render() |> text() |> String.trim()
    prefix = new_url |> String.split("/") |> List.last() |> String.slice(0, 5)
    view |> element("[data-role=feed-revoke]") |> render_click()
    view |> element("button", "Revoke and make a new URL") |> render_click()
    assert has_element?(view, "[data-role=feed-old]", "Old URL …/#{prefix}….ics was revoked")
  end

  test "default Meetings destination is its workspace list", %{conn: conn} do
    {:ok, view, _} = live(conn, "/meetings")
    assert has_element?(view, "[data-region=meetings-workspace]")
    refute has_element?(view, "[data-role=calendar-week-grid]")
    # v4 list pane section labels (task 01a18d9f stage 4).
    assert has_element?(view, ".mt-section-label", "Live now")
    assert has_element?(view, ".mt-section-label", "Upcoming")
    assert has_element?(view, ".mt-section-label", "Past")
  end

  test "overlapping recurrence occurrences have distinct DOM identities", %{
    conn: conn,
    scope: scope
  } do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Long recurring event",
        starts_at: DateTime.add(now, -86_400),
        ends_at: DateTime.add(now, 86_400),
        recurrence: "FREQ=DAILY;COUNT=3"
      })

    {:ok, view, _} = live(conn, "/calendar")
    html = render_click(view, "select_day", %{"date" => Date.to_iso8601(today)})

    ids =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='week-#{today}-event-']")
      |> LazyHTML.attribute("id")

    assert length(ids) == 2
    assert length(Enum.uniq(ids)) == 2
  end

  test "day chips lay overlapping events in separate lanes and clip at midnight" do
    first = %{
      kind: :event,
      id: "a",
      all_day: false,
      starts_at: ~U[2026-10-29 19:00:00Z],
      ends_at: ~U[2026-10-30 02:00:00Z]
    }

    second = %{first | id: "b", starts_at: ~U[2026-10-29 19:30:00Z]}
    chips = PlatformWeb.CalendarLive.day_chips([first, second], ~D[2026-10-29], "Etc/UTC")
    assert Enum.map(chips, & &1.lane) == [0, 1]
    assert Enum.all?(chips, &(&1.lanes == 2))
    # 19:00 is 12 hours below 07:00 at 48px an hour; the end clips to 21:00.
    assert [%{top: 576.0, height: 94.0} | _] = chips

    assert [%{s: 0, e: 120, top: +0.0}] =
             PlatformWeb.CalendarLive.day_chips([first], ~D[2026-10-30], "Etc/UTC")

    midnight = %{first | starts_at: ~U[2026-10-30 00:00:00Z], ends_at: nil}

    assert [%{s: 0, e: 30, height: 22, compact: true}] =
             PlatformWeb.CalendarLive.day_chips([midnight], ~D[2026-10-30], "Etc/UTC")
  end

  test "external calendars: v4 add errors, masked URL, show switch and remove", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, "/calendar/settings")

    view
    |> form("#external-calendar-form", %{url: "ftp://calendar.example/feed", label: "Work"})
    |> render_submit()

    assert has_element?(
             view,
             "#ext-err",
             "Paste an iCal link that starts with https:// or webcal://"
           )

    view
    |> form("#external-calendar-form", %{
      url: "webcal://calendar.example/private-secret",
      label: "My external calendar"
    })
    |> render_submit()

    render_async(view)
    [sub] = Calendar.Subscriptions.list(scope)
    assert sub.url == "https://calendar.example/private-secret"
    html = render(view)
    assert html =~ "My external calendar"
    assert html =~ "Read-only"
    assert html =~ "https://calendar.example/••••••"
    refute html =~ "private-secret"
    assert html =~ "My external calendar added"

    view |> element("button[aria-label='Show My external calendar']") |> render_click()

    assert has_element?(
             view,
             "button[aria-label='Show My external calendar'][aria-checked=false]"
           )

    view |> element("#external-calendar-#{sub.id} button", "Remove") |> render_click()
    assert [] == Calendar.Subscriptions.list(scope)
    assert render(view) =~ "My external calendar removed"
  end

  # ── Calendar v4 shell, list pane and grids (task 01a18d9f stage 1) ──────

  # A fixed-offset zone where it is midday now, so chips placed today at
  # 10:30–16:45 local always land in the 07–21 grid and the now line shows.
  defp midday_zone do
    offset = 12 - DateTime.utc_now().hour

    cond do
      offset == 0 -> "Etc/UTC"
      offset > 0 -> "Etc/GMT-#{offset}"
      true -> "Etc/GMT+#{-offset}"
    end
  end

  defp at(zone, date, hour, minute),
    do: date |> DateTime.new!(Time.new!(hour, minute, 0), zone) |> DateTime.shift_zone!("Etc/UTC")

  defp local_today(zone),
    do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp zoned(conn, zone), do: put_connect_params(conn, %{"timezone" => zone})

  defp seed_meeting!(zone, today, status) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "Calendar v4 #{n}",
        slug: "calendar-v4-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "design-#{n}",
        slug: "calendar-v4-space-#{n}",
        kind: "channel"
      })

    id = Platform.Types.UUIDv7.generate()

    %Platform.Meetings.Meeting{id: id}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "calendar-v4-#{n}",
      name: "#design · call",
      livekit_room_name: "meeting-#{id}",
      status: status,
      scheduled_start_at: at(zone, today, 10, 30),
      scheduled_end_at: at(zone, today, 11, 15)
    })
    |> Repo.insert!()
  end

  defp seed_external!(user, zone, today) do
    Repo.insert!(%Calendar.Subscription{
      owner_id: user.id,
      name: "Recruiting (Greenhouse)",
      url: "https://calendar.example/feed.ics",
      refreshed_at: DateTime.utc_now(),
      snapshot: [
        %{
          "uid" => "candidate-1",
          "sequence" => 0,
          "title" => "Candidate screen",
          "starts_at" => DateTime.to_iso8601(at(zone, today, 14, 0)),
          "ends_at" => DateTime.to_iso8601(at(zone, today, 15, 0)),
          "time_zone" => zone,
          "all_day" => false,
          "start_date" => nil,
          "end_date" => nil,
          "recurrence" => nil,
          "exception_dates" => [],
          "transparent" => false
        }
      ]
    })
  end

  defp seed_hold!(user, owner_scope, zone, today) do
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Platform.Agents.Agent{name: "Higgins", slug: "higgins-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "higgins-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Higgins"
      })

    Repo.insert!(%Platform.Access.RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions:
        Platform.Access.RuntimeProfiles.translated_permissions(["context_read"])
    })

    {:ok, _} =
      Calendar.AgentAccess.grant(owner_scope, agent.id, %{
        read: true,
        read_private: true,
        create: true
      })

    {:ok, %Calendar.Consent{}} =
      Calendar.AgentAccess.propose(
        Scope.for_runtime(runtime),
        user.id,
        "create",
        %{
          title: "Interview · Sam Rivera",
          starts_at: at(zone, today, 16, 0),
          ends_at: at(zone, today, 16, 45),
          time_zone: zone
        },
        "hold-#{n}"
      )
  end

  defp text(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.replace(~r/\s+/u, " ")

  defp chip_html(view, kind) do
    view
    |> element("[data-role=calendar-week] .cal-ev[data-kind=#{kind}]")
    |> render()
  end

  test "the week renders the four chip kinds with their verbatim meta lines", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    zone = midday_zone()
    today = local_today(zone)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Lunch with Alex",
        starts_at: at(zone, today, 12, 30),
        ends_at: at(zone, today, 13, 15),
        time_zone: zone,
        visibility: "busy",
        recurrence: "FREQ=WEEKLY"
      })

    seed_meeting!(zone, today, "live")
    seed_external!(user, zone, today)
    seed_hold!(user, scope, zone, today)

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    native = chip_html(view, "native")
    assert native =~ "Lunch with Alex"
    assert native =~ "12:30–13:15"
    assert native =~ "hero-eye-slash"
    assert native =~ "hero-arrow-path"
    assert native =~ "cal-k-native"

    assert native =~
             ~s(aria-label="Event: Lunch with Alex, #{Elixir.Calendar.strftime(today, "%a %-d %b")} 12:30 to 13:15")

    meeting = chip_html(view, "meeting")
    assert meeting =~ "cal-live"
    assert meeting =~ "cal-pulse"
    assert meeting =~ "hero-video-camera"
    assert text(meeting) =~ "Live · Meeting · 10:30–11:15"
    assert meeting =~ "Meeting: #design · call"

    external = chip_html(view, "external")
    assert external =~ "Candidate screen"
    assert external =~ "hero-lock-closed"
    assert text(external) =~ "Recruiting · 14:00–15:00"
    assert external =~ "External, read-only: Candidate screen"

    tentative = chip_html(view, "tentative")
    assert tentative =~ "<b>Interview · Sam Rivera</b>"
    assert text(tentative) =~ "Tentative · Higgins · needs OK"
    assert tentative =~ "Tentative hold by Higgins: Interview · Sam Rivera"
  end

  test "the now line sits in today's column", %{conn: conn} do
    zone = midday_zone()
    today = Date.to_iso8601(local_today(zone))
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    assert has_element?(
             view,
             "[data-role=calendar-week] [data-role=calendar-day-column][data-date='#{today}'] [data-role=calendar-now]"
           )

    assert [_] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[data-role=calendar-week] [data-role=calendar-now]")
             |> Enum.to_list()
  end

  test "a 30-minute slot opens New event preset to that time", %{conn: conn} do
    zone = midday_zone()
    today = local_today(zone)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")
    label = "New event #{Elixir.Calendar.strftime(today, "%a %-d %b")} 09:30"

    view
    |> element("[data-role=calendar-week] button.cal-slot[aria-label='#{label}']")
    |> render_click()

    assert has_element?(view, "h2", "New event")

    assert has_element?(
             view,
             "#calendar-event-form input[name='event[date]'][value='#{Date.to_iso8601(today)}']"
           )

    # app.js `openEditor`: the end defaults to start + 30 minutes.
    assert has_element?(view, "#calendar-event-form input[name='event[start]'][value='09:30']")
    assert has_element?(view, "#calendar-event-form input[name='event[end]'][value='10:00']")
  end

  test "Week/Month, Today and prev/next move the grid", %{conn: conn} do
    {:ok, view, _} = live(zoned(conn, "Etc/UTC"), "/calendar")
    today = local_today("Etc/UTC")
    monday = Date.beginning_of_week(today)
    week_label = PlatformWeb.CalendarLive.range_label("week", today, today)
    assert has_element?(view, "[data-role=calendar-range]", week_label)

    view
    |> element("[data-role=calendar-header] button[aria-label=Next]")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=calendar-range]",
             PlatformWeb.CalendarLive.range_label("week", Date.add(monday, 7), nil)
           )

    view
    |> element("[data-role=calendar-header] button", "Today")
    |> render_click()

    assert has_element?(view, "[data-role=calendar-range]", week_label)

    view
    |> element("[data-role=calendar-header] a[role=tab]", "Month")
    |> render_click()

    assert_patch(view, "/calendar?view=month")
    assert has_element?(view, "[data-role=calendar-month]")
    refute has_element?(view, "[data-role=calendar-week]")

    assert has_element?(
             view,
             "[data-role=calendar-range]",
             Elixir.Calendar.strftime(today, "%B %Y")
           )

    view
    |> element("[data-role=calendar-header] button[aria-label=Previous]")
    |> render_click()

    previous = today |> Date.beginning_of_month() |> Date.add(-1)

    assert has_element?(
             view,
             "[data-role=calendar-range]",
             Elixir.Calendar.strftime(previous, "%B %Y")
           )

    # A month cell opens that day's week.
    view
    |> element("[data-role=calendar-month] [data-date='#{Date.beginning_of_month(previous)}']")
    |> render_click()

    assert_patch(view, "/calendar?view=week")
    assert has_element?(view, "[data-role=calendar-week]")
  end

  test "the mini month pages months and a day moves the cursor", %{conn: conn} do
    {:ok, view, _} = live(zoned(conn, "Etc/UTC"), "/calendar")
    today = local_today("Etc/UTC")
    next_month = today |> Date.end_of_month() |> Date.add(1)

    view
    |> element("[data-role=calendar-mini-month] button[aria-label='Next month']")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=calendar-mini-label]",
             Elixir.Calendar.strftime(next_month, "%B %Y")
           )

    target = Date.add(next_month, 9)

    view
    |> element("[data-role=calendar-mini-month] button[phx-value-date='#{target}']")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=calendar-range]",
             PlatformWeb.CalendarLive.range_label("week", target, target)
           )

    assert has_element?(view, "[data-role=calendar-week] [data-date='#{target}']")
  end

  test "calendar toggles hide and show their entries", %{conn: conn, scope: scope, user: user} do
    zone = midday_zone()
    today = local_today(zone)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Own block",
        starts_at: at(zone, today, 12, 0),
        ends_at: at(zone, today, 13, 0),
        time_zone: zone
      })

    sub = seed_external!(user, zone, today)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    assert has_element?(view, "button[role=checkbox][data-calendar-key=native]", user.name)

    assert has_element?(
             view,
             "button[role=checkbox][data-calendar-key='ext:#{sub.id}']",
             "read-only · iCal"
           )

    assert has_element?(view, ".cal-ev[data-kind=native]", "Own block")
    assert has_element?(view, ".cal-ev[data-kind=external]", "Candidate screen")

    view |> element("button[data-calendar-key=native]") |> render_click()
    assert has_element?(view, "button[data-calendar-key=native][aria-checked=false]")
    refute has_element?(view, ".cal-ev[data-kind=native]")
    assert has_element?(view, ".cal-ev[data-kind=external]")

    view |> element("button[data-calendar-key='ext:#{sub.id}']") |> render_click()
    refute has_element?(view, ".cal-ev[data-kind=external]")

    view |> element("button[data-calendar-key=native]") |> render_click()
    assert has_element?(view, ".cal-ev[data-kind=native]", "Own block")
  end

  test "a Meetings-off scope renders no meeting row, legend item or chip", %{
    conn: conn,
    user: user
  } do
    zone = midday_zone()
    today = local_today(zone)
    seed_meeting!(zone, today, "live")

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    assert has_element?(
             view,
             "button[data-calendar-key=meetings]",
             "Burrow meetings you are invited to"
           )

    assert has_element?(view, "[data-legend=meeting]")
    assert has_element?(view, ".cal-ev[data-kind=meeting]")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, user.id},
        permission: "meetings",
        resource: {:module, Platform.TenancyFixtures.acme_org_id()}
      })

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")
    refute has_element?(view, "button[data-calendar-key=meetings]")
    refute has_element?(view, "[data-legend=meeting]")
    refute has_element?(view, ".cal-ev[data-kind=meeting]")
    assert has_element?(view, "[data-role=calendar-legend]", "Your events")
  end

  test "the phone day strip selects a day and the single-day column follows", %{conn: conn} do
    {:ok, view, _} = live(zoned(conn, "Etc/UTC"), "/calendar")
    today = local_today("Etc/UTC")
    days = PlatformWeb.CalendarLive.week_days(today)
    other = Enum.find(days, &(&1 != today))

    assert has_element?(view, ".lg\\:hidden [data-role=calendar-day-strip]")

    assert has_element?(
             view,
             "[data-role=calendar-day-strip] button[aria-selected=true][phx-value-date='#{today}']"
           )

    assert has_element?(
             view,
             "[data-role=calendar-phone-day] [data-role=calendar-day-column][data-date='#{today}']"
           )

    view
    |> element("[data-role=calendar-day-strip] button[phx-value-date='#{other}']")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=calendar-day-strip] button[aria-selected=true][phx-value-date='#{other}']"
           )

    assert has_element?(
             view,
             "[data-role=calendar-phone-day] [data-role=calendar-day-column][data-date='#{other}']"
           )

    refute has_element?(
             view,
             "[data-role=calendar-phone-day] [data-role=calendar-day-column][data-date='#{today}']"
           )

    # The phone's prev/next step one day.
    view
    |> element("[data-role=calendar-phone-header] button[aria-label=Next]")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=calendar-phone-day] [data-role=calendar-day-column][data-date='#{Date.add(other, 1)}']"
           )
  end

  # ── Calendar v4 details + editor (task 01a18d9f stage 2) ────────────────

  defp details_text(view),
    do: view |> element("[data-role=calendar-details]") |> render() |> text()

  defp open_chip(view, kind),
    do: view |> element("[data-role=calendar-week] .cal-ev[data-kind=#{kind}]") |> render_click()

  test "native details show the v4 copy, and Escape and the close button dismiss them", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    zone = midday_zone()
    today = local_today(zone)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Lunch with Alex",
        description: "Usual spot.",
        starts_at: at(zone, today, 12, 30),
        ends_at: at(zone, today, 13, 15),
        time_zone: zone,
        recurrence: "FREQ=WEEKLY"
      })

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")
    refute has_element?(view, "[data-role=calendar-details]")
    open_chip(view, "native")

    assert has_element?(view, "[data-role=calendar-details] .cal-dhead b", "Event")
    assert has_element?(view, "[data-role=calendar-details] .cal-pill-info", "Your event")
    assert has_element?(view, "[data-role=calendar-details] h3", "Lunch with Alex")
    assert has_element?(view, ".cal-ev[data-kind=native][aria-current=true]")
    copy = details_text(view)
    assert copy =~ "#{Elixir.Calendar.strftime(today, "%a %-d %b")} · 12:30–13:15"
    assert copy =~ "Weekly on #{Elixir.Calendar.strftime(today, "%A")}"
    assert copy =~ "Full detailsOthers with access see the title and notes"
    assert copy =~ "Usual spot."
    assert copy =~ user.name
    assert has_element?(view, ".cal-dfoot button", "Edit")
    assert has_element?(view, ".cal-dfoot button.cal-danger-btn", "Delete")

    view |> element("[data-page=calendar]") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "[data-role=calendar-details]")

    open_chip(view, "native")
    view |> element("button[aria-label='Close details']") |> render_click()
    refute has_element?(view, "[data-role=calendar-details]")

    # `?select=<id>` (the Inbox card's "See it on the calendar") opens it too.
    [%{id: id} | _] =
      Calendar.list_events(scope, at(zone, today, 0, 0), at(zone, Date.add(today, 1), 0, 0))

    {:ok, view, _} = live(zoned(conn, zone), "/calendar?date=#{today}&select=#{id}")
    assert has_element?(view, "[data-role=calendar-details] h3", "Lunch with Alex")
  end

  test "busy details read Busy only, and a meeting, external and hold each get their v4 copy",
       %{conn: conn, scope: scope, user: user} do
    zone = midday_zone()
    today = local_today(zone)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Focus",
        starts_at: at(zone, today, 8, 0),
        ends_at: at(zone, today, 9, 0),
        time_zone: zone,
        visibility: "busy"
      })

    meeting = seed_meeting!(zone, today, "live")

    {:ok, _} =
      Platform.Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Calendar user",
        joined_at: DateTime.utc_now()
      })

    seed_external!(user, zone, today)
    seed_hold!(user, scope, zone, today)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    open_chip(view, "native")
    assert details_text(view) =~ "Busy onlyOthers, agents and your feed see “Busy”"

    open_chip(view, "meeting")
    assert has_element?(view, "[data-role=calendar-details] .cal-dhead b", "Meeting")
    assert has_element?(view, "[data-role=calendar-details] .cal-pill-ok", "Live")
    copy = details_text(view)
    assert copy =~ "Burrow meeting in #design-"
    assert copy =~ "1 invitedCalendar user"

    assert has_element?(
             view,
             ".cal-dfoot a[href='/meetings/#{meeting.slug}']",
             "Join now"
           )

    assert has_element?(view, ".cal-dfoot a", "View in Meetings")

    open_chip(view, "external")
    assert has_element?(view, "[data-role=calendar-details] .cal-dhead b", "External event")
    copy = details_text(view)
    assert copy =~ "Read-only"
    assert copy =~ "From Recruiting (Greenhouse)Read-only. Edit it in the source calendar."
    assert copy =~ "Blocks your availabilityBooking-link guests can’t pick this time"

    assert has_element?(
             view,
             ".cal-dfoot a[href='/calendar/settings']",
             "Manage external calendars"
           )

    refute has_element?(view, ".cal-dfoot button", "Edit")

    open_chip(view, "tentative")
    assert has_element?(view, "[data-role=calendar-details] .cal-dhead b", "Agent hold")
    assert has_element?(view, ".cal-pill-acc", "Tentative · needs your OK")
    assert details_text(view) =~ "held by Higgins"
    assert has_element?(view, ".cal-dfoot button", "Approve")
    assert has_element?(view, ".cal-dfoot button", "Revert")
  end

  test "Approve in the hold's details commits it through AgentAccess", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    zone = midday_zone()
    today = local_today(zone)
    seed_hold!(user, scope, zone, today)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    open_chip(view, "tentative")
    view |> element(".cal-dfoot button", "Approve") |> render_click()

    assert [%{state: "approved"}] = Repo.all(Calendar.Consent)
    refute has_element?(view, ".cal-ev[data-kind=tentative]")
    assert has_element?(view, ".cal-ev[data-kind=native]", "Interview · Sam Rivera")
    # The open details follow the hold into a native event.
    assert has_element?(view, "[data-role=calendar-details] .cal-pill-info", "Your event")
  end

  test "Revert in the hold's details removes the hold", %{conn: conn, scope: scope, user: user} do
    zone = midday_zone()
    today = local_today(zone)
    seed_hold!(user, scope, zone, today)
    {:ok, view, _} = live(zoned(conn, zone), "/calendar")

    open_chip(view, "tentative")
    view |> element(".cal-dfoot button", "Revert") |> render_click()

    assert [%{state: "reverted"}] = Repo.all(Calendar.Consent)
    refute has_element?(view, ".cal-ev[data-kind=tentative]")
    refute has_element?(view, "[data-role=calendar-details]")
    assert render(view) =~ "Reverted · hold removed"
  end

  test "the editor shows the three v4 validation messages", %{conn: conn} do
    {:ok, view, _} = live(zoned(conn, "Etc/UTC"), "/calendar")
    view |> element("#calendar-new") |> render_click()

    view
    |> form("#calendar-event-form", event: %{title: ""})
    |> render_submit()

    assert has_element?(view, "#calendar-event-error[role=alert]", "Give the event a title.")
    assert has_element?(view, "input[name='event[title]'][aria-invalid=true]")

    view
    |> form("#calendar-event-form", event: %{title: "Standup", date: ""})
    |> render_submit()

    assert has_element?(view, "#calendar-event-error", "Pick a date, start and end.")
    assert has_element?(view, "input[name='event[date]'][aria-invalid=true]")

    view
    |> form("#calendar-event-form",
      event: %{title: "Standup", date: "2026-10-29", start: "10:00", end: "09:30"}
    )
    |> render_submit()

    assert has_element?(view, "#calendar-event-error", "End has to be after the start.")
    assert has_element?(view, "input[name='event[end]'][aria-invalid=true]")
    assert has_element?(view, "#calendar-editor")

    view |> element("#calendar-editor button", "Cancel") |> render_click()
    refute has_element?(view, "#calendar-editor")
  end

  test "Busy only persists as visibility busy", %{conn: conn, scope: scope} do
    {:ok, view, _} = live(zoned(conn, "Etc/UTC"), "/calendar")
    view |> element("#calendar-new") |> render_click()
    assert has_element?(view, ".cal-visopt input[value=details][checked]")

    view
    |> form("#calendar-event-form",
      event: %{
        title: "Dentist",
        date: "2026-10-28",
        start: "16:00",
        end: "16:45",
        visibility: "busy"
      }
    )
    |> render_submit()

    assert [%{visibility: "busy", title: "Dentist"}] =
             Calendar.list_events(scope, ~U[2026-10-28 00:00:00Z], ~U[2026-10-29 00:00:00Z])
  end

  test "editing a recurring event warns that changes apply to every occurrence", %{
    conn: conn,
    scope: scope
  } do
    zone = midday_zone()
    today = local_today(zone)

    {:ok, _} =
      Calendar.create_event(scope, %{
        title: "Review",
        starts_at: at(zone, today, 9, 0),
        ends_at: at(zone, today, 9, 30),
        time_zone: zone,
        recurrence: "FREQ=WEEKLY;INTERVAL=2;COUNT=3"
      })

    {:ok, view, _} = live(zoned(conn, zone), "/calendar")
    open_chip(view, "native")
    assert details_text(view) =~ "Every 2 weeks, 3 times"
    view |> element(".cal-dfoot button", "Edit") |> render_click()

    assert has_element?(view, "#calendar-editor .cal-hint", "Changes apply to every occurrence.")
    # The custom rule shows as its own selected Repeat option.
    assert has_element?(
             view,
             "select[name='event[repeat]'] option[value=custom][selected]",
             "Every 2 weeks, 3 times"
           )

    view |> element("#calendar-editor button", "Delete") |> render_click()
    refute has_element?(view, "#calendar-editor")
    refute has_element?(view, ".cal-ev[data-kind=native]")
  end
end
