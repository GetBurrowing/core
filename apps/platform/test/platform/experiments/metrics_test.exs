defmodule Platform.Experiments.MetricsTest do
  @moduledoc """
  The five starter metrics.

  ## Every fixture drives the real recording path

  Tasks move through `Platform.Tasks.transition_task/3`; plans are created
  and approved through `Platform.Tasks.create_plan/1` and
  `approve_plan/3`; stages and validations move through
  `transition_stage/2` and `evaluate_validation/3`. Nothing here inserts a
  `task_phase_transitions` row by hand.

  What a hand-inserted fixture would fail to catch, stated so the discipline
  survives someone in a hurry: it constructs exactly the row shape the
  metric's query already expects. The test then passes even if the
  production path never writes those rows, writes them under a different
  `to_status` vocabulary, or stops writing them altogether. The metric would
  go on returning a healthy-looking number over a table nothing populates,
  and this file would stay green through all of it.

  ## The assertion that matters most is the one about no data

  Each metric is asserted to return the bare atom `:insufficient_data` — not
  a `Result` with `value: 0.0`, not `nil`, not `n: 0`. `refute
  is_number(result)` alone would pass on a `%Result{}` too, so the
  assertions match the atom exactly.
  """

  use Platform.DataCase

  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Metrics.CycleTime
  alias Platform.Experiments.Metrics.PlanRevisionCount
  alias Platform.Experiments.Metrics.StagesPerPlan
  alias Platform.Experiments.Metrics.TimeInPhase
  alias Platform.Experiments.Metrics.ValidationFailureRate
  alias Platform.Repo
  alias Platform.Tasks

  @all_metrics [StagesPerPlan, PlanRevisionCount, ValidationFailureRate, CycleTime, TimeInPhase]

  # Long enough for every interval to be non-zero at microsecond resolution.
  @tick 15

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Metrics Project #{unique()}"})

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "metrics-#{unique()}",
        name: "Metrics Experiment",
        status: "draft"
      })

    {:ok, _control} =
      Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})

    {:ok, _treatment} =
      Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})

    %{project: project, experiment: experiment}
  end

  defp unique, do: System.unique_integer([:positive])

  defp user_fixture do
    n = unique()

    Repo.insert!(%Platform.Accounts.User{
      name: "Metrics User #{n}",
      email: "metrics-#{n}@example.com",
      oidc_sub: "metrics-sub-#{n}"
    })
  end

  defp task_fixture(project) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Metrics Task #{unique()}"})

    task
  end

  # Pins the subject into a named variant directly, so a test asserting a
  # metric is never also asserting the bucketing. `assign_once/2` would pick
  # by weight and the test would silently depend on which arm it landed in.
  defp assign(task, experiment, slug) do
    Repo.insert!(%Platform.Experiments.Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: task.id,
      variant_slug: slug,
      assigned_at: DateTime.utc_now()
    })

    task
  end

  defp validation_fixture(stage, status) do
    {:ok, validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

    case status do
      s when s in ["pending", "running"] -> validation
      resolved -> elem(Tasks.evaluate_validation(validation.id, resolved, %{}), 1)
    end
  end

  defp step(task, status) do
    Process.sleep(@tick)
    {:ok, task} = Tasks.transition_task(task, status, :system)
    task
  end

  # A task that has actually been worked: planned, approved, and moved
  # through the real status machine. `planning -> in_progress` is refused
  # without an approved plan, which is exactly the kind of constraint a
  # hand-inserted transition row would have hidden.
  defp worked_task(project, experiment, user, stages \\ 1) do
    task =
      project
      |> task_fixture()
      |> assign(experiment, "treatment")
      |> step("planning")

    plan = plan_fixture(task, user, stages)

    task =
      task
      |> Repo.reload!()
      |> then(fn t -> if t.status == "planning", do: step(t, "in_progress"), else: t end)
      |> step("done")

    {task, plan}
  end

  # A plan created and approved through the public path, so approval's
  # supersession of older siblings really happens.
  defp plan_fixture(task, user, stage_count) do
    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        title: "Plan #{unique()}",
        summary: "Metrics plan"
      })

    for position <- 1..stage_count//1 do
      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: position,
          name: "Stage #{position}",
          description: "Stage #{position} of the metrics fixture"
        })
    end

    {:ok, plan} = Tasks.submit_plan_for_review(plan)
    {:ok, plan} = Tasks.approve_plan(plan, user.id)
    plan
  end

  # An in-place draft correction, as it lands in the audit stream.
  #
  # The row shape is copied from what production actually produces, not
  # invented: `ToolSurface.emit_plan_updated/4` executes
  # `[:platform, :tasks, :plan_updated]` with `task_id` and `plan_id` in the
  # telemetry metadata, and `Audit.TelemetryHandler` joins the event name
  # with dots into `event_type` and stringifies the metadata keys into the
  # jsonb column (`build_attrs/3` + `ensure_json_safe/1`). `task_id` is NOT
  # a top-level key, so it stays inside `metadata` — which is exactly where
  # the metric reads it from.
  defp plan_updated_audit(task_id, plan_id, event_type \\ "platform.tasks.plan_updated") do
    {:ok, event} =
      Platform.Audit.record(%{
        event_type: event_type,
        actor_type: "agent",
        action: "plan_updated",
        resource_type: "plan",
        resource_id: plan_id,
        metadata: %{"task_id" => task_id, "plan_id" => plan_id}
      })

    event
  end

  describe "Metrics.subject_ids/2" do
    test "returns the variant's subjects and omits excluded ones", %{
      project: project,
      experiment: experiment
    } do
      kept = assign(task_fixture(project), experiment, "treatment")
      dropped = assign(task_fixture(project), experiment, "treatment")
      other_arm = assign(task_fixture(project), experiment, "control")

      {:ok, _} =
        Assignments.exclude(experiment, %{subject_type: "task", subject_id: dropped.id}, "flaky")

      ids = Metrics.subject_ids(experiment.id, "treatment")

      assert kept.id in ids
      refute dropped.id in ids
      refute other_arm.id in ids
      assert length(ids) == 1
    end

    test "the excluded row still exists, carrying its reason", %{
      project: project,
      experiment: experiment
    } do
      # Exclusions are recorded, never deleted. If exclusion removed the row
      # the filter above would pass for entirely the wrong reason.
      dropped = assign(task_fixture(project), experiment, "treatment")

      {:ok, _} =
        Assignments.exclude(experiment, %{subject_type: "task", subject_id: dropped.id}, "flaky")

      assert [assignment] =
               experiment
               |> Assignments.list_assignments()
               |> Enum.filter(&(&1.subject_id == dropped.id))

      assert assignment.excluded_reason == "flaky"
      assert assignment.variant_slug == "treatment"
    end
  end

  describe "no data is not zero data" do
    test "every metric returns :insufficient_data for a variant with no subjects", %{
      experiment: experiment
    } do
      for metric <- @all_metrics do
        assert metric.compute(experiment.id, "control") == :insufficient_data,
               "#{inspect(metric)} answered a variant with zero subjects"
      end
    end

    test "every metric returns :insufficient_data when subjects have no underlying rows", %{
      project: project,
      experiment: experiment
    } do
      # Subjects exist and are assigned; nothing else does. No plans, no
      # stages, no validations, no transitions.
      for _ <- 1..3, do: assign(task_fixture(project), experiment, "treatment")

      assert length(Metrics.subject_ids(experiment.id, "treatment")) == 3

      for metric <- @all_metrics do
        result = metric.compute(experiment.id, "treatment")

        assert result == :insufficient_data,
               "#{inspect(metric)} returned #{inspect(result)} over subjects with no rows"
      end
    end

    test "every metric returns :insufficient_data when its only subject is excluded", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")
      _plan = plan_fixture(task, user, 2)

      # Control: with the subject present the metric answers.
      assert {:ok, %Result{}} = StagesPerPlan.compute(experiment.id, "treatment")

      {:ok, _} =
        Assignments.exclude(experiment, %{subject_type: "task", subject_id: task.id}, "flaky")

      assert StagesPerPlan.compute(experiment.id, "treatment") == :insufficient_data
    end
  end

  describe "StagesPerPlan" do
    setup %{project: project, experiment: experiment} do
      user = user_fixture()

      a = project |> task_fixture() |> assign(experiment, "treatment")
      b = project |> task_fixture() |> assign(experiment, "treatment")
      excluded = project |> task_fixture() |> assign(experiment, "treatment")

      plan_fixture(a, user, 2)
      plan_fixture(b, user, 4)
      # Ten stages, so an unfiltered exclusion could not possibly leave the
      # expected mean intact — the wrong answer is far from the right one.
      plan_fixture(excluded, user, 10)

      {:ok, _} =
        Assignments.exclude(experiment, %{subject_type: "task", subject_id: excluded.id}, "noise")

      %{user: user}
    end

    test "means stages over plans, with n counting plans", %{experiment: experiment} do
      assert {:ok, %Result{value: value, n: n, unit: :count}} =
               StagesPerPlan.compute(experiment.id, "treatment")

      assert value == 3.0
      assert n == 2
    end

    test "the excluded subject's plan is in neither numerator nor denominator", %{
      experiment: experiment
    } do
      {:ok, %Result{value: value, n: n}} = StagesPerPlan.compute(experiment.id, "treatment")

      # With the ten-stage plan counted the mean would be 16/3 and n would be 3.
      refute n == 3
      refute_in_delta value, 16 / 3, 0.001
    end
  end

  describe "PlanRevisionCount" do
    test "means plan versions per task, with n counting tasks", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()

      one_plan = project |> task_fixture() |> assign(experiment, "treatment")
      three_plans = project |> task_fixture() |> assign(experiment, "treatment")

      plan_fixture(one_plan, user, 1)
      for _ <- 1..3, do: plan_fixture(three_plans, user, 1)

      assert {:ok, %Result{value: value, n: n, unit: :count}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 2.0
      assert n == 2
    end

    test "supersession is counted as a version, and rejection is not conflated with it", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")

      first = plan_fixture(task, user, 1)
      _second = plan_fixture(task, user, 1)

      # Approving the second superseded the first: the pointer is written on
      # the OLD plan, pointing FORWARD, and the old plan's status became
      # "rejected" — the same value a human rejection writes. Counting rows
      # is immune to that ambiguity; counting statuses would not be.
      superseded = Repo.reload!(first)
      assert superseded.status == "rejected"
      refute is_nil(superseded.superseded_by_plan_id)

      assert {:ok, %Result{value: 2.0, n: 1}} =
               PlanRevisionCount.compute(experiment.id, "treatment")
    end

    test "a task with no plans is absent from the sample rather than a zero", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()

      planned = project |> task_fixture() |> assign(experiment, "treatment")
      _unplanned = project |> task_fixture() |> assign(experiment, "treatment")

      plan_fixture(planned, user, 1)

      # Two subjects, one measurable unit. A zero for the unplanned task
      # would give value 0.5 and n 2.
      assert {:ok, %Result{value: 1.0, n: 1}} =
               PlanRevisionCount.compute(experiment.id, "treatment")
    end

    # -- In-place draft corrections (task 01a05bef) --
    #
    # Every expectation below is a hardcoded LITERAL, never derived from the
    # fixtures, from a second copy of the metric's query, or from
    # `length(audit_rows)`. An expectation computed from the same inputs the
    # metric reads cannot fail for any value the metric returns; it restates
    # the implementation and calls that a check. Nor are these ranges — a
    # `value > 1.0` would pass just as happily for a metric that counted the
    # wrong thing twice.

    test "an in-place draft correction is counted as a revision alongside the plan row", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")
      plan = plan_fixture(task, user, 1)

      plan_updated_audit(task.id, plan.id)
      plan_updated_audit(task.id, plan.id)

      # One plan row plus two in-place corrections is three revisions of one
      # task's plan. Counting rows alone — the pre-change behaviour — gives
      # 1.0 here, because `replace_plan_stages/3` deliberately reuses the
      # same plan row and never moves `version`.
      assert {:ok, %Result{value: value, n: n, unit: :count}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 3.0
      assert n == 1
    end

    test "a planned subject with no corrections still scores exactly what it always did", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")
      plan_fixture(task, user, 1)

      # The backward-compatibility guard. Every experiment number computed
      # before `plan_update` existed was computed over subjects with zero
      # `plan_updated` rows, so this case pins that the new source is purely
      # ADDITIVE: with nothing to add, the answer must be bit-for-bit the
      # old one. If this case ever moves, historical results have been
      # silently restated.
      assert {:ok, %Result{value: value, n: n}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 1.0
      assert n == 1
    end

    test "a correction for a task with no plan row cannot manufacture a unit", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()

      planned = project |> task_fixture() |> assign(experiment, "treatment")
      unplanned = project |> task_fixture() |> assign(experiment, "treatment")

      plan_fixture(planned, user, 1)
      plan_updated_audit(unplanned.id, Ecto.UUID.generate())

      # `n` counts TASKS THAT HAVE A PLAN, and the combine is keyed on the
      # plan map for exactly this reason. Keying on the UNION of the plan
      # and correction maps would admit `unplanned` as a unit worth 1, and
      # this would read value 1.0 with n 2 — the same value, a different
      # sample. That is why `n` is asserted as a literal here and not left
      # implicit: the value alone does not distinguish the two behaviours.
      assert {:ok, %Result{value: value, n: n}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 1.0
      assert n == 1
    end

    test "a correction on a task outside the variant does not contribute", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()

      subject = project |> task_fixture() |> assign(experiment, "treatment")
      outsider = project |> task_fixture() |> assign(experiment, "control")

      plan_fixture(subject, user, 1)
      outsider_plan = plan_fixture(outsider, user, 1)

      # A real, well-formed correction — on a task belonging to the OTHER
      # arm. If the audit query were not filtered by subject id, the control
      # arm's re-planning would be attributed to treatment.
      plan_updated_audit(outsider.id, outsider_plan.id)

      assert {:ok, %Result{value: value, n: n}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 1.0
      assert n == 1
    end

    test "a plan_rejected audit row is not counted as an in-place correction", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")
      plan = plan_fixture(task, user, 1)

      # Same task, same plan, different event. A rejection is a DISCARD, and
      # a discard is followed by a fresh plan ROW that `plan_counts/1`
      # already counts. Counting the rejection event as well would charge one
      # re-plan twice. Only `plan_updated` denotes the correction that leaves
      # no row behind, so only `plan_updated` may be added.
      plan_updated_audit(task.id, plan.id, "platform.tasks.plan_rejected")

      assert {:ok, %Result{value: value, n: n}} =
               PlanRevisionCount.compute(experiment.id, "treatment")

      assert value == 1.0
      assert n == 1
    end
  end

  describe "ValidationFailureRate" do
    setup %{project: project, experiment: experiment} do
      user = user_fixture()
      task = project |> task_fixture() |> assign(experiment, "treatment")
      plan = plan_fixture(task, user, 1)
      [stage] = Tasks.list_stages(plan.id)

      %{stage: stage, task: task, user: user}
    end

    test "is failed over resolved, with n counting resolved validations", %{
      experiment: experiment,
      stage: stage
    } do
      validation_fixture(stage, "failed")
      validation_fixture(stage, "passed")
      validation_fixture(stage, "passed")
      validation_fixture(stage, "passed")

      assert {:ok, %Result{value: value, n: 4, unit: :ratio}} =
               ValidationFailureRate.compute(experiment.id, "treatment")

      assert value == 0.25
    end

    test "pending and running leave BOTH sides of the ratio", %{
      experiment: experiment,
      stage: stage
    } do
      validation_fixture(stage, "failed")
      validation_fixture(stage, "passed")
      validation_fixture(stage, "pending")
      validation_fixture(stage, "pending")
      validation_fixture(stage, "pending")

      assert {:ok, %Result{value: value, n: n}} =
               ValidationFailureRate.compute(experiment.id, "treatment")

      # Counted as passes the rate would be 0.2 over n 5 — a lower failure
      # rate for a variant that has merely been evaluated more slowly.
      assert value == 0.5
      assert n == 2
    end

    test "only-pending validations are :insufficient_data, not 0.0", %{
      experiment: experiment,
      stage: stage
    } do
      validation_fixture(stage, "pending")
      validation_fixture(stage, "pending")

      result = ValidationFailureRate.compute(experiment.id, "treatment")

      assert result == :insufficient_data
      refute match?({:ok, %Result{value: +0.0}}, result)
    end
  end

  describe "CycleTime" do
    test "means measured seconds per task, with n counting tasks", %{
      project: project,
      experiment: experiment
    } do
      {task, _plan} = worked_task(project, experiment, user_fixture())

      never_moved = project |> task_fixture() |> assign(experiment, "treatment")

      assert {:ok, %Result{value: value, n: n, unit: :seconds}} =
               CycleTime.compute(experiment.id, "treatment")

      # Only the moved task is a unit; the untouched one decomposes to
      # phases: %{} and is excluded rather than counted as zero seconds.
      assert n == 1
      assert value > 0.0

      {:ok, decomposition} = Platform.Tasks.PhaseTransitions.decompose(task.id)
      assert decomposition.phases != %{}
      {:ok, %{phases: %{}}} = Platform.Tasks.PhaseTransitions.decompose(never_moved.id)
    end

    test "a task with no transition rows is excluded, so an all-empty set is insufficient", %{
      project: project,
      experiment: experiment
    } do
      for _ <- 1..3, do: assign(task_fixture(project), experiment, "treatment")

      assert CycleTime.compute(experiment.id, "treatment") == :insufficient_data
    end
  end

  describe "TimeInPhase" do
    setup %{project: project, experiment: experiment} do
      {task, _plan} = worked_task(project, experiment, user_fixture())

      %{task: task}
    end

    test "means closed seconds in the named phase", %{experiment: experiment, task: task} do
      {:ok, decomposition} = Platform.Tasks.PhaseTransitions.decompose(task.id)

      # Anti-vacuity: the phase must actually be present in the fixture, or
      # the assertion below would be about a metric that never ran.
      assert %{total_seconds: expected, open?: false} = decomposition.phases["planning"]

      assert {:ok, %Result{value: value, n: 1, unit: :seconds}} =
               TimeInPhase.compute(experiment.id, "treatment", "planning")

      assert_in_delta value, expected, 0.001
    end

    test "an ABSENT phase is :insufficient_data, never 0.0", %{
      experiment: experiment,
      task: task
    } do
      {:ok, decomposition} = Platform.Tasks.PhaseTransitions.decompose(task.id)

      # The fixture must genuinely lack this phase, or the test asserts
      # nothing about absence.
      refute Map.has_key?(decomposition.phases, "in_review")

      result = TimeInPhase.compute(experiment.id, "treatment", "in_review")

      assert result == :insufficient_data
      refute match?({:ok, %Result{value: +0.0}}, result)
      refute is_number(result)
    end

    test "a task missing the phase leaves the sample without dragging the mean", %{
      project: project,
      experiment: experiment,
      task: task
    } do
      # A second subject that never entered "planning" at all. It has real,
      # closed measured time in other phases, so it is a subject the metric
      # could plausibly have counted — which is what makes its absence from
      # this phase's sample a meaningful assertion rather than an artifact
      # of the task having no data at all.
      project
      |> task_fixture()
      |> assign(experiment, "treatment")
      |> step("blocked")
      |> step("cancelled")

      {:ok, decomposition} = Platform.Tasks.PhaseTransitions.decompose(task.id)
      expected = decomposition.phases["planning"].total_seconds

      assert {:ok, %Result{value: value, n: 1}} =
               TimeInPhase.compute(experiment.id, "treatment", "planning")

      # Treated as a zero the mean would halve and n would be 2.
      assert_in_delta value, expected, 0.001
    end
  end

  describe "the Result contract" do
    test "every successful return is a %Result{} with a positive integer n", %{
      project: project,
      experiment: experiment
    } do
      user = user_fixture()

      {_task, plan} = worked_task(project, experiment, user, 2)
      [stage | _] = Tasks.list_stages(plan.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      {:ok, _} = Tasks.evaluate_validation(validation.id, "passed", %{})

      for metric <- @all_metrics do
        assert {:ok, %Result{value: value, n: n, unit: unit}} =
                 metric.compute(experiment.id, "treatment"),
               "#{inspect(metric)} did not return a Result over a populated fixture"

        assert is_float(value), "#{inspect(metric)} returned a non-float value"
        assert is_integer(n) and n > 0, "#{inspect(metric)} returned n=#{inspect(n)}"
        assert is_atom(unit) and not is_nil(unit)
      end
    end

    test "no metric can return a bare number" do
      # The struct enforces its keys, so a Result without n cannot be built
      # at all — the rule is structural, not a convention.
      assert_raise ArgumentError, fn ->
        struct!(Result, value: 1.0, unit: :count)
      end
    end
  end
end
