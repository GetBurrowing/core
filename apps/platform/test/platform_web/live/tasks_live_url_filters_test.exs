defmodule PlatformWeb.TasksLiveUrlFiltersTest do
  @moduledoc """
  Task 01a161fd stage 1, the LiveView half: the new `?project=`, `?epic=`,
  `?status=`, multi-value `?kind=` and `?mine=1` params survive every OLD
  filter control's patch (`BoardData.tasks_path/1` is the one builder), the
  URL's project shows on the first connected render, and a single
  `?kind=bug` narrows the board as a one-element `:kind_filters` (task
  01a15746 stage 2 removed the single-kind DB opt).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  @new_params ~w(project status kind mine)

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "url_filters_#{n}@example.com",
      name: "Url Filters #{n}",
      oidc_sub: "oidc-url-filters-#{n}"
    })
    # The breadcrumb reads `@projects` (`list_projects_for_user/2`), which
    # lists a project only to a member of its org.
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp project!(name) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} #{u()}"})
    project
  end

  defp task!(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Url task #{u()}", priority: "medium"},
          attrs
        )
      )

    task
  end

  defp filters(view), do: with_target(view, "#tasks-filters")

  defp params_of(path) do
    %URI{path: "/tasks", query: query} = URI.parse(path)
    URI.decode_query(query || "")
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup %{conn: conn} do
    me = user!()
    p = project!("Url Proj")
    q = project!("Other Proj")

    rows = %{
      mine_bug: task!(p, %{status: "in_progress", kind: "bug", sponsor_user_id: me.id}),
      mine_feature_old: task!(p, %{status: "blocked", kind: "feature", sponsor_user_id: me.id}),
      theirs_bug: task!(p, %{status: "in_progress", kind: "bug"}),
      mine_done: task!(p, %{status: "done", kind: "bug", sponsor_user_id: me.id}),
      mine_chore: task!(p, %{status: "in_progress", kind: "chore", sponsor_user_id: me.id}),
      other_project: task!(q, %{status: "in_progress", kind: "bug", sponsor_user_id: me.id})
    }

    %{conn: init_test_session(conn, current_user_id: me.id), me: me, p: p, q: q, rows: rows}
  end

  defp board_url(p),
    do: "/tasks?project=#{p.id}&status=in_progress,blocked&kind=bug,feature&mine=1&sort=oldest"

  defp assert_new_params_kept(path, p) do
    params = params_of(path)
    assert params["project"] == p.id, "project dropped from #{path}"
    assert params["status"] == "in_progress,blocked", "status dropped from #{path}"
    assert params["mine"] == "1", "mine dropped from #{path}"
    params
  end

  test "the first connected render shows the URL's project and the narrowed list",
       %{conn: conn, p: p, rows: rows} do
    {:ok, view, html} = live(conn, board_url(p))

    # The html returned by live/2 is the join render, BEFORE the shell's
    # `{:sidebar_project_selected, _}` message is handled.
    breadcrumb =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-role=tasks-breadcrumb]")

    assert LazyHTML.text(breadcrumb) =~ p.name

    a = assigns(view)
    assert a.selected_project_id == p.id
    assert a.status_filters == ["in_progress", "blocked"]
    assert a.kind_filters == ["feature", "bug"]
    assert a.mine_filter == true
    assert a.board_sort == :oldest

    # mine, in P, in_progress|blocked, bug|feature, oldest first.
    assert Enum.map(a.filtered_tasks, & &1.id) == [rows.mine_bug.id, rows.mine_feature_old.id]
    assert a.filtered_count == 2
  end

  test "the old sponsor toggle's patch keeps project, status, the kind list and mine",
       %{conn: conn, p: p} do
    {:ok, view, _html} = live(conn, board_url(p))

    _ = render_click(filters(view), "filter_toggle_sponsor", %{})
    params = view |> assert_patch() |> assert_new_params_kept(p)
    assert params["kind"] == "feature,bug"
    assert params["sponsor"] == "mine"
    assert params["sort"] == "oldest"
  end

  test "the old scope chip's patch keeps them", %{conn: conn, p: p} do
    {:ok, view, _html} = live(conn, board_url(p))

    _ = render_click(filters(view), "filter_scope", %{})
    params = view |> assert_patch() |> assert_new_params_kept(p)
    assert params["kind"] == "feature,bug"
  end

  test "the filter popover's kind toggle edits the kind list and keeps the rest",
       %{conn: conn, p: p} do
    {:ok, view, _html} = live(conn, board_url(p))
    refute has_element?(view, "#tasks-kind-filter")

    render_click(view, "tasks_filter_open", %{"sheet" => "filter"})

    view
    |> element(~s(#tasks-filter-popover [data-role="tasks-filter-option"][data-kind="feature"]))
    |> render_click()

    params = view |> assert_patch() |> assert_new_params_kept(p)
    assert params["kind"] == "bug"
    assert assigns(view).kind_filters == ["bug"]
  end

  test "the old sort control and origin lanes link with every new param", %{conn: conn, p: p} do
    {:ok, view, _html} = live(conn, board_url(p))

    links =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=board-sort-option], [data-role=origin-lane-tab]")
      |> LazyHTML.attribute("href")

    assert length(links) >= 2 + 4, "positive control: the controls rendered"

    for href <- links do
      params = params_of(href)
      for key <- @new_params, do: assert(Map.has_key?(params, key), "#{key} missing in #{href}")
    end

    assert has_element?(view, ~s([data-role=board-sort-option][data-sort=newest]))
  end

  test "a single ?kind=bug narrows the board and list through :kind_filters",
       %{conn: conn, rows: rows} do
    {:ok, view, _html} = live(conn, "/tasks?kind=bug")

    a = assigns(view)
    assert a.kind_filters == ["bug"]
    # The DB query takes no kind opt any more: the chore is loaded, then
    # narrowed out in memory.
    assert rows.mine_chore.id in MapSet.new(a.all_tasks, & &1.id)

    board = a.columns |> Enum.flat_map(fn {_col, tasks} -> tasks end) |> MapSet.new(& &1.id)
    assert rows.mine_bug.id in board, "positive control"
    refute rows.mine_chore.id in board

    listed = MapSet.new(a.filtered_tasks, & &1.id)
    assert rows.mine_bug.id in listed, "positive control"
    refute rows.mine_chore.id in listed
  end

  test "an epic is honoured only inside the selected project", %{conn: conn, p: p, q: q} do
    {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Url Epic #{u()}"})

    {:ok, view, _html} = live(conn, "/tasks?project=#{p.id}&epic=#{epic.id}")
    _ = render(view)
    assert assigns(view).selected_epic_id == epic.id, "positive control"

    {:ok, view, _html} = live(conn, "/tasks?project=#{q.id}&epic=#{epic.id}")
    _ = render(view)
    assert assigns(view).selected_project_id == q.id
    assert assigns(view).selected_epic_id == nil
  end

  test "a non-UUID project is the All projects view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tasks?project=burrow")
    _ = render(view)
    assert assigns(view).selected_project_id == nil
  end
end
