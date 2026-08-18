defmodule PlatformWeb.Tasks.RailMaskSurfacesTest do
  @moduledoc """
  The five-plus-one surfaces that render the SAME org and project names as the
  masked rail, on the SAME screen (task 01a00cf1 stage 3).

  ## Why one test per surface rather than one whole-document sweep

  A single `refute_name_anywhere(whole_page, name)` would be shorter and worse.
  When it goes red it names the page, and the page has six independent render
  sites in three modules; the reader learns that something leaked and nothing
  about what. Worse, it CANNOT distinguish "the breadcrumb is masked" from "no
  project is selected so the breadcrumb did not render" — the vacuity failure
  this stack has hit repeatedly. So each test scopes to ONE subtree, pins that
  subtree non-empty, and asserts the placeholder IS there before asserting the
  real name is not. An empty subtree fails the pin, not the sweep.

  ## The sixth surface

  The stage's written site list has five entries and the scope-rail chips are
  not among them; stage 2's live-DOM sweep found them. They render in the page
  header at desktop width, inches above the rail, so a masked rail beside an
  unmasked `Soylent` chip is the exact failure this feature exists to prevent.
  Covered here.

  ## What is NOT covered, and is not an oversight

  Task card titles, `{task.project.name}` on the card, the task detail panel,
  epic and stack names, and search results all still render real names. They are
  free text and out of the feature's scope — see the PR body. This module's
  assertions are scoped to subtrees precisely so that they stay honest about it
  rather than being softened until a whole-page sweep passes.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership

  # `value` only. An `<option value="...">` carries the project UUID the form
  # submits, which is not a name — masking it would post a task against
  # nothing. The rail's other three (`phx-value-id`, `phx-value-key`,
  # `data-menu-key`) are NOT excluded any more: the behavioural review found
  # the real org slug alive in all three, and the org rows now route by the
  # per-session placeholder slug (see `TaskDisplay.real_org_slug/2`).
  @machine_attrs ~w(value)

  @tenants ~w(soylent wayne_tech sxi)

  defp fabrikam_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mask-surfaces-#{n}@example.com",
        name: "Mask Surfaces User #{n}",
        oidc_sub: "oidc-mask-surfaces-#{n}"
      })

    Enum.each(Tenancy.list_orgs(), fn org ->
      role = if org.slug == "fabrikam", do: "admin", else: "member"

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
      soylent: seed_project("soylent", "Soylent Storefront"),
      protect: seed_project("wayne_tech", "Wayne-Tech Rollout"),
      sxi: seed_project("sxi", "SXI Onboarding")
    }
  end

  defp real_names(projects) do
    Enum.map(@tenants, &Tenancy.scope_label/1) ++
      @tenants ++
      Enum.map(Map.values(projects), & &1.name)
  end

  # Scope to ONE subtree and PIN IT NON-EMPTY in the same breath. `LazyHTML`
  # returns "" for a selector that matched nothing, and "" passes every absence
  # assertion ever written — the vacuity mode this file's moduledoc names.
  defp subtree(html, selector) do
    fragment =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_html()

    assert fragment != "",
           "Expected #{inspect(selector)} to be in the DOM. An absence assertion " <>
             "against a subtree that did not render proves nothing at all."

    fragment
  end

  defp toggle_mask(view, masked?) do
    view
    |> element("[data-role=rail-mask-toggle]")
    |> render_click(%{"masked" => to_string(masked?)})
  end

  # The click's own return value is NOT enough. `SidebarComponent` does not own
  # `:selected_project_id` — it `send/2`s `{:sidebar_project_selected, id}` to
  # the shell, which is a separate message processed after `render_click/1` has
  # already returned. Reading that return value gives the DOM from BEFORE the
  # breadcrumb exists, and the surface under test never renders. `render/1`
  # forces the round-trip that flushes it.
  defp select_project(view, project) do
    view
    |> element("aside [phx-click=sidebar_select_project][phx-value-id='#{project.id}']")
    |> render_click()

    render(view)
  end

  defp open_epic_sheet(view) do
    view |> element("[data-role=header-create-menu-trigger]") |> render_click()

    view
    |> element("#header-create-menu [phx-click=sidebar_toggle_epic_sheet]")
    |> render_click()
  end

  # ── Site 1: the mobile project sheet ────────────────────────────────────

  describe "mobile #project-sheet" do
    test "renders the same masked rows as the desktop aside — text and attributes",
         %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, html} = live(conn, ~p"/tasks")

      # ANTI-VACUITY FIRST: the sheet carries every one of these names before
      # the mask is on, so the sweep below is known to be testing a surface
      # that ever leaked. The sheet is in the DOM regardless of `open` — that
      # is precisely why an unmasked one leaks on a share.
      for name <- real_names(projects),
          do: assert_name_anywhere(subtree(html, "#project-sheet"), name)

      sheet = view |> toggle_mask(true) |> subtree("#project-sheet")

      for name <- real_names(projects), do: refute_name_anywhere(sheet, name, @machine_attrs)

      assert sheet =~ "Workspace A"
      assert sheet =~ "Project A"
      refute sheet =~ ~s(data-org-slug="wayne-tech")
      refute sheet =~ ~s(data-org-slug="wayne_tech")
      assert sheet =~ ~s(data-org-slug="workspace-a")
    end

    test "the mode strip renders INSIDE the sheet, so the state is visible on a phone",
         %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, html} = live(conn, ~p"/tasks")
      refute subtree(html, "#project-sheet") =~ "Names hidden"

      sheet = view |> toggle_mask(true) |> subtree("#project-sheet")

      # THE STATE, NOT ONLY ITS EFFECT. Someone who masked at a laptop and then
      # opened this sheet on a phone sees rows of `Workspace A` with no
      # explanation unless the strip follows — which reads as a loading bug and
      # gives the person deciding whether to keep sharing nothing to decide on.
      assert sheet =~ "channel-mask-strip"
      assert sheet =~ "Names hidden for sharing"
      assert sheet =~ "rail-mask-strip-mobile"

      # Reveal controls are real focusable buttons here too — an
      # `@media (hover: hover)` affordance never matches on the touch device
      # this sheet exists for.
      assert has_element?(view, "[data-role=rail-reveal-org-mobile]")
      assert has_element?(view, "[data-role=rail-reveal-project-mobile]")
    end
  end

  # ── Site 2: the breadcrumb ──────────────────────────────────────────────

  describe "page-header breadcrumb" do
    test "the org label and the project name both follow the mask", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")

      unmasked =
        view |> select_project(projects.soylent) |> subtree("[data-role=tasks-breadcrumb]")

      assert_name_anywhere(unmasked, "Soylent")
      assert_name_anywhere(unmasked, "Soylent Storefront")

      crumb = view |> toggle_mask(true) |> subtree("[data-role=tasks-breadcrumb]")

      # The most visible single leak this task had left: on screen at BOTH
      # breakpoints for as long as a project is selected, directly above the
      # rail stage 2 masked.
      refute_name_anywhere(crumb, "Soylent Storefront", @machine_attrs)
      refute_name_anywhere(crumb, "Soylent", @machine_attrs)
      assert crumb =~ "Workspace"
      assert crumb =~ "Project"
    end
  end

  # ── Site 3 (the sixth surface): the scope rail ──────────────────────────

  describe "scope-rail chips" do
    test "the pill's visible text AND its aria-label take the resolved label", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, html} = live(conn, ~p"/tasks")

      rail = subtree(html, "#tasks-scope-rail")
      for slug <- @tenants, do: assert_name_anywhere(rail, Tenancy.scope_label(slug))

      rail = view |> toggle_mask(true) |> subtree("#tasks-scope-rail")

      for slug <- @tenants do
        refute_name_anywhere(rail, Tenancy.scope_label(slug), @machine_attrs)
        refute_name_anywhere(rail, slug, @machine_attrs)
      end

      # `label` overrides text and aria-label TOGETHER — a chip that masks its
      # text and keeps the real name in the accessibility tree has not been
      # masked. That is the defect the sibling task 01a00c66 shipped and fixed.
      assert rail =~ "Workspace A"
      refute rail =~ ~s(aria-label="Soylent)

      # `phx-value-scope` IS masked now. It is still the filter's argument —
      # but an argument does not have to be spelled with the real slug, and the
      # case-1 expected clause forbids that slug anywhere in the DOM,
      # attributes included. The chip carries the per-session alias and
      # `FiltersComponent` inverts it; the test below proves the control still
      # fires.
      refute rail =~ ~s(phx-value-scope="soylent")
      assert rail =~ ~s(phx-value-scope="workspace-b")
    end

    test "a masked chip still filters the board to its real org", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = toggle_mask(view, true)

      # Masking a control's LABEL must never disarm the control. Clicking a
      # `Workspace B` chip presses it, which is only possible if the real scope
      # survived in `phx-value-scope`.
      # THE ALIAS IS THE ARGUMENT NOW, and this is the test that keeps that
      # honest: click the chip by the placeholder slug it actually emits and
      # the board must still filter to the real org behind it.
      html =
        view
        |> element(~s([data-scope-chip] button[phx-value-scope="workspace-b"]))
        |> render_click()

      assert subtree(html, "#tasks-scope-rail") =~ ~s(aria-pressed="true")
    end
  end

  # ── Sites 4 & 5: the two project <select>s ──────────────────────────────

  describe "epic-create sheet project select" do
    test "the optgroup label and the option text are both masked", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")

      unmasked = view |> open_epic_sheet() |> subtree("#epic-sheet select")
      for name <- real_names(projects), do: assert_name_anywhere(unmasked, name)

      select = view |> toggle_mask(true) |> subtree("#epic-sheet select")

      # AN OPTGROUP LABEL IS ON SCREEN whenever the select is open, and in the
      # DOM the whole time regardless. Masking the options and leaving the
      # group headings puts every org name one tap from a shared screen.
      for name <- real_names(projects), do: refute_name_anywhere(select, name, @machine_attrs)

      # `Workspace B`, not `A`: the letters come from the SAME map the rail
      # letters from, where Fabrikam is `Workspace A`. Fabrikam owns no project here so
      # it has no optgroup — and that is the point. A picker that lettered its
      # groups independently would call Soylent `Workspace A` here and
      # `Workspace B` in the rail two inches away, which is worse than not
      # masking it: the viewer would believe they were two workspaces.
      assert select =~ ~s(label="Workspace B")
      assert select =~ "Project A"
    end
  end

  describe "new-task sheet project select" do
    test "the optgroup label and the option text are both masked", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")

      unmasked =
        view
        |> element("[data-role=header-new-task]")
        |> render_click()
        |> subtree("#task-sheet select[name='task[project_id]']")

      for name <- real_names(projects), do: assert_name_anywhere(unmasked, name)

      select = view |> toggle_mask(true) |> subtree("#task-sheet select[name='task[project_id]']")

      for name <- real_names(projects), do: refute_name_anywhere(select, name, @machine_attrs)

      # `Workspace B`, not `A`: the letters come from the SAME map the rail
      # letters from, where Fabrikam is `Workspace A`. Fabrikam owns no project here so
      # it has no optgroup — and that is the point. A picker that lettered its
      # groups independently would call Soylent `Workspace A` here and
      # `Workspace B` in the rail two inches away, which is worse than not
      # masking it: the viewer would believe they were two workspaces.
      assert select =~ ~s(label="Workspace B")
      assert select =~ "Project A"

      # The option VALUE keeps the real project id. It is what the form posts;
      # mask it and the sheet creates a task against nothing.
      assert select =~ ~s(value="#{projects.soylent.id}")
    end
  end

  # ── Site 6: the project-create sheet's org select ───────────────────────

  describe "project-create sheet" do
    test "the org select is masked; the name field the user is typing into is NOT",
         %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")

      unmasked =
        view
        |> element("aside [data-role=project-create-trigger]")
        |> render_click()
        |> subtree("[data-role=project-create-org-select]")

      for slug <- @tenants, do: assert_name_anywhere(unmasked, Tenancy.scope_label(slug))

      html = toggle_mask(view, true)
      select = subtree(html, "[data-role=project-create-org-select]")

      for slug <- @tenants do
        refute_name_anywhere(select, Tenancy.scope_label(slug), @machine_attrs)
      end

      assert select =~ "Workspace"

      # NOT A LEAK AND NOT MASKED: `project[name]` is a form field whose value
      # is the user's own keystrokes. Masking is about names the app puts on
      # screen, not names the user is putting there — rewriting it would
      # destroy the thing being created.
      assert subtree(html, "#project-create-sheet") =~ ~s(name="project[name]")
    end
  end

  # ── Sites 7 & 8: the two leaks the behavioural review found ─────────────

  # WHOLE-DOCUMENT, and the ONLY exclusions are `class` and `href`.
  #
  # `Platform.MaskAssertions.refute_name_anywhere/3` cannot be used for these
  # two: it strips `phx-value-scope` MODULE-LEVEL, and `phx-value-scope` is one
  # of the four attributes the review found the raw org slug living in. Widening
  # that module's exclusions is not an option either — chat still keeps the real
  # slug there and its assertions must stay behaviour-identical. So these two
  # sweeps do their own normalisation and exclude only the two attributes that
  # genuinely cannot follow a label: `class` (the scope-colour utilities are
  # named after the slug and cannot be regenerated per session) and `href` (the
  # address bar shows the URL regardless).
  defp refute_everywhere(html, name) do
    haystack =
      ~w(class href)
      |> Enum.reduce(html, fn attr, acc ->
        Regex.replace(~r/\s#{Regex.escape(attr)}="[^"]*"/, acc, " ")
      end)
      |> String.downcase()

    for form <- forms(name) do
      refute String.contains?(haystack, form),
             "#{inspect(form)} is still in the document — text or attribute."
    end

    :ok
  end

  defp seed_epic(project, name) do
    {:ok, epic} = Tasks.create_epic(%{name: name, project_id: project.id})
    epic
  end

  defp select_epic(view, epic) do
    view
    |> element("[phx-click=sidebar_select_epic][phx-value-id='#{epic.id}']")
    |> render_click()

    render(view)
  end

  describe "epic name in the breadcrumb" do
    test "the selected epic's real name is nowhere in the masked document", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()
      epic = seed_epic(projects.soylent, "Zephyr Migration")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = select_project(view, projects.soylent)
      unmasked = select_epic(view, epic)

      # ANTI-VACUITY: the epic name IS on this screen unmasked, and it is in
      # the breadcrumb specifically — an absence assertion against a document
      # that never carried it would prove nothing.
      assert_name_anywhere(unmasked, epic.name)
      assert_name_anywhere(subtree(unmasked, "[data-role=tasks-breadcrumb]"), epic.name)

      masked = toggle_mask(view, true)

      refute_everywhere(masked, epic.name)

      crumb = subtree(masked, "[data-role=tasks-breadcrumb]")
      assert crumb =~ "Epic A"
    end
  end

  describe "org slug in data-* and phx-value-*" do
    test "the raw slug is nowhere in the masked document, in either spelling",
         %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, html} = live(conn, ~p"/tasks")

      # ANTI-VACUITY: both spellings are in the unmasked document. `wayne_tech`
      # is stored underscored and rendered hyphenated, and one form passing
      # while the other leaks is exactly the hole the sibling task 01a00c66
      # shipped.
      for slug <- @tenants, do: assert_name_anywhere(html, slug)

      masked = toggle_mask(view, true)

      for slug <- @tenants, do: refute_everywhere(masked, slug)

      # The four attributes the review named, each now carrying the
      # per-session placeholder slug out of the SAME map the label came from.
      assert masked =~ ~s(data-menu-key="org:workspace-b")
      assert masked =~ ~s(data-menu-key="mobile-org:workspace-b")
      assert masked =~ ~s(phx-value-key="org:workspace-b")
      assert masked =~ ~s(phx-value-scope="workspace-b")

      assert masked =~
               ~s(<button :if data-role="rail-reveal-org") ||
               masked =~ ~s(data-role="rail-reveal-org")
    end
  end

  # ── Assertion integrity ─────────────────────────────────────────────────

  describe "assertion integrity" do
    test "DETONATION: the breadcrumb sweep fires when its mask is removed", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      projects = seed_rail()

      {:ok, view, _html} = live(conn, ~p"/tasks")
      crumb = view |> select_project(projects.soylent) |> subtree("[data-role=tasks-breadcrumb]")

      # The identical call the masked breadcrumb test makes, against the
      # UNMASKED breadcrumb — which is exactly the DOM that site rendered
      # before this stage. If this does not raise, that test proves nothing.
      #
      # Chosen over the mobile sheet on purpose: the sheet's failure mode is
      # genuinely independent of this one. The sheet reads `@mask_labels`
      # through `rail_label/2` inside `SidebarComponent`, the same call the
      # already-masked desktop rail makes, so a stage-2 regression would turn
      # both red. The breadcrumb reads it through `label_for/4` in a DIFFERENT
      # module wired by a DIFFERENT attr on a DIFFERENT `live_component` call —
      # drop either of those two lines from `tasks_live.html.heex` and only
      # this one fires.
      assert_raise ExUnit.AssertionError, fn ->
        refute_name_anywhere(crumb, "Soylent Storefront", @machine_attrs)
      end

      assert_raise ExUnit.AssertionError, fn ->
        refute_name_anywhere(crumb, "Soylent", @machine_attrs)
      end
    end

    test "DETONATION: the scope-rail sweep fires when its mask is removed", %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, _view, html} = live(conn, ~p"/tasks")
      rail = subtree(html, "#tasks-scope-rail")

      # The sixth surface's own control. `phx-value-scope` is excluded
      # module-level, so this fires on the pill's TEXT and `aria-label` — the
      # two surfaces the `label` attr overrides — and not on the argument.
      assert_raise ExUnit.AssertionError, fn ->
        refute_name_anywhere(rail, "Soylent", @machine_attrs)
      end
    end

    test "the mask does not leak into the UNMASKED mode on the wider-entity surfaces",
         %{conn: conn} do
      conn = fabrikam_admin_conn(conn)
      seed_rail()

      {:ok, view, html} = live(conn, ~p"/tasks")

      # `label_for/4` and `scope_pill_label/3` exist for these two surfaces:
      # both list entities `mask_labels` may never have heard of (`@orgs`
      # includes orgs with no projects; the scope rail is a fixed enum), so a
      # bare fail-closed `rail_label/2` would render `Workspace` for a real,
      # unmasked org. That bug ships green — every masked test still passes.
      rail = subtree(html, "#tasks-scope-rail")
      refute rail =~ "Workspace A"
      assert_name_anywhere(rail, "Soylent")

      select =
        view
        |> element("aside [data-role=project-create-trigger]")
        |> render_click()
        |> subtree("[data-role=project-create-org-select]")

      refute select =~ "Workspace A"
      assert_name_anywhere(select, "Soylent")
    end
  end
end
