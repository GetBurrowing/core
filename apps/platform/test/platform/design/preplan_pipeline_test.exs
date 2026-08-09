defmodule Platform.Design.PreplanPipelineTest do
  @moduledoc """
  Parts B and C (designer half) of task 019fe1b7 stage 4 — the designer's HOLD,
  its RELEASE and its EXPIRY still behave as they did before the migration,
  asserted with the gate NOT FIRST in its pipeline.

  The architect half of B and C is already pinned by
  `Platform.Tasks.ArchitectGatePipelineTest` with the same non-zero-position
  fixture and two mutants; this file is the designer's equivalent rather than
  a copy of it, because the two steps hold by DIFFERENT mechanisms and the
  distinction is the finding:

    * the architect gate can DIVERT — `:reject` halts the pipeline;
    * the designer NEVER diverts. `Platform.Design.PreplanLifecycleStep.start/2`
      has no `{:diverted, _}` branch at all. Its hold is the AWAIT: the
      pipeline blocks at the step until something outside closes the cursor,
      and design FAILS OPEN in every direction, so even an expiry lets the
      remaining steps run.

  A test that asserted "the designer diverts" would therefore be asserting a
  behaviour that has never existed, and it would pass against an
  implementation that diverted on every design step — which would strand
  every planner in the system.

  ## How "it held" is proved

  Not by a refute. `ran/0` lives in the executor's process dictionary and
  cannot be read mid-flight, so "probe_after had not run yet" is not
  observable from here. What IS observable is TIME: if the pipeline had not
  blocked at the design step, the edge would have returned before the closing
  signal was sent. So each hold case measures elapsed wall time against the
  moment the release was scheduled, and asserts the edge outcome could only
  have been produced by a run that waited.

  ## Positive controls

  Every "did not proceed" assertion in this file is paired, in the SAME run,
  with `"probe_before" in ran()`. Without it an implementation whose pipeline
  runs nothing at all satisfies every negative assertion here. It is stated as
  membership rather than as the order list for the reason
  `ArchitectGatePipelineTest` documents: a mutant that lets the wrong step run
  should detonate on the assertion that NAMES the defect, not on the control
  with a misleading message.

  `async: false` is load-bearing — `:lifecycle_step_registry` is VM-global,
  and the step's watcher runs in a spawned process that needs the sandbox
  connection.
  """
  use Platform.DataCase, async: false

  alias Platform.Design.PreplanLifecycleStep
  alias Platform.Design.PreplanStep
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.Executor
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  # A title the UI heuristic classifies as UI-touching, so `PreplanStep.start/1`
  # actually OPENS the step. A non-UI title resolves inline to
  # `:not_applicable` and there is no hold to test — the fixture would be
  # vacuous in exactly the way this stage is written against.
  @ui_title "Add an epic-create FAB above the kanban board"

  # MILLISECONDS, injected on the run rather than configured globally. A
  # test-only value that leaked into production config is the failure mode
  # this stack is written against.
  @step_budget_ms 400
  @edge_budget_ms 8_000

  # Long enough that a pipeline which did NOT block would certainly have
  # returned first; short enough to keep the case fast.
  @release_after_ms 150

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    previous_poll = Application.get_env(:platform, :design_settle_poll_ms)
    Application.put_env(:platform, :design_settle_poll_ms, 25)

    registry_name = :"design_pipeline_registry_#{u()}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

    before = Application.fetch_env(:platform, :lifecycle_step_registry)
    Application.put_env(:platform, :lifecycle_step_registry, registry_name)

    on_exit(fn ->
      case previous_poll do
        nil -> Application.delete_env(:platform, :design_settle_poll_ms)
        value -> Application.put_env(:platform, :design_settle_poll_ms, value)
      end

      case before do
        :error -> Application.delete_env(:platform, :lifecycle_step_registry)
        {:ok, value} -> Application.put_env(:platform, :lifecycle_step_registry, value)
      end
    end)

    # Two DISTINCT names so the order list can tell "before" from "after".
    for name <- ["probe_before", "probe_after"] do
      :ok =
        StepRegistry.register(
          %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
          registry_name
        )
    end

    # THE DESIGNER MUST BE FILLED, or `PreplanStep.start/1` answers
    # `:not_applicable` with reason `"no_designer"`, the step never opens, and
    # every hold assertion in this file becomes a statement about a step that
    # resolved inline. The anti-vacuity guard in the first describe block is
    # what catches this if the recipe ever rots.
    fill_designer_responsibility!()

    {:ok, project} = Tasks.create_project(%{name: "Design Pipeline #{u()}"})

    %{registry: registry_name, project: project}
  end

  @doc false
  def noop_dispatch(_signal), do: :ok

  defp fill_designer_responsibility! do
    [spec] = Platform.Responsibilities.Handlers.DesignTaskDirection.register()
    {:ok, _row} = Platform.Responsibilities.upsert_by_key(spec)

    Repo.insert!(
      %Platform.Roles.Role{
        key: "historian",
        name: "Historian",
        description: "test",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: "design.task_direction"
    })
    |> Repo.insert!()

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "design-pipeline-#{u()}",
        name: "Fixture Designer",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Platform.Roles.assign_role("historian", agent.id)

    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {__MODULE__, :noop_dispatch}
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        value -> Application.put_env(:platform, :responsibility_router_native_dispatcher, value)
      end
    end)
  end

  defp u, do: System.unique_integer([:positive])

  defp ui_task(project) do
    Repo.insert!(%Task{
      project_id: project.id,
      title: @ui_title,
      description: @ui_title,
      status: "planning"
    })
  end

  defp probe(name), do: %{"step" => name, "await" => true, "can_divert" => false}

  defp design_step do
    %{"step" => Edges.designer_step_name(), "await" => true, "can_divert" => true}
  end

  defp ran, do: TestSteps.Sync.ran()

  defp reload(task), do: Repo.get!(Task, task.id)

  # Runs the full three-step pipeline with the design step at POSITION 1 and
  # returns `{outcome, summary, elapsed_ms}`. The fire is chatty; the log is
  # not the subject.
  defp run_held(task, opts \\ []) do
    steps =
      Keyword.get(opts, :steps, [probe("probe_before"), design_step(), probe("probe_after")])

    {result, _log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        started = System.monotonic_time(:millisecond)

        {outcome, summary} =
          Executor.run_edge(task, Edges.designer_edge(),
            steps: steps,
            step_timeout_ms: Keyword.get(opts, :step_timeout_ms, @step_budget_ms),
            edge_budget_ms: @edge_budget_ms
          )

        {outcome, summary, System.monotonic_time(:millisecond) - started}
      end)

    result
  end

  # Schedules a closing signal `@release_after_ms` into the future, so the
  # elapsed-time assertion has something to compare against. The closer runs
  # in its own process against the shared sandbox connection.
  defp release_after(fun) do
    parent = self()

    spawn(fn ->
      Process.sleep(@release_after_ms)
      fun.()
      send(parent, :released)
    end)

    :ok
  end

  defp design_row(summary),
    do: Enum.find(summary.steps, &(&1.step == Edges.designer_step_name()))

  describe "the fixture actually opens a design step" do
    # ANTI-VACUITY PRECONDITION for every hold case below. If the heuristic
    # ever stops classifying this title as UI-touching, `PreplanStep.start/1`
    # answers `:not_applicable`, the step resolves inline, and every "it held"
    # assertion in this file becomes a statement about a step that never
    # waited for anything.
    test "the UI-titled fixture opens the cursor rather than resolving inline",
         %{project: project} do
      task = ui_task(project)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, opened} = PreplanStep.start(task)
        assert opened in [:open, :already_open]
      end)

      assert PreplanStep.open?(reload(task))
      assert reload(task).planning_step == "designing"
    end

    test "the designer step declares no divert branch at all" do
      # BEHAVIOURAL, not a grep for an absent function name. Every thing
      # `PreplanStep.start/1` can answer is exercised in
      # `PreplanLifecycleStepTest`; what matters here is that the step
      # declares `:async` and that the executor's divert path is therefore
      # unreachable for it. A designer that diverted would strand planners.
      assert PreplanLifecycleStep.kind() == :async
    end
  end

  describe "the hold, with the design step NOT first" do
    test "the pipeline BLOCKS at the design step until a settle closes it, then continues",
         %{project: project} do
      task = ui_task(project)

      release_after(fn -> PreplanStep.settle(task.id) end)

      {outcome, summary, elapsed_ms} = run_held(task)

      # POSITIVE CONTROL, deliberately weak (membership): without it, the
      # order assertion below is also satisfied by a pipeline that never
      # started.
      assert "probe_before" in ran(),
             "the probe ahead of the design step must have run — otherwise every " <>
               "assertion in this case is vacuous"

      # THE HOLD. A pipeline that did not block at the design step would have
      # returned before the closer even woke up.
      assert elapsed_ms >= @release_after_ms,
             "the edge returned in #{elapsed_ms}ms, before the settle at " <>
               "#{@release_after_ms}ms — the planner was NOT held at the design step"

      # THE RELEASE, as an explicit ORDER LIST. Set membership would be
      # satisfied by any sequence.
      assert outcome == :complete
      assert ran() == ["probe_before", "probe_after"]
      assert summary.not_run == []

      row = design_row(summary)
      assert row.position == 1, "the discriminating fixture requires a non-zero position"
      assert row.status == "completed"
      refute row.halts

      # The closing write still belongs to `PreplanStep`, not to the step
      # adapter: the outcome is on the task where it always was.
      assert PreplanStep.persisted_outcome(reload(task)) == :complete
      refute PreplanStep.open?(reload(task))
    end

    test "a DECLINE closes the hold too, and it is not_applicable rather than failed",
         %{project: project} do
      task = ui_task(project)

      release_after(fn -> PreplanStep.decline(task.id, "no design needed for this one") end)

      {outcome, summary, elapsed_ms} = run_held(task)

      assert "probe_before" in ran()
      assert elapsed_ms >= @release_after_ms

      assert outcome == :complete
      assert ran() == ["probe_before", "probe_after"]

      row = design_row(summary)
      assert row.position == 1
      assert row.status == "completed"

      # THE DISTINCTION THAT MATTERS, and the one ADR-0046 exists to keep: a
      # decline is "the hook ran and there was nothing to do", NOT "the hook
      # is broken". A fixture that only checked the pipeline continued could
      # not tell these apart — both continue.
      assert PreplanStep.persisted_outcome(reload(task)) == :not_applicable
      assert Edges.run_outcome(row.status) == "complete"
    end
  end

  describe "expiry on the per-step budget, injected in milliseconds" do
    test "an unclosed design step times out on its own budget and the run records failed",
         %{project: project} do
      task = ui_task(project)

      # No release is scheduled. The BUDGET is the only thing that can end
      # this wait — which is the property `Platform.Lifecycle.Step` requires
      # and the reason the support async step never settles by default.
      {outcome, summary, elapsed_ms} = run_held(task)

      assert "probe_before" in ran()

      assert elapsed_ms >= @step_budget_ms,
             "the edge returned in #{elapsed_ms}ms, faster than the #{@step_budget_ms}ms " <>
               "budget — something other than the budget ended the wait"

      row = design_row(summary)
      assert row.position == 1
      assert row.status == "timed_out"

      # WHICH budget expired is the whole point. The STEP budget was binding,
      # not the edge's, so this is not an edge kill.
      assert row.reason == "step_budget"
      refute row.halts

      # DESIGN FAILS OPEN. The step overran, and the pipeline still ran the
      # rest — asserted as an order list, so a halt would be caught here.
      assert ran() == ["probe_before", "probe_after"]
      assert summary.not_run == []
      assert outcome == :failed

      # And the translation into the planning-step vocabulary, read from the
      # persisted run status rather than restated.
      assert Edges.run_outcome(row.status) == "failed"
    end

    test "POSITIVE CONTROL: the same fixture with the same budget COMPLETES when closed in time",
         %{project: project} do
      # Without this, the timeout case above is also satisfied by an
      # implementation whose design step can never complete at all. Every
      # variable but the closing signal is identical.
      task = ui_task(project)

      release_after(fn -> PreplanStep.settle(task.id) end)

      {outcome, summary, _elapsed} = run_held(task)

      assert outcome == :complete
      assert design_row(summary).status == "completed"
      assert design_row(summary).reason == nil
    end

    test "the cursor left open when the edge is over is expired by PreplanStep, not stranded",
         %{project: project} do
      # The router's `close_open_step/1` posture, asserted at its own seam:
      # a bounded wait still leaves the cursor at `"designing"`, and a task
      # stuck there is held forever by the restart half of the hold
      # predicate. `PreplanStep.expire/2` is what closes it.
      task = ui_task(project)

      {_outcome, _summary, _elapsed} = run_held(task)

      # PRESENCE HALF: the step really is still open after the timeout, so
      # the expiry below is acting on a real state and not a no-op.
      assert PreplanStep.open?(reload(task)),
             "the step closed itself on timeout — the expiry assertion below " <>
               "would be vacuous"

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = PreplanStep.expire(reload(task), 1_000)
      end)

      refute PreplanStep.open?(reload(task))
      assert PreplanStep.persisted_outcome(reload(task)) == :failed

      assert reload(task).planning_step_outcomes["design"]["reason"] ==
               PreplanStep.reasons().timeout
    end
  end

  describe "the declaration and the run rows" do
    test "the designer edge ships a step, so an unconfigured project keeps its designer" do
      # A config-driven migration answers `[]` here, reports `:not_applicable`,
      # releases the planner and deletes the feature it migrates — with a
      # fully green suite. This asserts the shipped declaration verbatim.
      assert Edges.default_steps(Edges.designer_edge()) == [
               %{"step" => "design_preplan", "await" => true, "can_divert" => true}
             ]
    end

    test "the step name resolves through the registry allowlist and nowhere else",
         %{registry: registry} do
      assert {:ok, entry} = StepRegistry.fetch(Edges.designer_step_name(), registry)
      assert entry.mfa == {PreplanLifecycleStep, :start, 1}
    end

    test "the edge writes a row naming the dispatch-tick edge", %{project: project} do
      task = ui_task(project)

      release_after(fn -> PreplanStep.settle(task.id) end)
      {_outcome, _summary, _elapsed} = run_held(task)

      rows = Runs.for_edge(task.id, Edges.designer_edge())
      row = Enum.find(rows, &(&1.step_name == Edges.designer_step_name()))

      assert row.edge == "planning.design_requested"
      assert row.awaited
      assert row.can_divert
      assert row.position == 1
    end
  end
end
