defmodule Platform.Experiments.Metrics.StagesPerPlan do
  @moduledoc """
  Mean number of stages per plan, over the plans of a variant's subjects.
  Task 019fe6b9, ADR-0048.

  ## What `n` counts: PLANS, not tasks and not stages

  A task with three plans contributes three units, and a task with none
  contributes nothing at all. Stating this is not pedantry — the same value
  with `n` read as "tasks" would look like a much smaller sample than it is,
  and a reader deciding whether to act on a difference is deciding on `n`.

  ## A task with no plans is absent, not a zero

  Plans are counted by joining from the plans table, so an unplanned task
  never appears. Counting it as a plan with zero stages would drag every
  mean toward zero in proportion to how many subjects had not been planned
  yet — an artifact of timing that looks exactly like a treatment effect.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> stage_counts()
        |> Metrics.mean(:count)
    end
  end

  # One row per plan, so a plan with zero stages is still a measured unit —
  # unlike a task with no plans, which is not a unit at all. The left join is
  # what keeps the distinction: an empty plan is a real observation of a
  # planner that produced nothing.
  defp stage_counts(subject_ids) do
    Plan
    |> where([p], p.task_id in ^subject_ids)
    |> join(:left, [p], s in Stage, on: s.plan_id == p.id)
    |> group_by([p], p.id)
    |> select([p, s], count(s.id))
    |> Repo.all()
  end
end
