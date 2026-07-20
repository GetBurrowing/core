defmodule PlatformWeb.TasksLiveLifecycleTest do
  @moduledoc """
  Container-lifecycle UI on the Tasks surfaces (task 019f4eaa stage 6 +
  review follow-up): the fabrikam-admin-only Archive / Schedule-deletion kebab
  on org headers and project rows — on both the DESKTOP sidebar and the
  MOBILE project sheet — plus the Schedule-deletion confirm modal.
  Browser-only concerns (chip color, pixel layout) are out of scope here —
  covered by the task-level e2e + the human screenshot gate.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tasks.Project
  alias Platform.Tenancy.{Org, OrgMembership}

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "tasks-lifecycle-#{n}@example.com",
      name: "User #{n}",
      oidc_sub: "oidc-tasks-lifecycle-#{n}"
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

  describe "fabrikam admin — archive" do
    test "sees the project kebab, and archiving removes the row from the active sidebar", %{
      conn: conn
    } do
      {conn, _user} = fabrikam_admin_conn(conn)
      project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      menu = "[data-menu-key='project:#{project.id}']"
      assert has_element?(view, menu)

      # Open the kebab, then click Archive.
      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-archive]") |> render_click()

      # Row leaves the active sidebar and the DB row is archived.
      refute has_element?(view, menu)
      assert Repo.get(Project, project.id).archived_at
    end

    test "sees the org kebab on a tenant, and archiving the org drops it off the scope rail", %{
      conn: conn
    } do
      {conn, _user} = fabrikam_admin_conn(conn)
      _project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Scope rail shows soylent before, gone after archiving the org.
      assert has_element?(view, "[data-scope-chip='soylent']")

      org_menu = "[data-menu-key='org:soylent']"
      view |> element("#{org_menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{org_menu} [data-role=lifecycle-archive]") |> render_click()

      refute has_element?(view, "[data-scope-chip='soylent']")
      assert Repo.get_by(Org, slug: "soylent").archived_at
    end

    test "archiving an org's LAST project keeps the org header, kebab, and scope chip (regression: task 019f4eaa)",
         %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      # Soylent with exactly one project — the reported case (Marlowe, 2026-07-16).
      project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Present before: sidebar header, org kebab, scope chip.
      assert has_element?(view, "[data-role=project-group][data-org-slug='soylent']")
      assert has_element?(view, "[data-menu-key='org:soylent']")
      assert has_element?(view, "[data-scope-chip='soylent']")

      # Archive the org's ONLY project (not the org itself).
      menu = "[data-menu-key='project:#{project.id}']"
      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-archive]") |> render_click()

      # The project row leaves the sidebar...
      refute has_element?(view, menu)

      # ...but soylent is still an ACTIVE org, so its header + kebab survive.
      # Pre-fix the header was project-derived and vanished with the last
      # project — taking the org's own archive control with it — while the
      # scope chip (org-derived) stayed, so the surface contradicted itself.
      assert has_element?(view, "[data-role=project-group][data-org-slug='soylent']")
      assert has_element?(view, "[data-menu-key='org:soylent']")
      assert has_element?(view, "[data-scope-chip='soylent']")
      # The org row itself is untouched — only the project was archived.
      refute Repo.get_by(Org, slug: "soylent").archived_at
    end
  end

  describe "fabrikam admin — schedule deletion modal" do
    test "the confirm modal opens on 'Schedule deletion…' and confirming schedules the project",
         %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      project = create_project("sxi")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      menu = "[data-menu-key='project:#{project.id}']"

      # No modal until requested.
      refute has_element?(view, "[data-role=schedule-delete-modal]")

      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-schedule-delete]") |> render_click()

      # Confirm modal is open and names the resource.
      assert has_element?(view, "[data-role=schedule-delete-modal]")
      assert render(view) =~ "Schedule deletion for #{project.name}?"

      # Confirming stamps deletion_scheduled_at and removes the row.
      view |> element("[data-role=schedule-delete-confirm]") |> render_click()

      refute has_element?(view, "[data-role=schedule-delete-modal]")
      refute has_element?(view, menu)
      assert Repo.get(Project, project.id).deletion_scheduled_at
    end

    test "the confirm dialog's card does NOT use DaisyUI's .modal-box", %{conn: conn} do
      # Regression, found by Marlowe walking the review (task 019f4eaa).
      #
      # `.modal-box` ships `scale: 95%; opacity: 0` and is only revealed by a
      # `.modal` PARENT carrying .modal-open / [open] / :target. This dialog
      # rolls its own backdrop, so no such parent exists: the card rendered at
      # the correct size and position, with its text, at opacity 0 — visually
      # nothing but a dimmed page.
      #
      # Every assertion above passes at opacity 0, which is exactly how this
      # shipped: has_element?/2 proves a node is IN THE DOM, never that a human
      # can see it. A server-rendered test cannot read computed opacity, so
      # this pins the specific mistake structurally instead. Real visibility
      # proof lives in the browser e2e cases.
      {conn, _admin} = fabrikam_admin_conn(conn)
      project = create_project("sxi")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      menu = "[data-menu-key='project:#{project.id}']"
      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-schedule-delete]") |> render_click()

      assert has_element?(view, "[data-role=schedule-delete-modal]")

      card =
        view
        |> element("[data-role=schedule-delete-modal] [role=dialog]")
        |> render()

      refute card =~ "modal-box"
      # It must still carry the reskin's own surface treatment.
      assert card =~ "bg-base-100"
      assert card =~ "rounded-box"
    end

    test "Cancel closes the modal without scheduling", %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      project = create_project("sxi")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      menu = "[data-menu-key='project:#{project.id}']"

      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-schedule-delete]") |> render_click()
      view |> element("[data-role=schedule-delete-cancel]") |> render_click()

      refute has_element?(view, "[data-role=schedule-delete-modal]")
      refute Repo.get(Project, project.id).deletion_scheduled_at
    end
  end

  describe "fabrikam admin — mobile parity" do
    test "the mobile project sheet renders the same lifecycle kebab, wired to the same archive event",
         %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Mobile keys are `mobile-`-prefixed so their open-state never collides
      # with the desktop sidebar's data-menu-key in the DOM.
      mobile_menu = "[data-menu-key='mobile-project:#{project.id}']"
      assert has_element?(view, mobile_menu)
      assert has_element?(view, "[data-menu-key='mobile-org:soylent']")

      # Same event path as desktop: open the mobile kebab, click Archive.
      view |> element("#{mobile_menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{mobile_menu} [data-role=lifecycle-archive]") |> render_click()

      refute has_element?(view, mobile_menu)
      assert Repo.get(Project, project.id).archived_at
    end
  end

  describe "non-admin" do
    test "does NOT see the lifecycle controls on either surface", %{conn: conn} do
      {conn, _user} = member_conn(conn)
      _project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "[data-role=lifecycle-menu-trigger]")
      refute has_element?(view, "[data-menu-key^='project:']")
      refute has_element?(view, "[data-menu-key^='org:']")
      refute has_element?(view, "[data-menu-key^='mobile-project:']")
      refute has_element?(view, "[data-menu-key^='mobile-org:']")
    end
  end

  # ── Archive undo toast (task 019f4eaa, Marlowe's ask 2026-07-16) ─────────

  describe "archive undo toast" do
    # Archive is instant + dialog-free by design (recoverable by default, undo
    # not consent). But instant-and-SILENT meant an org archive could hide
    # several things with no acknowledgement. The toast is the undo-shaped
    # version of the confirm dialog's list: act now, say what went, keep the
    # reversal one click away.

    test "archiving an org shows what it took, and Undo puts it all back", %{conn: conn} do
      {conn, _admin} = fabrikam_admin_conn(conn)
      org = Tenancy.get_org_by_slug!("paragon")
      project = create_project("paragon")
      {:ok, _} = Tasks.update_project(project, %{name: "Site Expansion"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "[data-role=archive-undo-toast]")

      menu = "[data-menu-key='org:#{org.slug}']"
      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-archive]") |> render_click()

      toast = view |> element("[data-role=archive-undo-toast]") |> render()
      assert toast =~ "Archived"
      assert toast =~ "Paragon"
      # It names what the cascade took, not just a count.
      assert toast =~ "Site Expansion"

      assert Repo.reload!(org).archived_at
      assert Repo.reload!(project).archived_at

      view |> element("[data-role=archive-undo]") |> render_click()

      refute has_element?(view, "[data-role=archive-undo-toast]")
      refute Repo.reload!(org).archived_at
      refute Repo.reload!(project).archived_at
    end

    test "dismissing leaves the archive in place — dismiss is not undo", %{conn: conn} do
      {conn, _admin} = fabrikam_admin_conn(conn)
      org = Tenancy.get_org_by_slug!("soylent")
      # The Tasks sidebar only renders orgs that HAVE projects, so an org with
      # none has no kebab to click.
      _project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      menu = "[data-menu-key='org:#{org.slug}']"
      view |> element("#{menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{menu} [data-role=lifecycle-archive]") |> render_click()

      assert has_element?(view, "[data-role=archive-undo-toast]")

      view |> element("[data-role=archive-undo-dismiss]") |> render_click()

      refute has_element?(view, "[data-role=archive-undo-toast]")
      assert Repo.reload!(org).archived_at
    end
  end

  # ── select_project treats an archived project as a stale selection ─────

  describe "select_project with an archived project" do
    # Filtering archived projects out of the sidebar is NOT enough on its own.
    # `last_project.js` replays the stored id through this event on EVERY
    # mount, and the handler used to check only for nil — so whoever had a
    # project selected when it was archived kept getting a live, interactive
    # board for it on every visit, sticky until they picked another. Archived
    # is a stale selection, exactly like a deleted id.

    # NB: assert on the pushed event, not on the project NAME appearing in the
    # markup — the name stays in the sidebar either way, because `@projects` is
    # read once at mount and isn't re-fetched when a project is archived. The
    # push is also the thing that matters: `last_project.js` writes the id it
    # receives back to localStorage, so `"__all__"` is what self-heals the
    # stale entry and stops the archived board recurring on every visit.

    test "falls back to All Projects instead of selecting it", %{conn: conn} do
      {conn, admin} = fabrikam_admin_conn(conn)
      project = create_project("paragon")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Active: the replayed id selects normally.
      render_hook(view, "select_project", %{"id" => project.id})
      assert_push_event(view, "selected_project_changed", %{id: pushed_id})
      assert pushed_id == project.id

      {:ok, _} = Tasks.archive_project(admin, project)

      # Archived: the same replayed id must fall back, and push the correction.
      render_hook(view, "select_project", %{"id" => project.id})
      assert_push_event(view, "selected_project_changed", %{id: "__all__"})
    end

    test "an active project is still selectable", %{conn: conn} do
      {conn, _admin} = fabrikam_admin_conn(conn)
      project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "select_project", %{"id" => project.id})
      assert_push_event(view, "selected_project_changed", %{id: pushed_id})
      assert pushed_id == project.id
    end
  end

  # ── Org delete "surface & choose" (task 019f7600 stage 5) ──────────────

  describe "fabrikam admin — org delete surface & choose" do
    defp open_org_delete_modal(view) do
      org_menu = "[data-menu-key='org:soylent']"
      view |> element("#{org_menu} [data-role=lifecycle-menu-trigger]") |> render_click()
      view |> element("#{org_menu} [data-role=lifecycle-schedule-delete]") |> render_click()
      view
    end

    test "the org delete confirm lists children as a checklist, Delete gated until acknowledged",
         %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      swept = create_project("soylent")
      kept = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      open_org_delete_modal(view)

      assert has_element?(view, "[data-role=purge-checklist]")
      assert has_element?(view, "[data-role=purge-item][data-id='#{swept.id}']")
      assert has_element?(view, "[data-role=purge-item][data-id='#{kept.id}']")

      # The destructive button is disabled until the "I understand" gate is armed.
      assert has_element?(view, "[data-role=schedule-delete-confirm][disabled]")
    end

    test "keeping a child spares it while the org + the rest are scheduled", %{conn: conn} do
      {conn, _user} = fabrikam_admin_conn(conn)
      swept = create_project("soylent")
      kept = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      open_org_delete_modal(view)

      modal =
        form(view, "#schedule-delete-modal form", %{"keep" => [kept.id], "acknowledge" => "on"})

      render_change(modal)
      render_submit(modal)

      refute has_element?(view, "[data-role=schedule-delete-modal]")

      # Org + the un-kept project are scheduled …
      assert Repo.get_by(Org, slug: "soylent").deletion_scheduled_at
      assert Repo.get(Project, swept.id).deletion_scheduled_at
      # … the kept project is spared (no clock, survives as its own archived row).
      refute Repo.get(Project, kept.id).deletion_scheduled_at
    end

    test "submitting without the acknowledgement schedules nothing and leaves the modal open", %{
      conn: conn
    } do
      {conn, _user} = fabrikam_admin_conn(conn)
      project = create_project("soylent")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      open_org_delete_modal(view)

      modal = form(view, "#schedule-delete-modal form", %{"keep" => []})
      render_change(modal)
      render_submit(modal)

      assert has_element?(view, "[data-role=schedule-delete-modal]")
      refute Repo.get_by(Org, slug: "soylent").deletion_scheduled_at
      refute Repo.get(Project, project.id).deletion_scheduled_at
    end
  end
end
