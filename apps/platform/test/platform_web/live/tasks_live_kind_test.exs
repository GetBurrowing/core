defmodule PlatformWeb.TasksLiveKindTest do
  @moduledoc """
  Regression coverage for task kind on the human board.

  Every case fails on the unfixed base: the create selector and board badges
  do not exist, the UI submit path discards a non-default kind, and the board
  has no kind URL/filter/query plumbing. These assertions therefore cannot be
  satisfied by the schema's feature default alone.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "task-kind-ui-#{System.unique_integer([:positive])}@example.com",
        name: "Task Kind UI User",
        oidc_sub: "task-kind-ui-#{System.unique_integer([:positive])}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp project_fixture do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Task Kind Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/task-kind.git"
      })

    project
  end

  defp task_fixture(project, title, kind) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "backlog",
        priority: "medium",
        kind: kind
      })

    task
  end

  test "create sheet exposes all five kinds and persists a non-default choice", %{conn: conn} do
    project = project_fixture()
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    view |> element("[data-role='header-new-task']") |> render_click()

    assert has_element?(view, "[data-role='task-kind-select'][name='task[kind]']")

    for kind <- ~w(feature chore bug research ops) do
      assert has_element?(view, "[data-role='task-kind-select'] option[value='#{kind}']")
    end

    render_submit(with_target(view, "#tasks-create"), "taskcreate_submit", %{
      "task" => %{
        "title" => "Non-default UI chore",
        "project_id" => project.id,
        "kind" => "chore",
        "what" => "Exercise the human write surface",
        "why" => "Defaults alone are not taxonomy support",
        "wrong" => "If the row is not chore, stop and re-derive",
        "action" => "create",
        "assignee_id" => "",
        "assignee_type" => "agent",
        "deploy_target" => "",
        "epic_id" => ""
      }
    })

    created =
      Enum.find(Tasks.list_tasks_by_project(project.id), &(&1.title == "Non-default UI chore"))

    assert created.kind == "chore"
  end

  test "board displays kind badges and kind URL narrows standalone tasks", %{conn: conn} do
    project = project_fixture()
    chore = task_fixture(project, "Visible Chore", "chore")
    feature = task_fixture(project, "Hidden Feature", "feature")
    conn = authenticated_conn(conn)

    {:ok, view, html} = live(conn, ~p"/tasks?kind=chore")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.kind_filters == ["chore"]
    # Task 01a15746 stage 2: the single-kind assign and the old select are gone.
    refute has_element?(view, "#tasks-kind-filter")
    assert html =~ ~s(id="task-card-#{chore.id}")
    refute html =~ ~s(id="task-card-#{feature.id}")

    assert has_element?(
             view,
             "#task-card-#{chore.id} [data-role='task-kind-badge'][data-task-kind='chore']"
           )
  end

  test "the filter popover's kind toggle patches a shareable URL; invalid values fail open",
       %{conn: conn} do
    project = project_fixture()
    chore = task_fixture(project, "Chore Through Control", "chore")
    feature = task_fixture(project, "Feature Through Control", "feature")
    conn = authenticated_conn(conn)

    {:ok, view, html} = live(conn, ~p"/tasks")
    assert html =~ ~s(id="task-card-#{feature.id}"), "positive control"

    render_click(view, "tasks_filter_open", %{"sheet" => "filter"})

    view
    |> element(~s(#tasks-filter-popover [data-role="tasks-filter-option"][data-kind="chore"]))
    |> render_click()

    assert_patched(view, "/tasks?kind=chore")
    html = render(view)
    assert html =~ ~s(id="task-card-#{chore.id}")
    refute html =~ ~s(id="task-card-#{feature.id}")

    {:ok, invalid_view, invalid_html} = live(conn, ~p"/tasks?kind=not-a-kind")
    assert :sys.get_state(invalid_view.pid).socket.assigns.kind_filters == []
    assert invalid_html =~ ~s(id="task-card-#{chore.id}")
    assert invalid_html =~ ~s(id="task-card-#{feature.id}")
  end
end
