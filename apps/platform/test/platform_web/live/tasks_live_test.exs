defmodule PlatformWeb.TasksLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.{Epic, Plan}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_test_#{System.unique_integer([:positive])}@example.com",
        name: "Tasks Test User",
        oidc_sub: "oidc-tasks-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Test Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Task #{System.unique_integer([:positive])}",
            status: "backlog",
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  # ── Kanban board tests ─────────────────────────────────────────────────

  test "GET /tasks renders the kanban board", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Tasks"
    assert html =~ "Backlog"
    assert html =~ "In Progress"
    assert html =~ "In Review"
    assert html =~ "Done"
    assert html =~ "All Projects"
  end

  test "kanban board groups tasks by status column", %{conn: conn} do
    project = create_project()
    _t1 = create_task(project, %{title: "Alpha Backlog", status: "backlog"})
    _t2 = create_task(project, %{title: "Beta In Progress", status: "in_progress"})
    _t3 = create_task(project, %{title: "Gamma In Review", status: "in_review"})
    _t4 = create_task(project, %{title: "Delta Done", status: "done"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Alpha Backlog"
    assert html =~ "Beta In Progress"
    assert html =~ "Gamma In Review"
    assert html =~ "Delta Done"
  end

  test "clicking a task card opens the detail panel", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Clickable Task", description: "A detailed description"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    html =
      view
      |> element("[phx-click=\"select_task\"][phx-value-id=\"#{task.id}\"]")
      |> render_click()

    assert html =~ "Clickable Task"
    assert html =~ "Description"
  end

  test "task status transitions work from the detail panel", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Transition Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # Transition from backlog → planning (valid per ADR 0018 §7)
    html =
      view
      |> element("button[phx-click=\"transition_task\"][phx-value-status=\"planning\"]")
      |> render_click()

    assert html =~ "moved to planning"

    # Verify task is now planning in the DB
    updated = Tasks.get_task_detail(task.id)
    assert updated.status == "planning"
  end

  test "project filter narrows tasks", %{conn: conn} do
    p1 = create_project()
    p2 = create_project()
    _t1 = create_task(p1, %{title: "Project One Task"})
    _t2 = create_task(p2, %{title: "Project Two Task"})

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks")

    # Both visible initially
    assert html =~ "Project One Task"
    assert html =~ "Project Two Task"

    # Filter to p1
    html =
      view
      |> element("form")
      |> render_change(%{"project_id" => p1.id})

    assert html =~ "Project One Task"
    refute html =~ "Project Two Task"
  end

  test "PubSub updates refresh the board", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "PubSub Task", status: "backlog"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Simulate a PubSub broadcast
    Tasks.broadcast_board({:task_updated, task})

    # The view should handle the message without crashing
    html = render(view)
    assert html =~ "PubSub Task"
  end

  test "shows priority badges on task cards", %{conn: conn} do
    project = create_project()
    _t = create_task(project, %{title: "Urgent Item", priority: "high"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "high"
    assert html =~ "Urgent Item"
  end

  test "shows plan progress on task cards", %{conn: conn} do
    project = create_project()
    task = create_task(project, %{title: "Planned Task", status: "in_progress"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

    {:ok, _s1} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Step 1", status: "passed"})

    {:ok, _s2} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Step 2", status: "pending"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # Should show progress 1/2
    assert html =~ "1/2"
  end

  test "GET /tasks redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/tasks")
    assert redirected_to(conn) == "/auth/login"
  end

  test "shell sidebar includes tasks navigation", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "/tasks"
    assert html =~ "Tasks"
  end
end
