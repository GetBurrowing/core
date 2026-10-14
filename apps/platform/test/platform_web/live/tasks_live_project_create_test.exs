defmodule PlatformWeb.TasksLiveProjectCreateTest do
  @moduledoc """
  Stage 5 of ADR-0042: a "+" button in the Tasks sidebar (and a mobile
  FAB) opens a New-Project bottom sheet. The form requires an `org_id`,
  defaults to the current user's primary membership's org, and on submit
  calls `Platform.Tasks.create_project/1`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Project

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_create_#{System.unique_integer([:positive])}@example.com",
        name: "Create Test User",
        oidc_sub: "oidc-tasks-create-#{System.unique_integer([:positive])}"
      })
      |> member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  describe "new-project sheet" do
    test "opens via the sidebar trigger and renders the org select", %{conn: conn} do
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The sheet is hidden by default.
      refute render(view) =~ ~s(data-role="project-create-form")

      view
      |> element(~s(button[data-role="project-create-trigger"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(data-role="project-create-form")
      assert html =~ ~s(data-role="project-create-org-select")
      assert html =~ "New Project"

      # The org select is populated from `Tenancy.list_orgs/0` — Acme +
      # the four tenant orgs that the seed migration installs. Options
      # carry the canonical scope labels from `Tenancy.scope_label/1`.
      select_html =
        Regex.run(
          ~r/data-role="project-create-org-select"[\s\S]*?<\/select>/,
          html
        )
        |> List.first()

      assert select_html, "expected org select to render in opened sheet"
      assert select_html =~ "Acme"
      assert select_html =~ "Soylent"
      assert select_html =~ "Wayne-Tech"
      assert select_html =~ "SXI"
      assert select_html =~ "Paragon"
    end

    test "submit creates a project owned by the chosen org", %{conn: conn} do
      conn = authenticated_conn(conn)
      org_id = tenant_org_id("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> element(~s(button[data-role="project-create-trigger"]))
      |> render_click()

      view
      |> form(~s(form[data-role="project-create-form"]), %{
        "project" => %{
          "name" => "Created Via Form",
          "slug" => "created-via-form",
          "org_id" => org_id
        }
      })
      |> render_submit()

      project = Repo.get_by!(Project, slug: "created-via-form")
      assert project.name == "Created Via Form"
      assert project.org_id == org_id

      # After create the sheet closes — verify the form is no longer in
      # the rendered DOM and the new project surfaces in the sidebar.
      html = render(view)
      refute html =~ ~s(data-role="project-create-form")
      assert html =~ "Created Via Form"
    end

    test "submit without org_id renders an inline error", %{conn: conn} do
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> element(~s(button[data-role="project-create-trigger"]))
      |> render_click()

      # `required` is enforced at the changeset layer
      # (`Project.changeset/2 |> validate_required([:name, :org_id])`).
      # Bypass the HTML `required` attribute by submitting via the
      # phx-submit path with an empty org_id.
      html =
        view
        |> form(~s(form[data-role="project-create-form"]), %{
          "project" => %{"name" => "No Org", "slug" => "no-org", "org_id" => ""}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Tasks.list_projects_unscoped() |> Enum.all?(fn p -> p.slug != "no-org" end)
    end

    # Re-skin Phase 2 stage 2 (task 019f51ca): the standalone project FAB
    # became a menu item inside the single create-FAB menu. The
    # data-role="project-create-fab" e2e hook moved onto that MENU ITEM;
    # md:hidden now lives on the FAB cluster wrapper (#tasks-create-fab)
    # because desktop creates via the page-header split button instead.
    test "create-FAB menu exposes the New-Project item and the cluster is md:hidden", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)

      {:ok, view, html} = live(conn, ~p"/tasks")

      # Menu closed by default — the item only renders once the FAB is tapped.
      refute html =~ ~s(data-role="project-create-fab")

      html = render_click(create(view), "taskcreate_toggle_fab")
      assert html =~ ~s(data-role="project-create-fab")

      # The wrapper hides the whole FAB cluster on md+.
      [_, classes] =
        Regex.run(~r/id="tasks-create-fab"[^>]*class="([^"]+)"/s, html) ||
          Regex.run(~r/class="([^"]+)"[^>]*id="tasks-create-fab"/s, html)

      assert classes =~ "md:hidden",
             "expected FAB cluster wrapper to carry md:hidden, got: #{classes}"

      # The menu item fires the same event the old FAB did and opens the
      # sheet (the toggle handler also closes the menu server-side).
      view
      |> element(~s(button[data-role="project-create-fab"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(data-role="project-create-form")
      refute html =~ ~s(data-role="fab-new-epic")
    end
  end

  # Task 01a008f6 stage 6: New-Task creation is a LiveComponent.
  defp create(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-create")
end
