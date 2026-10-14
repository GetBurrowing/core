defmodule PlatformWeb.TasksLiveBoardPayloadTest do
  @moduledoc """
  Selecting and closing a task must not re-read or re-send the board
  (task 01a13884 stage 2).

  Stage 1 measured, on the 1,363-task dev seed, that closing the detail
  panel ran `BoardHooks.refresh_board/1` (every task re-queried, 91-304 ms
  of DB time in `handle_info`) and re-sent the mobile list, which an `:if`
  had unmounted on open. The board is kept fresh by PubSub instead, so the
  live-update paths are asserted here too: a rename of another task while
  one is open, and a move between columns.

  The "board-wide read" counter is a `:telemetry` handler on the repo query
  event, scoped to the LiveView's own process and to `tasks`-table SELECTs
  that return at least the seeded row count. `list_all_tasks/1` and
  `list_by_status/1` are the only reads that return every task; the detail
  panel's `get_task_detail/1` returns one row. The counter is shown to fire
  on a `{:task_updated, _}` before its zero is trusted.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  @seeded 24

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_payload_#{System.unique_integer([:positive])}@example.com",
        name: "Board Payload User",
        oidc_sub: "oidc-tasks-payload-#{System.unique_integer([:positive])}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp seed_board do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Payload Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    for i <- 1..@seeded do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Payload task #{i}",
          status: if(rem(i, 2) == 0, do: "in_progress", else: "backlog"),
          priority: "medium"
        })

      task
    end
  end

  # Forwards `{:board_read, num_rows}` for every board-wide `tasks` SELECT
  # issued by `lv_pid`. The discriminator runs in the emitting process, so
  # `self()` is the process that ran the query.
  defp count_board_reads(lv_pid) do
    Platform.TelemetryHelpers.attach_scoped(
      [:platform, :repo, :query],
      fn meta ->
        self() == lv_pid and meta[:source] == "tasks" and board_wide?(meta[:result])
      end,
      self(),
      tag: :board_read
    )
  end

  defp board_wide?({:ok, %{num_rows: n}}) when is_integer(n), do: n >= @seeded
  defp board_wide?(_), do: false

  defp drain_board_reads(acc \\ 0) do
    receive do
      {:board_read, _event, _measurements, _meta} -> drain_board_reads(acc + 1)
    after
      0 -> acc
    end
  end

  defp detail(view), do: with_target(view, "#tasks-detail")

  test "select and close issue no board-wide task read; the counter fires on a refresh",
       %{conn: conn} do
    [first | _] = tasks = seed_board()
    other = Enum.at(tasks, 5)

    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")
    count_board_reads(view.pid)

    # POSITIVE CONTROL. A PubSub refresh re-reads the board, so a counter
    # that cannot see that read would make the zeros below vacuous.
    send(view.pid, {:task_updated, other})
    _ = render(view)
    assert_receive {:board_read, _event, _measurements, _meta}, 1_000
    _ = drain_board_reads()

    render_click(view, "select_task", %{"id" => first.id})
    assert_patch(view, ~p"/tasks/#{first.id}")
    assert render(element(view, "#tasks-detail")) =~ first.title
    refute_receive {:board_read, _event, _measurements, _meta}, 200

    render_click(detail(view), "detail_close")
    assert_patch(view, ~p"/tasks")
    html = render(view)
    assert html =~ ~s(id="task-card-#{first.id}")
    refute_receive {:board_read, _event, _measurements, _meta}, 200
  end

  test "the mobile list stays mounted while a task is open; the panel hides it client-side",
       %{conn: conn} do
    [first | _] = seed_board()
    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks/#{first.id}")

    assert has_element?(view, "#tasks-mobile-list")
    panel = render(element(view, ~s([data-role="task-detail-panel"])))
    assert panel =~ "phx-mounted"
    assert panel =~ "max-lg:hidden"
    assert panel =~ "phx-remove"

    render_click(detail(view), "detail_close")
    assert has_element?(view, "#tasks-mobile-list")
    refute has_element?(view, ~s([data-role="task-detail-panel"]))
  end

  test "renaming another task while one is open updates its card and keeps the panel",
       %{conn: conn} do
    tasks = seed_board()
    open = Enum.at(tasks, 1)
    other = Enum.at(tasks, 3)

    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks/#{open.id}")
    assert render(element(view, "#tasks-detail")) =~ open.title

    {:ok, _} = Tasks.update_task(other, %{title: "Renamed by broadcast"})

    assert render(element(view, "#card-title-#{other.id}")) =~ "Renamed by broadcast"
    detail_html = render(element(view, "#tasks-detail"))
    assert detail_html =~ open.title
    refute detail_html =~ "Renamed by broadcast"
  end

  test "a task moved in_progress -> in_review leaves its column and lands in the new one",
       %{conn: conn} do
    tasks = seed_board()
    moving = Enum.find(tasks, &(&1.status == "in_progress"))

    {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")
    assert has_element?(view, "#column-in_progress #task-card-#{moving.id}")
    refute has_element?(view, "#column-in_review #task-card-#{moving.id}")

    {:ok, _} = Tasks.update_task(moving, %{status: "in_review"})
    _ = render(view)

    assert has_element?(view, "#column-in_review #task-card-#{moving.id}")
    refute has_element?(view, "#column-in_progress #task-card-#{moving.id}")
  end
end
