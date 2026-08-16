defmodule Platform.Experiments.Metrics.OverscopedGateCountTest do
  @moduledoc """
  `OverscopedGateCount` — mean number of manual_approval gates sitting on
  stages that name no UI surface, per plan. Task 01a00c96.

  ## Both sides, always

  A module that counted EVERY manual_approval regardless of the stage
  description would satisfy the non-UI case and nothing else. So the UI case
  is asserted separately and pinned to `0.0`, and the fixture string it uses
  is fed to `PlanEngine.ui_touching?/1` directly — if the token list ever
  stops recognising that string, this file fails loudly at the predicate
  rather than quietly agreeing with a metric that has stopped discriminating.
  The non-UI fixture gets the mirror-image check for the same reason.

  ## `n` is asserted, not only `value`

  `n` counts PLANS. It is the only observable that separates "a plan was
  skipped by the query" from "a plan counted zero" — both of which can push
  `value` in the same plausible direction. Every case here pins it.

  ## Two causes of `:insufficient_data`, never merged

  No subjects and subjects-without-plans are distinct failures with the same
  answer, and a single test that accepts either cannot tell them apart. They
  are separate tests. Neither may return `{:ok, %Result{value: 0.0}}` — that
  would report "these plans are clean" about plans that do not exist.

  ## Fixtures go through the Tasks API

  Plans, stages and validations are built with `Tasks.create_plan/1`,
  `create_stage/1` and `create_validation/1`, the same calls production
  uses. Hand-inserting the exact row shape the metric's join expects would
  keep this file green even if nothing ever wrote that shape.
  """

  use Platform.DataCase

  alias Platform.Experiments
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Metrics.OverscopedGateCount
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  # A description carrying a token `PlanEngine.ui_touching?/1` recognises.
  @ui_description "Update apps/platform/lib/platform_web/live/tasks_live.html.heex " <>
                    "so the gate renders"

  # A description carrying none of them.
  @non_ui_description "Add a context function and its tests"

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Overscoped Project #{unique()}"})

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "overscoped-#{unique()}",
        name: "Overscoped Experiment",
        status: "draft"
      })

    {:ok, _control} =
      Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})

    {:ok, _treatment} =
      Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})

    %{project: project, experiment: experiment}
  end

  defp unique, do: System.unique_integer([:positive])

  # Pins the subject into a named variant, so a test asserting a mean is not
  # also asserting the bucketing.
  defp subject(project, experiment, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Overscoped Task #{unique()}"})

    Repo.insert!(%Platform.Experiments.Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: task.id,
      variant_slug: "treatment",
      assigned_at: DateTime.utc_now(),
      excluded_reason: Keyword.get(opts, :excluded_reason)
    })

    task
  end

  # One plan on `task` carrying one stage per entry in `stages`. Each entry is
  # `{description, gate?}` — `gate?` decides whether the stage gets a
  # manual_approval validation at all, which is what the no-gate control needs.
  defp plan_with(task, stages) do
    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        title: "Plan #{unique()}",
        summary: "Overscoped gate fixture"
      })

    for {{description, gate?}, position} <- Enum.with_index(stages, 1) do
      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: position,
          name: "Stage #{position}",
          description: description
        })

      if gate? do
        {:ok, _validation} =
          Tasks.create_validation(%{
            stage_id: stage.id,
            kind: "manual_approval",
            status: "pending"
          })
      end
    end

    plan
  end

  defp compute(experiment), do: OverscopedGateCount.compute(experiment.id, "treatment")

  describe "the fixture descriptions are what this file claims they are" do
    # Anti-vacuity for both sides below. If a token-list edit reclassifies
    # either string, every value assertion in this file silently swaps its
    # meaning; these two make that a loud failure at the predicate instead.
    test "the UI fixture string IS ui_touching" do
      assert PlanEngine.ui_touching?(@ui_description)
    end

    test "the non-UI fixture string is NOT ui_touching" do
      refute PlanEngine.ui_touching?(@non_ui_description)
    end
  end

  describe "compute/2" do
    test "a gate on a stage naming no UI surface counts", ctx do
      task = subject(ctx.project, ctx.experiment)
      plan_with(task, [{@non_ui_description, true}])

      assert {:ok, %Result{value: 1.0, n: 1, unit: :count}} = compute(ctx.experiment)
    end

    test "a gate on a UI-touching stage does NOT count", ctx do
      task = subject(ctx.project, ctx.experiment)
      plan_with(task, [{@ui_description, true}])

      # A count-everything metric reports 1.0 here. `n` still 1: the plan was
      # measured and found clean, it was not skipped.
      assert {:ok, %Result{value: +0.0, n: 1, unit: :count}} = compute(ctx.experiment)
    end

    test "a plan with no manual_approval at all is a real zero, not an error", ctx do
      task = subject(ctx.project, ctx.experiment)
      plan_with(task, [{@non_ui_description, false}])

      # The common case. Without this, "refuses to count anything" and "counts
      # correctly" produce the same evidence.
      assert {:ok, %Result{value: +0.0, n: 1, unit: :count}} = compute(ctx.experiment)
    end

    test "one overscoped plan and one clean plan average to 0.5 over n 2", ctx do
      overscoped = subject(ctx.project, ctx.experiment)
      plan_with(overscoped, [{@non_ui_description, true}])

      clean = subject(ctx.project, ctx.experiment)
      plan_with(clean, [{@ui_description, true}])

      # `n` is asserted because a metric that dropped the clean plan entirely
      # would report value 1.0 with n 1 — and a metric that dropped the
      # overscoped one would report 0.0 with n 1. Only n separates those from
      # a genuine two-plan mean.
      assert {:ok, %Result{value: value, n: 2, unit: :count}} = compute(ctx.experiment)
      assert value == 0.5
    end

    test "a variant with no assigned subjects is :insufficient_data", ctx do
      # Cause one. The atom exactly: 0.0 would report clean plans for an arm
      # holding no subjects.
      assert compute(ctx.experiment) == :insufficient_data
    end

    test "assigned subjects that have NO plans is :insufficient_data", ctx do
      subject(ctx.project, ctx.experiment)
      subject(ctx.project, ctx.experiment)

      # Cause two, and a DIFFERENT bug from cause one — here the subject query
      # worked and the plan query came back empty. Asserted separately because
      # a test accepting either answer cannot tell which path ran.
      assert compute(ctx.experiment) == :insufficient_data
    end

    test "an excluded subject contributes to neither the mean nor n", ctx do
      excluded = subject(ctx.project, ctx.experiment, excluded_reason: "contaminated")
      plan_with(excluded, [{@non_ui_description, true}])

      included = subject(ctx.project, ctx.experiment)
      plan_with(included, [{@ui_description, true}])

      # Counted, this reads 0.5 over n 2. Both observables move, and n is the
      # one that says the excluded plan entered the denominator.
      assert {:ok, %Result{value: +0.0, n: 1, unit: :count}} = compute(ctx.experiment)
    end

    test "another arm's plans do not contribute", ctx do
      task = subject(ctx.project, ctx.experiment)
      plan_with(task, [{@non_ui_description, true}])

      assert {:ok, %Result{value: 1.0, n: 1}} = compute(ctx.experiment)
      assert OverscopedGateCount.compute(ctx.experiment.id, "control") == :insufficient_data
    end
  end

  describe "the UI predicate is borrowed, not restated" do
    @metric_file Path.expand(
                   Path.join([
                     __DIR__,
                     "..",
                     "..",
                     "..",
                     "..",
                     "lib",
                     "platform",
                     "experiments",
                     "metrics",
                     "overscoped_gate_count.ex"
                   ])
                 )

    @plan_engine_file Path.expand(
                        Path.join([
                          __DIR__,
                          "..",
                          "..",
                          "..",
                          "..",
                          "lib",
                          "platform",
                          "tasks",
                          "plan_engine.ex"
                        ])
                      )

    # Read off `@ui_tokens` in plan_engine.ex. Pinned as literals rather than
    # parsed out of the source, and cross-checked against that file below, so
    # a token renamed there fails HERE with a message telling the next reader
    # to go re-read the list.
    @ui_tokens [
      ".heex",
      "tasks_live.ex",
      "assets/js/",
      "assets/css/",
      "compose_input",
      "app.css",
      "chat_live",
      "_web/live/",
      "_web/components/"
    ]

    test "both files exist and are the files we think they are" do
      # Anti-vacuity. A rename or a move makes every refute below trivially
      # true and switches this guard off without a word.
      assert File.exists?(@metric_file)
      assert File.exists?(@plan_engine_file)

      assert @metric_file
             |> File.read!()
             |> String.contains?("defmodule Platform.Experiments.Metrics.OverscopedGateCount")

      assert @plan_engine_file
             |> File.read!()
             |> String.contains?("def ui_touching?(description) when is_binary(description)")
    end

    test "the pinned token list still matches plan_engine.ex" do
      source = File.read!(@plan_engine_file)

      for token <- @ui_tokens do
        assert String.contains?(source, inspect(token)),
               """
               #{inspect(token)} is no longer a literal in plan_engine.ex.

               This file pins @ui_tokens as it stood when the metric was
               written. Re-read `@ui_tokens` in plan_engine.ex and update the
               list here — otherwise the scan below stops covering whatever
               replaced it.
               """
      end
    end

    test "overscoped_gate_count.ex calls the predicate and restates no token" do
      source = File.read!(@metric_file)

      assert String.contains?(source, "PlanEngine.ui_touching?"),
             "the metric must ask PlanEngine, not decide for itself"

      # The loose form above is satisfied by the moduledoc alone — it names
      # `PlanEngine.ui_touching?/1` in prose. Measured: a mutation replacing
      # the call with `fn _ -> false end` left the loose assertion GREEN.
      # This pins the call shape, which that mutation does remove.
      assert String.contains?(source, "PlanEngine.ui_touching?(description)"),
             """
             overscoped_gate_count.ex names `PlanEngine.ui_touching?` somewhere
             but does not apply it to a stage description.

             A prose mention in the moduledoc satisfies the assertion above.
             This one wants the call site.
             """

      for token <- @ui_tokens do
        refute String.contains?(source, token),
               """
               overscoped_gate_count.ex contains the UI token #{inspect(token)}.

               The token list lives in PlanEngine's @ui_tokens and is reached
               through `ui_touching?/1`. A second copy here drifts from the
               advisory that emits the warning this metric counts, and the
               metric then measures a rule the platform no longer applies.
               """
      end
    end

    # WHAT THIS SCAN DOES NOT PROVE. It is a text scan over one file. It shows
    # that a second literal token list is not sitting in the metric and that a
    # call-shaped mention of the predicate is present. It cannot show the
    # predicate is semantically shared, and it cannot tell a comment from a
    # call: the loose assertion above was measured GREEN under a mutation that
    # deleted the call outright, because the moduledoc names the function. The
    # call-shape assertion narrows that gap; it does not close it. The metric
    # could still call `ui_touching?/1`, discard the answer, and apply a rule
    # built from strings assembled at runtime, and every assertion in this
    # describe block would pass.
    #
    # The behavioural cover is the UI-side / non-UI-side pair in `compute/2`.
    # Measured: the count-everything mutation detonates exactly three tests —
    # the UI-side zero, the mixed 0.5-over-2, and the exclusion case. Those,
    # not this scan, are what fail if the discrimination stops working.
  end

  describe "registry" do
    test "the slug resolves to this module and is registered lower_is_better" do
      assert Metrics.metric_module("overscoped_gate_count") == OverscopedGateCount
      assert "overscoped_gate_count" in Metrics.known_metrics()

      entry = Enum.find(Metrics.catalog(), &(&1.slug == "overscoped_gate_count"))

      assert entry.direction == :lower_is_better
    end
  end
end
