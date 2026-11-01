defmodule PlatformWeb.TasksFilterBarTest do
  @moduledoc """
  The phone Tasks header and sheets (task 01a161fd stage 3, prototype canvas
  01a16202 node `p`): `PlatformWeb.Tasks.FilterBar`, `FilterSheets` and
  `FilterHooks`. Task 01a168c2 stage 1 adds the Filter sheet's Project row
  and the project picker it hosts.

  Every absence is preceded by a positive control on the same render showing
  the same query can find something.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.{BoardData, FilterSheets, StatusLabels}

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "filter-bar-#{n}@example.com",
      name: "Filter Bar #{n}",
      oidc_sub: "filter-bar-#{n}"
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

  defp list_doc(view),
    do: view |> element("#tasks-my-list") |> render() |> LazyHTML.from_fragment()

  defp q(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  defp hrefs(doc, sel), do: doc |> q(sel) |> Enum.map(&attr(&1, "href"))

  defp classes(nodes),
    do: Enum.flat_map(nodes, &String.split(attr(&1, "class") || "", ~r/\s+/, trim: true))

  defp open(view, sheet), do: render_click(view, "tasks_filter_open", %{"sheet" => sheet})

  defp sheet_doc(view),
    do: view |> element("#tasks-filter-sheet") |> render() |> LazyHTML.from_fragment()

  defp row_ids(doc),
    do: doc |> q("[data-role=tasks-my-row]") |> Enum.map(&attr(&1, "data-row-task-id"))

  defp click_row(view),
    do: view |> element("#tasks-my-list [data-role=tasks-filter-project-row]") |> render_click()

  # A viewer in ONE tenant org (a root-org member reads every project), a
  # readable home project and a foreign project in another tenant.
  defp tenant_viewer! do
    home_org = Platform.TenancyFixtures.tenant_org_id("filter_row_home_#{u()}")
    foreign_org = Platform.TenancyFixtures.tenant_org_id("filter_row_foreign_#{u()}")
    n = u()

    viewer =
      Repo.insert!(%User{
        email: "filter-row-tenant-#{n}@example.com",
        name: "Filter Row tenant #{n}",
        oidc_sub: "filter-row-tenant-#{n}"
      })

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: home_org,
      role: "member"
    })
    |> Repo.insert!()

    {:ok, home} = Tasks.create_project(%{name: "Filter Row Home #{u()}", org_id: home_org})

    {:ok, foreign} =
      Tasks.create_project(%{name: "Secret Foreign Project #{u()}", org_id: foreign_org})

    {:ok, foreign_epic} =
      Tasks.create_epic(%{project_id: foreign.id, name: "Secret Foreign Epic #{u()}"})

    task!(home, "Home task", status: "in_progress")
    task!(foreign, "Foreign task", status: "in_progress")
    %{viewer: viewer, home: home, foreign: foreign, foreign_epic: foreign_epic}
  end

  setup do
    me = user!()
    {:ok, p} = Tasks.create_project(%{name: "Filter Bar Project #{u()}"})
    {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Filter Bar Epic #{u()}"})

    a =
      task!(p, "Alpha widget",
        status: "in_progress",
        kind: "bug",
        priority: "high",
        sponsor_user_id: me.id,
        epic_id: epic.id
      )

    b = task!(p, "Beta", status: "blocked", kind: "feature", priority: "low")
    c = task!(p, "Gamma", status: "done", kind: "chore", priority: "medium")

    %{me: me, p: p, epic: epic, a: a, b: b, c: c}
  end

  test "each option's href is the tasks_path/1 URL for that one change", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    base = %{selected_project_id: ctx.p.id}
    path = &BoardData.tasks_path(Map.merge(base, &1))

    open(view, "filter")
    d = list_doc(view)

    for mode <- BoardData.sort_modes() do
      assert hrefs(d, ~s([data-sort="#{mode}"])) == [path.(%{board_sort: mode})]
    end

    assert hrefs(d, ~s([data-status="in_progress"])) == [
             path.(%{status_filters: ["in_progress"]})
           ]

    assert hrefs(d, ~s([data-kind="bug"])) == [path.(%{kind_filters: ["bug"]})]
    assert hrefs(d, ~s([data-mine="true"])) == [path.(%{mine_filter: true})]
    assert hrefs(d, ~s([data-mine="false"])) == [path.(%{})]
    assert hrefs(d, ~s([data-sponsor="mine"])) == [path.(%{sponsor_filter: :mine})]

    assert hrefs(d, ~s([data-source="external_feedback"])) == [
             path.(%{origin_filter: "external_feedback"})
           ]

    # The exact strings, so the builder itself is pinned too.
    assert hrefs(d, ~s([data-status="in_progress"])) == [
             "/tasks?project=#{ctx.p.id}&status=in_progress"
           ]

    open(view, "project")
    d = list_doc(view)
    assert hrefs(d, ~s([data-project="all"])) == ["/tasks?project=all"]
    assert hrefs(d, ~s([data-project="#{ctx.p.id}"])) == ["/tasks?project=#{ctx.p.id}"]

    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    d = list_doc(view)
    assert hrefs(d, ~s([data-epic="all"])) == ["/tasks?project=#{ctx.p.id}"]

    assert hrefs(d, ~s([data-epic="#{ctx.epic.id}"])) == [
             "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}"
           ]

    # A toggle on an active value removes it, keeping the other.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&status=in_progress,blocked")
    open(view, "filter")
    d = list_doc(view)

    assert hrefs(d, ~s([data-status="blocked"])) == [
             "/tasks?project=#{ctx.p.id}&status=in_progress"
           ]
  end

  test "no live link inside the list or either sheet carries phx-click", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&status=in_progress,blocked")

    docs = [
      list_doc(view),
      open(view, "filter") && list_doc(view),
      open(view, "project") && list_doc(view),
      render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id}) && list_doc(view)
    ]

    links = Enum.flat_map(docs, &q(&1, "[data-phx-link]"))
    # Positive control: rows, chips, Clear all, every option and Reset.
    assert length(links) > 20
    assert Enum.filter(links, &(attr(&1, "phx-click") != nil)) == []

    # The picker hosted in the Filter sheet (task 01a168c2), both levels.
    hosted = [
      open(view, "filter_project") && sheet_doc(view),
      render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id}) && sheet_doc(view)
    ]

    hosted_links = Enum.flat_map(hosted, &q(&1, "[data-phx-link]"))
    # Positive control: All projects + the project at the root, All of + the epic below.
    assert length(hosted_links) >= 4
    assert Enum.filter(hosted_links, &(attr(&1, "phx-click") != nil)) == []
  end

  test "both sheets are bottom sheets with handle_close and swipe_dismiss", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    d = list_doc(view)

    for id <- ["tasks-project-sheet", "tasks-filter-sheet"] do
      [sheet] = q(d, "##{id}")
      assert "sheet-bottom" in classes([sheet])
      assert attr(sheet, "data-swipe-dismiss") == "true"
      assert [_] = q(d, "##{id} .sheet-handle-button[aria-label=Close]")
      assert q(d, "##{id} .sheet-close-button") == []
      assert q(d, "##{id} .sheet-handle--status") == []
    end

    open(view, "filter")
    d = list_doc(view)
    [title] = q(d, "#tasks-filter-sheet [data-role=tasks-filter-sheet-body] > p")
    assert attr(title, "aria-hidden") == "true"
    assert text(title) == "Filter and sort"
    assert d |> q("#tasks-filter-sheet") |> hd() |> attr("data-open") == "true"
  end

  test "the badge equals the chip count and excludes sort and project; Clear all keeps them",
       ctx do
    url =
      "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}&sort=priority&status=in_progress,blocked&kind=bug&mine=1&sponsor=mine&q=widget"

    view = mount(ctx.conn, ctx.me, url)
    d = list_doc(view)

    chips = q(d, "[data-role=tasks-filter-chip]")

    assert Enum.map(chips, &text/1) == [
             "In progress×",
             "Blocked×",
             "Bug×",
             "Mine×",
             "I sponsor×",
             ~s("widget"×)
           ]

    assert d |> q("[data-role=tasks-filter-badge]") |> hd() |> text() == "6"

    assert d |> q("[data-role=tasks-filter-button]") |> hd() |> attr("aria-label") ==
             "Filter, 6 on"

    keep = "/tasks?sort=priority&project=#{ctx.p.id}&epic=#{ctx.epic.id}"
    assert hrefs(d, "[data-role=tasks-clear-all]") == [keep]

    open(view, "filter")
    assert hrefs(list_doc(view), "[data-role=tasks-filter-reset]") == [keep]

    # Removing one chip drops exactly that value.
    assert hrefs(d, ~s([data-chip="kind-bug"])) == [
             "/tasks?sponsor=mine&sort=priority&q=widget&project=#{ctx.p.id}&epic=#{ctx.epic.id}&status=in_progress,blocked&mine=1"
           ]

    # Sort and project alone: no chip, no badge, no Clear all.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&sort=priority")
    d = list_doc(view)
    assert [_] = q(d, "[data-role=tasks-sort-chip]"), "positive control"
    assert q(d, "[data-role=tasks-filter-chip]") == []
    assert q(d, "[data-role=tasks-filter-badge]") == []
    assert q(d, "[data-role=tasks-clear-all]") == []
  end

  test "Clear all appears only from 2 active filters", ctx do
    one = list_doc(mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&status=blocked"))
    assert [_] = q(one, "[data-role=tasks-filter-chip]")
    assert q(one, "[data-role=tasks-clear-all]") == []

    two = list_doc(mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&status=blocked&mine=1"))
    assert length(q(two, "[data-role=tasks-filter-chip]")) == 2
    assert [_] = q(two, "[data-role=tasks-clear-all]")
  end

  test "the sort chip has no remove link and opens the filter sheet", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&sort=oldest&status=blocked")
    d = list_doc(view)
    [chip] = q(d, "[data-role=tasks-sort-chip]")
    assert LazyHTML.tag(chip) == ["button"]
    assert text(chip) == "Oldest"
    assert q(d, "[data-role=tasks-sort-chip] a, [data-role=tasks-sort-chip] [href]") == []
    refute Enum.any?(q(d, "[data-role=tasks-filter-chip]"), &(text(&1) =~ "Oldest"))

    view |> element("[data-role=tasks-sort-chip]") |> render_click()
    assert has_element?(view, "#tasks-filter-sheet[data-open=true] [data-role=tasks-filter-sort]")
  end

  test "'Show N tasks' equals the row count; 0 gives a disabled 'No tasks match'", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    open(view, "filter")
    d = list_doc(view)
    rows = q(d, "[data-role=tasks-my-row]")
    assert length(rows) == 3
    [show] = q(d, "[data-role=tasks-filter-show]")
    assert text(show) == "Show 3 tasks"
    assert attr(show, "disabled") == nil

    # Live apply: a patch from inside the filter sheet keeps it open.
    view |> element(~s(#tasks-my-list [data-status="blocked"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}&status=blocked")
    d = list_doc(view)
    assert d |> q("#tasks-filter-sheet") |> hd() |> attr("data-open") == "true"
    assert d |> q("[data-role=tasks-filter-show]") |> hd() |> text() == "Show 1 task"

    view |> element(~s(#tasks-my-list [data-kind="ops"])) |> render_click()
    d = list_doc(view)
    [show] = q(d, "[data-role=tasks-filter-show]")
    assert text(show) == "No tasks match"
    assert attr(show, "disabled") != nil
    assert q(d, "[data-role=tasks-my-row]") == []
    assert [_] = q(d, "[data-role=tasks-my-empty]")

    # Show closes the sheet.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    open(view, "filter")
    view |> element("#tasks-my-list [data-role=tasks-filter-show]") |> render_click()
    assert has_element?(view, "#tasks-filter-sheet[data-open=false]")
  end

  test "a project or epic pick closes the project sheet", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks")
    open(view, "project")
    assert has_element?(view, "#tasks-project-sheet[data-open=true]")
    assert has_element?(view, "[data-role=tasks-title-picker][aria-expanded=true]")

    view |> element(~s(#tasks-my-list [data-project="#{ctx.p.id}"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}")
    assert has_element?(view, "#tasks-project-sheet[data-open=false]")

    assert view |> element("#tasks-my-list [data-role=tasks-title-project]") |> render() =~
             ctx.p.name

    open(view, "project")
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    view |> element(~s(#tasks-my-list [data-epic="#{ctx.epic.id}"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}")
    assert has_element?(view, "#tasks-project-sheet[data-open=false]")

    assert view |> element("#tasks-my-list [data-role=tasks-title-epic]") |> render() =~
             ctx.epic.name

    # The root marks the project with an epic as •, and Back returns there.
    open(view, "project")
    assert view |> element(~s(#tasks-my-list [data-project="#{ctx.p.id}"])) |> render() =~ "•"
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    render_click(view, "tasks_filter_back", %{})
    assert has_element?(view, "[data-role=tasks-project-root]")
  end

  test "masking leaves no real project or epic name anywhere in the list", ctx do
    path = "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}"

    states = fn view ->
      [
        list_doc(view),
        open(view, "project") && list_doc(view),
        render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id}) && list_doc(view),
        open(view, "filter") && list_doc(view)
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
    assert masked =~ "tasks-title-project", "positive control: the title renders"
    assert masked =~ "tasks-my-epic", "positive control: the row's epic slot renders"
    refute masked =~ ctx.p.name
    refute masked =~ ctx.epic.name
  end

  # ── The Project row (task 01a168c2 stage 1) ──────────────────────────

  test "the Project row is the Filter sheet's first section and reads the selection", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    open(view, "filter")
    d = sheet_doc(view)

    sections =
      d |> q("[data-role=tasks-filter-sheet-body] > section") |> Enum.map(&attr(&1, "data-role"))

    assert ["tasks-filter-project", "tasks-filter-sort" | _] = sections

    [row] = q(d, "[data-role=tasks-filter-project] [data-role=tasks-filter-project-row]")
    assert LazyHTML.tag(row) == ["button"]
    assert attr(row, "type") == "button"
    assert attr(row, "href") == nil
    assert attr(row, "phx-click") == "tasks_filter_open"
    assert attr(row, "phx-value-sheet") == "filter_project"
    assert attr(row, "aria-haspopup") == "dialog"
    assert attr(row, "aria-label") == "Project: All projects. Change project"
    assert "active:bg-base-200" in classes([row])
    assert "w-full" in classes([row])
    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == "All projects"
    assert [chev] = q(d, "[data-role=tasks-filter-project-row] .hero-chevron-right")
    assert attr(chev, "aria-hidden") == "true"
    [label] = q(d, "[data-role=tasks-filter-project] > p")
    assert text(label) == "Project"
    assert attr(label, "aria-hidden") == "true"
    assert "border-t" in classes(q(d, "[data-role=tasks-filter-sort]"))

    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}")
    open(view, "filter")
    d = sheet_doc(view)
    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == ctx.p.name

    view = mount(ctx.conn, ctx.me, "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}")
    open(view, "filter")
    d = sheet_doc(view)

    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() ==
             "#{ctx.p.name} › #{ctx.epic.name}"

    assert d |> q("[data-role=tasks-filter-project-row]") |> hd() |> attr("aria-label") ==
             "Project: #{ctx.p.name}, epic #{ctx.epic.name}. Change project"
  end

  test "the row hosts the picker in the Filter sheet and a pick returns to Filter", ctx do
    {:ok, other} = Tasks.create_project(%{name: "Filter Row Other #{u()}"})
    o = task!(other, "Other project task", status: "in_progress")

    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    # Positive control: before the pick the list carries another project's task.
    assert o.id in row_ids(list_doc(view))
    assert ctx.a.id in row_ids(list_doc(view))

    open(view, "filter")
    click_row(view)

    assert has_element?(
             view,
             "#tasks-filter-sheet[data-open=true] [data-role=tasks-project-root]"
           )

    assert has_element?(view, "#tasks-filter-sheet [data-role=tasks-project-back-filter]")
    assert has_element?(view, "#tasks-project-sheet[data-open=false]")
    refute has_element?(view, "#tasks-project-sheet [data-role=tasks-project-root]")

    assert has_element?(
             view,
             "#tasks-my-list [data-role=tasks-title-picker][aria-expanded=false]"
           )

    # The picker replaces the body and the footer.
    refute has_element?(view, "#tasks-filter-sheet [data-role=tasks-filter-sheet-body]")
    refute has_element?(view, "#tasks-filter-sheet [data-role=tasks-filter-show]")

    view |> element(~s(#tasks-filter-sheet [data-project="#{ctx.p.id}"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}")

    d = list_doc(view)
    assert d |> q("#tasks-filter-sheet") |> hd() |> attr("data-open") == "true"
    assert [_] = q(d, "#tasks-filter-sheet [data-role=tasks-filter-sheet-body]")
    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == ctx.p.name

    ids = row_ids(d)
    assert ids != []
    refute o.id in ids
    p_ids = MapSet.new([ctx.a.id, ctx.b.id, ctx.c.id])
    assert Enum.all?(ids, &MapSet.member?(p_ids, &1))
  end

  test "Back steps out of the hosted picker one level at a time, inside the Filter sheet",
       ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    open(view, "filter")
    click_row(view)

    view |> element("#tasks-filter-sheet [data-role=tasks-project-back-filter]") |> render_click()

    assert has_element?(
             view,
             "#tasks-filter-sheet[data-open=true] [data-role=tasks-filter-sheet-body]"
           )

    refute has_element?(view, "#tasks-filter-sheet [data-role=tasks-project-root]")

    click_row(view)

    view
    |> element(
      ~s(#tasks-filter-sheet [data-role=tasks-project-epics][phx-value-id="#{ctx.p.id}"])
    )
    |> render_click()

    assert has_element?(view, "#tasks-filter-sheet [data-role=tasks-project-epic-level]")
    assert has_element?(view, ~s(#tasks-filter-sheet [data-epic="#{ctx.epic.id}"]))
    assert has_element?(view, "#tasks-project-sheet[data-open=false]")

    view |> element("#tasks-filter-sheet [data-role=tasks-project-back]") |> render_click()

    assert has_element?(
             view,
             "#tasks-filter-sheet[data-open=true] [data-role=tasks-project-root]"
           )

    assert has_element?(view, "#tasks-filter-sheet [data-role=tasks-project-back-filter]")
    assert has_element?(view, "#tasks-project-sheet[data-open=false]")

    # An epic pick from the hosted epic level also returns to Filter.
    render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id})
    view |> element(~s(#tasks-filter-sheet [data-epic="#{ctx.epic.id}"])) |> render_click()
    assert_patch(view, "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}")

    assert view
           |> element("#tasks-filter-sheet [data-role=tasks-filter-project-value]")
           |> render() =~
             "#{ctx.p.name} › #{ctx.epic.name}"

    click_row(view)
    render_click(view, "tasks_filter_close", %{})
    assert has_element?(view, "#tasks-filter-sheet[data-open=false]")
    refute has_element?(view, "#tasks-filter-sheet [data-role=tasks-project-root]")
  end

  test "the title picker renders no Back to filter and keeps its chevron", ctx do
    view = mount(ctx.conn, ctx.me, "/tasks?project=all")
    open(view, "project")
    d = list_doc(view)
    [heading] = q(d, "#tasks-project-sheet [data-role=tasks-project-root] > p")
    assert text(heading) == "Project"
    assert q(d, "[data-role=tasks-project-back-filter]") == []
    assert [_] = q(d, "#tasks-title-picker .hero-chevron-down")
  end

  test "a forged epics id from another tenant leaves the hosted picker at its root" do
    t = tenant_viewer!()
    view = mount(build_conn(), t.viewer, "/tasks?project=all")
    open(view, "filter")
    click_row(view)

    render_click(view, "tasks_filter_epics", %{"id" => t.foreign.id})
    d = sheet_doc(view)
    assert [_] = q(d, "[data-role=tasks-project-root]")
    assert q(d, "[data-role=tasks-project-epic-level]") == []
    refute LazyHTML.to_html(d) =~ t.foreign.name
    refute LazyHTML.to_html(d) =~ t.foreign_epic.name

    # Positive control: the readable home project DOES open its epic level.
    render_click(view, "tasks_filter_epics", %{"id" => t.home.id})
    d = sheet_doc(view)
    assert [_] = q(d, "[data-role=tasks-project-epic-level]")
    assert LazyHTML.to_html(d) =~ t.home.name
  end

  test "?project=<foreign id> reads All projects and leaks no foreign name", ctx do
    t = tenant_viewer!()
    view = mount(build_conn(), t.viewer, "/tasks?project=#{t.foreign.id}")
    open(view, "filter")
    d = list_doc(view)
    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == "All projects"
    assert d |> q("[data-role=tasks-my-row]") |> length() >= 1, "positive control: rows render"
    refute LazyHTML.to_html(d) =~ t.foreign.name

    # Positive control: a viewer who can read it sees the same name in the row.
    view = mount(ctx.conn, ctx.me, "/tasks?project=#{t.foreign.id}")
    open(view, "filter")
    d = list_doc(view)
    assert d |> q("[data-role=tasks-filter-project-value]") |> hd() |> text() == t.foreign.name
  end

  test "masking leaves no real project or epic name in the Filter sheet's row or picker", ctx do
    path = "/tasks?project=#{ctx.p.id}&epic=#{ctx.epic.id}"

    states = fn view ->
      [
        open(view, "filter") && sheet_doc(view),
        click_row(view) && sheet_doc(view),
        render_click(view, "tasks_filter_epics", %{"id" => ctx.p.id}) && sheet_doc(view)
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

  test "the new modules carry no hover: utility and no text-base-content/<n>" do
    files =
      ~w(filter_bar.ex filter_sheets.ex filter_hooks.ex my_tasks_list.ex)
      |> Enum.map(&File.read!(Path.join("lib/platform_web/live/tasks", &1)))

    source = Enum.join(files)
    # Positive controls: the scan reads the components and their class strings.
    assert Enum.all?(files, &(byte_size(&1) > 0))
    assert source =~ "active:bg-base-200"
    assert source =~ "text-base-content"
    assert source =~ "data-role=\"tasks-filter-chip\""

    # A utility, not prose: `hover:` followed by a class name.
    assert Regex.match?(~r/active:[a-z\[]/, source), "positive control for the pattern"
    refute Regex.match?(~r/hover:[a-z\[]/, source)
    refute Regex.match?(~r/text-base-content\/\d/, source)
  end

  test "StatusLabels.dot_class/1 maps every status to the binding palette" do
    statuses = Task.statuses()
    refute Enum.empty?(statuses)

    expected = %{
      "backlog" => "bg-edge",
      "planning" => "bg-edge",
      "in_progress" => "bg-info",
      "in_review" => "bg-edge",
      "deploying" => "bg-info",
      "done" => "bg-success",
      "blocked" => "bg-warning",
      "stack_pending" => "bg-edge",
      "cancelled" => "bg-edge"
    }

    for s <- statuses, do: assert(StatusLabels.dot_class(s) == Map.fetch!(expected, s))
    assert StatusLabels.dot_class("something_new") == "bg-edge"

    # The Status and Kind sections list every status and kind exactly once.
    assert Enum.sort(FilterSheets.status_order()) == Enum.sort(statuses)
    assert Enum.sort(FilterSheets.kind_order()) == Enum.sort(Task.kinds())
  end
end
