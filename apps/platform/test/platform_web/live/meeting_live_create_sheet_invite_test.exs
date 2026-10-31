defmodule PlatformWeb.MeetingLiveCreateSheetInviteTest do
  @moduledoc """
  Enter in the new-meeting sheet's invite search (task 01a192d6 stage 3).

  The `InviteSearchEnter` hook pushes `meeting_create_invite_commit` with the
  raw typed value. The server stages exactly the option the dropdown would
  highlight, and a submit with a typed but unadded address is refused
  rather than silently dropping it.

  Commits are pushed through `render_hook/3` on the search input element,
  which also asserts the input carries a `phx-hook`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @search "#meeting-create-invite-search"

  setup %{conn: conn} do
    user = member!("Sheet Host", "sheet_host_#{System.unique_integer([:positive])}@example.com")

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Invite Enter Project #{System.unique_integer([:positive])}",
        slug: "invite-enter-project-#{System.unique_integer([:positive])}",
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
        oidc_sub: "oidc-invite-enter-#{System.unique_integer([:positive])}"
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

  defp open_sheet(conn) do
    {:ok, view, _html} = live(conn, ~p"/meetings")
    _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
    view
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

  defp submit(view, project, overrides) do
    params =
      Map.merge(
        %{
          "name" => "Invite review",
          "project_id" => project.id,
          "date" => "",
          "start_time" => "",
          "duration_minutes" => "30",
          "invite_query" => ""
        },
        overrides
      )

    view |> form("#start-meeting-form", start_meeting: params) |> render_submit()
  end

  describe "Enter commits the highlighted option" do
    test "an address that matched nobody stages the default guest row and creates no meeting",
         %{conn: conn} do
      view = open_sheet(conn)

      html = commit(view, "guest@example.com")

      assert staged_ids(html) == ["guest:guest@example.com"]
      refute Repo.exists?(Meeting)
    end

    test "a query matching exactly one member stages that member", %{conn: conn} do
      quill = member!("Quillon Zebedee", "quillon.zebedee@example.com")
      view = open_sheet(conn)

      html = commit(view, "Quillon Zebedee")

      assert staged_ids(html) == ["user:" <> quill.id]
    end

    test "a query matching two members stages nothing and leaves the dropdown open",
         %{conn: conn} do
      member!("Quillon Zebedee", "quillon.zebedee@example.com")
      member!("Quillon Zephyr", "quillon.zephyr@example.com")
      view = open_sheet(conn)

      html = commit(view, "Quillon")

      assert staged_ids(html) == []
      assert has_element?(view, ~s([data-role="meeting-invite-candidate"]))
    end

    test "a blank value does nothing", %{conn: conn} do
      view = open_sheet(conn)

      html = commit(view, "   ")

      assert staged_ids(html) == []
    end
  end

  describe "submit with a typed but unadded address" do
    test "is refused, writes no row, and keeps the staged guest and the typed text",
         %{conn: conn, project: project} do
      view = open_sheet(conn)
      commit(view, "guest@example.com")

      html = submit(view, project, %{"invite_query" => "elias@example.com"})

      assert html =~ "Add elias@example.com or clear it."
      refute Repo.exists?(Meeting)
      assert staged_ids(html) == ["guest:guest@example.com"]
      assert has_element?(view, ~s(#{@search}[value="elias@example.com"]))
    end

    test "a blank query with one staged guest creates the meeting with exactly one invite",
         %{conn: conn, project: project} do
      view = open_sheet(conn)
      commit(view, "guest@example.com")

      html = submit(view, project, %{"invite_query" => ""})

      assert html =~ "Meeting created."
      assert [%Meeting{} = meeting] = Repo.all(Meeting)
      assert [invite] = Meetings.list_invites(meeting.id)
      assert invite.email == "guest@example.com"
    end
  end
end
