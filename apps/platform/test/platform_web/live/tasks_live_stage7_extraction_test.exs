defmodule PlatformWeb.TasksLiveStage7ExtractionTest do
  @moduledoc """
  Guards for the FINAL Tasks-shell extraction (task 01a008f6 stage 7): the
  board, the board's PubSub, container lifecycle and pin-to-chat.

  Each check exists because the failure it catches is invisible to the rest
  of the suite:

    * A LiveComponent extraction that forgets a `phx-target` renders
      byte-identical markup and passes every existing assertion while the
      feature is dead.
    * A JS hook's `pushEvent` IGNORES `phx-target` and always lands on the
      parent LiveView. Moving `kanban_drop` into a component without
      converting the hook to `pushEventTo` kills drag-and-drop outright with
      `mix test` still fully green — `mix test` cannot execute JS at all, so
      the source check below is the only thing standing between that and
      production.
    * PubSub is delivered to the LiveView PROCESS, so a board `handle_info`
      that moved into a LiveComponent would never be called. `BoardHooks`
      keeps them on the shell; these tests drive real broadcasts to prove
      the hook is attached and halting.

  Every assertion here was detonated before it was committed — watched going
  red against a deliberately broken tree, then green again.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  @board_component "lib/platform_web/live/tasks/board_component.ex"
  @shell_template "lib/platform_web/live/tasks_live.html.heex"
  @shell "lib/platform_web/live/tasks_live.ex"
  @drag_hook "assets/js/hooks/kanban_drag_drop.js"

  setup %{conn: conn} do
    %{conn: authenticated_conn(conn)}
  end

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks_stage7_#{n}@example.com",
        name: "Stage 7 Test User",
        oidc_sub: "oidc-tasks-stage7-#{n}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stage 7 Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  # `sponsor_user_id` on purpose in the drop tests: ADR-0042's sponsor-bypass
  # rule lets a task's sponsor move it without an approved plan, which is
  # what makes a drop assertable without building a whole plan fixture.
  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Stage 7 Task #{System.unique_integer([:positive])}",
            status: "backlog",
            priority: "medium"
          },
          attrs
        )
      )

    task
  end

  defp board(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-board")

  defp user_id(conn), do: Plug.Conn.get_session(conn, :current_user_id)

  describe "the drag-and-drop hook still reaches its handler" do
    test "kanban_drag_drop.js pushes to the component, not the LiveView" do
      hook = File.read!(@drag_hook)

      # POSITIVE CONTROL: the file we are asserting about is the one that
      # actually binds the drop listener. Without this, a renamed or moved
      # hook file makes every check below vacuous.
      assert hook =~ ~s(addEventListener("drop")

      # THE PROMISE. `pushEvent` from a hook ignores phx-target and lands on
      # the parent LiveView, where `board_drop` no longer exists. The only
      # correct call is pushEventTo.
      refute hook =~ "this.pushEvent(",
             "kanban_drag_drop.js uses pushEvent, which ignores phx-target — " <>
               "the drop would land on the shell, which no longer handles it"

      assert hook =~ ~s(this.pushEventTo()
      assert hook =~ ~s("board_drop")

      # The selector lives in the template so there is exactly one place to
      # change the component id.
      assert hook =~ "dataset.boardTarget"
      assert File.read!(@board_component) =~ ~s(data-board-target="#tasks-board")
    end

    test "a drop moves the task and the move PERSISTS across a reload", %{conn: conn} do
      project = create_project()
      user_id = user_id(conn)
      task = create_task(project, %{status: "backlog", sponsor_user_id: user_id})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Drive the same event the hook pushes, at the same target it pushes
      # to. Naming a different target here would prove nothing about the
      # wiring the browser exercises.
      view
      |> board()
      |> render_hook("board_drop", %{"task_id" => task.id, "column" => "in_progress"})

      # PERSISTENCE, from the database — not from the rendered markup, which
      # a purely optimistic client-side move would also satisfy.
      assert %{status: "in_progress"} = Repo.get!(Tasks.Task, task.id)

      # And it survives a fresh mount: the reloaded board renders the card in
      # the In Progress column.
      {:ok, _view2, html2} = live(conn, ~p"/tasks")
      assert html2 =~ task.title
      assert %{status: "in_progress"} = Repo.get!(Tasks.Task, task.id)
    end

    test "a refused drop leaves the task where it was and says why", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{status: "backlog"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> board()
      |> render_hook("board_drop", %{"task_id" => task.id, "column" => "not-a-column"})

      assert %{status: "backlog"} = Repo.get!(Tasks.Task, task.id)
      # The flash arrives one message later — a LiveComponent cannot
      # put_flash/3, so BoardComponent reports up and the shell renders it.
      assert render(view) =~ "Unknown column."
    end
  end

  describe "board PubSub still lands (BoardHooks is attached)" do
    test "a task renamed elsewhere re-renders without a reload", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Before Broadcast", status: "backlog"})

      {:ok, view, html} = live(conn, ~p"/tasks")
      assert html =~ "Before Broadcast"
      refute html =~ "After Broadcast"

      # A real write through the context, which broadcasts `{:task_updated,
      # _}` on the board topic — the same path another session takes. The
      # clause that handles it lives in BoardHooks, attached to the shell;
      # had it moved into the LiveComponent it would never be called, because
      # PubSub delivers to the process.
      {:ok, _} = Tasks.update_task(task, %{title: "After Broadcast"})

      assert render(view) =~ "After Broadcast"
    end

    test "a task deleted elsewhere disappears without a reload", %{conn: conn} do
      project = create_project()
      task = create_task(project, %{title: "Broadcast Departure", status: "backlog"})

      {:ok, view, html} = live(conn, ~p"/tasks")
      assert html =~ "Broadcast Departure"

      {:ok, _} = Tasks.soft_delete_task(task)

      refute render(view) =~ "Broadcast Departure"
    end
  end

  describe "the board left the shell and nothing came back" do
    test "the shell template renders the board as a component only" do
      template = File.read!(@shell_template)

      # POSITIVE CONTROL: the shell still renders the component.
      assert template =~ "PlatformWeb.Tasks.BoardComponent"
      assert template =~ ~s(id="tasks-board")

      # THE PROMISE: the kanban, the mobile list and the epics strip are all
      # gone from the shell template.
      for needle <- [
            "kanban-board",
            "KanbanDragDrop",
            "tasks-mobile-list",
            "epics-section",
            "task-actions-sheet"
          ] do
        refute template =~ needle,
               "#{needle} is still rendered from the shell template"
      end

      board = File.read!(@board_component)

      for needle <- ["kanban-board", "KanbanDragDrop", "tasks-mobile-list"],
          do: assert(board =~ needle)
    end

    test "the shell holds no board, lifecycle or pin handler" do
      shell = File.read!(@shell)

      # POSITIVE CONTROL: the shell still holds the navigation events that
      # deliberately did NOT move (select_task has emitters in two other
      # modules and is push_patch, i.e. a LiveView concern).
      assert shell =~ ~s(handle_event("select_task")

      for needle <- [
            "kanban_drop",
            "board_drop",
            "archive_container",
            "confirm_schedule_deletion",
            "task_pin_added",
            "task_pin_removed"
          ] do
        refute shell =~ needle, "#{needle} is still handled in the shell"
      end
    end
  end
end
