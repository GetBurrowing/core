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

  test "event CRUD uses viewer-local time, and deletion removes the calendar entry", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _} = live(conn, "/calendar")
    view |> element("#calendar-new") |> render_click()
    view |> element("#calendar-create-event") |> render_click()

    view
    |> form("#calendar-event-form",
      event: %{
        title: "Board preparation",
        starts_at: "2026-10-29T14:00",
        ends_at: "2026-10-29T15:00",
        time_zone: "America/Chicago",
        where: "private",
        repeat: "",
        visibility: "details"
      }
    )
    |> render_submit()

    [event] = Calendar.list_events(scope, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
    assert event.starts_at == ~U[2026-10-29 19:00:00.000000Z]
    assert event.title == "Board preparation"
    render_click(view, "select", %{"id" => event.id, "kind" => "event"})
    view |> element("button", "Edit event") |> render_click()

    view
    |> form("#calendar-event-form", event: %{title: "Board preparation revised"})
    |> render_submit()

    assert {:ok, %{title: "Board preparation revised"}} = Calendar.get_event(scope, event.id)
    render_click(view, "select", %{"id" => event.id, "kind" => "event"})
    view |> element("button", "Delete event") |> render_click()
    assert [] == Calendar.list_events(scope, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
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
    {:ok, view, _} = live(conn, "/calendar")
    render_click(view, "new_event")

    view
    |> form("#calendar-event-form", event: %{all_day: "true", repeat: "custom"})
    |> render_change()

    view
    |> form("#calendar-event-form",
      event: %{
        title: "Away",
        all_day: "true",
        start_date: "2026-11-01",
        end_date: "2026-11-01",
        time_zone: "America/Chicago",
        custom_frequency: "WEEKLY",
        custom_interval: "2",
        custom_count: "3",
        custom_until: "",
        repeat: "custom",
        where: "private",
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

  test "subscription rotation requires confirmation and revokes the previous link", %{
    conn: conn,
    scope: scope
  } do
    {:ok, old_token} = Calendar.rotate_feed(scope)
    {:ok, view, _} = live(conn, "/calendar")
    view |> element("#calendar-subscribe") |> render_click()
    refute has_element?(view, "#calendar-copy-feed")
    view |> element("button", "Regenerate link") |> render_click()
    assert {:ok, _} = Calendar.feed_scope(old_token)
    assert render(view) =~ "The old link will stop working"
    view |> element("button", "Confirm regeneration") |> render_click()
    assert {:error, :not_found} = Calendar.feed_scope(old_token)
    assert has_element?(view, "#calendar-copy-feed[data-clipboard-text]")
    view |> element("button", "Revoke link") |> render_click()
    refute has_element?(view, "#calendar-copy-feed")
  end

  test "default Meetings destination is its workspace list", %{conn: conn} do
    {:ok, view, _} = live(conn, "/meetings")
    assert has_element?(view, "[data-region=meetings-workspace]")
    refute has_element?(view, "[data-role=calendar-week-grid]")
    assert has_element?(view, "a[href='/calendar']", "View on calendar")
    assert has_element?(view, "h2", "Live")
    assert has_element?(view, "h2", "Upcoming")
    assert has_element?(view, "h2", "Past")
  end

  test "shared arithmetic lays overlapping native events in separate lanes and clips midnight" do
    first = %{
      kind: :event,
      all_day: false,
      starts_at: ~U[2026-10-29 23:00:00Z],
      ends_at: ~U[2026-10-30 02:00:00Z]
    }

    second = %{first | starts_at: ~U[2026-10-29 23:30:00Z]}
    blocks = PlatformWeb.CalendarLive.day_blocks([first, second], ~D[2026-10-29], "Etc/UTC")
    assert length(blocks) == 2
    assert Enum.map(blocks, fn {_, p} -> p.lane end) == [0, 1]
    assert Enum.all?(blocks, fn {_, p} -> p.top + p.height <= 100.00001 end)

    assert [{_, position}] =
             PlatformWeb.CalendarLive.day_blocks([first], ~D[2026-10-30], "Etc/UTC")

    assert position.top == 0
    midnight = %{first | starts_at: ~U[2026-10-30 00:00:00Z], ends_at: nil}

    assert [{_, midnight_position}] =
             PlatformWeb.CalendarLive.day_blocks([midnight], ~D[2026-10-30], "Etc/UTC")

    assert midnight_position.top == 0
    assert midnight_position.height > 0
  end
end
