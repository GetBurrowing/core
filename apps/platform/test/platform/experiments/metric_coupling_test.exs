defmodule Platform.Experiments.MetricCouplingTest do
  @moduledoc """
  `metric.ex` — the CONTRACT — must stay ignorant of tasks.

  The scope here is deliberately narrower than the policy layer's equivalent.
  Concrete metrics under `metrics/` query task tables and must: knowing that
  a stage belongs to a plan belongs to a task is the whole job of a metric
  implementation. What must not happen is that knowledge migrating into the
  behaviour, because a contract that named a task id would have to keep
  naming one forever, and a dispatch-level metric could never satisfy it.

  So this scans one file.
  """

  use ExUnit.Case, async: true

  @metric_file Path.expand(
                 Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "lib",
                   "platform",
                   "experiments",
                   "metric.ex"
                 ])
               )

  test "metric.ex exists and is the file we think it is" do
    # Anti-vacuity: a renamed or missing file would make the refute below
    # vacuously true and switch the guard off in silence.
    assert File.exists?(@metric_file)

    source = File.read!(@metric_file)

    assert String.contains?(source, "@callback compute(experiment_id")
    assert String.contains?(source, "defmodule Result do")
  end

  test "the metric contract names no task type" do
    source = File.read!(@metric_file)

    for term <- ["Platform.Tasks", "%Task{", "task_id"] do
      refute String.contains?(source, term),
             """
             metric.ex contains #{inspect(term)}.

             compute/2 takes an experiment id and a variant slug. Subjects are
             found through experiment_assignments, which is what lets a
             non-task subject work here later without changing this contract.
             Implementations under metrics/ may know about tasks; the
             behaviour may not.
             """
    end
  end
end
