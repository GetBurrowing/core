defmodule PlatformWeb.TasksLiveProjectGroupingTest do
  @moduledoc """
  Stage 5 of ADR-0042 (+ V1 e2e regression fix): the Tasks sidebar
  groups its project picker by owning org. Fabrikam (root) renders first,
  then tenant orgs in canonical `Platform.Tenancy.tenant_priority/0`
  order — Soylent, Wayne-Tech, SXI, Paragon — matching the
  project-create FAB's `<select>` so the two surfaces never disagree.
  Each section is a collapsible `<details>` with a colored dot driven
  by `Platform.Tenancy.scope_color/1`.

  Covers the desktop sidebar, the mobile project sheet, AND the breadcrumb
  org-prefix — all four template surfaces that read `@projects_by_org`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_grp_#{System.unique_integer([:positive])}@example.com",
        name: "Grouping Test User",
        oidc_sub: "oidc-tasks-grp-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp seed_project(org_slug, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
        org_id: tenant_or_fabrikam_org_id(org_slug)
      })

    project
  end

  defp tenant_or_fabrikam_org_id("fabrikam"), do: fabrikam_org_id()
  defp tenant_or_fabrikam_org_id(slug), do: tenant_org_id(slug)

  describe "sidebar project picker grouped by org" do
    test "renders one <details> section per org slug present in the data", %{conn: conn} do
      conn = authenticated_conn(conn)

      # Seed projects across multiple orgs (Fabrikam + 2 tenants).
      _fabrikam_proj = seed_project("fabrikam", "Platform Core")
      _gen_proj = seed_project("soylent", "Soylent Storefront")
      _sxi_proj = seed_project("sxi", "SXI Onboarding")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Each org slug present in the seeded data renders a <details>
      # section keyed by `data-org-slug=<slug>`.
      assert html =~ ~s(data-role="project-group" data-org-slug="fabrikam")
      assert html =~ ~s(data-role="project-group" data-org-slug="soylent")
      assert html =~ ~s(data-role="project-group" data-org-slug="sxi")

      # Header labels come from Tenancy.scope_label/1 (canonical
      # human-readable names).
      assert html =~ "Fabrikam"
      assert html =~ "Soylent"
      assert html =~ "SXI"

      # Project names render inside their sections.
      assert html =~ "Platform Core"
      assert html =~ "Soylent Storefront"
      assert html =~ "SXI Onboarding"
    end

    test "Fabrikam (root) section renders before any tenant section", %{conn: conn} do
      conn = authenticated_conn(conn)

      # Alphabetical name order would put Paragon first, but Fabrikam must
      # always lead because it's the root org.
      _paragon = seed_project("paragon", "Paragon Project")
      _fabrikam = seed_project("fabrikam", "Fabrikam Project")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      fabrikam_pos = :binary.match(html, ~s(data-org-slug="fabrikam"))
      paragon_pos = :binary.match(html, ~s(data-org-slug="paragon"))

      assert is_tuple(fabrikam_pos) and is_tuple(paragon_pos)
      {fabrikam_idx, _} = fabrikam_pos
      {alt_idx, _} = paragon_pos
      assert fabrikam_idx < alt_idx, "Fabrikam section must render before tenant sections"
    end

    test "tenant sections render in canonical tenant-priority order", %{conn: conn} do
      # Regression for V1 e2e failure: the sidebar used to sort tenants
      # alphabetically by name (putting Paragon first), but the reviewer
      # expected the canonical "tenant-priority" order matching the seed
      # list — Soylent, Wayne-Tech, SXI, Paragon — also matching the
      # project-create FAB's <select> ordering.
      conn = authenticated_conn(conn)

      # Insert in reverse priority order to ensure the sort actually fires.
      _paragon = seed_project("paragon", "Paragon Project")
      _sxi = seed_project("sxi", "SXI Project")
      _wayne_tech = seed_project("wayne_tech", "Wayne-Tech Project")
      _soylent = seed_project("soylent", "Soylent Project")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      positions =
        for slug <- ["paragon", "soylent", "wayne_tech", "sxi"] do
          {idx, _} = :binary.match(html, ~s(data-org-slug="#{slug}"))
          {slug, idx}
        end

      sorted = Enum.sort_by(positions, fn {_slug, idx} -> idx end)

      assert Enum.map(sorted, &elem(&1, 0)) == ["soylent", "wayne_tech", "sxi", "paragon"],
             "expected soylent → wayne_tech → sxi → paragon (tenant-priority) render order, got: #{inspect(sorted)}"
    end

    test "@orgs assigns surface in tenant-priority order for the FAB <select>", %{conn: conn} do
      # The project-create FAB's <option> list must match the sidebar
      # grouping order so the two surfaces don't disagree. The FAB
      # sheet is conditionally rendered behind `@show_project_create_sheet`,
      # so we have to trigger the toggle first to materialize the
      # <select>.
      conn = authenticated_conn(conn)
      _ = seed_project("fabrikam", "Anchor")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Open the FAB sheet.
      render_click(view, "toggle_project_create_sheet")
      html = render(view)

      # Slice the HTML from the FAB's <select> open tag to its </select>.
      [_, after_open] = String.split(html, ~s(data-role="project-create-org-select"), parts: 2)
      [options_block, _] = String.split(after_open, "</select>", parts: 2)

      # Pull each option's label text in render order.
      option_labels =
        Regex.scan(~r/<option[^>]*>\s*([^<]+?)\s*<\/option>/, options_block)
        |> Enum.map(fn [_, label] -> String.trim(label) end)
        |> Enum.reject(&(&1 == "Select org"))

      # First label should be Fabrikam (root); tenant labels follow canonical order.
      assert hd(option_labels) == "Fabrikam",
             "expected FAB select to lead with Fabrikam; got: #{inspect(option_labels)}"

      tenants_in_order = Enum.drop(option_labels, 1) |> Enum.take(4)

      assert tenants_in_order == ["Soylent", "Wayne-Tech", "SXI", "Paragon"],
             "FAB org-select tenant ordering: #{inspect(tenants_in_order)}"
    end

    test "breadcrumb prefixes selected project with org label", %{conn: conn} do
      conn = authenticated_conn(conn)
      proj = seed_project("soylent", "Storefront")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Drive the select-project handler. The project button is rendered
      # in BOTH the desktop sidebar AND the mobile sheet, so a plain CSS
      # selector matches twice — scope to the desktop `<aside>` to make
      # the selector unique.
      view
      |> element(~s(aside button[phx-click="select_project"][phx-value-id="#{proj.id}"]))
      |> render_click()

      html = render(view)

      # Breadcrumb shows "Soylent / Storefront" with the org-scope color
      # class on the org label. The breadcrumb lives in the board header.
      breadcrumb =
        Regex.run(
          ~r/<div[^>]*selected_project_id[\s\S]*?<\/div>|<div[^>]*flex items-center gap-1 text-xs[\s\S]*?<\/div>/,
          html
        ) || [""]

      _ = breadcrumb

      # `text-soylent` appears only on the breadcrumb's org-label span
      # (org dots use `bg-current text-<scope>` inside the sidebar but
      # those render even pre-selection — so this assertion needs to
      # specifically prove the breadcrumb fires). Use the breadcrumb's
      # adjacent slash separator as a positional anchor.
      assert html =~ "Storefront"
      # The "/" between org label and project name is part of the
      # breadcrumb only.
      assert html =~ ~r/text-soylent[^>]*>\s*Soylent\s*<\/span>\s*<span[^>]*>\s*\/\s*<\/span>/
    end
  end
end
