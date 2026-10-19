defmodule PlatformWeb.RecoveryLiveTest do
  @moduledoc """
  The Recovery hub (task 019f7600 stage 4): lists archived + deletion-scheduled
  orgs, projects, AND channels from the unified recoverable inventory; groups
  cascade children under their org; and restores them via selection (leaves) or
  "Restore all" (containers), with an act-then-confirm success toast. Acme-admin
  only.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Chat, Repo, Tasks, Tenancy}
  alias Platform.Chat.Space
  alias Platform.Tasks.Project
  alias Platform.Tenancy.{Org, OrgMembership}

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "recovery-#{n}@example.com",
      name: "User #{n}",
      oidc_sub: "oidc-recovery-#{n}"
    })
  end

  defp acme_admin_conn(conn) do
    user = insert_user()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp member_conn(conn) do
    user = insert_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  # A fresh tenant org parented to Acme — isolated so archiving it can't perturb
  # a seeded tenant.
  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp project!(org, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(Map.merge(%{name: "Proj #{n}", org_id: org.id}, attrs))
    project
  end

  defp channel!(org, attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel", org_id: org.id}, attrs)
      )

    space
  end

  defp row(type, id), do: "[data-role=recovery-row][data-type=#{type}][data-id='#{id}']"

  # ── Acme admin ─────────────────────────────────────────────────────────

  describe "acme admin" do
    test "empty state renders when nothing is archived", %{conn: conn} do
      {conn, _user} = acme_admin_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/admin/recovery")

      assert html =~ "Nothing archived"
    end

    test "an independently-archived channel renders as its own row", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      channel = channel!(org, %{name: "Announcements"})
      {:ok, _} = Chat.archive_space(admin, channel)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      assert has_element?(view, row("channel", channel.id))
      assert render(view) =~ "Announcements"
    end

    test "an archived org groups its cascade children — revealed on expand", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!(%{name: "Initech"})
      project = project!(org, %{name: "Discovery"})
      channel = channel!(org, %{name: "Standup"})

      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      # The org container row and its expand affordance are present…
      assert has_element?(view, row("org", org.id))
      assert has_element?(view, "#{row("org", org.id)} [data-role=expand-toggle]")

      # …but the cascade children are collapsed until the toggle is used.
      refute has_element?(view, row("project", project.id))
      refute has_element?(view, row("channel", channel.id))

      view |> element("#{row("org", org.id)} [data-role=expand-toggle]") |> render_click()

      assert has_element?(view, row("project", project.id))
      assert has_element?(view, row("channel", channel.id))
    end

    test "the selection bar appears only once a leaf row is checked", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      refute has_element?(view, "[data-role=selection-bar]")

      view |> element("#{row("project", project.id)} [data-role=select]") |> render_click()

      assert has_element?(view, "[data-role=selection-bar]")
      assert render(view) =~ "1 selected"
    end

    test "the row selector is a checkbox, not a radio", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      # The per-row select is a square checkbox (multi-select intent), never a
      # single-choice radio — locks the control's role after the visual-gate
      # rework that squared off its (previously circular) corners.
      assert has_element?(
               view,
               "#{row("project", project.id)} input[type=checkbox][data-role=select]"
             )

      refute has_element?(view, "#{row("project", project.id)} input[type=radio]")
    end

    test "Restore selected brings back a leaf and shows the success toast", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org, %{name: "Roadmap"})
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("project", project.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()

      # DB row is active again, its recovery row is gone, and the toast fired.
      refute Repo.get(Project, project.id).archived_at
      refute has_element?(view, row("project", project.id))
      assert has_element?(view, "[data-role=recovery-toast]")
      assert render(view) =~ "Roadmap restored"
    end

    # The toast's "View →" quick-link. Assert via an attribute selector (matches
    # the element on both data-role AND href) rather than a regex over serialized
    # HTML — Phoenix renders attributes in a non-deterministic order.

    test "the toast View link points at the restored project's files", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org, %{name: "Roadmap"})
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("project", project.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()

      path = ~p"/files/#{project.id}"
      assert has_element?(view, "[data-role=toast-view][href='#{path}']")
    end

    test "the toast View link opens the restored channel in chat", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      channel = channel!(org, %{name: "Standup", slug: "standup-view"})
      {:ok, _} = Chat.archive_space(admin, channel)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("channel", channel.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()

      path = ~p"/chat/#{channel.slug}"
      assert has_element?(view, "[data-role=toast-view][href='#{path}']")
    end

    test "a multi-item restore shows the toast but no View link", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      alpha = project!(org, %{name: "Alpha"})
      beta = project!(org, %{name: "Beta"})
      {:ok, _} = Tasks.archive_project(admin, alpha)
      {:ok, _} = Tasks.archive_project(admin, beta)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("project", alpha.id)} [data-role=select]") |> render_click()
      view |> element("#{row("project", beta.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()

      assert has_element?(view, "[data-role=recovery-toast]")
      assert render(view) =~ "2 items restored"
      refute has_element?(view, "[data-role=toast-view]")
    end

    test "restoring a cascade child names the org reactivated as a side-effect", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!(%{name: "Initech"})
      project = project!(org, %{name: "Discovery"})

      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=expand-toggle]") |> render_click()
      view |> element("#{row("project", project.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()

      toast = view |> element("[data-role=recovery-toast]") |> render()
      assert toast =~ "Discovery restored"
      assert toast =~ "Initech reactivated too"

      # The child came back and its org was reactivated with it.
      refute Repo.get(Project, project.id).archived_at
      refute Repo.get(Org, org.id).archived_at
    end

    test "container Restore all brings back the whole subtree", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      channel = channel!(org)

      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()

      refute has_element?(view, row("org", org.id))
      refute Repo.get(Org, org.id).archived_at
      refute Repo.get(Project, project.id).archived_at
      refute Repo.get(Space, channel.id).archived_at
      assert has_element?(view, "[data-role=recovery-toast]")
    end

    test "a deletion-scheduled row shows the Scheduled status", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      {:ok, _} = Tasks.schedule_project_deletion(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      assert has_element?(view, "#{row("project", project.id)}[data-status=scheduled]")
      assert render(view) =~ "Scheduled for deletion"
    end

    test "Undo re-archives just the restored leaf", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      {:ok, _} = Tasks.archive_project(admin, project)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("project", project.id)} [data-role=select]") |> render_click()
      view |> element("[data-role=restore-selected]") |> render_click()
      refute Repo.get(Project, project.id).archived_at

      view |> element("[data-role=toast-undo]") |> render_click()

      # Re-archived and back in the list.
      assert Repo.get(Project, project.id).archived_at
      assert has_element?(view, row("project", project.id))
    end
  end

  # ── Restore all — scheduled-children warning (task 019f7600 stage 5) ────

  describe "restore all warning modal" do
    test "an org with plain-archived children restores straight away (no warning)", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      # Plain archive → children hidden with NO countdown → nothing to warn about.
      {:ok, _} = Tenancy.archive_org(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()

      refute has_element?(view, "[data-role=restore-all-modal]")
      refute Repo.get(Org, org.id).archived_at
      refute Repo.get(Project, project.id).archived_at
    end

    test "an org with scheduled children opens the warning instead of restoring", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!(%{name: "Initech"})
      project = project!(org, %{name: "Discovery"})
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()

      # The modal lists the scheduled child; nothing has been restored yet.
      assert has_element?(view, "[data-role=restore-all-modal]")
      assert has_element?(view, "[data-role=keep-scheduled-item][data-id='#{project.id}']")
      assert render(view) =~ "Discovery"
      assert Repo.get(Org, org.id).deletion_scheduled_at
      assert Repo.get(Project, project.id).deletion_scheduled_at
    end

    test "confirming with the default restores the subtree and cancels the countdowns", %{
      conn: conn
    } do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      channel = channel!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()
      view |> element("[data-role=restore-all-confirm]") |> render_click()

      refute has_element?(view, "[data-role=restore-all-modal]")
      refute Repo.get(Org, org.id).archived_at

      proj = Repo.get(Project, project.id)
      refute proj.archived_at
      refute proj.deletion_scheduled_at

      chan = Repo.get(Space, channel.id)
      refute chan.archived_at
      refute chan.deletion_scheduled_at

      assert has_element?(view, "[data-role=recovery-toast]")
    end

    test "keeping a child scheduled restores the org but leaves that child counting down", %{
      conn: conn
    } do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      kept = project!(org)
      revived = project!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()

      # Mark the first child "keep scheduled", then confirm.
      view
      |> element(
        "[data-role=keep-scheduled-item][data-id='#{kept.id}'] [data-role=keep-scheduled]"
      )
      |> render_click()

      view |> element("[data-role=restore-all-confirm]") |> render_click()

      # Org is active again and the other child fully revived …
      refute Repo.get(Org, org.id).archived_at
      revived = Repo.get(Project, revived.id)
      refute revived.archived_at
      refute revived.deletion_scheduled_at

      # … but the kept child is still scheduled (detached, own clock intact).
      kept = Repo.get(Project, kept.id)
      assert kept.deletion_scheduled_at
      assert is_nil(kept.archived_cascade_org_id)
    end

    test "Cancel closes the warning without restoring", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      org = tenant_org!()
      project = project!(org)
      {:ok, _} = Tenancy.schedule_org_deletion(admin, org)

      {:ok, view, _html} = live(conn, ~p"/admin/recovery")

      view |> element("#{row("org", org.id)} [data-role=restore-all]") |> render_click()
      view |> element("[data-role=restore-all-cancel]") |> render_click()

      refute has_element?(view, "[data-role=restore-all-modal]")
      assert Repo.get(Org, org.id).deletion_scheduled_at
      assert Repo.get(Project, project.id).deletion_scheduled_at
    end
  end

  # ── Non-admin ──────────────────────────────────────────────────────────

  describe "non-admin" do
    test "is refused (redirected away from the recovery route)", %{conn: conn} do
      {conn, _user} = member_conn(conn)

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} = live(conn, ~p"/admin/recovery")
    end
  end
end
