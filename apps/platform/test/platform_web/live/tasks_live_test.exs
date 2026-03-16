defmodule PlatformWeb.TasksLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Artifacts, Context, Execution, Repo}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_test_#{System.unique_integer([:positive])}@example.com",
        name: "Tasks Test User",
        oidc_sub: "oidc-tasks-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  test "GET /tasks redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/tasks")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /tasks/:task_id renders task detail from execution/context/artifact state", %{
    conn: conn
  } do
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, run} =
      Execution.start_run(task_id, project_id: "proj-1", epic_id: "epic-1", runner_type: :local)

    {:ok, _session} = Context.ensure_session(%{task_id: task_id})

    {:ok, _version} =
      Context.put_item(%{task_id: task_id}, "task:title", "Tasks UI MVP", kind: :task_metadata)

    {:ok, _artifact} =
      Artifacts.register_artifact(%{
        task_id: task_id,
        run_id: run.id,
        source: :execution,
        kind: :document,
        name: "run-summary.md",
        locator: %{path: "/tmp/run-summary.md"}
      })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task_id}")

    assert html =~ "Tasks"
    assert html =~ task_id
    assert html =~ "Live runs"
    assert html =~ "run-summary.md"
    assert html =~ "Tasks UI MVP"
    assert html =~ "Stop"
    assert html =~ "Force kill"
  end

  test "shell sidebar includes tasks navigation", %{conn: conn} do
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _run} = Execution.start_run(task_id, project_id: "proj-1", epic_id: "epic-1")

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks/#{task_id}")

    assert html =~ "/tasks"
    assert html =~ "Tasks"
  end

  test "can bootstrap the proof-of-life task from the tasks UI", %{conn: conn} do
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _run} = Execution.start_run(task_id, project_id: "proj-1", epic_id: "epic-1")

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks/#{task_id}")

    assert html =~ "Create proof-of-life task"

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("button[phx-click=\"create_proof_task\"]")
             |> render_click()

    assert to == "/tasks/suite-proof-of-life"

    {:ok, _view, html} = live(conn, to)
    assert html =~ "suite-proof-of-life"
    assert html =~ "Launch proof run"
  end
end
