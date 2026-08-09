defmodule Platform.Tasks.ArchitectGatePipelineTest do
  @moduledoc """
  ADR-0046 Amendment 1, task 019fe1b7 stage 3 — the architecture gate as a
  declared lifecycle pipeline step.

  ## The regression that matters is the DIVERT, and the gate is not first

  The whole point of `can_divert` being a DECLARATION is that authority does
  not come from position. A divert test with the gate at index 0 cannot
  discriminate: a positional implementation ("only the first step may halt")
  and the declared implementation give the SAME answer there, so the fixture
  separates nothing. Every divert case below therefore puts a no-op probe
  AHEAD of the gate and a second probe AFTER it, and asserts:

    * the probe before it RAN — the positive control, without which
      "the probe after did not run" is satisfied by a pipeline that never
      fired at all;
    * the gate diverted from index 1;
    * the probe after it did NOT run, asserted as an explicit ORDER LIST
      rather than set membership.

  The pair `diverts from index 1 when declared` / `does not divert from
  index 1 when not declared` is what actually separates the two rules: a
  positional implementation fails the first, and a
  "divert-whenever-the-step-says-so" implementation that ignores the
  declaration fails the second.
  """
  # `async: false` is load-bearing for the same reason as
  # `Platform.Lifecycle.ExecutorTest`: `:lifecycle_step_registry` is VM-global.
  use Platform.DataCase, async: false

  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.Executor
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ArchitectGateLifecycleStep
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task

  @architect_step "architect_gate"

  setup do
    registry_name = :"architect_gate_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

    before = Application.fetch_env(:platform, :lifecycle_step_registry)
    Application.put_env(:platform, :lifecycle_step_registry, registry_name)

    on_exit(fn ->
      case before do
        :error -> Application.delete_env(:platform, :lifecycle_step_registry)
        {:ok, value} -> Application.put_env(:platform, :lifecycle_step_registry, value)
      end
    end)

    # Two DISTINCT registry names for the probes so the order list below can
    # tell "before" from "after". Both resolve to the same support module.
    for name <- ["probe_before", "probe_after"] do
      :ok =
        StepRegistry.register(
          %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
          registry_name
        )
    end

    {:ok, project} = Tasks.create_project(%{name: "Architect Gate Pipeline #{u()}"})

    task =
      Repo.insert!(%Task{project_id: project.id, title: "Gate subject", status: "planning"})

    %{registry: registry_name, project: project, task: task}
  end

  defp u, do: System.unique_integer([:positive])

  defp gated_plan(task, state) do
    plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "pending_review"})
    {:ok, opened} = Tasks.open_architecture_gate(plan)

    case state do
      :pending ->
        opened

      terminal ->
        {:ok, resolved} =
          Tasks.record_architecture_verdict(opened, %{"state" => terminal}, source: "mcp")

        resolved
    end
  end

  defp probe(name), do: %{"step" => name, "await" => true, "can_divert" => false}

  defp gate(opts \\ []) do
    %{
      "step" => @architect_step,
      "await" => true,
      "can_divert" => Keyword.get(opts, :can_divert, true)
    }
  end

  defp ran, do: TestSteps.Sync.ran()

  defp run(task, steps) do
    Executor.run_edge(task, Edges.architect_edge(),
      steps: steps,
      step_timeout_ms: 200,
      edge_budget_ms: 2_000
    )
  end

  describe "the divert, with the gate NOT first" do
    test "a rejected verdict diverts from index 1 and halts the step after it",
         %{task: task} do
      _plan = gated_plan(task, "rejected")

      {outcome, summary} =
        run(task, [probe("probe_before"), gate(), probe("probe_after")])

      # POSITIVE CONTROL, and DELIBERATELY WEAK — membership, not the order
      # list. Without it, "probe_after did not run" is also true of a
      # pipeline that never started. Stated as `in` rather than `==` so that
      # a mutant which lets probe_after run detonates on the DIVERT
      # assertion below, which names what actually broke, instead of here.
      assert "probe_before" in ran(),
             "the probe ahead of the gate must have run — otherwise the " <>
               "halt assertion below is vacuous"

      assert outcome == :diverted,
             "the gate at index 1 did not divert — divert authority is being " <>
               "taken from position rather than from the declaration"

      # ORDER, as an explicit list. Set membership would be satisfied by a
      # pipeline that ran the steps in any sequence.
      assert ran() == ["probe_before"]
      assert Enum.map(summary.steps, & &1.step) == ["probe_before", @architect_step]
      assert summary.not_run == ["probe_after"]

      gate_row = Enum.find(summary.steps, &(&1.step == @architect_step))
      assert gate_row.position == 1, "the discriminating fixture requires a non-zero position"
      assert gate_row.status == "diverted"
      assert gate_row.halts
    end

    test "the SAME rejected verdict at the SAME position does NOT divert when the " <>
           "declaration withholds the authority",
         %{task: task} do
      _plan = gated_plan(task, "rejected")

      {outcome, summary} =
        run(task, [
          probe("probe_before"),
          gate(can_divert: false),
          probe("probe_after")
        ])

      # This is the half of the pair that a "the step decides" implementation
      # fails. Everything else about the fixture is identical to the case
      # above; only the DECLARATION differs, so the declaration is the only
      # thing the difference in outcome can be attributed to.
      assert ran() == ["probe_before", "probe_after"]
      assert outcome == :complete
      assert summary.not_run == []

      gate_row = Enum.find(summary.steps, &(&1.step == @architect_step))
      assert gate_row.position == 1
      assert gate_row.divert_ignored
      assert gate_row.status == "completed"
    end
  end

  describe "settlement outcomes" do
    test "a passed verdict completes and the pipeline continues", %{task: task} do
      _plan = gated_plan(task, "passed")

      {outcome, summary} = run(task, [probe("probe_before"), gate(), probe("probe_after")])

      assert ran() == ["probe_before", "probe_after"]
      assert outcome == :complete

      assert Enum.map(summary.steps, & &1.step) == [
               "probe_before",
               @architect_step,
               "probe_after"
             ]
    end

    test "an expired verdict FAILS the run while the plan itself falls open", %{task: task} do
      plan = gated_plan(task, "expired")

      {outcome, summary} = run(task, [gate()])

      assert outcome == :failed
      assert [%{status: "failed", reason: reason}] = summary.steps
      assert reason =~ "expired"

      # The plan is NOT held: `:expired` falls open by design. The run
      # records that the hook did not do its job; the two are different facts.
      refute Tasks.architecture_gate_open?(plan.id)
    end

    test "a submission with no gate at all is not_applicable, not failed", %{task: task} do
      Repo.insert!(%Plan{task_id: task.id, version: 1, status: "pending_review"})

      {outcome, summary} = run(task, [gate()])

      assert outcome == :complete
      assert [%{status: "completed"}] = summary.steps
    end

    test "an OPEN gate is awaited and times out on the step budget rather than " <>
           "resolving itself",
         %{task: task} do
      plan = gated_plan(task, :pending)

      {outcome, summary} = run(task, [gate()])

      assert outcome == :failed
      assert [%{status: "timed_out"}] = summary.steps

      # THE STEP MUST NOT HAVE RESOLVED THE GATE. Re-entering
      # `resolve_architecture_gate/3` from an observer is the double-approval
      # defect; the gate is still open and still pending.
      assert Tasks.architecture_gate_open?(plan.id)
      assert %{"state" => "pending"} = Repo.get(Plan, plan.id).architecture_verdict
    end
  end

  describe "the declaration and the registry" do
    test "the architect edge ships a step, so an unconfigured project does not " <>
           "silently lose the gate" do
      steps = Edges.default_steps(Edges.architect_edge())

      # A config-driven migration answers `[]` here, reports `:not_applicable`
      # and deletes the feature it migrates. The shipped default is what stops
      # that, and this asserts the declaration verbatim.
      assert steps == [
               %{"step" => "architect_gate", "await" => true, "can_divert" => true}
             ]
    end

    test "the step name resolves through the registry allowlist and nowhere else", %{
      registry: registry
    } do
      # Registered from the SHIPPED built-ins, not by this test's setup.
      assert {:ok, entry} = StepRegistry.fetch(@architect_step, registry)
      assert entry.mfa == {ArchitectGateLifecycleStep, :start, 1}
    end

    test "the step declares itself async, because a gate resolves out of band" do
      assert ArchitectGateLifecycleStep.kind() == :async
    end
  end

  describe "run rows" do
    test "the edge writes a row naming the plan-submission edge", %{task: task} do
      _plan = gated_plan(task, "passed")

      {_outcome, _summary} = run(task, [gate()])

      assert [row] = Runs.for_edge(task.id, Edges.architect_edge())
      assert row.edge == "plan.review_requested"
      assert row.step_name == @architect_step
      assert row.awaited
      assert row.can_divert
    end
  end
end
