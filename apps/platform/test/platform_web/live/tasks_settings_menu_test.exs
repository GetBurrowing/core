defmodule PlatformWeb.TasksSettingsMenuTest do
  @moduledoc """
  Task 019fed1e — the admin-only settings cog in the Tasks module header, and
  the admin-only pipeline page it leads to.

  The asymmetry is the point, and it needs BOTH directions:

    * an admin must be able to reach pipeline THROUGH THE RENDERED
      AFFORDANCE. Firing `toggle_settings_menu` by name or GETting
      `/tasks/pipeline` would prove the handler and the route exist while a
      header with no cog in it passed the whole suite. So this drives the UI:
      find the trigger, click it, find the link, follow it.
    * a member must be refused SERVER-SIDE on a direct request that
      deliberately bypasses the affordance. Hiding the cog is not access
      control.
    * a member must not see the cog — asserted in the same test as a positive
      assertion that the member CAN see the Tasks page, so the absence is a
      distinction rather than what a blank or errored render would have
      produced anyway.

  Every assertion goes through a stable `data-role`, never rendered copy.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # LazyHTML, not Floki — Phoenix.LiveViewTest 1.1 replaced it.
  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  # LazyHTML is a struct, not a list: `q(...) == []` is FALSE even for zero
  # nodes, so a naive emptiness assertion fails on an empty match and a naive
  # `!= []` passes on one. Count instead.
  defp count(html, selector), do: html |> q(selector) |> Enum.count()

  defp member_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks-settings-member-#{n}@example.com",
        name: "Tasks Settings Member",
        oidc_sub: "oidc-tasks-settings-member-#{n}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks-settings-admin-#{n}@example.com",
        name: "Tasks Settings Admin",
        oidc_sub: "oidc-tasks-settings-admin-#{n}"
      })

    org = Tenancy.get_org_by_slug!("acme")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "admin"})
    |> Repo.insert!()

    init_test_session(conn, current_user_id: user.id)
  end

  describe "an admin reaching pipeline through the cog" do
    test "clicks the trigger, follows the rendered row, and lands on the pipeline page",
         %{conn: conn} do
      conn = admin_conn(conn)
      {:ok, view, html} = live(conn, "/tasks")

      # The affordance exists before anything is clicked, and the menu does
      # not — otherwise "clicking opened it" is not a claim about the click.
      assert count(html, "[data-role=tasks-settings-menu-trigger]") == 1
      assert count(html, "[data-role=tasks-settings-pipeline-link]") == 0

      opened =
        view
        |> element("[data-role=tasks-settings-menu-trigger]")
        |> render_click()

      assert count(opened, "[data-role=tasks-settings-pipeline-link]") == 1,
             "the settings menu did not render its Pipeline row"

      link = q(opened, "[data-role=tasks-settings-pipeline-link]")

      # The row is two lines, and the description is what makes a one-item
      # menu worth existing. Asserted as structure (a second child element
      # under the link), not as the copy itself.
      assert length(LazyHTML.query(link, "span") |> Enum.to_list()) >= 2

      {:ok, pipeline_view, pipeline_html} =
        view
        |> element("[data-role=tasks-settings-pipeline-link]")
        |> render_click()
        |> follow_redirect(conn, "/tasks/pipeline")

      assert count(pipeline_html, "[data-role=pipeline-page]") == 1
      assert pipeline_view.module == PlatformWeb.PipelineLive
    end
  end

  describe "a member" do
    test "sees the Tasks page but no settings cog anywhere in it", %{conn: conn} do
      {:ok, _view, html} = conn |> member_conn() |> live("/tasks")

      # Anti-vacuity, paired in the same test: the member really did render
      # the Tasks page. Without this the refute below would pass on a blank
      # body, an error page, or a redirect.
      assert count(html, "[data-role=header-new-task]") > 0,
             "the member did not render the Tasks page at all"

      assert count(html, "[data-role=tasks-settings-menu-trigger]") == 0
      assert count(html, "[data-role=tasks-settings-pipeline-link]") == 0
      assert count(html, "[data-role=tasks-settings-pipeline-link-mobile]") == 0
    end

    test "is refused /tasks/pipeline on a direct request that bypasses the affordance",
         %{conn: conn} do
      assert {:error, {_, %{to: "/access-denied?module=tasks"}}} =
               conn |> member_conn() |> live("/tasks/pipeline")
    end
  end
end
