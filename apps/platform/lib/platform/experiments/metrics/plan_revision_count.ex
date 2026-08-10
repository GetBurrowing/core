defmodule Platform.Experiments.Metrics.PlanRevisionCount do
  @moduledoc """
  Mean number of plan versions per task, over a variant's subjects.
  Task 019fe6b9, ADR-0048.

  ## What `n` counts: TASKS that have at least one plan

  A task with no plans contributes nothing and is not a zero — it has not
  been planned yet, which is a different fact from having been planned once.

  ## Counting plan ROWS, and the trap that made that the right choice

  A task's versions are exactly its plan rows, so this counts rows per task.
  The alternative — counting supersessions — is where the trap is, and it is
  worth writing down because the obvious query is wrong.

  Approving a plan supersedes the task's older `approved`/`completed`
  siblings inside the approval transaction. The supersession sets the OLD
  sibling's `superseded_by_plan_id` to point FORWARD at the new plan, and
  sets that sibling's `status` to `"rejected"` — the SAME value a human
  rejection writes. The two are distinguishable only by
  `superseded_by_plan_id` being non-nil.

  So `count(status == "rejected")` silently sums re-planning and human
  disapproval and returns a perfectly plausible number while doing it. If a
  supersession count is ever wanted, the predicate is
  `superseded_by_plan_id IS NOT NULL` and never the status. Same disease as
  collapsing `stopped` into `concluded`: one value carrying two meanings, so
  the difference is unrecoverable after the write.

  Counting rows sidesteps the question entirely: every version is a row
  whether it was superseded, rejected, or is the one currently in force.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.Plan

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> plan_counts()
        |> Metrics.mean(:count)
    end
  end

  # Grouped over the plans table, so only tasks that HAVE plans appear. An
  # inner grouping cannot manufacture a zero for a task with none.
  defp plan_counts(subject_ids) do
    Plan
    |> where([p], p.task_id in ^subject_ids)
    |> group_by([p], p.task_id)
    |> select([p], count(p.id))
    |> Repo.all()
  end
end
