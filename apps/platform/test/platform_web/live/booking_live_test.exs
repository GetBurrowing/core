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
    refute html =~ "Private owner policy"
    render_change(view, "date", %{"date" => Date.to_iso8601(link.start_date)})
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    render_click(view, "select", %{"start" => DateTime.to_iso8601(slot.starts_at)})

    html =
      render_submit(view, "book", %{
        "guest" => %{
          "name" => "Guest",
          "email" => "guest@example.com",
          "create_meeting" => "true",
          "project_id" => "forged"
        }
      })

    assert html =~ "You're booked"
    [receipt] = BookingLinks.receipts(scope)
    assert receipt.event_id
    refute receipt.meeting_id
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

    {:ok, view, _} = live(conn, "/book/#{link.token}")
    html = render_change(view, "date", %{"date" => Date.to_iso8601(link.start_date)})
    assert html =~ "Availability cannot be confirmed"
    refute has_element?(view, "#public-booking-form")
    {:ok, _} = BookingLinks.revoke(scope, link.id)
    {:ok, _, html} = live(conn, "/book/#{link.token}")
    assert html =~ "Availability cannot be confirmed"
  end

  test "owner edits and revokes only their links; failed delivery is visible", %{
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
    render_click(view, "edit", %{"id" => link.id})
    view |> form("#booking-link-form", link: %{title: "Revised policy"}) |> render_submit()
    assert Enum.any?(BookingLinks.list(scope), &(&1.title == "Revised policy"))
    render_click(view, "revoke", %{"id" => link.id})
    assert render(view) =~ "Revoked"
  end

  test "owner creates bounded booking windows through settings", %{auth: conn, scope: scope} do
    {:ok, view, _} = live(conn, "/calendar/booking")

    view
    |> form("#booking-link-form",
      link: %{
        title: "Afternoon appointments",
        time_zone: "America/Chicago",
        duration_minutes: "45",
        buffer_before_minutes: "10",
        buffer_after_minutes: "15",
        start_date: Date.to_iso8601(Date.utc_today()),
        end_date: Date.to_iso8601(Date.add(Date.utc_today(), 14)),
        windows_text: "2 13:00-16:00"
      }
    )
    |> render_submit()

    assert Enum.any?(BookingLinks.list(scope), fn link ->
             link.title == "Afternoon appointments" and link.duration_minutes == 45 and
               link.windows == [%{"weekday" => 2, "start" => "13:00", "end" => "16:00"}]
           end)
  end

  test "public booking HTTP attempts are bounded before token lookup", %{conn: conn} do
    ip = {192, 0, 2, 91}
    :ok = Platform.Calendar.BookingRateLimit.check({:ip, ip}, 60, 60)
    conn = %{conn | remote_ip: ip} |> get("/book/not-a-valid-token")
    assert response(conn, 429) =~ "Too many requests"
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "Meetings disabled hides optional meeting controls", %{auth: conn} do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, false)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)
    {:ok, view, _} = live(conn, "/calendar/booking")
    refute has_element?(view, "input[name='link[create_meeting]']")
  end
end
