defmodule PlatformWeb.TasksLiveNeedsPromotionTest do
  @moduledoc """
  Tests for the meeting-triage `needs_promotion` kanban badge + the
  `promote_task` LiveView event (task 019f5e2b-8d29 stage 2).

  Split from the umbrella `tasks_live_test.exs` (10.7 kloc) so the
  triage-flow surface has its own focused file; matches the pattern of
  `tasks_live_search_test.exs` and `tasks_live_project_grouping_test.exs`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "needs_promotion_#{System.unique_integer([:positive])}@example.com",
        name: "Needs Promotion Test User",
        oidc_sub: "oidc-needs-promotion-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Promo Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/promo.git"
      })

    project
  end

  defp create_backlog_task(project, needs_promotion?) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Filed-triage task #{System.unique_integer([:positive])}",
        status: "backlog",
        priority: "medium",
        needs_promotion: needs_promotion?,
        metadata: %{"source" => "meetings.triage"}
      })

    task
  end

  describe "needs_promotion badge rendering" do
    test "renders on a backlog task flagged needs_promotion", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_backlog_task(project, true)

      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Badge is rendered as a <button> with the data-role hook so
      # tests do not couple to Tailwind class ordering.
      assert html =~ ~s(data-role="needs-promotion-badge")
      assert html =~ "Needs promotion"

      # Uses the semantic warning badge slot (mirrors the review badge).
      assert html =~ ~r{badge badge-warning[^"]*}

      # Wires the promote_task event with the task id.
      assert html =~ ~s(phx-click="board_promote_task")
      assert html =~ ~s(phx-value-id="#{task.id}")

      # M5b Stage 3: browser-native tooltip conveys the meeting-canvas
      # provenance. Non-empty `title=` is enough — the exact copy is
      # tunable without a test rewrite.
      assert html =~ ~r/title="[^"]{5,}"/
      assert html =~ ~s(title="Filed from a meeting canvas. Click to promote.")

      # M5b Stage 3: hero-icon prefix for scannability at kanban density.
      # `hero-arrow-up-circle` reads "promote / lift out" more clearly
      # than the M5a-shipped plain `hero-arrow-up`.
      assert html =~ ~s(hero-arrow-up-circle size-3)
    end

    test "does not render when needs_promotion is false", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      _task = create_backlog_task(project, false)

      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(data-role="needs-promotion-badge")
      refute html =~ "Needs promotion"
    end

    # M5b Stage 3: regression guard against a stray `:if` deletion that
    # would show the badge on every backlog card. Ensures the flag is
    # actually consulted at render time.
    test "does not render when a peer backlog task has needs_promotion: false",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      flagged = create_backlog_task(project, true)
      unflagged = create_backlog_task(project, false)

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(phx-value-id="#{flagged.id}")
      # The unflagged peer must NOT carry a promote button.
      refute html =~ ~s(data-role="needs-promotion-badge" phx-value-id="#{unflagged.id}")
      refute html =~ ~s(phx-value-id="#{unflagged.id}" data-role="needs-promotion-badge")
    end

    test "does not render when flagged task is NOT in backlog", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_backlog_task(project, true)

      # Flip out of backlog directly — flag stays set, but the badge
      # should be gated behind `status == "backlog"`.
      task
      |> Ecto.Changeset.change(status: "planning")
      |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(data-role="needs-promotion-badge")
    end
  end

  describe "promote_task LiveView event" do
    test "clicking the badge clears needs_promotion + refreshes the view", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_backlog_task(project, true)

      {:ok, view, initial_html} = live(conn, ~p"/tasks")
      assert initial_html =~ "Needs promotion"

      # Fire the event via render_click on the badge button. The badge
      # has a unique data-role hook so we can select it deterministically.
      view
      |> element(~s([data-role="needs-promotion-badge"][phx-value-id="#{task.id}"]))
      |> render_click()

      # Post-click render — badge should be gone.
      updated_html = render(view)
      refute updated_html =~ ~s(data-role="needs-promotion-badge")

      # DB reflects the flip.
      assert %{needs_promotion: false} = Repo.get!(Tasks.Task, task.id)
    end

    test "unknown task id flashes an error and does not crash", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      _task = create_backlog_task(project, true)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Send the event with a bogus id via render_hook — no matching DOM
      # element to click. We invoke handle_event directly.
      #
      # Two renders, not one: `board_promote_task` is BoardComponent's, and a
      # LiveComponent cannot `put_flash/3`. It reports the outcome up with
      # `send(self(), {:board_flash, ...})`, which the shell handles on the
      # NEXT message — so the diff `render_hook/3` returns predates the flash.
      # Re-rendering drains the mailbox first.
      view
      |> Phoenix.LiveViewTest.with_target("#tasks-board")
      |> render_hook("board_promote_task", %{"id" => Ecto.UUID.generate()})

      assert render(view) =~ "Task not found."
    end

    test "promoting a task that is already promoted no-ops without error", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()
      task = create_backlog_task(project, false)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # No badge rendered — hit the event directly.
      view
      |> Phoenix.LiveViewTest.with_target("#tasks-board")
      |> render_hook("board_promote_task", %{"id" => task.id})

      # Still cleared in DB (idempotent).
      assert %{needs_promotion: false} = Repo.get!(Tasks.Task, task.id)
    end
  end

  # M5b (task 019f6e2c) Stage 5 — kanban live-refresh on batch soft-delete.
  # The board LiveView subscribes to `Tasks.subscribe_board/0` and handles
  # `{:tasks_batch_deleted, _ids, _meta}` by re-rendering — every card
  # listed disappears in a single reflow. Broadcasting from the test rather
  # than through Triage keeps this focused on the LV handler.
  describe "tasks_batch_deleted broadcast — live board refresh" do
    test "cards for soft-deleted ids disappear from the mounted board without a reload",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = create_project()

      task_a = create_backlog_task(project, false)
      task_b = create_backlog_task(project, false)
      task_c = create_backlog_task(project, false)

      {:ok, view, initial_html} = live(conn, ~p"/tasks")

      # Sanity: all three cards render on mount.
      assert initial_html =~ ~s(phx-value-id="#{task_a.id}")
      assert initial_html =~ ~s(phx-value-id="#{task_b.id}")
      assert initial_html =~ ~s(phx-value-id="#{task_c.id}")

      # Simulate a Triage.junk_batch/2 soft-delete + broadcast — mirror the
      # exact shape emitted by `broadcast_batch_deleted/4`.
      ids = [task_a.id, task_b.id, task_c.id]
      now = DateTime.utc_now()

      for id <- ids do
        Repo.get!(Tasks.Task, id)
        |> Ecto.Changeset.change(deleted_at: now)
        |> Repo.update!()
      end

      Platform.Tasks.broadcast_board(
        {:tasks_batch_deleted, ids,
         %{canvas_id: Ecto.UUID.generate(), count: 3, soft_deleted_at: now}}
      )

      # Give the LV a tick to process the PubSub message.
      _ = :sys.get_state(view.pid)

      html = render(view)

      refute html =~ ~s(phx-value-id="#{task_a.id}")
      refute html =~ ~s(phx-value-id="#{task_b.id}")
      refute html =~ ~s(phx-value-id="#{task_c.id}")
    end
  end
end
