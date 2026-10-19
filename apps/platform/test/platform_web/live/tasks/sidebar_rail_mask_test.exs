defmodule PlatformWeb.Tasks.SidebarRailMaskTest do
  @moduledoc """
  Screen-share name masking wired into the DESKTOP Tasks rail (task 01a00cf1
  stage 2).

  ## What "the rail" means here, and why the assertions are scoped to it

  Every absence assertion runs against the desktop `<aside>` SUBTREE, not the
  whole `/tasks` document. That is deliberate and it is a limitation, not a
  convenience:

    * The `<aside>` is what this stage changed. Scoping there means a failure
      names the surface that regressed.
    * The rest of the page still renders real org names — the FiltersComponent
      scope rail (`scope_pill/1`) and its breadcrumb both do, and the mobile
      `#project-sheet` renders the same rows as the rail unmasked. None are in
      this stage's scope. A whole-document sweep would fail today for reasons
      that are not this stage's, and softening it to make it pass would be the
      worse outcome. The gap is real and is recorded in the PR body.

  ## No excluded machine attributes any more

  `phx-value-id`, `phx-value-key` and `data-menu-key` used to be handed to
  `Platform.MaskAssertions.refute_name_anywhere/3` as the ARGUMENTS of the
  controls they sit on. They are not excluded here any more: the behavioural
  review found the real org slug alive in all three, and the org rows now route
  by the same per-session placeholder slug the label uses
  (`TaskDisplay.rail_org_slug/2`), which the handlers invert with
  `TaskDisplay.real_org_slug/2`. Project rows were always keyed by UUID, which
  is not a name. So there is nothing left in these attributes to exclude, and
  the sweeps below cover them.

  `class` is excluded module-level, which is what lets `Tenancy.scope_color/1`
  keep the real slug: it emits a colour utility and no name.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership

  # Nothing to exclude any more — see the moduledoc.
  @machine_attrs []

  # Tenant orgs only. Acme is masked too, but "acme" appears in the page's
  # own chrome (routes, ids) outside the rail, and sweeping the root org
  # would test the fixture rather than the feature.
  @tenants ~w(initech vandelay_ind globex)

  defp acme_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "rail-mask-#{n}@example.com",
        name: "Rail Mask User #{n}",
        oidc_sub: "oidc-rail-mask-#{n}"
      })

    # Member everywhere (project_sections is viewer-scoped), admin in Acme so
    # the lifecycle kebab — a derived-string leak site — actually renders.
    Enum.each(Tenancy.list_orgs(), fn org ->
      role = if org.slug == "acme", do: "admin", else: "member"

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
      |> Repo.insert!()
    end)

    init_test_session(conn, current_user_id: user.id)
  end

  defp seed_project(org_slug, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
        org_id: Tenancy.get_org_by_slug!(org_slug).id
      })

    project
  end

  defp seed_rail do
    %{
      initech: seed_project("initech", "Initech Storefront"),
      protect: seed_project("vandelay_ind", "Vandelay-Ind Rollout"),
      globex: seed_project("globex", "Globex Onboarding")
    }
  end

  # The desktop `<aside>` subtree only. See the moduledoc.
  defp rail(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("aside")
    |> LazyHTML.to_html()
  end

  defp toggle_mask(view, masked?) do
    view
    |> element("[data-role=rail-mask-toggle]")
    |> render_click(%{"masked" => to_string(masked?)})
  end

  # Every real name the rail carries: the three tenant display names, their
  # slugs (both spellings are covered by `forms/1`), and the project names.
  defp real_names(projects) do
    Enum.map(@tenants, &Tenancy.get_org_by_slug!(&1).name) ++
      @tenants ++
      Enum.map(Map.values(projects), & &1.name)
  end

  describe "unmasked (default)" do
    test "the rail renders real names and real slugs, and the eye is unpressed", %{conn: conn} do
      conn = acme_admin_conn(conn)
      projects = seed_rail()

      {:ok, _view, html} = live(conn, ~p"/tasks")
      rail = rail(html)

      # ANTI-VACUITY. Every name the masked sweep below refutes is asserted
      # PRESENT here first, so a green sweep is known to be testing a surface
      # that actually carried the name. Without this pair the sweep would pass
      # just as happily against an empty rail.
      for name <- real_names(projects), do: assert_name_anywhere(rail, name)

      assert rail =~ ~s(data-org-slug="initech")
      assert rail =~ ~s(aria-pressed="false")
      assert rail =~ "hero-eye "
      refute rail =~ "channel-mask-strip"
      refute rail =~ "Names hidden"
    end
  end

  describe "masked" do
    test "no real name survives anywhere in the rail — text or attribute", %{conn: conn} do
      conn = acme_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      rail = view |> toggle_mask(true) |> rail()

      for name <- real_names(projects) do
        refute_name_anywhere(rail, name, @machine_attrs)
      end

      # And the placeholders ARE there, so the rail is not simply empty.
      assert rail =~ "Workspace A"
      assert rail =~ "Project A"
    end

    test "data-org-slug carries the placeholder's slug, not the org's", %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      rail = view |> toggle_mask(true) |> rail()

      # The specific leak `refute html =~ "Vandelay-Ind"` cannot see: the slug is
      # stored underscored and rendered hyphenated, so an assertion on the
      # display form passes with the attribute untouched.
      refute rail =~ ~s(data-org-slug="initech")
      refute rail =~ ~s(data-org-slug="vandelay-ind")
      refute rail =~ ~s(data-org-slug="vandelay_ind")
      assert rail =~ ~s(data-org-slug="workspace-a")
    end

    test "the lifecycle kebab's aria-label and phx-value-name take the resolved label",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      # The menu's `phx-value-name` — which becomes the confirm modal's
      # heading and the archive flash — only renders while the menu is OPEN,
      # so the menu has to be opened for the assertion to reach it. Asserting
      # against the closed row would have been vacuously green.
      rail =
        view
        |> element("[data-menu-key='org:workspace-b'] [data-role=lifecycle-menu-trigger]")
        |> render_click()
        |> rail()

      # A DERIVED-STRING LEAK if the menu had kept `Tenancy.scope_label/1` —
      # the visible text would mask while `aria-label="Manage Initech"` sat
      # in the accessibility tree beside it.
      assert rail =~ ~s(aria-label="Manage Workspace)
      assert rail =~ ~s(phx-value-name="Workspace)
      refute rail =~ ~s(aria-label="Manage Initech")
      refute rail =~ ~s(phx-value-name="Initech Storefront")

      # And the project kebab's too, in the same open pass for the org.
      refute_name_anywhere(rail, "Initech Storefront", @machine_attrs)
    end

    test "the mode strip is the signal, and its copy names no privacy claim", %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      rail = view |> toggle_mask(true) |> rail()

      assert rail =~ "channel-mask-strip"
      assert rail =~ "Names hidden for sharing"
      assert rail =~ ~s(aria-pressed="true")
      assert rail =~ "hero-eye-slash"

      # Word discipline binds the rendered copy as well as the code: no
      # padlock, no shield, and none of the four forbidden words.
      down = String.downcase(rail)

      for banned <- ~w(padlock shield privacy secure protected encrypted client) do
        refute String.contains?(down, banned),
               "The masking feature must not use the word #{inspect(banned)}."
      end
    end

    test "per-item reveal buttons are in the DOM for every masked row, not hover-gated",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      # A real focusable button per row, present unconditionally: an
      # `@media (hover: hover)` affordance never matches on touch and would
      # leave the control unreachable there.
      assert has_element?(view, "[data-role=rail-reveal-org]")
      assert has_element?(view, "[data-role=rail-reveal-project]")
    end
  end

  describe "reveal and re-mask" do
    test "revealing one org shows only that name; the rest of the rail stays masked",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      rail =
        view
        |> element("[data-role=rail-reveal-org][phx-value-id=workspace-b]")
        |> render_click()
        |> rail()

      assert_name_anywhere(rail, "Initech")
      assert rail =~ ~s(data-org-slug="initech")

      # The strip's count is the only place the reveal is announced.
      assert rail =~ "Names hidden · 1 showing"

      # Everything else is untouched — including the revealed org's PROJECT,
      # which letters independently and was not revealed.
      refute_name_anywhere(rail, "Vandelay-Ind", @machine_attrs)
      refute_name_anywhere(rail, "Globex", @machine_attrs)
      refute_name_anywhere(rail, projects.initech.name, @machine_attrs)
    end

    test "Show all re-masks everything while leaving the mode on", %{conn: conn} do
      conn = acme_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      _ =
        view
        |> element("[data-role=rail-reveal-org][phx-value-id=workspace-b]")
        |> render_click()

      rail =
        view
        |> element("[data-role=rail-mask-remask-all]")
        |> render_click()
        |> rail()

      for name <- real_names(projects), do: refute_name_anywhere(rail, name, @machine_attrs)
      assert rail =~ "Names hidden for sharing"
      assert rail =~ ~s(aria-pressed="true")
    end

    test "FAIL CLOSED: turning the mode off clears reveals, so re-enabling starts fully masked",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      _ =
        view
        |> element("[data-role=rail-reveal-org][phx-value-id=workspace-b]")
        |> render_click()

      # Off, then on again. Without the clear, the earlier reveal is
      # resurrected on the next share and one workspace is silently visible —
      # the feature failing in the exact direction it exists to prevent.
      _ = toggle_mask(view, false)
      rail = view |> toggle_mask(true) |> rail()

      for name <- real_names(projects), do: refute_name_anywhere(rail, name, @machine_attrs)
      assert rail =~ "Names hidden for sharing"
      refute rail =~ "showing"
    end

    test "the toggle posts the desired next state, so a duplicated event is idempotent",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      # Same payload twice — a client-side render race. Still masked, rather
      # than flipped back off.
      rail = view |> toggle_mask(true) |> rail()
      assert rail =~ "Names hidden for sharing"
    end
  end

  describe "assertion integrity" do
    test "the sweep FIRES when a real name is present — it is not vacuously green",
         %{conn: conn} do
      conn = acme_admin_conn(conn)
      seed_rail()

      {:ok, _view, html} = live(conn, ~p"/tasks")
      unmasked_rail = rail(html)

      # The identical call the masked tests make, against the UNMASKED rail.
      # If this does not raise, every `refute_name_anywhere` above proves
      # nothing and the excluded-attribute list has swallowed the surface.
      assert_raise ExUnit.AssertionError, fn ->
        refute_name_anywhere(unmasked_rail, "Initech Storefront", @machine_attrs)
      end

      assert_raise ExUnit.AssertionError, fn ->
        refute_name_anywhere(unmasked_rail, "Vandelay-Ind", @machine_attrs)
      end
    end
  end
end
