defmodule PlatformWeb.TasksLiveStage6ExtractionTest do
  @moduledoc """
  Guards for the four concerns task 01a008f6 stage 6 moved out of the Tasks
  shell. Each one exists because the failure it catches is INVISIBLE to the
  rest of the suite: a LiveComponent extraction that forgets a `phx-target`
  renders byte-identical markup and passes every existing assertion while
  the feature is dead.

  Every assertion here was detonated before it was committed — the guard was
  watched going red against a deliberately broken tree, then green again.
  A check nobody has seen fire proves nothing.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  setup %{conn: conn} do
    %{conn: authenticated_conn(conn)}
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "tasks_stage6_#{System.unique_integer([:positive])}@example.com",
        name: "Stage 6 Test User",
        oidc_sub: "oidc-tasks-stage6-#{System.unique_integer([:positive])}"
      })
      # Org membership is what makes the sub-org scope chips render at all —
      # without it `active_scope_keys/1` is empty and the two chip assertions
      # below would be vacuous rather than failing.
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stage 6 Project #{System.unique_integer([:positive])}",
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

  describe "filters → board mediation" do
    # The chip is clicked THROUGH THE RENDERED DOM, not by pushing a
    # synthetic event at the component. That is the whole point: a synthetic
    # `render_click(filters(view), "filter_scope", …)` passes even when the
    # rendered button carries no `phx-target` and would land on a shell that
    # no longer has the clause. `scope_pill/1` hardcoded exactly such an
    # un-targeted `phx-click="scope_filter"` until this stage.
    test "clicking the rendered All chip routes to the component and the shell mirrors it",
         %{conn: conn} do
      project = create_project()
      create_task(project, %{title: "Scope Mediation Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # POSITIVE CONTROL: drive it OFF :all first, so the assertion below is
      # not satisfied by the mount default.
      view
      |> element(~s([data-scope-chip="fabrikam"] button))
      |> render_click()

      _ = :sys.get_state(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.scope_filter == :fabrikam

      view
      |> element(~s(button[data-scope-chip="all"]))
      |> render_click()

      _ = :sys.get_state(view.pid)

      # The SHELL assign moved — that is the mediation. The component writing
      # its own copy would leave this at :fabrikam and the board unnarrowed.
      assert :sys.get_state(view.pid).socket.assigns.scope_filter == :all
    end

    test "the rendered sub-org chip carries a phx-target (scope_pill is shared with ChatLive)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      [attrs] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-scope-chip="fabrikam"] button))
        |> LazyHTML.attributes()
        |> Enum.map(&Map.new/1)

      assert Map.get(attrs, "phx-click") == "filter_scope"

      assert Map.has_key?(attrs, "phx-target"),
             "the sub-org chip has no phx-target — it would click into the shell, " <>
               "which no longer handles the event. scope_pill/1 is shared with " <>
               "ChatLive and defaults to the un-targeted ChatLive event."
    end

    test "the search input and the mobile status pills both target the filters component",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      doc = LazyHTML.from_fragment(html)

      [form] = doc |> LazyHTML.query(~s(form#task-search-form)) |> LazyHTML.attributes()
      form = Map.new(form)
      assert Map.get(form, "phx-change") == "filter_search"
      assert Map.get(form, "phx-target") == "#tasks-filters"

      pills =
        doc
        |> LazyHTML.query(~s(#tasks-status-filter-pills button[phx-click="filter_by_status"]))
        |> LazyHTML.attributes()
        |> Enum.map(&Map.new/1)

      assert pills != [], "no mobile status pills rendered — the refute below would be vacuous"

      assert Enum.all?(pills, &(Map.get(&1, "phx-target") == "#tasks-filters"))
    end

    # `mix test` cannot execute a JS hook, and a hook's `pushEvent` silently
    # ignores `phx-target`. These two would have gone dead with the whole
    # suite green, so the guard reads the source.
    test "the two JS hooks that push filter events were retargeted at the component" do
      status_filter = File.read!("assets/js/hooks/tasks_status_filter.js")
      last_project = File.read!("assets/js/hooks/last_project.js")

      assert status_filter =~ ~s|pushEventTo("#tasks-filters", "filter_by_status"|

      refute status_filter =~ ~s|pushEvent("filter_by_status"|,
             "an un-targeted pushEvent would land on the shell and the stored " <>
               "mobile pill would silently stop being replayed"

      assert last_project =~ ~s|pushEventTo("#tasks-filters", "filter_clear"|
      refute last_project =~ ~s|pushEvent("clear_filters"|
    end

    test "the component never reaches for the board itself" do
      source = File.read!("lib/platform_web/live/tasks/filters_component.ex")

      # POSITIVE CONTROL: the file is the one we think it is.
      assert source =~ "defmodule PlatformWeb.Tasks.FiltersComponent"
      assert source =~ "tasks_filters_changed"

      # Match the CALL form, not the word: the moduledoc names both functions
      # to explain why they are absent, and a bare-substring refute would be
      # asserting on prose.
      refute source =~ "refresh_board("
      refute source =~ "rebuild_board_shapes("
      refute source =~ ":board_items"
    end
  end

  describe "task-create FAB survives on mobile" do
    # The clearance tokens live in the shared `fab_create/1` primitive, so a
    # verbatim move cannot drop them — but a hand-rolled replacement FAB in
    # the new component could, and that is what this catches.
    test "the FAB clears the safe-area inset AND the bottom nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      [fab] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#tasks-create-fab button[aria-label="Create"]))
        |> LazyHTML.attributes()
        |> Enum.map(&Map.new/1)

      classes = Map.get(fab, "class", "")

      assert classes =~ "env(safe-area-inset-bottom)",
             "FAB lost its safe-area inset: on a notched phone it sits under the home bar"

      assert classes =~ "var(--bottom-nav-height,0px)",
             "FAB lost its bottom-nav clearance: on mobile it renders BEHIND the nav bar"
    end

    # Drive the sheet, don't assert the markup exists. A sheet that renders
    # and cannot be opened or submitted is the exact shape of a broken
    # extraction.
    test "the FAB menu opens the sheet and the sheet creates a task", %{conn: conn} do
      project = create_project()

      {:ok, view, html} = live(conn, ~p"/tasks")

      # Menu closed on mount — otherwise the click below proves nothing.
      refute html =~ ~s(data-role="fab-new-task")

      html =
        view
        |> element(~s(#tasks-create-fab button[aria-label="Create"]))
        |> render_click()

      assert html =~ ~s(data-role="fab-new-task")

      html =
        view
        |> element(~s(button[data-role="fab-new-task"]))
        |> render_click()

      assert html =~ ~s(id="create-task-form")

      title = "FAB Created Task #{System.unique_integer([:positive])}"

      view
      |> form("#create-task-form",
        task: %{
          "title" => title,
          "project_id" => project.id,
          "what" => "opened from the mobile FAB",
          "why" => "the FAB path is the only create affordance below md"
        }
      )
      |> render_submit()

      _ = :sys.get_state(view.pid)

      assert Enum.any?(Tasks.list_all_tasks(), &(&1.title == title)),
             "the sheet submitted but no task landed — the form's phx-target or the " <>
               "component's create path is broken"
    end

    test "the sheet's close callback names the component (sheet.js pushes from a hook)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html =
        view
        |> element(~s(button[data-role="header-new-task"]))
        |> render_click()

      [sheet] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#task-sheet))
        |> LazyHTML.attributes()
        |> Enum.map(&Map.new/1)

      assert Map.get(sheet, "data-on-close") == "taskcreate_close_sheet"

      assert Map.get(sheet, "data-on-close-target"),
             "no data-on-close-target: Escape / scrim close is pushed by the Sheet " <>
               "JS hook, whose pushEvent ignores phx-target, so it would land on the " <>
               "shell and the sheet would silently stop closing"
    end
  end

  describe "gate + supersede triggers reach their components" do
    test "the supersede trigger in the detail panel targets the supersede component",
         %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Supersede Target Task", status: "in_progress"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      [button] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(button[data-role="supersede-plan-button"]))
        |> LazyHTML.attributes()
        |> Enum.map(&Map.new/1)

      assert Map.get(button, "phx-click") == "supersede_open"
      assert Map.get(button, "phx-target") == "#tasks-supersede"
    end
  end
end
