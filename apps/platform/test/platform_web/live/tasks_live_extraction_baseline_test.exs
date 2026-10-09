defmodule PlatformWeb.TasksLiveExtractionBaselineTest do
  @moduledoc """
  Extraction baseline for the TasksLive modularization (task 01a008f6).

  `tasks_live.ex` (6,027 lines) and `tasks_live.html.heex` (4,906 lines)
  are about to be split into `lib/platform_web/live/tasks/` components
  over seven stages. The existing 507-test Tasks corpus is a strong
  baseline for board/detail/lifecycle behaviour, but four concerns
  scheduled for extraction had no self-contained LiveViewTest exercising
  their PRIMARY flow end to end — they were only reachable through
  `tasks_live_test.exs`, the 11,773-line file most likely to be churned
  by the same refactor.

  This file is deliberately separate and self-contained (its own
  fixtures, no shared setup) so it survives the extraction unchanged and
  can be run alone as a smoke check after each stage:

      mix test test/platform_web/live/tasks_live_extraction_baseline_test.exs

  The four concerns, one describe block each:

    a. sidebar project/epic expand + select navigation
    b. stack detail render including the dep-graph annotation
    c. the task creation sheet submit path
    d. filters + search narrowing the board

  Each test asserts on BOTH the rendered wiring (which must survive
  being moved into a function component) and the resulting server state
  or board contents (which must survive being moved into a handler
  module). Every one of them was confirmed to go red by breaking the
  thing it checks before this file was committed.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Stacks

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks-extraction-baseline-#{n}@example.com",
        name: "Extraction Baseline User #{n}",
        oidc_sub: "oidc-tasks-extraction-baseline-#{n}"
      })
      |> member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project(name \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: name || "Baseline Project #{n}",
        repo_url: "git@github.com:test/repo.git",
        org_id: acme_org_id()
      })

    project
  end

  defp create_task(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Baseline Task #{System.unique_integer([:positive])}",
            status: "backlog",
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp attrs(html, selector) do
    html
    |> query(selector)
    |> LazyHTML.attributes()
    |> Enum.map(&Map.new/1)
  end

  # ------------------------------------------------------------------
  # (a) sidebar project/epic expand + select navigation
  # ------------------------------------------------------------------
  describe "sidebar project and epic navigation" do
    test "project buttons carry select_project wiring and selecting one scopes the board",
         %{conn: conn} do
      keep = create_project("Baseline Keep Project")
      drop = create_project("Baseline Drop Project")

      create_task(keep, %{title: "Kept Sidebar Task"})
      create_task(drop, %{title: "Dropped Sidebar Task"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      # Wiring: the sidebar row must still be the thing that dispatches
      # select_project, with the project id on it. If extraction moves
      # the row into a component and drops phx-value-id, this fails.
      # Scoped to the DESKTOP sidebar <aside>. The mobile project sheet
      # renders a second, near-identical set of select_project buttons;
      # an unscoped selector would let a broken sidebar pass on the
      # strength of the sheet's markup (confirmed by mutation: dropping
      # phx-value-id from the sidebar button left an unscoped assertion
      # green).
      project_buttons = attrs(html, ~s(aside [data-role="project-group"] button))
      ids = Enum.map(project_buttons, &Map.get(&1, "phx-value-id"))
      events = project_buttons |> Enum.map(&Map.get(&1, "phx-click")) |> Enum.uniq()

      assert events == ["sidebar_select_project"]
      assert keep.id in ids
      assert drop.id in ids

      # Behaviour: selecting narrows the board to that project.
      html = sidebar_click(view, "sidebar_select_project", %{"id" => keep.id})

      assert assigns(view).selected_project_id == keep.id
      assert html =~ "Kept Sidebar Task"
      refute html =~ "Dropped Sidebar Task"
    end

    test "the epics panel expand toggle flips collapse state and the epic row selects",
         %{conn: conn} do
      project = create_project()

      {:ok, epic} =
        Tasks.create_epic(%{
          project_id: project.id,
          name: "Baseline Sidebar Epic",
          status: "open"
        })

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The epics strip renders only once a project is scoped
      # (`:if={@selected_project_id && @epics != []}`), so the sidebar
      # selection is a precondition of the epic assertions below —
      # which is exactly the navigation coupling this test guards.
      html = sidebar_click(view, "sidebar_select_project", %{"id" => project.id})

      # The collapse control must actually be wired to the handler this
      # test drives below — otherwise render_click/3 exercises a server
      # handler no button can reach.
      assert [toggle] = attrs(html, ~s(#epics-section button[aria-expanded]))
      assert Map.get(toggle, "phx-click") == "sidebar_toggle_epics_panel"
      assert Map.get(toggle, "aria-expanded") == "true"

      # Expanded by default: the epic card renders and carries select_epic.
      epic_nodes = attrs(html, ~s([phx-click="sidebar_select_epic"]))
      assert epic.id in Enum.map(epic_nodes, &Map.get(&1, "phx-value-id"))
      assert html =~ "Baseline Sidebar Epic"

      # Collapse: the panel toggle hides the epic rows entirely.
      html = sidebar_click(view, "sidebar_toggle_epics_panel", %{})
      assert assigns(view).epics_collapsed
      assert attrs(html, ~s([phx-click="sidebar_select_epic"])) == []

      # Expand again, then select.
      html = sidebar_click(view, "sidebar_toggle_epics_panel", %{})
      refute assigns(view).epics_collapsed
      assert attrs(html, ~s([phx-click="sidebar_select_epic"])) != []

      sidebar_click(view, "sidebar_select_epic", %{"id" => epic.id})
      assert assigns(view).selected_epic_id == epic.id
    end

    # The Tasks project picker renders TWICE — once in the desktop <aside>
    # and once in the mobile #project-sheet. Stage 1 discovered the hard way
    # that an UNSCOPED assertion on `button[phx-click="select_project"]`
    # stays green with the desktop sidebar fully broken, because the mobile
    # sheet's markup satisfies it. The corresponding extraction hazard is a
    # HALF move: desktop lifted into the component, mobile sheet left in the
    # shell reading assigns the shell no longer owns. That fails only at the
    # mobile breakpoint, so it survives tests and a desktop screenshot both.
    test "both breakpoints' project pickers moved into SidebarComponent", %{conn: conn} do
      project = create_project("Both Breakpoints Project")
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      shell = File.read!("lib/platform_web/live/tasks_live.html.heex")
      component = File.read!("lib/platform_web/live/tasks/sidebar_component.ex")

      # POSITIVE CONTROLS. Without these the refutations below pass just as
      # happily against a misspelt needle as against a clean shell.
      assert component =~ ~s(phx-click="sidebar_select_project")
      assert component =~ ~s(id="project-sheet")
      assert component =~ "<aside"

      # Neither render site is left in the shell template.
      refute shell =~ "sidebar_select_project"
      refute shell =~ ~s(id="project-sheet")
      refute shell =~ "<aside"

      # And both are live in the rendered page, each carrying the id — a
      # source-only check would pass on a component that never renders.
      desktop = attrs(html, ~s(aside [data-role="project-group"] button))
      mobile = attrs(html, ~s(#project-sheet [data-role="project-group"] button))

      for {label, nodes} <- [{"desktop", desktop}, {"mobile", mobile}] do
        assert nodes != [], "#{label} project picker rendered no buttons"

        assert nodes |> Enum.map(&Map.get(&1, "phx-click")) |> Enum.uniq() ==
                 ["sidebar_select_project"],
               "#{label} project picker is not wired to sidebar_select_project"

        assert project.id in Enum.map(nodes, &Map.get(&1, "phx-value-id")),
               "#{label} project picker dropped phx-value-id"
      end
    end
  end

  # ------------------------------------------------------------------
  # (b) stack detail render including the dep-graph annotation
  # ------------------------------------------------------------------
  describe "stack detail panel" do
    test "renders member rows and the dep annotation sub-line", %{conn: conn} do
      project = create_project()
      slug = "baseline-#{System.unique_integer([:positive])}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Baseline Stack",
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      # Three members, positions 1..3. m2 and m3 both depend only on m1,
      # so m2's annotation is "depends on ① (parallel with ③)".
      [m1, m2, m3] =
        for pos <- 1..3 do
          create_task(project, %{
            stack_id: stack.id,
            stack_position: pos,
            title: "Baseline Member #{pos}",
            status: "in_review"
          })
        end

      for m <- [m2, m3] do
        {:ok, _} =
          Tasks.update_task(m, %{dependencies: [%{"task_id" => m1.id, "kind" => "blocks"}]})
      end

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = stacks_click(view, "stack_open_detail", %{"id" => stack.id})

      rows = attrs(html, ~s([data-role="stack-detail-member-row"]))
      row_ids = Enum.map(rows, &Map.get(&1, "data-member-id"))
      assert m1.id in row_ids
      assert m2.id in row_ids
      assert m3.id in row_ids

      # The dep annotation is the discriminating assertion: it is the
      # only part of the panel produced by member_dep_annotation/2, the
      # private helper most at risk of being dropped when the panel
      # moves into its own component.
      assert html =~ "depends on ① (parallel with ③)",
             "stack detail panel rendered without the dep annotation sub-line"
    end

    # The stack card renders TWICE on the board — once in the desktop kanban
    # column and once in the mobile section list — and BOTH carry the
    # triggers for events that now live on StacksComponent. The extraction
    # hazard is a half-retarget: desktop gets `phx-target="#tasks-stacks"`,
    # mobile is left un-targeted, so its clicks land on the shell, which no
    # longer has a handler. That crashes only at the mobile breakpoint, so it
    # survives a desktop screenshot AND every unscoped selector assertion —
    # the same failure shape stage 2 hit with the project picker.
    test "both breakpoints' stack cards target StacksComponent", %{conn: conn} do
      project = create_project("Both Breakpoints Stack")
      slug = "breakpoints-#{System.unique_integer([:positive])}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Breakpoint Stack",
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      _member =
        create_task(project, %{stack_id: stack.id, stack_position: 1, title: "BP Member 1"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      shell = File.read!("lib/platform_web/live/tasks_live.html.heex")
      component = File.read!("lib/platform_web/live/tasks/stacks_component.ex")

      # POSITIVE CONTROLS. Without these the refutations below pass just as
      # happily against a misspelt needle as against a clean shell.
      assert component =~ ~s(phx-click="stack_close_detail")
      assert component =~ ~s(phx-click="stack_open_feedback_overlay")
      assert component =~ ~s(phx-click="stack_open_graph_expand")
      assert component =~ ~s(phx-click="stack_clear_member_override")

      # The four panel/overlay/modal render regions left the shell entirely.
      for needle <- [
            "stack-detail-member-row",
            "stack_close_detail",
            "stack_open_feedback_overlay",
            "stack_open_graph_expand",
            "stack_save_assignees"
          ] do
        refute shell =~ needle,
               "#{needle} is still rendered from the shell template"
      end

      # Every stack-card trigger must be retargeted, at BOTH breakpoints.
      # Un-targeted, the click lands on a shell that no longer handles it.
      #
      # The board card markup moved OUT of the shell and into
      # `BoardComponent` in stage 7, so the source read follows it there —
      # the shell refutations above still prove it left the shell.
      #
      # BOTH SITES, from source. The mobile and desktop boards share one DOM
      # under CSS visibility, but they are two separate markup blocks, and a
      # rendered-DOM count cannot distinguish "the other breakpoint is not
      # retargeted" from "the other breakpoint's card did not render for this
      # fixture". The source count can, and it is the check that bites.
      board = File.read!("lib/platform_web/live/tasks/board_component.ex")

      refute shell =~ ~s(phx-click="stack_open_detail"),
             "the board's stack cards are still rendered from the shell template"

      for event <- ["stack_open_detail", "stack_toggle_expand"] do
        sites =
          board
          |> String.split("\n")
          |> Enum.with_index()
          |> Enum.filter(fn {line, _i} -> line =~ ~s(phx-click="#{event}") end)

        assert length(sites) == 2,
               "expected #{event} at exactly 2 breakpoints, found #{length(sites)}"

        lines = String.split(board, "\n")

        for {_line, i} <- sites do
          assert Enum.at(lines, i + 1) =~ ~s(phx-target="#tasks-stacks"),
                 "the #{event} site at board_component line #{i + 1} is not targeted at " <>
                   "StacksComponent — an un-targeted site lands on a shell that " <>
                   "no longer handles the event, and fails only at its own breakpoint"
        end
      end

      # RENDERED POSITIVE CONTROL: the source check above proves nothing if
      # the card never reaches the page.
      headers = attrs(html, ~s([data-role="stack-header"]))
      assert headers != [], "no stack header rendered on the board at all"

      assert headers |> Enum.map(&Map.get(&1, "phx-target")) |> Enum.uniq() ==
               ["#tasks-stacks"]

      assert stack.id in Enum.map(headers, &Map.get(&1, "phx-value-id"))
    end
  end

  # ------------------------------------------------------------------
  # (c) task creation sheet submit path
  # ------------------------------------------------------------------
  describe "task creation sheet" do
    test "opening the sheet renders the form and submitting it persists a task",
         %{conn: conn} do
      project = create_project()

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(create(view), "taskcreate_toggle_sheet", %{})

      form = attrs(html, ~s(form#create-task-form))
      assert [form_attrs] = form
      assert Map.get(form_attrs, "phx-submit") == "taskcreate_submit"
      assert Map.get(form_attrs, "phx-change") == "taskcreate_validate"

      title = "Baseline Created Task #{System.unique_integer([:positive])}"

      html =
        view
        |> form("#create-task-form",
          task: %{
            "title" => title,
            "project_id" => project.id,
            "what" => "created through the sheet",
            "why" => "to prove the create_task submit path still lands"
          }
        )
        |> render_submit()

      assert Repo.get_by(Platform.Tasks.Task, title: title),
             "create_task submit did not persist the task"

      # And the board picked it up without a reload.
      # Stage 6: the component reports the outcome up; the flash and the
      # board refresh land in the NEXT render, not the submit reply.
      html = render(view)

      assert html =~ title
    end
  end

  # ------------------------------------------------------------------
  # (d) filters and search narrowing the board
  # ------------------------------------------------------------------
  describe "filters and search" do
    test "the status filter and the search box each narrow the board", %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Baseline Widget Alpha", status: "backlog"})
      create_task(project, %{title: "Baseline Widget Beta", status: "backlog"})
      create_task(project, %{title: "Baseline Gadget Gamma", status: "in_progress"})

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")

      assert html =~ "Baseline Widget Alpha"
      assert html =~ "Baseline Widget Beta"
      assert html =~ "Baseline Gadget Gamma"

      # Search narrows to the two Widgets, case-insensitively.
      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => "widget"})

      html = after_filter(view)
      assert html =~ "Baseline Widget Alpha"
      assert html =~ "Baseline Widget Beta"
      refute html =~ "Baseline Gadget Gamma"

      # Clearing search restores the full board.
      _ =
        view
        |> element("#task-search-form")
        |> render_change(%{"q" => ""})

      html = after_filter(view)
      assert html =~ "Baseline Gadget Gamma"

      # The mobile status filter narrows the rendered column instead.
      render_click(filters(view), "filter_by_status", %{"status" => "in_progress"})
      assert assigns(view).active_status_filter == "in_progress"
    end
  end

  # ── Sidebar event helpers (task 01a008f6 stage 2) ──────────────────────
  #
  # Sidebar / Projects / Epics events live on
  # `PlatformWeb.TasksLive.SidebarComponent`. Dispatching to a LiveComponent
  # returns only THAT component's HTML, and any state the component asks the
  # shell to change arrives as a message the shell processes afterwards — so
  # a raw `render_click(with_target(...))` snapshot shows neither the board
  # nor the post-notify state. These helpers dispatch to the component and
  # then re-render the whole view, which is what every assertion here wants.

  # Task 01a008f6 stage 6: FiltersComponent hands its value to the shell as
  # `{:tasks_filters_changed, _}`, so the board work lands in the render
  # AFTER the event reply.
  defp after_filter(view) do
    _ = :sys.get_state(view.pid)
    Phoenix.LiveViewTest.render(view)
  end

  defp sidebar_click(view, event, params \\ %{}) do
    _ = render_click(with_target(view, "#tasks-sidebar"), event, params)
    render(view)
  end

  # Stacks events live on `PlatformWeb.Tasks.StacksComponent` (task
  # 01a008f6 stage 3). Dispatch to the component, then re-render the whole
  # view so board markup and post-notify shell state are both visible.
  defp stacks_click(view, event, params \\ %{}) do
    _ = render_click(with_target(view, "#tasks-stacks"), event, params)
    render(view)
  end

  # Task 01a008f6 stage 6: New-Task creation is a LiveComponent.
  defp create(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-create")

  # Task 01a008f6 stage 6: board filtering is a LiveComponent.
  defp filters(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-filters")
end
