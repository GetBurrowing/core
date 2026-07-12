defmodule PlatformWeb.TasksLiveSearchTest do
  @moduledoc """
  Re-skin Phase 2 stage 2 (task 019f51ca): the page-header search input
  narrows the board in-memory via the `search_tasks` event across task
  id, title, sponsor name, assignee display and epic name. Escape (or an
  empty query) restores the unfiltered board.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_search_#{System.unique_integer([:positive])}@example.com",
        name: "Search Test User",
        oidc_sub: "oidc-tasks-search-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Search Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_task(project, attrs) do
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

  describe "board search" do
    test "renders the search input in the page header", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(id="task-search-form")
      assert html =~ ~s(phx-change="search_tasks")
      assert html =~ ~s(aria-label="Search tasks")
    end

    test "filters board items by title, case-insensitively", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Alpha Rocket"})
      create_task(project, %{title: "Beta Boat"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      assert html =~ "Alpha Rocket"
      assert html =~ "Beta Boat"

      html =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "rocket"})

      assert html =~ "Alpha Rocket"
      refute html =~ "Beta Boat"
    end

    test "matches on task id substring and epic name", %{conn: conn} do
      project = create_project()

      {:ok, epic} =
        Tasks.create_epic(%{name: "Skyhook Epic", project_id: project.id})

      task = create_task(project, %{title: "Id Target"})
      create_task(project, %{title: "Epic Member", epic_id: epic.id})
      create_task(project, %{title: "Unrelated"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # UUIDv7 ids share a timestamp prefix across same-test inserts —
      # the random tail is the only discriminating substring.
      id_fragment = String.slice(task.id, -12, 12)
      html = view |> element("#task-search-form") |> render_change(%{"q" => id_fragment})
      assert html =~ "Id Target"
      refute html =~ "Unrelated"

      html = view |> element("#task-search-form") |> render_change(%{"q" => "skyhook"})
      assert html =~ "Epic Member"
      refute html =~ "Unrelated"
    end

    test "shows the empty banner when nothing matches and Escape clears", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Only Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "zzz-no-such-task"})

      refute html =~ "Only Task"
      assert html =~ ~s(data-role="search-empty-state")
      assert html =~ "No matching tasks"

      # Escape keydown on the input clears the query and restores the board.
      html = render_keydown(view, "search_tasks", %{"key" => "Escape", "value" => "zzz"})
      assert html =~ "Only Task"
      refute html =~ ~s(data-role="search-empty-state")
    end

    test "an active search survives a board refresh (PubSub)", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Kept Match"})
      nonmatch = create_task(project, %{title: "Filtered Away"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = view |> element("#task-search-form") |> render_change(%{"q" => "kept"})
      assert html =~ "Kept Match"
      refute html =~ "Filtered Away"

      # update_task broadcasts {:task_updated, _} on the board topic →
      # refresh_board/1 refetches. The query must still narrow the
      # refreshed board (maybe_reapply_search/1).
      {:ok, _} = Tasks.update_task(nonmatch, %{priority: "high"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Kept Match"
      refute html =~ "Filtered Away"
    end
  end

  test "scope-rail counts and header total narrow with an active search and restore on clear",
       %{conn: conn} do
    project = create_project()
    create_task(project, %{title: "Composer dock retrofit"})
    create_task(project, %{title: "Unrelated widget"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live("/tasks")

    # Marlowe 2026-07-12: every on-screen count describes the filtered board.
    html = render_change(view, "search_tasks", %{"q" => "composer"})
    assert html =~ "Composer dock retrofit"
    refute html =~ "Unrelated widget"
    # header badge + fabrikam scope chip both show exactly one visible task
    assert view |> element("#tasks-page-header") |> render() =~ ">1<"

    # clearing restores the unfiltered totals everywhere
    html = render_change(view, "search_tasks", %{"q" => ""})
    assert html =~ "Unrelated widget"
    refute view |> element("#tasks-page-header") |> render() =~ ">1<"
  end
end
