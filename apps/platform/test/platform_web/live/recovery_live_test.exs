defmodule PlatformWeb.RecoveryLiveTest do
  @moduledoc """
  The Recovery surface (task 019f4eaa stage 6): lists archived +
  deletion-scheduled containers and restores them. Fabrikam-admin only.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "recovery-#{n}@example.com",
      name: "User #{n}",
      oidc_sub: "oidc-recovery-#{n}"
    })
  end

  defp fabrikam_admin_conn(conn) do
    user = insert_user()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp member_conn(conn) do
    user = insert_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_project(org_slug) do
    org = Tenancy.get_org_by_slug!(org_slug)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Proj #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git",
        org_id: org.id
      })

    project
  end

  describe "fabrikam admin" do
    test "empty state renders when nothing is archived", %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/admin/recovery")

      assert html =~ "Nothing archived"
    end

    # ── What Restore brings back with it (Marlowe's ask, 2026-07-16) ────────
    #
    # Cascade children are deliberately NOT rows of their own — they return
    # with their org, so a separate Restore for them would imply you could
    # surface a project under a still-hidden org. Marlowe walked exactly this
    # and asked the reasonable question: then how do I see what's inside?
    # The row now says so.

    test "an archived org's row lists the children its Restore will bring back", %{conn: conn} do
      {conn, admin} = fabrikam_admin_conn(conn)
      org = Tenancy.get_org_by_slug!("paragon")
      project = create_project("paragon")
      {:ok, _} = Tasks.update_project(project, %{name: "Site Expansion"})

      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      row = "[data-role=recovery-row][data-id='#{org.id}']"
      assert has_element?(view, "#{row} [data-role=recovery-row-hidden]")
      assert render(view) =~ "Site Expansion"
    end

    test "the row lists ONLY what Restore actually returns — not an inventory", %{conn: conn} do
      # The honesty property. An independently-archived child has a NULL
      # provenance marker, so the org's Restore does NOT bring it back — and
      # the row must not claim it will.
      {conn, admin} = fabrikam_admin_conn(conn)
      org = Tenancy.get_org_by_slug!("paragon")

      cascaded = create_project("paragon")
      {:ok, _} = Tasks.update_project(cascaded, %{name: "Comes Back"})

      independent = create_project("paragon")
      {:ok, _} = Tasks.update_project(independent, %{name: "Stays Archived"})
      {:ok, _} = Tasks.archive_project(admin, Repo.reload!(independent))

      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      hidden =
        view
        |> element(
          "[data-role=recovery-row][data-id='#{org.id}'] [data-role=recovery-row-hidden]"
        )
        |> render()

      assert hidden =~ "Comes Back"
      refute hidden =~ "Stays Archived"
    end

    test "no hidden line on a project row — a project has no cascade", %{conn: conn} do
      {conn, admin} = fabrikam_admin_conn(conn)
      project = create_project("sxi")
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      row = "[data-role=recovery-row][data-id='#{project.id}']"
      assert has_element?(view, row)
      refute has_element?(view, "#{row} [data-role=recovery-row-hidden]")
    end

    test "lists an archived project and Restore brings it back to active", %{conn: conn} do
      {conn, admin} = fabrikam_admin_conn(conn)
      project = create_project("soylent")
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      row = "[data-role=recovery-row][data-id='#{project.id}']"
      assert has_element?(view, row)
      assert render(view) =~ project.name

      view |> element("#{row} [data-role=restore]") |> render_click()

      # Row leaves the recovery list and the DB row is active again.
      refute has_element?(view, row)
      refute Repo.get(Project, project.id).archived_at
    end

    test "a deletion-scheduled project shows under Scheduled and Restore cancels the deletion", %{
      conn: conn
    } do
      {conn, admin} = fabrikam_admin_conn(conn)
      project = create_project("sxi")
      {:ok, _} = Tasks.schedule_project_deletion(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      row = "[data-role=recovery-row][data-id='#{project.id}']"
      assert has_element?(view, "#{row}[data-status=scheduled]")

      view |> element("#{row} [data-role=restore]") |> render_click()

      refute has_element?(view, row)
      reloaded = Repo.get(Project, project.id)
      refute reloaded.archived_at
      refute reloaded.deletion_scheduled_at
    end

    test "Restore is the only action offered — on a scheduled row and an archived one",
         %{conn: conn} do
      {conn, admin} = fabrikam_admin_conn(conn)
      scheduled_project = create_project("sxi")
      archived_project = create_project("paragon")
      {:ok, _} = Tasks.schedule_project_deletion(admin, scheduled_project)
      {:ok, _} = Tasks.archive_project(admin, archived_project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      scheduled_row = "[data-role=recovery-row][data-id='#{scheduled_project.id}']"
      archived_row = "[data-role=recovery-row][data-id='#{archived_project.id}']"

      assert has_element?(view, "#{scheduled_row}[data-status=scheduled] [data-role=restore]")
      assert has_element?(view, "#{archived_row}[data-status=archived] [data-role=restore]")

      # No intermediate "stop the countdown but stay archived" action: it
      # duplicated Restore without offering anything Restore does not
      # (task 019f4eaa review). Restore is the whole recovery vocabulary.
      refute has_element?(view, "[data-role=keep]")
    end
  end

  describe "non-admin" do
    test "is refused (redirected away from the recovery route)", %{conn: conn} do
      {conn, _user} = member_conn(conn)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/admin/recovery")
    end
  end
end
