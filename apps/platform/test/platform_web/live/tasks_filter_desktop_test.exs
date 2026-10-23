defmodule PlatformWeb.TasksFilterDesktopTest do
  @moduledoc """
  The desktop Tasks picker and filters (task 01a161fd stage 4):
  `PlatformWeb.Tasks.FilterDesktop` in the board's `page_header`, and the
  desktop kanban narrowed by the status set, Mine and a multi-kind set
  (`BoardData.narrow_board/3` via `BoardHooks`). Task 01a168c2 stage 2: the
  filter popover's Project row and the project picker it hosts.

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

  defp pop_doc(view), do: doc(view, "#tasks-filter-popover")
  defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp click_row(view),
    do:
      view
      |> element("#tasks-filter-popover [data-role=tasks-filter-project-row]")
      |> render_click()

  @scrim ~s(#tasks-filter-button-desktop ~ [data-role="tasks-filter-scrim"])

  # A viewer in ONE tenant org (a root-org member reads every project), a
  # readable home project and a foreign project in another tenant.
  defp tenant_viewer! do
    home_org = Platform.TenancyFixtures.tenant_org_id("filter_pop_home_#{u()}")
    foreign_org = Platform.TenancyFixtures.tenant_org_id("filter_pop_foreign_#{u()}")
    n = u()

    viewer =
      Repo.insert!(%User{
        email: "filter-pop-tenant-#{n}@example.com",
        name: "Filter Pop tenant #{n}",
        oidc_sub: "filter-pop-tenant-#{n}"
      })

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: home_org,
      role: "member"
    })
    |> Repo.insert!()

    {:ok, home} = Tasks.create_project(%{name: "Filter Pop Home #{u()}", org_id: home_org})

    {:ok, foreign} =
      Tasks.create_project(%{name: "Secret Foreign Project #{u()}", org_id: foreign_org})

    {:ok, foreign_epic} =
      Tasks.create_epic(%{project_id: foreign.id, name: "Secret Foreign Epic #{u()}"})

    task!(home, "Home task", status: "in_progress")
    %{viewer: viewer, home: home, foreign: foreign, foreign_epic: foreign_epic}
  end

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

    # The picker hosted in the filter popover (task 01a168c2), both levels.
    open(view, "filter_project")
    root = q(pop_doc(view), "[data-phx-link]")
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    epics = q(pop_doc(view), "[data-phx-link]")
    # Positive control: All projects + the project; All of + the epic.
    assert length(root) >= 2 and length(epics) >= 2
    links = links ++ root ++ epics

    # Positive control: there are many option links to check.
    assert length(links) > 20
    assert Enum.all?(links, &(attr(&1, "data-phx-link") == "patch"))
    assert Enum.filter(links, &(attr(&1, "phx-click") != nil)) == []
  end

  # ── The Project row (task 01a168c2 stage 2) ──────────────────────────

  test "the popover's first section is the Project row, with the masked label", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}")
    open(view, "filter")
    pop = pop_doc(view)

    sections =
      pop
      |> q("[data-role=tasks-filter-sheet-body] > section")
      |> Enum.map(&attr(&1, "data-role"))

    assert ["tasks-filter-project", "tasks-filter-sort" | _] = sections
    [row] = q(pop, "[data-role=tasks-filter-project-row]")
    assert attr(row, "phx-value-sheet") == "filter_project"

    assert pop |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() ==
             "#{ctx.p.name} › #{ctx.epic.name}"

    render_click(view, "toggle_mask_names", %{"masked" => "true"})
    open(view, "filter")
    pop = pop_doc(view)
    [value] = q(pop, "[data-role=tasks-filter-project-value]")
    assert text(value) != "", "positive control: the masked row renders a label"
    refute text(value) =~ ctx.p.name
    refute text(value) =~ ctx.epic.name
  end

  test "the row hosts the picker in the popover and a pick returns to the filter body", ctx do
    {:ok, other} = Tasks.create_project(%{name: "Filter Pop Other #{u()}"})
    o = task!(other, "Other project task", status: "in_progress")

    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    # Positive control: before the pick the kanban carries another project's card.
    assert MapSet.member?(board_ids(view), o.id)

    open(view, "filter")
    click_row(view)

    h = header_doc(view)
    assert [pop] = q(h, "#tasks-filter-popover")
    assert q(pop, "[data-role=tasks-project-root]") != []
    assert q(pop, "[data-role=tasks-project-back-filter]") != []
    assert q(pop, "[data-role=tasks-filter-sheet-body]") == []
    assert q(pop, "[data-role=tasks-filter-show]") == []
    assert q(h, "#tasks-title-menu") == []
    assert h |> q("#tasks-title-picker-desktop") |> hd() |> attr("aria-expanded") == "false"
    assert h |> q("#tasks-filter-button-desktop") |> hd() |> attr("aria-expanded") == "true"

    view |> element(~s(#tasks-filter-popover [data-project="#{ctx.p.id}"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}")

    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-filter-sheet-body]") != []
    assert q(pop, "[data-role=tasks-filter-show]") != []
    assert pop |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == ctx.p.name
    assert board_ids(view) == MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id, ctx.d.id])
  end

  test "Back, the epic level, the scrim and Escape inside the hosted picker", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    open(view, "filter")
    click_row(view)

    view
    |> element("#tasks-filter-popover [data-role=tasks-project-back-filter]")
    |> render_click()

    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-filter-sheet-body]") != []
    assert q(pop, "[data-role=tasks-project-root]") == []

    click_row(view)

    view
    |> element(
      ~s(#tasks-filter-popover [data-role=tasks-project-epics][phx-value-id="#{ctx.p.id}"])
    )
    |> render_click()

    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-project-epic-level]") != []
    assert q(pop, ~s([data-epic="#{ctx.epic.id}"])) != []
    assert q(header_doc(view), "#tasks-title-menu") == []

    view |> element("#tasks-filter-popover [data-role=tasks-project-back]") |> render_click()
    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-project-root]") != []
    assert q(pop, "[data-role=tasks-project-back-filter]") != []

    # The scrim still returns focus to the Filter button.
    [scrim] = q(header_doc(view), @scrim)
    assert attr(scrim, "phx-click") =~ "#tasks-filter-button-desktop"
    assert attr(scrim, "phx-window-keydown") =~ "tasks_filter_close"

    # Escape closes from the hosted picker.
    view |> element(@scrim) |> render_keydown(%{"key" => "Escape"})
    assert q(header_doc(view), "#tasks-filter-popover") == []

    # Click-away closes from the hosted epic level.
    open(view, "filter_project")
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    assert q(pop_doc(view), "[data-role=tasks-project-epic-level]") != []
    view |> element(@scrim) |> render_click()
    assert q(header_doc(view), "#tasks-filter-popover") == []
  end

  test "a forged epics id from another tenant leaves the hosted picker at its root" do
    t = tenant_viewer!()
    view = mount(build_conn(), t.viewer, "/tasks?project=all")
    open(view, "filter")
    click_row(view)

    render_click(view, "tasks_filter_epics", %{"id" => t.foreign.id})
    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-project-root]") != []
    assert q(pop, "[data-role=tasks-project-epic-level]") == []
    refute LazyHTML.to_html(pop) =~ t.foreign.name
    refute LazyHTML.to_html(pop) =~ t.foreign_epic.name

    # Positive control: the readable home project DOES open its epic level.
    render_click(view, "tasks_filter_epics", %{"id" => t.home.id})
    pop = pop_doc(view)
    assert q(pop, "[data-role=tasks-project-epic-level]") != []
    assert LazyHTML.to_html(pop) =~ t.home.name
  end

  test "masking leaves no real project or epic name in the popover's row or picker", ctx do
    path = "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}"

    states = fn view ->
      [
        open(view, "filter") && pop_doc(view),
        click_row(view) && pop_doc(view),
        render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id}) && pop_doc(view)
      ]
      |> Enum.map(&LazyHTML.to_html/1)
      |> Enum.join()
    end

    unmasked = states.(mount(ctx.conn, ctx.me, path))
    assert unmasked =~ ctx.p.name, "positive control"
    assert unmasked =~ ctx.epic.name, "positive control"

    view = mount(ctx.conn, ctx.me, path)
    render_click(view, "toggle_mask_names", %{"masked" => "true"})
    masked = states.(view)
    assert masked =~ "tasks-filter-project-value", "positive control: the row renders"
    assert masked =~ "tasks-project-root", "positive control: the hosted root renders"
    assert masked =~ "tasks-project-epic-level", "positive control: the epic level renders"
    refute masked =~ ctx.p.name
    refute masked =~ ctx.epic.name
  end

  test "the desktop title keeps its chevron", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    assert [_] = q(header_doc(view), "#tasks-title-picker-desktop .hero-chevron-down")
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
