defmodule PlatformWeb.TasksLiveProjectGroupingTest do
  @moduledoc """
  Stage 5 of ADR-0042 (+ V1 e2e regression fix): the Tasks sidebar
  groups its project picker by owning org. Acme (root) renders first,
  then tenant orgs in canonical `Platform.Tenancy.tenant_priority/0`
  order — Initech, Vandelay-Ind, Globex, Hooli — matching the
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
      |> member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp seed_project(org_slug, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
        org_id: tenant_or_acme_org_id(org_slug)
      })

    project
  end

  defp tenant_or_acme_org_id("acme"), do: acme_org_id()
  defp tenant_or_acme_org_id(slug), do: tenant_org_id(slug)

  describe "sidebar project picker grouped by org" do
    test "renders one <details> section per org slug present in the data", %{conn: conn} do
      conn = authenticated_conn(conn)

      # Seed projects across multiple orgs (Acme + 2 tenants).
      _acme_proj = seed_project("acme", "Platform Core")
      _gen_proj = seed_project("initech", "Initech Storefront")
      _globex_proj = seed_project("globex", "Globex Onboarding")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Each org slug present in the seeded data renders a <details>
      # section keyed by `data-org-slug=<slug>`.
      assert html =~ ~s(data-role="project-group" data-org-slug="acme")
      assert html =~ ~s(data-role="project-group" data-org-slug="initech")
      assert html =~ ~s(data-role="project-group" data-org-slug="globex")

      # Header labels come from Tenancy.scope_label/1 (canonical
      # human-readable names).
      assert html =~ "Acme"
      assert html =~ "Initech"
      assert html =~ "Globex"

      # Project names render inside their sections.
      assert html =~ "Platform Core"
      assert html =~ "Initech Storefront"
      assert html =~ "Globex Onboarding"
    end

    test "Acme (root) section renders before any tenant section", %{conn: conn} do
      conn = authenticated_conn(conn)

      # Alphabetical name order would put Hooli first, but Acme must
      # always lead because it's the root org.
      _hooli = seed_project("hooli", "Hooli Project")
      _acme = seed_project("acme", "Acme Project")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      acme_pos = :binary.match(html, ~s(data-org-slug="acme"))
      hooli_pos = :binary.match(html, ~s(data-org-slug="hooli"))

      assert is_tuple(acme_pos) and is_tuple(hooli_pos)
      {acme_idx, _} = acme_pos
      {alt_idx, _} = hooli_pos
      assert acme_idx < alt_idx, "Acme section must render before tenant sections"
    end

    test "tenant sections render in canonical tenant-priority order", %{conn: conn} do
      # Regression for V1 e2e failure: the sidebar used to sort tenants
      # alphabetically by name (putting Hooli first), but the reviewer
      # expected the canonical "tenant-priority" order matching the seed
      # list — Initech, Vandelay-Ind, Globex, Hooli — also matching the
      # project-create FAB's <select> ordering.
      conn = authenticated_conn(conn)

      # Insert in reverse priority order to ensure the sort actually fires.
      _hooli = seed_project("hooli", "Hooli Project")
      _globex = seed_project("globex", "Globex Project")
      _vandelay_ind = seed_project("vandelay_ind", "Vandelay-Ind Project")
      _initech = seed_project("initech", "Initech Project")

      {:ok, _view, html} = live(conn, ~p"/tasks")

      positions =
        for slug <- ["hooli", "initech", "vandelay_ind", "globex"] do
          {idx, _} = :binary.match(html, ~s(data-org-slug="#{slug}"))
          {slug, idx}
        end

      sorted = Enum.sort_by(positions, fn {_slug, idx} -> idx end)

      assert Enum.map(sorted, &elem(&1, 0)) == ["initech", "vandelay_ind", "globex", "hooli"],
             "expected initech → vandelay_ind → globex → hooli (tenant-priority) render order, got: #{inspect(sorted)}"
    end

    test "@orgs assigns surface in tenant-priority order for the FAB <select>", %{conn: conn} do
      # The project-create FAB's <option> list must match the sidebar
      # grouping order so the two surfaces don't disagree. The FAB
      # sheet is conditionally rendered behind `@show_project_create_sheet`,
      # so we have to trigger the toggle first to materialize the
      # <select>.
      conn = authenticated_conn(conn)
      _ = seed_project("acme", "Anchor")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Open the FAB sheet.
      sidebar_click(view, "sidebar_toggle_project_create_sheet")
      html = render(view)

      # Slice the HTML from the FAB's <select> open tag to its </select>.
      [_, after_open] = String.split(html, ~s(data-role="project-create-org-select"), parts: 2)
      [options_block, _] = String.split(after_open, "</select>", parts: 2)

      # Pull each option's label text in render order.
      option_labels =
        Regex.scan(~r/<option[^>]*>\s*([^<]+?)\s*<\/option>/, options_block)
        |> Enum.map(fn [_, label] -> String.trim(label) end)
        |> Enum.reject(&(&1 == "Select org"))

      # First label should be Acme (root); tenant labels follow canonical order.
      assert hd(option_labels) == "Acme",
             "expected FAB select to lead with Acme; got: #{inspect(option_labels)}"

      tenants_in_order = Enum.drop(option_labels, 1) |> Enum.take(4)

      assert tenants_in_order == ["Initech", "Vandelay-Ind", "Globex", "Hooli"],
             "FAB org-select tenant ordering: #{inspect(tenants_in_order)}"
    end

    test "breadcrumb prefixes selected project with org label", %{conn: conn} do
      conn = authenticated_conn(conn)
      proj = seed_project("initech", "Storefront")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Drive the select-project handler. The project button is rendered
      # in BOTH the desktop sidebar AND the mobile sheet, so a plain CSS
      # selector matches twice — scope to the desktop `<aside>` to make
      # the selector unique.
      view
      |> element(~s(aside button[phx-click="sidebar_select_project"][phx-value-id="#{proj.id}"]))
      |> render_click()

      html = render(view)

      # Breadcrumb shows "Initech / Storefront" with the org-scope color
      # class on the org label. The breadcrumb lives in the board header.
      breadcrumb =
        Regex.run(
          ~r/<div[^>]*selected_project_id[\s\S]*?<\/div>|<div[^>]*flex items-center gap-1 text-xs[\s\S]*?<\/div>/,
          html
        ) || [""]

      _ = breadcrumb

      # `text-initech` appears only on the breadcrumb's org-label span
      # (org dots use `bg-current text-<scope>` inside the sidebar but
      # those render even pre-selection — so this assertion needs to
      # specifically prove the breadcrumb fires). Use the breadcrumb's
      # adjacent slash separator as a positional anchor.
      assert html =~ "Storefront"
      # The "/" between org label and project name is part of the
      # breadcrumb only.
      assert html =~
               ~r/scope-fill-text"\s+data-scope="initech"[^>]*>\s*Initech\s*<\/span>\s*<span[^>]*>\s*\/\s*<\/span>/
    end
  end

  # ── Sidebar event helpers (task 01a008f6 stage 2) ──────────────────────
  #
  # Sidebar / Projects / Epics events live on
  # `PlatformWeb.TasksLive.SidebarComponent`. Dispatching to a LiveComponent
  # returns only THAT component's HTML, and any state the component asks the
  # shell to change arrives as a message the shell processes afterwards — so
  # a raw `render_click(with_target(...))` snapshot shows neither the board
  # nor the post-notify state. These helpers dispatch to the component and
  # then re-render the whole view, which is what every assertion here wants.

  defp sidebar_click(view, event, params \\ %{}) do
    _ = render_click(with_target(view, "#tasks-sidebar"), event, params)
    render(view)
  end
end
