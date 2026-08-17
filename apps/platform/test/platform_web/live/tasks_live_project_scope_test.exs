defmodule PlatformWeb.TasksLiveProjectScopeTest do
  @moduledoc """
  The `/tasks` board reads its project sidebar (and the New-Task `<select>`
  that shares the same assign) from a project list. Before this test's
  companion change that list came from the unscoped `Tasks.list_projects_unscoped/1`,
  so every authenticated user could read the NAME of every project in every
  org.

  These assertions are deliberately about the RENDERED sidebar markup, not
  about the return value of `Tasks.list_projects_for_user/2` — that
  context-level coverage lives with the function itself. The point here is
  that the LiveView actually passes a viewer through, on every path that
  reads the list: `mount/3`, the `create_project` re-fetch, and the
  `refresh_containers/1` re-fetch behind archive.

  The positive controls are mandatory: an implementation that assigns `[]`
  to `@projects` for everybody would satisfy the absence assertion alone
  while breaking the feature.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # `@example.com` keeps `Tenancy.derive_role_from_email/1` at `:member`;
  # a `@example.com` address would derive admin and blanket-bypass the very
  # scope these tests pin.
  defp user!(role, org_id) do
    user =
      Repo.insert!(%User{
        email: "tasks_scope_#{System.unique_integer([:positive])}@example.com",
        name: "Tasks Scope User",
        oidc_sub: "oidc-tasks-scope-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id, name) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: name,
        slug: "tasks-scope-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  # Read the project sidebar's own subtree rather than the whole document, so
  # a name appearing elsewhere on the board (a task card, a flash) can never
  # make an absence assertion pass or fail for the wrong reason.
  defp sidebar_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=project-group]")
    |> LazyHTML.text()
  end

  defp member_of!(user, org_id) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
  end

  # The distinct org slugs the sidebar rendered a SECTION HEADER for. An empty
  # header naming an org the viewer doesn't belong to is an existence leak on
  # its own, independent of whether that org's project names are hidden — so
  # this reads the headers, not the project rows.
  defp section_slugs(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=project-group]")
    |> LazyHTML.attribute("data-org-slug")
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The full section-header text (org labels), for asserting a foreign org's
  # NAME never reaches the markup even if the slug attribute changed shape.
  defp section_header_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=project-group] > summary")
    |> LazyHTML.text()
  end

  defp seed do
    fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
    tenant_org_id = Platform.TenancyFixtures.tenant_org_id("sxi")

    own = project!(fabrikam_org_id, "Own Fabrikam Project #{System.unique_integer([:positive])}")
    foreign = project!(tenant_org_id, "Foreign Project #{System.unique_integer([:positive])}")

    %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign}
  end

  describe "mount" do
    test "a plain member does not see a foreign org's project name", %{conn: conn} do
      %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign} = seed()
      user = user!("member", fabrikam_org_id)

      # Precondition: an admin viewer bypasses the scope by design, which
      # would make a broken filter look correct.
      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, "/tasks")

      sidebar = sidebar_text(html)

      # Positive control — without it, `@projects == []` passes the refute.
      assert sidebar =~ own.name
      refute sidebar =~ foreign.name
    end

    test "a Fabrikam root admin sees both orgs' projects", %{conn: conn} do
      %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign} = seed()
      admin = user!("admin", fabrikam_org_id)

      assert Tenancy.fabrikam_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, _view, html} = live(conn, "/tasks")

      sidebar = sidebar_text(html)

      assert sidebar =~ own.name
      assert sidebar =~ foreign.name
    end
  end

  describe "org section headers" do
    # Scoping the PROJECT list alone left the sidebar rendering a header for
    # every active org — a member of two orgs saw five section names with a
    # `0` count on the three they don't belong to. The header list has to be
    # viewer-scoped too.

    test "a member of exactly two orgs sees exactly those two sections", %{conn: conn} do
      fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
      soylent_org_id = Platform.TenancyFixtures.tenant_org_id("soylent")
      sxi_org_id = Platform.TenancyFixtures.tenant_org_id("sxi")

      own = project!(fabrikam_org_id, "Own Fabrikam Project #{System.unique_integer([:positive])}")

      soylent =
        project!(soylent_org_id, "Soylent Work #{System.unique_integer([:positive])}")

      foreign = project!(sxi_org_id, "Foreign Project #{System.unique_integer([:positive])}")

      user = user!("member", fabrikam_org_id) |> member_of!(soylent_org_id)
      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, "/tasks")

      # Positive control — an implementation rendering ZERO sections must fail.
      assert section_slugs(html) == ["soylent", "fabrikam"]

      headers = section_header_text(html)
      assert headers =~ Tenancy.scope_label("fabrikam")
      assert headers =~ Tenancy.scope_label("soylent")

      for absent <- ["wayne_tech", "sxi", "paragon"] do
        refute headers =~ Tenancy.scope_label(absent)
      end

      sidebar = sidebar_text(html)
      assert sidebar =~ own.name
      assert sidebar =~ soylent.name
      refute sidebar =~ foreign.name
    end

    test "a Fabrikam root admin still sees every active org's section", %{conn: conn} do
      fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
      admin = user!("admin", fabrikam_org_id)
      assert Tenancy.fabrikam_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, _view, html} = live(conn, "/tasks")

      slugs = section_slugs(html)

      for expected <- Enum.map(Tenancy.list_active_tenants_unscoped(), & &1.slug) do
        assert expected in slugs
      end
    end

    test "the refresh path keeps the section list scoped", %{conn: conn} do
      # `create_project` re-runs `project_sections/2` outside `mount/3`; a
      # viewer-less read there re-leaks the headers after any sidebar refresh.
      fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
      soylent_org_id = Platform.TenancyFixtures.tenant_org_id("soylent")

      user = user!("member", fabrikam_org_id) |> member_of!(soylent_org_id)
      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, "/tasks")

      new_name = "Created Fabrikam Project #{System.unique_integer([:positive])}"

      html =
        sidebar_submit(view, "sidebar_create_project", %{
          "project" => %{"name" => new_name, "slug" => "", "org_id" => fabrikam_org_id}
        })

      assert section_slugs(html) == ["soylent", "fabrikam"]
      assert sidebar_text(html) =~ new_name
    end
  end

  describe "re-fetch paths" do
    # These are the paths most likely to regress: they re-read the project
    # list OUTSIDE `mount/3`, so a viewer-less read here would leak even
    # though the initial render looked correct.

    test "the create_project re-fetch stays scoped", %{conn: conn} do
      %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign} = seed()
      user = user!("member", fabrikam_org_id)
      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, "/tasks")

      new_name = "Created Fabrikam Project #{System.unique_integer([:positive])}"

      html =
        sidebar_submit(view, "sidebar_create_project", %{
          "project" => %{"name" => new_name, "slug" => "", "org_id" => fabrikam_org_id}
        })

      sidebar = sidebar_text(html)

      # Positive controls: the re-fetch produced a real list, including the
      # project just created.
      assert sidebar =~ new_name
      assert sidebar =~ own.name
      refute sidebar =~ foreign.name
    end

    test "the archive re-fetch (refresh_containers/1) reads through a viewer", %{conn: conn} do
      # `archive_container` is Fabrikam-admin-only (re-authorized in
      # `Platform.Tenancy.Lifecycle`), so a plain member cannot reach
      # `refresh_containers/1` at all. What this pins is that the re-fetch
      # passes a real viewer through: a `nil` or missing assign there empties
      # the sidebar for everyone, including the admin, and this goes red.
      %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign} = seed()
      admin = user!("admin", fabrikam_org_id)
      assert Tenancy.fabrikam_admin?(admin) == true

      doomed = project!(fabrikam_org_id, "Doomed Project #{System.unique_integer([:positive])}")

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, view, html} = live(conn, "/tasks")
      assert sidebar_text(html) =~ doomed.name

      html =
        render_click(view, "archive_container", %{
          "type" => "project",
          "id" => doomed.id,
          "name" => doomed.name
        })

      sidebar = sidebar_text(html)

      refute sidebar =~ doomed.name
      assert sidebar =~ own.name
      assert sidebar =~ foreign.name
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

  defp sidebar_submit(view, event, params) do
    _ = render_submit(with_target(view, "#tasks-sidebar"), event, params)
    render(view)
  end
end
