defmodule PlatformWeb.TasksFilterDesktopTest do
  @moduledoc """
  The desktop Tasks picker and filters (task 01a161fd stage 4):
  `PlatformWeb.Tasks.FilterDesktop` in the board's `page_header`, and the
  desktop kanban narrowed by the status set, Mine and a multi-kind set
  (`BoardData.narrow_board/3` via `BoardHooks`).

  Every absence is preceded by a positive control on the same render showing
  the same query can find something.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.BoardData

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "filter-desktop-#{n}@example.com",
      name: "Filter Desktop #{n}",
      oidc_sub: "filter-desktop-#{n}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp task!(project, title, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp mount(conn, user, path) do
    {:ok, view, _html} = live(init_test_session(conn, current_user_id: user.id), path)
    view
  end

  defp doc(view, sel), do: view |> element(sel) |> render() |> LazyHTML.from_fragment()
  defp header_doc(view), do: doc(view, "#tasks-page-header")
  defp q(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp classes(node), do: String.split(attr(node, "class") || "", ~r/\s+/, trim: true)

  # The task ids on the desktop kanban, column by column.
  defp board_ids(view) do
    d = doc(view, "#kanban-board")

    d
    |> q("[data-task-id]")
    |> Enum.map(&attr(&1, "data-task-id"))
    |> Enum.uniq()
    |> MapSet.new()
  end

  defp open(view, sheet), do: render_click(view, "tasks_filter_open", %{"sheet" => sheet})

  setup do
    me = user!()
    {:ok, p} = Tasks.create_project(%{name: "Filter Desktop Project #{u()}"})
    {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Filter Desktop Epic #{u()}"})

    a =
      task!(p, "Alpha widget",
        status: "in_progress",
        kind: "bug",
        priority: "high",
        sponsor_user_id: me.id,
        epic_id: epic.id
      )

    b = task!(p, "Beta", status: "blocked", kind: "feature", priority: "low")
    c = task!(p, "Gamma", status: "in_review", kind: "chore", priority: "medium")
    d = task!(p, "Delta", status: "in_progress", kind: "research", priority: "low")

    %{me: me, p: p, epic: epic, a: a, b: b, c: c, d: d}
  end

  test "the desktop triggers render hidden lg:inline-flex in the page header", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    h = header_doc(view)

    assert [title] = q(h, "#tasks-title-picker-desktop")
    assert [filter] = q(h, "#tasks-filter-button-desktop")

    for node <- [title, filter] do
      assert "hidden" in classes(node)
      assert "lg:inline-flex" in classes(node)
      assert attr(node, "aria-expanded") == "false"
    end

    assert LazyHTML.text(title) =~ ctx.p.name
    assert attr(title, "aria-label") == "Project: #{ctx.p.name}. Change project"
    assert attr(filter, "aria-label") == "Filter"

    # Additive: the old desktop controls are all still in the header.
    for sel <- ["#task-search", "#tasks-filters", ~s([data-role="header-new-task"])] do
      assert q(h, sel) != [], "old control #{sel} is gone"
    end

    # The badge counts filters, not the project or sort.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&sort=updated&status=blocked")
    [filter] = q(header_doc(view), "#tasks-filter-button-desktop")
    assert attr(filter, "aria-label") == "Filter, 1 on"

    assert q(header_doc(view), ~s(#tasks-filter-button-desktop [data-role="tasks-filter-badge"])) !=
             []
  end

  test "the title menu opens at both levels and closes on click-away and Escape", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    assert q(header_doc(view), "#tasks-title-menu") == []

    open(view, "project")
    h = header_doc(view)
    assert [menu] = q(h, "#tasks-title-menu")
    assert attr(menu, "role") == "dialog"
    assert attr(menu, "aria-label") == "Choose project"
    assert "border-edge" in classes(menu) and "bg-base-100" in classes(menu)
    assert attr(menu, "style") =~ "--shadow-dropdown"
    # No grab handle and no sheet: a styled div.
    assert q(menu, ".sheet-handle, .sheet") == []
    assert q(menu, ~s([data-role="tasks-project-root"])) != []
    assert [title] = q(h, "#tasks-title-picker-desktop")
    assert attr(title, "aria-expanded") == "true"

    # The scrim: transparent, click-away and Escape both close and return focus.
    assert [scrim] = q(h, ~s(#tasks-title-picker-desktop ~ [data-role="tasks-filter-scrim"]))
    refute Enum.any?(classes(scrim), &String.starts_with?(&1, "bg-"))
    assert attr(scrim, "phx-key") == "escape"
    assert attr(scrim, "phx-window-keydown") =~ "tasks_filter_close"
    assert attr(scrim, "phx-window-keydown") =~ "#tasks-title-picker-desktop"
    assert attr(scrim, "phx-click") =~ "focus"

    # Epic level.
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    assert [menu] = q(header_doc(view), "#tasks-title-menu")
    assert q(menu, ~s([data-role="tasks-project-epic-level"])) != []
    assert q(menu, ~s([data-epic="#{ctx.epic.id}"])) != []

    # Click-away.
    view
    |> element(~s(#tasks-title-picker-desktop ~ [data-role="tasks-filter-scrim"]))
    |> render_click()

    assert q(header_doc(view), "#tasks-title-menu") == []

    # Escape (the window keydown on the scrim).
    open(view, "project")
    assert q(header_doc(view), "#tasks-title-menu") != []

    view
    |> element(~s(#tasks-title-picker-desktop ~ [data-role="tasks-filter-scrim"]))
    |> render_keydown(%{"key" => "Escape"})

    assert q(header_doc(view), "#tasks-title-menu") == []

    # A pick closes it (the option is a patch link).
    open(view, "project")

    view
    |> element(~s(#tasks-title-menu [data-project="all"]))
    |> render_click()

    assert_patch(view, "/tasks?project=all")
    assert q(header_doc(view), "#tasks-title-menu") == []
  end

  test "the filter popover opens, applies live, and closes on click-away and Escape", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    assert q(header_doc(view), "#tasks-filter-popover") == []

    open(view, "filter")
    h = header_doc(view)
    assert [pop] = q(h, "#tasks-filter-popover")
    assert attr(pop, "aria-label") == "Filter and sort tasks"
    assert "right-0" in classes(pop) and "w-[400px]" in classes(pop)
    assert q(pop, ".sheet-handle, .sheet") == []

    for section <- ~w(sort status kind scope sponsor) do
      assert q(pop, ~s([data-role="tasks-filter-#{section}"])) != []
    end

    assert [show] = q(pop, ~s([data-role="tasks-filter-show"]))
    assert LazyHTML.text(show) =~ "Show 4 tasks"
    assert attr(show, "phx-click") =~ "#tasks-filter-button-desktop"

    # Live apply: the popover stays open across a patch.
    view |> element(~s(#tasks-filter-popover [data-status="blocked"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}&status=blocked")
    assert [pop] = q(header_doc(view), "#tasks-filter-popover")
    assert [show] = q(pop, ~s([data-role="tasks-filter-show"]))
    assert LazyHTML.text(show) =~ "Show 1 task"

    # Escape.
    view
    |> element(~s(#tasks-filter-button-desktop ~ [data-role="tasks-filter-scrim"]))
    |> render_keydown(%{"key" => "Escape"})

    assert q(header_doc(view), "#tasks-filter-popover") == []

    # Click-away.
    open(view, "filter")

    view
    |> element(~s(#tasks-filter-button-desktop ~ [data-role="tasks-filter-scrim"]))
    |> render_click()

    assert q(header_doc(view), "#tasks-filter-popover") == []

    # 'No tasks match' at zero.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&status=done")
    open(view, "filter")
    [show] = q(header_doc(view), ~s(#tasks-filter-popover [data-role="tasks-filter-show"]))
    assert LazyHTML.text(show) =~ "No tasks match"
    assert attr(show, "disabled") != nil
  end

  test "options in both popovers are patch links with no phx-click", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")

    links =
      for {sheet, sel} <- [{"project", "#tasks-title-menu"}, {"filter", "#tasks-filter-popover"}] do
        open(view, sheet)
        q(doc(view, sel), "[data-phx-link]")
      end
      |> List.flatten()

    # Positive control: there are many option links to check.
    assert length(links) > 20
    assert Enum.all?(links, &(attr(&1, "data-phx-link") == "patch"))
    assert Enum.filter(links, &(attr(&1, "phx-click") != nil)) == []
  end

  test "status, mine and kind lists narrow the kanban columns", ctx do
    all = MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id, ctx.d.id])
    base = "/tasks?project=#{ctx.p.id}"

    assert board_ids(mount(ctx.conn, ctx.me, base)) == all

    assert board_ids(mount(ctx.conn, ctx.me, base <> "&status=in_progress,blocked")) ==
             MapSet.new([ctx.a.id, ctx.b.id, ctx.d.id])

    assert board_ids(mount(ctx.conn, ctx.me, base <> "&mine=1")) == MapSet.new([ctx.a.id])

    assert board_ids(mount(ctx.conn, ctx.me, base <> "&kind=feature,chore")) ==
             MapSet.new([ctx.b.id, ctx.c.id])

    view = mount(ctx.conn, ctx.me, base <> "&status=in_progress&kind=bug,research")
    assert board_ids(view) == MapSet.new([ctx.a.id, ctx.d.id])

    # The in-progress column holds exactly those two; blocked is empty.
    d = doc(view, "#kanban-board")

    in_progress =
      d
      |> q(~s([data-column="in_progress"] [data-task-id]))
      |> Enum.map(&attr(&1, "data-task-id"))

    assert MapSet.new(in_progress) == MapSet.new([ctx.a.id, ctx.d.id])
    assert q(d, ~s([data-column="blocked"] [data-task-id])) == []

    # Live: a patch narrows and widens without a remount.
    view = mount(ctx.conn, ctx.me, base)
    render_patch(view, base <> "&status=blocked")
    assert board_ids(view) == MapSet.new([ctx.b.id])
    render_patch(view, base)
    assert board_ids(view) == all
  end

  test "a no-filter render equals the control render, byte for byte", ctx do
    base = "/tasks?project=#{ctx.p.id}"
    control = mount(ctx.conn, ctx.me, base)
    control_html = control |> element("#kanban-board") |> render()

    # A second view narrows, then clears every narrowing filter.
    view = mount(ctx.conn, ctx.me, base <> "&status=blocked&mine=1&kind=bug,feature")
    refute view |> element("#kanban-board") |> render() == control_html
    render_patch(view, base)

    assert view |> element("#kanban-board") |> render() == control_html
    assert BoardData.board_narrowing?(%{}) == false
  end
end
