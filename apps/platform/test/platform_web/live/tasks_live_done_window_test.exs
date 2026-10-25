defmodule PlatformWeb.TasksLiveDoneWindowTest do
  @moduledoc """
  The Done column renders collapsed and windowed (task 01a13884 stage 3).

  Done (with cancelled folded in) was 1,150 of the 1,363 cards in the perf
  seed and nearly all of the 33,892 DOM nodes on /tasks. The column now
  renders no cards until it is opened, then the 20 most recently updated,
  plus 50 per "Show 50 more". The count in the header is always the full
  total, and an active search opens Done, so a found task is never behind
  the collapse.

  Each refutation below is paired with a positive control on the same
  selector, so an absence is attributable to the window and not to a
  selector that never matched anything.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Task

  @done 60

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks_done_window_#{n}@example.com",
        name: "Done Window User",
        oidc_sub: "oidc-tasks-done-window-#{n}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Done Window Project #{n}",
        repo_url: "git@github.com:test/repo.git"
      })

    # Done task i was last updated i minutes ago, so index order IS
    # newest-first order. Titles are zero-padded so "Done 01" never
    # substring-matches "Done 010".
    base = DateTime.utc_now()

    done =
      for i <- 1..@done do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Finished item #{String.pad_leading(Integer.to_string(i), 3, "0")}",
            status: "done",
            # Priority deliberately runs AGAINST recency, so a Done list in
            # the board's default priority order would fail the order check.
            priority: if(i > 40, do: "critical", else: "low")
          })

        stamp = DateTime.add(base, -i * 60, :second)
        Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [updated_at: stamp])
        task
      end

    {:ok, live_task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Still moving",
        status: "in_progress",
        priority: "medium"
      })

    %{conn: init_test_session(conn, current_user_id: user.id), done: done, live_task: live_task}
  end

  defp board(view), do: with_target(view, "#tasks-board")
  defp filters(view), do: with_target(view, "#tasks-filters")

  defp settle(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  # Done task ids rendered as desktop cards, in DOM order.
  defp done_card_ids(html, done) do
    done_ids = MapSet.new(done, & &1.id)

    ~r/id="task-card-([0-9a-f-]{36})"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&MapSet.member?(done_ids, &1))
  end

  defp done_count(view) do
    view |> element(~s([data-role="column-count-done"])) |> render() |> strip()
  end

  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  test "Done is collapsed by default: no done card renders, the header has the full count",
       %{conn: conn, done: done, live_task: live_task} do
    {:ok, view, html} = live(conn, ~p"/tasks")

    # Positive control: the card selector matches a card that is rendered.
    assert html =~ ~s(id="task-card-#{live_task.id}")
    assert done_card_ids(html, done) == []

    assert done_count(view) == "#{@done}"
    assert has_element?(view, ~s([data-role="done-collapsed"] [data-role="done-show"]))
    # The column stays the drop target while collapsed.
    assert has_element?(view, ~s(#column-done[data-column="done"]))
    refute has_element?(view, ~s([data-role="done-more"]))
  end

  test "opening Done renders the 20 newest, newest first; Show more renders the rest",
       %{conn: conn, done: done} do
    {:ok, view, _html} = live(conn, ~p"/tasks")

    html = render_click(board(view), "board_toggle_done", %{"expanded" => "true"})
    assert done_card_ids(html, done) == done |> Enum.take(20) |> Enum.map(& &1.id)
    assert_push_event(view, "done_column_changed", %{expanded: true})

    refute has_element?(view, ~s([data-role="done-collapsed"]))
    assert has_element?(view, ~s([data-role="done-hide"]))

    assert view |> element(~s([data-role="done-more"])) |> render() |> strip() =~
             "Show 40 more (40 older)"

    html = render_click(board(view), "board_done_more", %{})
    assert done_card_ids(html, done) == Enum.map(done, & &1.id)
    refute has_element?(view, ~s([data-role="done-more"]))
    assert done_count(view) == "#{@done}"

    # Hide collapses again and resets the window to its first page.
    html = render_click(board(view), "board_toggle_done", %{"expanded" => "false"})
    assert done_card_ids(html, done) == []
    assert_push_event(view, "done_column_changed", %{expanded: false})

    html = render_click(board(view), "board_toggle_done", %{})
    assert length(done_card_ids(html, done)) == 20
  end

  test "a search matching an old done task renders it while Done is set collapsed",
       %{conn: conn, done: done} do
    {:ok, view, _html} = live(conn, ~p"/tasks")
    oldest = List.last(done)

    _ = render_click(board(view), "board_toggle_done", %{"expanded" => "false"})
    assert done_card_ids(render(view), done) == []

    _ = render_change(filters(view), "filter_search", %{"q" => oldest.title})
    html = settle(view)

    # The oldest done task, outside any first page, is the one match.
    assert done_card_ids(html, done) == [oldest.id]
    refute has_element?(view, ~s([data-role="done-collapsed"]))
    assert done_count(view) == "1"

    # Clearing the search returns to the stored (collapsed) state.
    _ = render_change(filters(view), "filter_search", %{"q" => ""})
    assert done_card_ids(settle(view), done) == []
  end

  test "a live move into collapsed Done changes the count and renders no card",
       %{conn: conn, done: done, live_task: live_task} do
    {:ok, view, html} = live(conn, ~p"/tasks")
    assert html =~ ~s(id="task-card-#{live_task.id}")

    {:ok, _} = Tasks.update_task(live_task, %{status: "done"})
    html = settle(view)

    assert done_count(view) == "#{@done + 1}"
    refute html =~ ~s(id="task-card-#{live_task.id}")
    assert done_card_ids(html, done) == []
  end

  test "the mobile Done section renders the same 20 / +50 window, newest first",
       %{conn: conn, done: done} do
    # `?status=done` keeps the in-progress task out of the phone list, so the
    # ids scanned below are the Done section's alone.
    {:ok, view, _html} = live(conn, ~p"/tasks?status=done")
    settle(view)

    mobile_ids = fn ->
      view
      |> element("#tasks-mobile-list")
      |> render()
      |> then(&Regex.scan(~r/phx-value-id="([0-9a-f-]{36})"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()
    end

    assert mobile_ids.() == done |> Enum.take(20) |> Enum.map(& &1.id)

    assert view |> element(~s([data-role="done-more-mobile"])) |> render() |> strip() =~
             "Show 40 more (40 older)"

    _ = render_click(board(view), "board_done_more", %{})
    assert mobile_ids.() == Enum.map(done, & &1.id)
  end
end
