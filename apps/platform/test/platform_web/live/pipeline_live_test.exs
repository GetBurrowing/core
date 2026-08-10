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
    * Below the distribution floor it must say so in words rather than draw a
      distribution from three points, and it must state the floor itself — a
      threshold that fires silently is indistinguishable from a page with no
      chart, and this page transitions unattended.

  Fixtures write transition rows at chosen timestamps rather than driving live
  transitions: cohort membership keys off `inserted_at` (see
  `PipelineHealth` — the completion column may not be read), so a fixture that
  lets the DB stamp the row builds a different cohort than it intends.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
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

  # Twenty decomposable tasks is exactly the floor at which the page draws a
  # distribution, so a populated cohort is built at the floor and not above it:
  # a fixture with room to spare cannot tell a raised floor from a removed one.
  defp populated_cohort(project) do
    Enum.each(1..19, &decomposable_task(project, 2 + rem(&1, 5), 4))
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

      assert line =~ "20 of 23 tasks decomposable"
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

    # The 6px floor exists so the single >7d task — the one that drags the mean
    # away from the median — is not a 4px sliver. It must not become a floor
    # under EVERY bucket: a 6px stub over an empty bin draws a task that does
    # not exist, which is the `0.0 h` mistake in another medium.
    test "the min-height floor lifts occupied buckets only, never an empty one", %{
      conn: conn,
      project: project
    } do
      populated_cohort(project)

      {:ok, _view, html} = conn |> authenticated_conn() |> live("/control/pipeline")

      heights = bucket_min_heights(html)

      # Anti-vacuity on both sides: the fixture must actually produce an empty
      # bucket AND an occupied one, or the assertion below is about nothing.
      assert Map.fetch!(heights, {"1-4h", 0}) == "0"
      assert Map.fetch!(heights, {"&gt;7d", 1}) == "6px"

      for {{label, count}, min_height} <- heights do
        expected = if count > 0, do: "6px", else: "0"

        assert min_height == expected,
               "bucket #{label} holds #{count} tasks but renders min-height: #{min_height}"
      end
    end
  end

  # Pairs each histogram bucket's `title` (which carries its label and count)
  # with the `min-height` of the bar the code draws for it, so the floor is
  # asserted against the bucket it belongs to rather than page-wide.
  defp bucket_min_heights(html) do
    ~r/title="([^"]+): (\d+) tasks".*?min-height: ([^;"]+)/s
    |> Regex.scan(html)
    |> Map.new(fn [_, label, count, min_height] ->
      {{label, String.to_integer(count)}, String.trim(min_height)}
    end)
  end

  describe "human/engine attribution" do
    test "a build interval closed by an agent reads as engine, not human wait", %{
      conn: conn,
      project: project
    } do
      # The direction matters and is easy to invert: `human` is derived from
      # the actor who TERMINATED an interval. Every chain here is closed by
      # `agent`, so nothing on this page may claim human wait. A fixture that
      # drove its transitions through a user principal would paint the whole
      # bar as human wait and misrepresent what production shows.
      populated_cohort(project)

      {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view |> element("#phase-row-in_progress") |> render() =~ "engine"
      refute view |> element("#phase-row-in_progress") |> render() =~ "human wait"
      assert view |> element("#legend") |> render() =~ "human wait — none recorded"
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

      # Collapsed: HEEx wraps the copy across source lines, so a raw-string
      # match would assert the formatter's line breaks rather than the wording.
      note = view |> element("#sparse-distribution-note") |> render() |> squish()

      assert note =~ "3 of 3"

      # The floor is stated, not merely applied. Without this the page is
      # silently withholding a chart and a reader cannot tell whether one is
      # coming, is broken, or does not exist.
      assert note =~ "a distribution needs 20"
      assert note =~ "It appears at 20 tasks measured end to end"

      # And the bar's own note states its floor too, in the same terms.
      assert view |> element("#sparse-bar-note") |> render() |> squish() =~
               "a proportional split needs 20"

      refute has_element?(view, "#cycle-time-histogram")
      refute has_element?(view, "#phase-bar")

      # The banner says a proportional split is not meaningful yet, so the
      # page must not then print one: a legend with engine/human percentages
      # directly under that sentence contradicts it.
      refute has_element?(view, "#legend")

      # Not blank: the throughput panel and the numbers table still render.
      assert has_element?(view, "#throughput-rate")
      assert has_element?(view, "#phase-row-planning")
    end

    # Both sides, in one test, against the same fixture shape. A test that
    # only checks the sparse side passes for a floor of 20, 200 or infinity;
    # one that only checks the populated side passes for a floor of 20, 5 or
    # zero. Neither alone can detect an off-by-one, and the transition here
    # happens unattended on real data.
    test "at one below the floor the sentence renders and the chart does not; at the floor they swap",
         %{conn: conn, project: project} do
      Enum.each(1..19, &decomposable_task(project, 2 + rem(&1, 5), 4))

      {:ok, below, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view_states(below) == %{
               sparse_note: true,
               bar_note: true,
               histogram: false,
               bar: false,
               legend: false
             }

      assert below |> element("#sparse-distribution-note") |> render() =~ "19 of 19"

      # The twentieth task, and nothing else about the fixture, changes.
      decomposable_task(project, 3, 4)

      {:ok, at_floor, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

      assert view_states(at_floor) == %{
               sparse_note: false,
               bar_note: false,
               histogram: true,
               bar: true,
               legend: true
             }

      assert at_floor |> element("#exclusion-line") |> render() =~ "20 of 20"
    end
  end

  defp squish(html), do: html |> String.replace(~r/\s+/, " ") |> String.trim()

  defp view_states(view) do
    %{
      sparse_note: has_element?(view, "#sparse-distribution-note"),
      bar_note: has_element?(view, "#sparse-bar-note"),
      histogram: has_element?(view, "#cycle-time-histogram"),
      bar: has_element?(view, "#phase-bar"),
      legend: has_element?(view, "#legend")
    }
  end

  describe "in-segment labels" do
    # `36.0…` is worse than no label: it invites the reader to wonder whether
    # it means 36 minutes or 36-point-something. The rule is drop, not
    # truncate — the numbers table one row down carries the exact value.
    test "a segment too narrow for its label drops it rather than truncating", %{
      conn: conn,
      project: project
    } do
      # A cohort whose build phase dwarfs the other two: 1h plan, 200h build,
      # 1h deploy puts `deploy` at about half a percent of the bar. The
      # ordinary populated cohort has no segment narrow enough to trigger the
      # rule, so it would pass this test whatever the rule did.
      Enum.each(1..20, &decomposable_task(project, 12 + rem(&1, 5), 200))

      {:ok, view, html} = conn |> authenticated_conn() |> live("/control/pipeline")

      # Anti-vacuity: the assertion below is only meaningful if the narrow
      # segment is actually rendered and actually narrow.
      assert has_element?(view, "#phase-segment-deploying")
      deploying = view |> element("#phase-segment-deploying") |> render()

      assert [width] = Regex.run(~r/width: ([\d.]+)%/, deploying, capture: :all_but_first)
      assert String.to_float(width) < 1.0

      # The value is still reachable — in the title, and in the table row.
      assert deploying =~ "median"
      assert view |> element("#phase-median-deploying") |> render() =~ "h"

      # The label element is absent, not merely un-ellipsised. Asserting only
      # the absence of `truncate` or of `…` would stay green if the label were
      # rendered in full and overflowed out of the segment instead.
      refute deploying =~ ~r/<span[^>]*font-mono/

      # ...and the mechanism is gone as well as its symptom. Note there is no
      # point refuting a literal "…" anywhere: `truncate` is CSS
      # text-overflow, so the ellipsis never appears in the markup and such a
      # refute would be true by construction whatever the page did.
      refute deploying =~ "truncate"

      # The phase-NAME axis below keeps its truncation deliberately — a
      # clipped word is not ambiguous the way a clipped number is — so the
      # rule must not have been applied page-wide.
      assert html =~ ~r/text-\[10px\] text-base-content\/70 text-center truncate/

      # Anti-vacuity for the drop: the wide segment DOES carry a label span,
      # so a missing one is a width decision rather than the page having
      # stopped labelling segments at all.
      wide = view |> element("#phase-segment-in_progress") |> render()

      assert wide =~ ~r/<span[^>]*font-mono/
      assert wide =~ "h"
    end

    # The drop rule is scoped to engine segments on purpose. On a human-wait
    # segment the in-segment number is one of the four non-colour carriers of
    # the split — the human token is 2.55:1 against the light surface, under
    # the 3:1 floor, and may not be darkened — so dropping it there would
    # quietly weaken an accessibility mitigation instead of tidying a label.
    # Too narrow for its label is a defect to report, not to absorb.
    test "a human-wait segment keeps its label even when too narrow, and says so", %{
      conn: conn,
      project: project
    } do
      Enum.each(1..20, fn i ->
        project |> decomposable_task(12 + rem(i, 5), 200) |> close_deploy_as_human()
      end)

      log =
        capture_log(fn ->
          {:ok, view, _html} = conn |> authenticated_conn() |> live("/control/pipeline")

          # Anti-vacuity on both preconditions: the segment must actually read
          # as human wait AND actually be under the label width, or "kept the
          # label" is what an engine segment would have done anyway.
          assert view |> element("#phase-row-deploying") |> render() =~ "human wait"

          deploying = view |> element("#phase-segment-deploying") |> render()

          assert [width] = Regex.run(~r/width: ([\d.]+)%/, deploying, capture: :all_but_first)
          assert String.to_float(width) < 1.0

          assert deploying =~ ~r/<span[^>]*font-mono/
          assert deploying =~ "h"
        end)

      assert log =~ "human-wait segment deploying is too narrow for its label"
    end
  end

  # The interval's `human` flag comes from whoever CLOSED it, so the deploy
  # phase is made human by the transition that ends it, not by the one that
  # starts it.
  defp close_deploy_as_human(task) do
    {1, _} =
      PhaseTransition
      |> where([t], t.task_id == ^task.id and t.to_status == "done")
      |> Repo.update_all(set: [actor_kind: "user"])

    task
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

      assert view |> element("#exclusion-line") |> render() =~ "23 of 26"

      view |> element("form") |> render_change(%{"range" => "7"})

      # The 7d window drops the four older decomposable tasks (three at 20-22d
      # plus the week-long outlier) AND the three uninstrumented ones, so BOTH
      # numbers move.
      assert view |> element("#exclusion-line") |> render() =~ "19 of 19"
    end
  end
end
