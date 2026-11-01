defmodule PlatformWeb.MeetingLiveCalendarOriginTest do
  @moduledoc """
  Calendar's New -> Meeting opens the existing create sheet (task 01a1986e
  stage 1).

  Calendar navigates to `/meetings?schedule=true&from=calendar&date=…&start_time=…`.
  The sheet opens prefilled, commits through the one `create_from_sheet/7`
  path (so staged invites are replayed exactly as from the index), and
  returns the viewer to `/calendar` on the meeting's day with it selected.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @search "#meeting-create-invite-search"
  @calendar_path "/meetings?schedule=true&from=calendar&date=2026-11-04&start_time=2:00 PM"

  setup %{conn: conn} do
    user = member!("Calendar Host", "cal_host_#{System.unique_integer([:positive])}@example.com")

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Calendar Origin Project #{System.unique_integer([:positive])}",
        slug: "calendar-origin-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    Repo.delete_all(Meeting)

    conn =
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => "America/Chicago"})

    {:ok, conn: conn, project: project}
  end

  defp member!(name, email) do
    user =
      Repo.insert!(%User{
        email: email,
        name: name,
        oidc_sub: "oidc-calendar-origin-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp commit(view, value) do
    view |> element(@search) |> render_hook("meeting_create_invite_commit", %{"value" => value})
  end

  defp staged_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#start-meeting-form [data-role="meeting-invite-row"]))
    |> LazyHTML.attribute("data-entry-id")
  end

  defp input_value(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}")
    |> LazyHTML.attribute("value")
  end

  defp submit(view, project, overrides) do
    params =
      Map.merge(
        %{
          "name" => "Calendar review",
          "project_id" => project.id,
          "date" => "2026-11-04",
          "start_time" => "2:00 PM",
          "duration_minutes" => "30",
          "invite_query" => ""
        },
        overrides
      )

    view |> form("#start-meeting-form", start_meeting: params) |> render_submit()
  end

  describe "prefill" do
    test "a calendar link opens the sheet with date and start prefilled and nothing staged",
         %{conn: conn} do
      {:ok, view, html} = live(conn, @calendar_path)

      assert has_element?(view, ~s([data-role="start-meeting-sheet"]))
      assert input_value(html, "meeting-create-date") == ["2026-11-04"]
      assert input_value(html, "meeting-create-start-time") == ["2:00 PM"]
      assert staged_ids(html) == []
    end

    test "start_time is re-emitted in the sheet's own format", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/meetings?schedule=true&from=calendar&date=2026-11-04&start_time=14:30")

      assert input_value(html, "meeting-create-start-time") == ["2:30 PM"]
    end

    test "an unparseable date and start_time are dropped, not echoed", %{conn: conn} do
      {:ok, view, html} =
        live(conn, "/meetings?schedule=true&from=calendar&date=2026-13-45&start_time=lunchish")

      assert has_element?(view, ~s([data-role="start-meeting-sheet"]))
      assert input_value(html, "meeting-create-date") == [""]
      assert input_value(html, "meeting-create-start-time") == [""]
      refute html =~ "2026-13-45"
      refute html =~ "lunchish"
    end
  end

  describe "create from a calendar-origin sheet" do
    test "calendar-origin create records the member and the guest invite",
         %{conn: conn, project: project} do
      quill = member!("Quillon Zebedee", "quillon.zebedee@example.com")
      {:ok, view, _html} = live(conn, @calendar_path)

      commit(view, "Quillon Zebedee")
      html = commit(view, "guest@example.com")
      assert staged_ids(html) == ["user:" <> quill.id, "guest:guest@example.com"]

      result = submit(view, project, %{})

      assert [%Meeting{} = meeting] = Repo.all(Meeting)
      assert %DateTime{} = meeting.scheduled_start_at

      invites = Repo.all(from(i in Invite, where: i.meeting_id == ^meeting.id))
      assert length(invites) == 2
      assert Enum.count(invites, &(&1.user_id == quill.id)) == 1
      assert Enum.count(invites, &(&1.email == "guest@example.com" and is_nil(&1.user_id))) == 1
      assert length(Meetings.list_invites(meeting.id)) == 2

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == "/calendar?date=2026-11-04&select=#{meeting.id}"
    end

    test "a typed but unadded address is refused with no row and no redirect",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, @calendar_path)
      commit(view, "guest@example.com")

      html = submit(view, project, %{"invite_query" => "elias@example.com"})

      assert is_binary(html)
      assert html =~ "Add elias@example.com or clear it."
      refute Repo.exists?(Meeting)
    end

    test "a sheet opened without from=calendar still stays on the index",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/meetings?schedule=true")

      html = submit(view, project, %{})

      assert is_binary(html)
      assert html =~ "Meeting created."
      assert [%Meeting{}] = Repo.all(Meeting)
    end
  end

  describe "close" do
    test "closing a calendar-origin sheet navigates back to the calendar day", %{conn: conn} do
      {:ok, view, _html} = live(conn, @calendar_path)

      assert {:error, {:live_redirect, %{to: "/calendar?date=2026-11-04"}}} =
               view |> element(~s([data-role="start-meeting-sheet-close"])) |> render_click()
    end

    test "closing a sheet with no origin only hides it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meetings?schedule=true")

      html = view |> element(~s([data-role="start-meeting-sheet-close"])) |> render_click()

      assert is_binary(html)
      refute has_element?(view, ~s([data-role="start-meeting-sheet"]))
    end
  end

  describe "calendar-origin chrome (stage 3)" do
    test "calendar origin renders the toggle with Meeting checked, the helper and one Create meeting",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @calendar_path)

      assert has_element?(view, "#start-meeting-sheet-title", "New")
      refute has_element?(view, "#start-meeting-sheet-title", "New meeting")

      assert has_element?(
               view,
               ~s([data-role="new-kind-toggle"] [role="radio"][data-kind="meeting"][aria-checked="true"])
             )

      assert has_element?(
               view,
               ~s([data-role="new-kind-toggle"] [role="radio"][data-kind="event"][aria-checked="false"])
             )

      assert view |> element(~s([data-role="meeting-create-helper"])) |> render() =~
               "Meetings get a room link and send invites."

      assert view
             |> element(~s(button[data-role="meeting-create-submit-calendar"][type="submit"]))
             |> render() =~ "Create meeting"

      # The active Meeting dot takes the segment's content colour, so it
      # does not vanish on the primary fill (stage 4).
      assert has_element?(
               view,
               ~s([data-kind="meeting"][aria-checked="true"] [data-role="new-kind-swatch"].bg-primary-content)
             )

      refute has_element?(
               view,
               ~s([data-kind="meeting"][aria-checked="true"] [data-role="new-kind-swatch"].cal-k-meeting)
             )

      refute has_element?(view, ~s([data-role="meeting-meet-now"]))
      refute has_element?(view, ~s([data-role="meeting-create-submit-mobile"]))
      refute has_element?(view, ~s([data-role="start-meeting-submit"]))
      refute has_element?(view, ~s([data-role="start-meeting-cancel"]))
    end

    test "without an origin the sheet renders as before", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/meetings?schedule=true")

      assert has_element?(view, "#start-meeting-sheet-title", "New meeting")
      assert has_element?(view, ~s([data-role="meeting-meet-now"]))
      assert has_element?(view, ~s([data-role="start-meeting-submit"]))
      refute has_element?(view, ~s([data-role="new-kind-toggle"]))
      refute has_element?(view, ~s([data-role="meeting-create-helper"]))
      refute has_element?(view, ~s([data-role="meeting-create-submit-calendar"]))
    end

    test "Event carries the date and start back to Calendar's New editor", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, "/meetings?schedule=true&from=calendar")

      view
      |> form("#start-meeting-form",
        start_meeting: %{
          "name" => "",
          "project_id" => project.id,
          "date" => "2026-11-04",
          "start_time" => "3:00 PM",
          "duration_minutes" => "30"
        }
      )
      |> render_change()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element(~s([data-role="new-kind-toggle"] [data-kind="event"]))
               |> render_click()

      %URI{path: path, query: query} = URI.parse(to)
      assert path == "/calendar"

      assert URI.decode_query(query) == %{
               "new" => "1",
               "date" => "2026-11-04",
               "start" => "3:00 PM"
             }

      refute Repo.exists?(Meeting)
    end

    test "a staged guest row's tag says guest in text", %{conn: conn} do
      {:ok, view, _html} = live(conn, @calendar_path)

      html = commit(view, "guest@example.com")

      assert [tag] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(
                 ~s(#start-meeting-form [data-role="meeting-invite-row"][data-entry-id="guest:guest@example.com"] [data-role="meeting-invite-tag"])
               )
               |> LazyHTML.text()
               |> List.wrap()

      assert tag =~ "guest"
    end
  end

  describe "Calendar to Meetings round trip (stage 4)" do
    test "slot, Meeting, stage a member and a guest, create, and land back on the calendar",
         %{conn: conn, project: project} do
      quill = member!("Quillon Zebedee", "quillon.zebedee@example.com")

      {:ok, cal, _html} = live(conn, "/calendar?date=2026-11-04")
      render_click(cal, "new_at", %{"date" => "2026-11-04", "minute" => "630"})
      assert has_element?(cal, "#calendar-event-form input[name='event[start]'][value='10:30 AM']")

      {:ok, sheet, _html} =
        cal
        |> element("#calendar-editor [data-role=new-kind-toggle] [data-kind=meeting]")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(sheet, ~s([data-role="meeting-create-submit-calendar"]))
      assert has_element?(sheet, "#meeting-create-date[value='2026-11-04']")
      assert has_element?(sheet, "#meeting-create-start-time[value='10:30 AM']")

      commit(sheet, "Quillon Zebedee")
      commit(sheet, "guest@example.com")

      result =
        sheet
        |> form("#start-meeting-form",
          start_meeting: %{
            "name" => "Round trip",
            "project_id" => project.id,
            "date" => "2026-11-04",
            "start_time" => "10:30 AM",
            "duration_minutes" => "30",
            "invite_query" => ""
          }
        )
        |> render_submit()

      # Cross-live_session push_navigate: LiveViewTest reports it as a
      # live_redirect; follow_redirect/2 mounts CalendarLive fresh.
      assert {:error, {:live_redirect, %{to: "/calendar?" <> _}}} = result
      {:ok, cal, html} = follow_redirect(result, conn)

      assert [%Meeting{} = meeting] = Repo.all(Meeting)
      assert %DateTime{} = meeting.scheduled_start_at
      assert html =~ "Meeting created."

      assert has_element?(cal, ".cal-ev[data-kind=meeting]", "Round trip")
      assert has_element?(cal, "[data-role=calendar-details] h3", "Round trip")

      invites = Repo.all(from(i in Invite, where: i.meeting_id == ^meeting.id))
      assert length(invites) == 2
      assert Enum.count(invites, &(&1.user_id == quill.id)) == 1
      assert Enum.count(invites, &(&1.email == "guest@example.com" and is_nil(&1.user_id))) == 1
    end
  end
end
