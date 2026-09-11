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
  alias Platform.Tasks.{Stacks, Task}
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

  defp create_stack(project) do
    slug = "search-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Search Stack #{System.unique_integer([:positive])}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Task 01a06df3 stage 2. Two people independently searched the board for a
  # real ticket, found nothing, and concluded it did not exist. The ticket was
  # a stack member: `group_board_items/2` suppresses any task with a
  # `stack_id` from the flat column list, and a `stack_pending` member's
  # status is in NEITHER `@desktop_column_statuses` NOR
  # `@mobile_column_statuses`, so the parent stack card is the only place it
  # can render at all. Stage 1 taught the matcher to see member titles; this
  # stage makes the found member actually visible, because
  # `refresh_board/1` empties `:expanded_stacks` right before re-applying the
  # search and `BoardComponent` gates the member rows on that MapSet.
  describe "board search reaches a task parked inside a stack" do
    test "a stack_pending member matched by title renders in its auto-expanded stack card",
         %{conn: conn} do
      project = create_project()

      # One shared term, and nothing else on the board carries it.
      solo = create_task(project, %{title: "Periscope standalone ticket"})

      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Periscope stacked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      # NEGATIVE CONTROL. A build that ignores the query and lists everything
      # passes both assertions above and fails this one.
      control = create_task(project, %{title: "Unrelated widget ticket"})

      # A lone `stack_pending` member rolls the stack up to `in_progress`
      # (`rollup_status_for/1`), which is a real desktop AND mobile column —
      # so the card has somewhere to land.
      {:ok, _stack} = Stacks.recompute_stack_status(stack)

      # Load-bearing: `create_task/2` is not obliged to honour the status we
      # asked for (an assignee can force `planning`, for one). If the seed
      # does not actually park the member at `stack_pending` then the member
      # has an ordinary column to render in and this test proves nothing
      # about the stack path.
      assert Repo.get!(Task, member.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      member_row =
        ~s([data-stack-card="true"] [data-stack-member="true"][data-member-id="#{member.id}"])

      # Preconditions with NO query, so each later assertion is attributable
      # to the filter rather than to something never having rendered:
      #   * the control renders, so its absence under the query is the filter
      #   * the member row does NOT render, because the stack card starts
      #     collapsed — which is exactly what stage 2 has to overcome
      assert has_element?(view, ~s([data-task-id="#{control.id}"]))
      assert has_element?(view, ~s([data-task-id="#{solo.id}"]))
      refute has_element?(view, member_row)

      _ = render_change(filters(view), "filter_search", %{"q" => "periscope"})
      _ = after_filter(view)

      # The standalone task: an ordinary card.
      assert has_element?(view, ~s([data-task-id="#{solo.id}"]))

      # The stacked task: visible with no further click, and still legible AS
      # a stack member — the row is inside a stack card and carries its own
      # member id.
      assert has_element?(view, member_row)
      assert has_element?(view, ~s([data-stack-card="true"][data-stack-id="#{stack.id}"]))

      # Visible means the card is genuinely expanded, not that the row leaked
      # out of a collapsed card.
      assert has_element?(
               view,
               ~s([data-stack-card="true"][data-stack-id="#{stack.id}"][data-expanded="true"])
             )

      # Negative control.
      refute has_element?(view, ~s([data-task-id="#{control.id}"]))
      refute render(view) =~ "Unrelated widget ticket"
    end

    test "a search does not collapse a stack the user expanded by hand", %{conn: conn} do
      project = create_project()
      stack = create_stack(project)

      member =
        create_task(project, %{
          title: "Periscope stacked ticket",
          status: "stack_pending",
          stack_id: stack.id,
          stack_position: 1
        })

      {:ok, _stack} = Stacks.recompute_stack_status(stack)
      assert Repo.get!(Task, member.id).status == "stack_pending"

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      member_row =
        ~s([data-stack-card="true"] [data-stack-member="true"][data-member-id="#{member.id}"])

      # The user opens the card themselves.
      refute has_element?(view, member_row)

      _ =
        view
        |> Phoenix.LiveViewTest.with_target("#tasks-stacks")
        |> render_click("stack_toggle_expand", %{"id" => stack.id})

      _ = after_filter(view)
      assert has_element?(view, member_row)

      # Now a query that hits the stack's OWN NAME and no member title. The
      # auto-expand set for this query is therefore empty, so a write that
      # REPLACED `:expanded_stacks` instead of unioning into it would slam
      # the card shut under the user. This assertion is the difference
      # between the two, and it is why the hook unions.
      _ = render_change(filters(view), "filter_search", %{"q" => stack.name})
      _ = after_filter(view)

      assert has_element?(view, ~s([data-stack-card="true"][data-stack-id="#{stack.id}"]))
      assert has_element?(view, member_row)
    end
  end

  describe "board search" do
    test "renders the search input in the page header", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(id="task-search-form")
      assert html =~ ~s(phx-change="filter_search")
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

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "rocket"})

      html = after_filter(view)
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
      _ = view |> element("#task-search-form") |> render_change(%{"q" => id_fragment})
      html = after_filter(view)
      assert html =~ "Id Target"
      refute html =~ "Unrelated"

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "skyhook"})

      html = after_filter(view)
      assert html =~ "Epic Member"
      refute html =~ "Unrelated"
    end

    test "shows the empty banner when nothing matches and Escape clears", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Only Task"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "zzz-no-such-task"})

      html = after_filter(view)
      refute html =~ "Only Task"
      assert html =~ ~s(data-role="search-empty-state")
      assert html =~ "No matching tasks"

      # Escape keydown on the input clears the query and restores the board.
      _ = render_keydown(filters(view), "filter_search", %{"key" => "Escape", "value" => "zzz"})
      html = after_filter(view)
      assert html =~ "Only Task"
      refute html =~ ~s(data-role="search-empty-state")
    end

    test "an active search survives a board refresh (PubSub)", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Kept Match"})
      nonmatch = create_task(project, %{title: "Filtered Away"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ = view |> element("#task-search-form") |> render_change(%{"q" => "kept"})

      html = after_filter(view)
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
    _ = render_change(filters(view), "filter_search", %{"q" => "composer"})
    html = after_filter(view)
    assert html =~ "Composer dock retrofit"
    refute html =~ "Unrelated widget"
    # header badge + fabrikam scope chip both show exactly one visible task
    assert view |> element("#tasks-page-header") |> render() =~ ">1<"

    # clearing restores the unfiltered totals everywhere
    _ = render_change(filters(view), "filter_search", %{"q" => ""})
    html = after_filter(view)
    assert html =~ "Unrelated widget"
    refute view |> element("#tasks-page-header") |> render() =~ ">1<"
  end

  # Task 01a008f6 stage 6: board filtering is a LiveComponent.
  defp filters(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-filters")

  # Task 01a008f6 stage 6: FiltersComponent writes the filter value and hands
  # it to the shell as `{:tasks_filters_changed, _}`. The shell's board work
  # therefore lands in the render AFTER the event reply, so a test that reads
  # the reply html directly is reading the pre-mediation board.
  defp after_filter(view) do
    _ = :sys.get_state(view.pid)
    Phoenix.LiveViewTest.render(view)
  end
end
