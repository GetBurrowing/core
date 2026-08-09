defmodule PlatformWeb.PipelineLiveTest do
  @moduledoc """
  What `/control/pipeline` must refuse to render.

    * It must resolve as the pipeline page, not as an agent named "pipeline" —
      the route sits under a catch-all `/control/:agent_slug` and an ordering
      regression is invisible until someone opens the URL.
    * It must print BOTH cohort numbers. A page showing only the decomposable
      count presents a fraction of the data as the whole of it.
    * A phase nobody visited must render an em-dash, never `0.0`. That
      assertion is scoped to the cell the code feeds for that phase — a
      whole-page grep for "0.0" passes or fails for reasons that have nothing
      to do with the phase under test.
    * Under five decomposable tasks it must say so in words rather than draw a
      distribution from three points.

  Fixtures write transition rows at chosen timestamps rather than driving live
  transitions: cohort membership keys off `inserted_at` (see
  `PipelineHealth` — the completion column may not be read), so a fixture that
  lets the DB stamp the row builds a different cohort than it intends.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Pipeline Live Project"})
    %{project: project}
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "pipeline_live_#{System.unique_integer([:positive])}@example.com",
        name: "Pipeline Live User",
        oidc_sub: "oidc-pipeline-live-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  # Recent enough to sit inside the default 30d window, old enough that the
  # fixture's own spans do not run past `until`.
  defp at(days_ago, hours \\ 0) do
    DateTime.utc_now()
    |> DateTime.add(-days_ago * 86_400 + hours * 3_600, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp done_task(project, created_at, title \\ "Pipeline Task") do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})

    {1, _} =
      Tasks.Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [status: "done", inserted_at: created_at])

    Repo.get!(Tasks.Task, task.id)
  end

  defp record_chain(task, steps) do
    Enum.reduce(steps, "backlog", fn {to_status, occurred_at}, from_status ->
      Repo.insert!(%PhaseTransition{
        task_id: task.id,
        from_status: from_status,
        to_status: to_status,
        occurred_at: occurred_at,
        actor_kind: "agent"
      })

      to_status
    end)
  end

  # planning -> in_progress -> deploying -> done. `in_review` is never entered,
  # so `awaiting_manual_approval` is an absent phase for every such cohort.
  defp decomposable_task(project, days_ago, build_hours) do
    task = done_task(project, at(days_ago))

    record_chain(task, [
      {"planning", at(days_ago, 1)},
      {"in_progress", at(days_ago, 2)},
      {"deploying", at(days_ago, 2 + build_hours)},
      {"done", at(days_ago, 3 + build_hours)}
    ])

    task
  end

  defp populated_cohort(project) do
    Enum.each([2, 3, 4, 5, 6], &decomposable_task(project, &1, 4))
    decomposable_task(project, 7, 200)

    # Uninstrumented: in the cohort, out of every aggregate.
    Enum.each([8, 9, 10], &done_task(project, at(&1), "Uninstrumented"))
  end

  describe "routing" do
    test "/control/pipeline renders the pipeline page, not a missing-agent 404", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert html =~ "Pipeline health"
      assert html =~ "Where the time goes"
    end

    test "resolves to PipelineLive while an arbitrary slug still resolves to the catch-all",
         %{conn: conn} do
      # Router resolution, not source order: a grep over router.ex cannot tell
      # a live/3 call from a comment, and the ordering bug is a resolution bug.
      assert %{plug_opts: :index, phoenix_live_view: {PlatformWeb.PipelineLive, _, _, _}} =
               Phoenix.Router.route_info(
                 PlatformWeb.Router,
                 "GET",
                 "/control/pipeline",
                 "example"
               )

      assert %{phoenix_live_view: {PlatformWeb.ControlCenterLive, _, _, _}} =
               Phoenix.Router.route_info(
                 PlatformWeb.Router,
                 "GET",
                 "/control/some-other-agent",
                 "example"
               )

      # And the catch-all still answers for a slug with no agent behind it —
      # it renders the Control Center rather than 404ing, which is the
      # behaviour on this tree.
      {:ok, view, _html} =
        conn |> authenticated_conn() |> live("/control/definitely-not-an-agent-slug")

      assert view.module == PlatformWeb.ControlCenterLive
    end
  end

  describe "populated cohort" do
    test "states both cohort numbers, with the decomposable count strictly smaller",
         %{conn: conn, project: project} do
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      line = view |> element("#exclusion-line") |> render()

      assert line =~ "6 of 9 tasks decomposable"
    end

    test "renders the phase bar with the phases that were measured", %{
      conn: conn,
      project: project
    } do
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert has_element?(view, "#phase-segment-planning")
      assert has_element?(view, "#phase-segment-in_progress")
      assert has_element?(view, "#phase-segment-deploying")
    end

    test "draws both a median and a mean rule, never one figure alone", %{
      conn: conn,
      project: project
    } do
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert has_element?(view, "#cycle-time-histogram")
      assert view |> element("#cycle-rule-median") |> render() =~ "median"
      assert view |> element("#cycle-rule-mean") |> render() =~ "mean"
    end

    test "the >7d overflow bucket is labelled on the axis", %{conn: conn, project: project} do
      populated_cohort(project)

      {:ok, _view, html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert html =~ "&gt;7d"
    end
  end

  describe "a phase nobody visited" do
    test "renders an em-dash and no zero in ITS OWN cell, and draws no segment", %{
      conn: conn,
      project: project
    } do
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      median = view |> element("#phase-median-awaiting_manual_approval") |> render()
      p75 = view |> element("#phase-p75-awaiting_manual_approval") |> render()

      assert median =~ "—"
      assert p75 =~ "—"
      refute median =~ "0.0"
      refute p75 =~ "0.0"

      # A gap in the bar, not a zero-width labelled segment.
      refute has_element?(view, "#phase-segment-awaiting_manual_approval")

      # Anti-vacuity within the test itself: a phase that DID happen renders a
      # duration in the same column, so the em-dash is a distinction and not
      # the column's default.
      assert view |> element("#phase-median-in_progress") |> render() =~ "h"
    end
  end

  describe "sparse early state" do
    test "says how few tasks are decomposable instead of drawing a distribution", %{
      conn: conn,
      project: project
    } do
      Enum.each([2, 3, 4], &decomposable_task(project, &1, 4))

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      note = view |> element("#sparse-distribution-note") |> render()

      assert note =~ "3 of 3"
      assert note =~ "not meaningful yet"

      refute has_element?(view, "#cycle-time-histogram")
      refute has_element?(view, "#phase-bar")

      # Not blank: the throughput panel and the numbers table still render.
      assert has_element?(view, "#throughput-rate")
      assert has_element?(view, "#phase-row-planning")
    end
  end

  describe "the instrumentation window" do
    test "is stated even when the page is fully populated", %{conn: conn, project: project} do
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view |> element("#instrumentation-note") |> render() =~
               "Nothing before that date can be decomposed"
    end

    test "is stated in the sparse state too", %{conn: conn, project: project} do
      decomposable_task(project, 2, 4)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view |> element("#instrumentation-note") |> render() =~ "instrumented from"
    end
  end

  describe "the range control" do
    test "re-renders a narrower cohort when switched to 7d", %{conn: conn, project: project} do
      populated_cohort(project)
      # Well outside 7d, inside 30d.
      Enum.each([20, 21, 22], &decomposable_task(project, &1, 4))

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view |> element("#exclusion-line") |> render() =~ "9 of 12"

      view |> element("form") |> render_change(%{"range" => "7"})

      # The 7d window drops the three older decomposable tasks AND the three
      # uninstrumented ones, so BOTH numbers move.
      assert view |> element("#exclusion-line") |> render() =~ "5 of 5"
    end
  end
end
