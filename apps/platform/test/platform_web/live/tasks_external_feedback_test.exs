defmodule PlatformWeb.TasksExternalFeedbackTest do
  @moduledoc """
  The External Feedback board surface (task 01a11ec3 stage 4).

  Covers lane separation by PERSISTED origin, the trust badge, durable
  repository/issue provenance in the detail panel, and promotion through the
  Tasks UI — which must call only `Platform.Tasks.promote_from_quarantine/3`,
  and only for a human allowed to manage the task.

  The authorization cases are the point of this file. Stage 1's promotion
  accepts any `{:user, _}`, `{:agent, _}` or `:system` actor and checks no
  permission, so the LiveView event handler is the boundary for the human
  path. A hidden button is not that boundary: every refusal test below pushes
  the event directly, bypassing the markup, and asserts the persisted row and
  the audit stream are unchanged.

  Every test here fails against the stage-3 tip (69719af1f), where the lane,
  badge, provenance block and promote event do not exist.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler
  alias Platform.{Repo, Tasks, Tenancy, TenancyFixtures}

  @promoted_event "platform.tasks.external_feedback_promoted"

  setup do
    Platform.TelemetryHelpers.ensure_boot_handler!(TelemetryHandler)

    org_id = TenancyFixtures.tenant_org_id("initech")
    other_org_id = TenancyFixtures.tenant_org_id("hooli")

    {:ok, project} =
      Tasks.create_project(%{
        name: "External Feedback Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/external-feedback.git",
        org_id: org_id
      })

    %{project: project, org_id: org_id, other_org_id: other_org_id}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ext-feedback-#{label}-#{n}@example.com",
      name: "External Feedback #{label} #{n}",
      oidc_sub: "ext-feedback-#{label}-#{n}"
    })
  end

  defp membership!(user, org_id, role) do
    %Tenancy.OrgMembership{}
    |> Tenancy.OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  # A viewer who can SEE the board but may not manage the project's org.
  defp member_viewer!, do: user!("member") |> TenancyFixtures.member_of_all_orgs!()

  # An admin of the project's own org.
  defp org_admin!(org_id), do: user!("org-admin") |> membership!(org_id, "admin")

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp external_task!(project, attrs \\ %{}) do
    issue = System.unique_integer([:positive])

    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "External report #{issue}",
            status: "backlog",
            priority: "medium",
            kind: "bug",
            origin: "external_feedback",
            trust: "quarantined",
            external_repository_identity: "Startup-Suite/feedback",
            external_issue_number: issue
          },
          attrs
        )
      )

    task
  end

  defp internal_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Internal work #{System.unique_integer([:positive])}",
        status: "backlog",
        priority: "medium",
        kind: "bug"
      })

    task
  end

  defp promoted_events(task_id) do
    Repo.all(
      from(e in Event, where: e.event_type == @promoted_event and e.resource_id == ^task_id)
    )
  end

  defp push_promote(view, task) do
    render_click(with_target(view, "#tasks-detail"), "detail_promote_from_quarantine", %{
      "id" => task.id
    })
  end

  # ── lane separation ─────────────────────────────────────────────────────

  describe "External Feedback lane" do
    test "the lane URL shows only persisted external_feedback tasks", %{
      conn: conn,
      project: project
    } do
      quarantined = external_task!(project)
      internal = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, html} = live(conn, ~p"/tasks?origin=external_feedback")

      assert :sys.get_state(view.pid).socket.assigns.origin_filter == "external_feedback"
      assert html =~ ~s(id="task-card-#{quarantined.id}")
      refute html =~ ~s(id="task-card-#{internal.id}")

      assert has_element?(
               view,
               "[data-role='origin-lane-tab'][data-lane='external_feedback'][aria-current='page']"
             )

      assert has_element?(view, "[data-role='external-feedback-lane-banner']")
    end

    test "the default board keeps every task and offers the lane tab", %{
      conn: conn,
      project: project
    } do
      quarantined = external_task!(project)
      internal = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.origin_filter == :all
      assert html =~ ~s(id="task-card-#{quarantined.id}")
      assert html =~ ~s(id="task-card-#{internal.id}")
      refute has_element?(view, "[data-role='external-feedback-lane-banner']")

      assert has_element?(
               view,
               "[data-role='origin-lane-tab'][data-lane='all'][aria-current='page']"
             )
    end

    test "the lane tab patches a shareable URL and keeps the other filters", %{
      conn: conn,
      project: project
    } do
      quarantined = external_task!(project)
      internal = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, _html} = live(conn, ~p"/tasks?kind=bug")

      view
      |> element("[data-role='origin-lane-tab'][data-lane='external_feedback']")
      |> render_click()

      assert_patched(view, "/tasks?kind=bug&origin=external_feedback")
      html = render(view)
      assert html =~ ~s(id="task-card-#{quarantined.id}")
      refute html =~ ~s(id="task-card-#{internal.id}")

      view
      |> element("[data-role='origin-lane-tab'][data-lane='all']")
      |> render_click()

      assert_patched(view, "/tasks?kind=bug")
    end

    test "an unknown origin value fails open to the full board", %{conn: conn, project: project} do
      internal = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, html} = live(conn, ~p"/tasks?origin=internal_but_spoofed")

      assert :sys.get_state(view.pid).socket.assigns.origin_filter == :all
      assert html =~ ~s(id="task-card-#{internal.id}")
    end
  end

  # ── badges ──────────────────────────────────────────────────────────────

  describe "trust badge" do
    test "external cards carry the persisted trust; internal cards carry none", %{
      conn: conn,
      project: project
    } do
      quarantined = external_task!(project)
      trusted = external_task!(project)
      {:ok, trusted} = Tasks.promote_from_quarantine(trusted, :system, via: "test_seed")
      internal = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, _html} = live(conn, ~p"/tasks?origin=external_feedback")

      assert has_element?(
               view,
               "#task-card-#{quarantined.id} [data-role='task-trust-badge'][data-trust='quarantined']"
             )

      assert has_element?(
               view,
               "#task-card-#{trusted.id} [data-role='task-trust-badge'][data-trust='trusted']"
             )

      badge =
        view
        |> element("#task-card-#{quarantined.id} [data-role='task-trust-badge']")
        |> render()

      # Semantic tokens only: the destructive chip tone, never a raw colour.
      assert badge =~ "chip-error"
      refute badge =~ ~r/#[0-9a-fA-F]{3,8}\b/

      {:ok, all_view, _html} = live(conn, ~p"/tasks")
      refute has_element?(all_view, "#task-card-#{internal.id} [data-role='task-trust-badge']")
    end
  end

  # ── detail provenance ───────────────────────────────────────────────────

  describe "detail provenance" do
    test "detail shows repository and issue identity for an external task", %{
      conn: conn,
      project: project
    } do
      # A FIXED six-digit issue number, so the hex-colour guard below meets
      # its hard case on every run instead of only once
      # `System.unique_integer/1` has climbed past 99_999.
      task = external_task!(project, %{external_issue_number: 435_138})
      conn = login(conn, member_viewer!())

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      block = view |> element("[data-role='detail-external-provenance']") |> render()

      assert block =~ "Startup-Suite/feedback"
      assert block =~ "##{task.external_issue_number}"

      assert block =~
               ~s(href="https://github.com/Startup-Suite/feedback/issues/#{task.external_issue_number}")

      assert block =~ ~s(data-trust="quarantined")

      # No raw hex colour anywhere in the block. The issue reference
      # `#<number>` is removed first and only that exact token: a decimal
      # issue number of six digits is also a valid `#rrggbb`, so matching it
      # was a data-dependent false failure, not a colour.
      without_issue_ref = String.replace(block, "##{task.external_issue_number}", "")
      refute without_issue_ref =~ ~r/#[0-9a-fA-F]{6}\b/
    end

    test "an internal task renders no provenance block", %{conn: conn, project: project} do
      task = internal_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "[data-role='detail-external-provenance']")
      refute has_element?(view, "[data-role='detail-promote-from-quarantine']")
    end
  end

  # ── promotion ───────────────────────────────────────────────────────────

  describe "promotion" do
    test "an org admin promotes; the audit row names that human; lane and provenance survive",
         %{conn: conn, project: project, org_id: org_id} do
      task = external_task!(project)
      admin = org_admin!(org_id)
      conn = login(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-role='detail-promote-from-quarantine']") |> render_click()

      persisted = Tasks.get_task_record(task.id)
      assert persisted.trust == "trusted"
      assert persisted.origin == "external_feedback"
      assert persisted.external_repository_identity == task.external_repository_identity
      assert persisted.external_issue_number == task.external_issue_number

      assert [event] = promoted_events(task.id)
      assert event.actor_type == "user"
      assert event.actor_id == admin.id
      assert event.metadata["via"] == "tasks_ui"

      # The panel re-renders from the persisted row: trusted badge, provenance
      # intact, no control left to press.
      assert has_element?(
               view,
               "[data-role='detail-external-provenance'] [data-role='task-trust-badge'][data-trust='trusted']"
             )

      refute has_element?(view, "[data-role='detail-promote-from-quarantine']")

      # Still in the External Feedback lane after promotion.
      {:ok, lane, lane_html} = live(conn, ~p"/tasks?origin=external_feedback")
      assert lane_html =~ ~s(id="task-card-#{task.id}")

      assert has_element?(
               lane,
               "#task-card-#{task.id} [data-role='task-trust-badge'][data-trust='trusted']"
             )
    end

    test "a root-org admin may promote a tenant project's task", %{
      conn: conn,
      project: project
    } do
      task = external_task!(project)
      root_admin = user!("root-admin") |> membership!(TenancyFixtures.acme_org_id(), "admin")
      conn = login(conn, root_admin)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      push_promote(view, task)

      assert Tasks.get_task_record(task.id).trust == "trusted"
      assert [%{actor_id: actor_id}] = promoted_events(task.id)
      assert actor_id == root_admin.id
    end

    test "a plain member sees no control, and a forged event changes nothing", %{
      conn: conn,
      project: project
    } do
      task = external_task!(project)
      conn = login(conn, member_viewer!())

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "[data-role='detail-promote-from-quarantine']")

      # Bypass the markup entirely: the handler is the boundary.
      push_promote(view, task)

      persisted = Tasks.get_task_record(task.id)
      assert persisted.trust == "quarantined"
      assert persisted.updated_at == task.updated_at
      assert promoted_events(task.id) == []
      assert render(view) =~ "not allowed to promote"
    end

    test "an admin of a DIFFERENT org is refused", %{
      conn: conn,
      project: project,
      other_org_id: other_org_id
    } do
      task = external_task!(project)
      conn = login(conn, org_admin!(other_org_id))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "[data-role='detail-promote-from-quarantine']")

      push_promote(view, task)

      assert Tasks.get_task_record(task.id).trust == "quarantined"
      assert promoted_events(task.id) == []
    end

    test "an external admin of the project's org is refused", %{
      project: project,
      org_id: org_id
    } do
      task = external_task!(project)
      external_admin = user!("external-admin")

      %Tenancy.OrgMembership{}
      |> Tenancy.OrgMembership.changeset(%{
        user_id: external_admin.id,
        org_id: org_id,
        role: "admin",
        external: true
      })
      |> Repo.insert!()

      # External users may not reach /tasks at all, so this is pinned on the
      # predicate the handler calls rather than through a mounted view.
      refute Tasks.can_promote_from_quarantine?(external_admin, task)
    end

    test "the authorization predicate refuses non-human and unknown actors", %{
      project: project,
      org_id: org_id
    } do
      task = external_task!(project)
      admin = org_admin!(org_id)

      assert Tasks.can_promote_from_quarantine?(admin, task)
      refute Tasks.can_promote_from_quarantine?(member_viewer!(), task)
      refute Tasks.can_promote_from_quarantine?(nil, task)
      refute Tasks.can_promote_from_quarantine?(:system, task)
      refute Tasks.can_promote_from_quarantine?({:agent, Ecto.UUID.generate()}, task)
      refute Tasks.can_promote_from_quarantine?(%{id: Ecto.UUID.generate()}, task)
    end

    test "a forged event for an internal task is refused and audits nothing", %{
      conn: conn,
      project: project,
      org_id: org_id
    } do
      internal = internal_task!(project)
      quarantined = external_task!(project)
      conn = login(conn, org_admin!(org_id))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{quarantined.id}")
      push_promote(view, internal)

      assert Tasks.get_task_record(internal.id).trust == "trusted"
      assert promoted_events(internal.id) == []
      assert Tasks.get_task_record(quarantined.id).trust == "quarantined"
    end
  end
end
