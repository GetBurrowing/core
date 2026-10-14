defmodule Platform.Experiments.MetricKindsTest do
  @moduledoc """
  Data-defined metric kinds (task 01a0d415, the experimentation-layer ADR-0052).

  Every expectation is a LITERAL (ADR-0048 addendum's anti-vacuity rule). A
  value recomputed from the fixtures restates the implementation and cannot
  fail for any value the metric returns.
  """

  use Platform.DataCase, async: true

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Results
  alias Platform.Experiments.Signals
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition

  @outcome_spec %{
    "kind" => "outcome_rate",
    "labels" => ["positive"],
    "window_days" => 7,
    "anchor" => "assigned_at"
  }

  defp unique, do: System.unique_integer([:positive])

  defp experiment!(attrs) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(%{slug: "mk-#{unique()}", name: "Metric kinds"}, attrs)
      )

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "treatment", content: "t", weight: 1})
    experiment
  end

  defp treatment_row(experiment),
    do: Enum.find(Results.rows(experiment), &(&1.variant_slug == "treatment"))

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  defp assign!(experiment, assigned_at, opts \\ []) do
    subject_id = Keyword.get(opts, :subject_id, Ecto.UUID.generate())

    Repo.insert!(%Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: subject_id,
      variant_slug: "treatment",
      assigned_at: assigned_at,
      excluded_reason: Keyword.get(opts, :excluded_reason)
    })

    subject_id
  end

  defp signal!(experiment, subject_id, label, observed_at) do
    {:ok, _} =
      Signals.record(%{
        experiment_id: experiment.id,
        subject_type: "task",
        subject_id: subject_id,
        label: label,
        status: "labelled",
        source_type: "test",
        source_id: "src-#{unique()}",
        inserted_at: observed_at
      })
  end

  describe "outcome_rate" do
    test "3 subjects past the window (1 positive) and 1 inside it: 1/3, n 3, pending 1" do
      experiment = experiment!(%{metric_spec: @outcome_spec})

      positive = assign!(experiment, days_ago(10))
      negative = assign!(experiment, days_ago(10))
      late = assign!(experiment, days_ago(10))
      young = assign!(experiment, days_ago(1))

      signal!(experiment, positive, "positive", days_ago(8))
      # Wrong label: not an outcome.
      signal!(experiment, negative, "negative", days_ago(8))
      # Right label, but observed 9 days after the anchor: outside the window.
      signal!(experiment, late, "positive", days_ago(1))
      # The young subject's positive does not make it eligible.
      signal!(experiment, young, "positive", DateTime.utc_now())

      assert {:ok, %Result{value: value, n: 3, unit: :ratio, pending: 1}} =
               Metrics.compute_spec(experiment, "treatment")

      assert value == 1 / 3
    end

    test "every subject inside the window is insufficient data carrying its pending count, not 0.0" do
      experiment = experiment!(%{metric_spec: @outcome_spec})
      assign!(experiment, days_ago(1))
      assign!(experiment, days_ago(2))

      assert Metrics.compute_spec(experiment, "treatment") ==
               {:insufficient_data, %{pending: 2}}
    end

    # Reviewer finding at 66af0259: the insufficient row hard-coded
    # `pending: 0`, so an arm whose only subject was in the window read
    # "0 pending" in the UI, the experiment_results tool and the Scientist.
    test "results row: an arm whose only subject is in the window reads pending 1, value nil" do
      experiment = experiment!(%{metric_spec: @outcome_spec})
      assign!(experiment, days_ago(1))

      row = treatment_row(experiment)

      assert row.pending == 1
      assert row.value == nil
      assert row.n == 0
      assert row.subjects == 1
      assert row.reason == :insufficient_data
    end

    test "results row: 2 eligible and 1 in the window reads n 2, pending 1" do
      experiment = experiment!(%{metric_spec: @outcome_spec})
      assign!(experiment, days_ago(10))
      assign!(experiment, days_ago(10))
      assign!(experiment, days_ago(1))

      row = treatment_row(experiment)

      assert row.n == 2
      assert row.pending == 1
      assert row.subjects == 3
    end

    test "an excluded subject is absent from n" do
      experiment = experiment!(%{metric_spec: @outcome_spec})

      positive = assign!(experiment, days_ago(10))
      assign!(experiment, days_ago(10))
      excluded = assign!(experiment, days_ago(10), excluded_reason: "project excluded")
      signal!(experiment, positive, "positive", days_ago(9))
      signal!(experiment, excluded, "positive", days_ago(9))

      assert {:ok, %Result{value: 0.5, n: 2, pending: 0}} =
               Metrics.compute_spec(experiment, "treatment")
    end
  end

  describe "duration_between" do
    test "closed intervals only; open and row-less subjects are dropped" do
      experiment =
        experiment!(%{
          metric_spec: %{
            "kind" => "duration_between",
            "from_status" => "planning",
            "to_status" => "in_progress"
          }
        })

      {:ok, project} = Tasks.create_project(%{name: "Duration #{unique()}"})

      [closed, open, silent] =
        for _ <- 1..3 do
          {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "D #{unique()}"})
          task
        end

      t0 = ~U[2026-09-01 10:00:00.000000Z]
      transition!(closed, "planning", t0)
      transition!(closed, "in_progress", DateTime.add(t0, 120, :second))
      transition!(open, "planning", t0)

      for task <- [closed, open, silent],
          do: assign!(experiment, days_ago(1), subject_id: task.id)

      assert {:ok, %Result{value: 120.0, n: 1, unit: :seconds}} =
               Metrics.compute_spec(experiment, "treatment")
    end
  end

  describe "registered" do
    test "an empty metric_spec falls back to primary_metric through the module registry" do
      experiment = experiment!(%{primary_metric: "cycle_time"})

      assert experiment.metric_spec == %{}
      assert Metrics.compute_spec(experiment, "treatment") == :insufficient_data

      assert Metrics.compute_spec(%{experiment | primary_metric: nil}, "treatment") ==
               :no_metric
    end

    test "delegates to the registered module" do
      experiment = experiment!(%{metric_spec: %{"kind" => "registered", "slug" => "cycle_time"}})

      assert {:ok, Platform.Experiments.MetricKinds.Registered, %{"slug" => "cycle_time"}} =
               MetricKind.parse(experiment.metric_spec)
    end
  end

  describe "validation at spec-build time" do
    test "an unknown kind is a changeset error" do
      assert {:error, changeset} =
               Experiments.create_experiment(%{
                 slug: "bad-#{unique()}",
                 name: "Bad",
                 metric_spec: %{"kind" => "vibes"}
               })

      assert {message, _} = changeset.errors[:metric_spec]
      assert message =~ "unknown metric kind \"vibes\""
    end

    test "a bad parameter is a changeset error" do
      for spec <- [
            %{@outcome_spec | "window_days" => 0},
            %{@outcome_spec | "labels" => []},
            Map.put(@outcome_spec, "surprise", 1),
            %{"kind" => "registered", "slug" => "not_a_metric"},
            %{
              "kind" => "duration_between",
              "from_status" => "planning",
              "to_status" => "planning"
            }
          ] do
        assert {:error, [_ | _]} = MetricKind.validate_spec(spec), inspect(spec)
      end

      assert MetricKind.validate_spec(%{}) == :ok
      assert MetricKind.validate_spec(@outcome_spec) == :ok
    end
  end

  defp transition!(task, to_status, occurred_at) do
    %PhaseTransition{}
    |> PhaseTransition.changeset(%{
      task_id: task.id,
      to_status: to_status,
      occurred_at: occurred_at,
      actor_kind: "system"
    })
    |> Repo.insert!()
  end
end
