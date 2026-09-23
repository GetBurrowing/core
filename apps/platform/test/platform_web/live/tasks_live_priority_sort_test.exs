defmodule PlatformWeb.TasksLivePrioritySortTest do
  @moduledoc """
  The rendered board order is priority-first (task 01a0cef1 stage 1).

  Asserted on BOTH rendered surfaces, separately, because they read
  different assigns: the desktop kanban column is `@columns` +
  `@desktop_stacks_by_column` merged by `BoardComponent.desktop_column_items/5`,
  the mobile section list is `@board_items` from
  `BoardData.group_board_items/3`. A fix to one alone leaves the other
  recency-ordered.

  Fixtures mirror `PlatformWeb.Tasks.BoardDataSortTest`: explicit
  `inserted_at` across a month boundary, `updated_at` reversed against it
  (so the pre-change recency order is the exact reverse within each
  priority), a NULL and an unknown `"urgent"` priority written with
  `update_all` because the changeset refuses both, and one stack whose only
  member is critical.

  Everything sits in `in_progress`: it is a desktop column AND the default
  mobile pill (`TasksLive.mount/3`), and a lone `stack_pending` member rolls
  its stack up to `in_progress`, so the stack lands in the same column.

  Stage 2 adds the control and the URL: `?sort=updated` selects the
  recency order, the default emits no param, and every patch back to the
  board (the sort options, the sponsor toggle, closing a task) goes through
  `BoardData.tasks_path/2` so none of them drops the other's param.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Tasks.{Stack, Stacks, Task}
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn), do: conn |> authenticated_conn_with_user() |> elem(0)

  defp authenticated_conn_with_user(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_prio_sort_#{System.unique_integer([:positive])}@example.com",
        name: "Priority Sort User",
        oidc_sub: "oidc-tasks-prio-sort-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp dt(iso) do
    {:ok, value, 0} = DateTime.from_iso8601(iso)
    value
  end

  defp seed_task(project, name, priority, inserted, updated, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Prio #{name}", status: "backlog", priority: "medium"},
          attrs
        )
      )

    # Priority, status and both timestamps written directly: nil/"urgent"
    # are refused by the changeset, and the timestamps must be exact.
    {1, _} =
      Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(
        set: [
          priority: priority,
          status: Map.get(attrs, :status, "in_progress"),
          inserted_at: dt(inserted),
          updated_at: dt(updated)
        ]
      )

    {name, task.id}
  end

  defp seed do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Prio Sort Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    tasks =
      [
        seed_task(
          project,
          :l1,
          "low",
          "2026-01-10T09:00:00.000000Z",
          "2026-03-08T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :c1,
          "critical",
          "2026-01-20T09:00:00.000000Z",
          "2026-03-07T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :m1,
          "medium",
          "2026-01-31T23:00:00.000000Z",
          "2026-03-06T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :h1,
          "high",
          "2026-02-01T01:00:00.000000Z",
          "2026-03-05T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :l2,
          "low",
          "2026-02-05T09:00:00.000000Z",
          "2026-03-04T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :c2,
          "critical",
          "2026-02-10T09:00:00.000000Z",
          "2026-03-03T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :n1,
          nil,
          "2026-02-12T09:00:00.000000Z",
          "2026-03-02T00:00:00.000000Z"
        ),
        seed_task(
          project,
          :u1,
          "urgent",
          "2026-02-15T09:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )
      ]
      |> Map.new()

    slug = "prio-sort-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Prio Sort Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {_, _member_id} =
      seed_task(
        project,
        :member,
        "critical",
        "2026-01-01T00:00:00.000000Z",
        "2026-01-01T00:00:00.000000Z",
        %{status: "stack_pending", stack_id: stack.id, stack_position: 1}
      )

    {:ok, _} = Stacks.recompute_stack_status(stack)

    # Stack inserted between c1 (Jan 20) and c2 (Feb 10); updated OLDEST of
    # all, so under recency it would render last.
    {1, _} =
      Stack
      |> where([s], s.id == ^stack.id)
      |> Repo.update_all(
        set: [
          inserted_at: dt("2026-01-25T00:00:00.000000Z"),
          updated_at: dt("2026-01-02T00:00:00.000000Z")
        ]
      )

    # Load-bearing premises: the rollup put the stack in the column under
    # test, and the NULL/unknown priorities actually persisted.
    assert Repo.get!(Stack, stack.id).status == "in_progress"
    assert Repo.get!(Task, tasks.n1).priority == nil
    assert Repo.get!(Task, tasks.u1).priority == "urgent"

    tasks |> Map.put(:stack, stack.id) |> Map.put(:project_id, project.id)
  end

  defp expected_priority_order(t),
    do: [t.c2, t.stack, t.c1, t.h1, t.m1, t.l2, t.l1, t.u1, t.n1]

  defp recency_order(t),
    do: [t.l1, t.c1, t.m1, t.h1, t.l2, t.c2, t.n1, t.u1, t.stack]

  @card ~r/id="task-card-([0-9a-f-]{36})"|data-stack-card="true"[^>]*?data-stack-id="([0-9a-f-]{36})"/
  @mobile_card ~r/data-task-id="([0-9a-f-]{36})"|data-stack-card="true"[^>]*?data-stack-id="([0-9a-f-]{36})"/

  defp scan_ids(html, regex) do
    regex
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn
      [task_id] -> task_id
      ["", stack_id] -> stack_id
      [task_id, _] -> task_id
    end)
    |> Enum.uniq()
  end

  defp desktop_order(view) do
    view |> element("#column-in_progress") |> render() |> scan_ids(@card)
  end

  defp filters(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-filters")

  defp mobile_order(view) do
    view |> element("#tasks-mobile-list") |> render() |> scan_ids(@mobile_card)
  end

  # Stage 2: the mobile list for the in_progress pill, selected explicitly
  # (see the stage-1 mobile test for why the mount default is not trusted).
  defp mobile_in_progress_order(view) do
    _ = render_click(filters(view), "filter_by_status", %{"status" => "in_progress"})
    _ = :sys.get_state(view.pid)
    assert view |> element("#tasks-mobile-list h2") |> render() =~ "In Progress · 9"
    mobile_order(view)
  end

  @controls ~w(board-sort-control mobile-board-sort-control)

  # The `data-sort` each of the two controls reports, desktop first.
  defp control_sorts(view) do
    for role <- @controls do
      view
      |> element(~s([data-role="#{role}"]))
      |> render()
      |> then(&Regex.run(~r/data-sort="(\w+)"/, &1))
      |> List.last()
    end
  end

  defp option(role, mode),
    do: ~s([data-role="#{role}"] a[data-role="board-sort-option"][data-sort="#{mode}"])

  defp board_sort(view), do: :sys.get_state(view.pid).socket.assigns.board_sort

  describe "default /tasks order is priority-first" do
    test "desktop kanban column renders critical, high, medium, low, then nil/unknown", %{
      conn: conn
    } do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      # Premise: the two orders differ, so this assertion distinguishes them.
      refute expected_priority_order(t) == recency_order(t)

      assert desktop_order(view) == expected_priority_order(t)
    end

    test "mobile section list renders the same priority order", %{conn: conn} do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      # Select the In Progress pill explicitly rather than trusting the mount
      # default. FiltersComponent hands the value to the shell, so the board
      # lands in the render AFTER the event reply.
      _ = render_click(filters(view), "filter_by_status", %{"status" => "in_progress"})
      _ = :sys.get_state(view.pid)

      # Premise: the list is showing the in_progress section with all nine
      # items, so an order mismatch below is an order fault, not a missing
      # section.
      assert view |> element("#tasks-mobile-list h2") |> render() =~ "In Progress · 9"

      assert mobile_order(view) == expected_priority_order(t)
    end
  end

  describe "the sort control and ?sort= (stage 2)" do
    test "default /tasks: both controls read Sort: Priority and the order is priority-first", %{
      conn: conn
    } do
      t = seed()
      {:ok, view, html} = live(authenticated_conn(conn), ~p"/tasks")

      assert control_sorts(view) == ["priority", "priority"]
      assert html =~ "Sort: Priority"
      assert board_sort(view) == :priority
      assert desktop_order(view) == expected_priority_order(t)
      assert mobile_in_progress_order(view) == expected_priority_order(t)
    end

    test "?sort=updated renders the updated_at-desc order on the desktop column AND the mobile list",
         %{conn: conn} do
      t = seed()
      {:ok, view, html} = live(authenticated_conn(conn), ~p"/tasks?sort=updated")

      # Premise: the two orders differ, so each assertion below tells them
      # apart. They differ at 7 of 9 positions (h1 and u1 happen to sit at
      # the same index in both), and within every priority they are reversed.
      refute recency_order(t) == expected_priority_order(t)

      assert control_sorts(view) == ["updated", "updated"]
      assert html =~ "Sort: Updated"
      assert desktop_order(view) == recency_order(t)
      assert mobile_in_progress_order(view) == recency_order(t)
    end

    test "?sort=bogus decodes to the priority order", %{conn: conn} do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks?sort=bogus")

      assert board_sort(view) == :priority
      assert control_sorts(view) == ["priority", "priority"]
      assert desktop_order(view) == expected_priority_order(t)
    end

    test "each option is a patch link to its own shareable URL, on both controls", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      for role <- @controls do
        assert view |> element(option(role, "updated")) |> render() =~
                 ~s(href="/tasks?sort=updated")

        assert view |> element(option(role, "priority")) |> render() =~ ~s(href="/tasks")
        assert view |> element(option(role, "updated")) |> render() =~ ~s(data-phx-link="patch")
      end

      assert view
             |> has_element?(
               ~s([data-role="board-sort-control"] button[aria-label="Change sort order"][aria-expanded="false"])
             )
    end

    test "round trip: Sort: Updated patches to ?sort=updated, Sort: Priority restores the exact order",
         %{conn: conn} do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      before = desktop_order(view)
      assert before == expected_priority_order(t)

      view |> element(option("board-sort-control", "updated"), "Sort: Updated") |> render_click()
      assert_patched(view, "/tasks?sort=updated")
      assert board_sort(view) == :updated
      assert desktop_order(view) == recency_order(t)
      assert control_sorts(view) == ["updated", "updated"]

      view
      |> element(option("board-sort-control", "priority"), "Sort: Priority")
      |> render_click()

      assert_patched(view, "/tasks")
      assert board_sort(view) == :priority
      assert desktop_order(view) == before
    end

    test "the mobile control patches the same way", %{conn: conn} do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      view |> element(option("mobile-board-sort-control", "updated")) |> render_click()
      assert_patched(view, "/tasks?sort=updated")
      assert mobile_in_progress_order(view) == recency_order(t)
    end

    test "the sponsor toggle preserves ?sort=updated in both directions", %{conn: conn} do
      t = seed()
      {conn, user} = authenticated_conn_with_user(conn)

      # Sponsor everything seeded, so the :mine board still holds the whole
      # set and its ORDER is observable, not just the URL.
      Repo.update_all(where(Task, [x], x.project_id == ^t.project_id),
        set: [sponsor_user_id: user.id]
      )

      Repo.update_all(where(Stack, [x], x.id == ^t.stack), set: [sponsor_user_id: user.id])

      {:ok, view, _html} = live(conn, ~p"/tasks?sort=updated")

      _ = render_click(filters(view), "filter_toggle_sponsor", %{})
      assert_patched(view, "/tasks?sponsor=mine&sort=updated")
      assert :sys.get_state(view.pid).socket.assigns.sponsor_filter == :mine
      assert board_sort(view) == :updated
      assert desktop_order(view) == recency_order(t)

      _ = render_click(filters(view), "filter_toggle_sponsor", %{})
      assert_patched(view, "/tasks?sort=updated")
      assert :sys.get_state(view.pid).socket.assigns.sponsor_filter == :all
      assert board_sort(view) == :updated
      assert desktop_order(view) == recency_order(t)
    end

    test "opening then closing a task keeps ?sort=updated", %{conn: conn} do
      t = seed()
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks?sort=updated")

      _ = render_click(view, "select_task", %{"id" => t.c1})
      assert_patched(view, "/tasks/#{t.c1}")

      # `detail_close` reports `{:detail_closed}` to the shell with `send/2`,
      # so the patch lands AFTER this event's reply: wait for it
      # (`assert_patch/2`) rather than asserting it already happened.
      _ = render_click(with_target(view, "#tasks-detail"), "detail_close", %{})
      assert_patch(view, "/tasks?sort=updated")
      assert board_sort(view) == :updated
      assert desktop_order(view) == recency_order(t)
    end
  end
end
