defmodule Platform.Experiments.Metrics.ValidationFailureRate do
  @moduledoc """
  Share of RESOLVED validations that failed, over a variant's subjects.
  Task 019fe6b9, ADR-0048.

  `failed / (passed + failed)`.

  ## What `n` counts: RESOLVED validations

  Not tasks, not plans, not stages, and not all validations — the number of
  validations that actually reached a verdict and therefore contributed to
  the ratio.

  ## `pending` and `running` are unresolved, and leave BOTH sides

  `Platform.Tasks.Validation` declares statuses `pending | running | passed |
  failed`. The first two are not yet answers. They are excluded from the
  numerator AND the denominator, because a validation that has not been
  evaluated is not evidence of anything.

  Counting them as passes would be the more natural-looking mistake — the
  denominator grows, the rate falls, and the number stays inside its
  plausible range the whole time. A variant whose validations are simply
  slower to be evaluated would then appear to be a variant that fails less,
  which is the exact opposite of the truth.

  A subject set whose validations are ALL still pending yields
  `:insufficient_data`, not `0.0`. Nothing has been measured yet, and
  reporting a perfect pass rate for a variant nobody has finished evaluating
  is the failure mode this rule exists to prevent.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @resolved ~w(passed failed)

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> resolved_statuses()
        |> rate()
    end
  end

  defp rate([]), do: :insufficient_data

  defp rate(statuses) do
    n = length(statuses)
    failed = Enum.count(statuses, &(&1 == "failed"))

    {:ok, %Result{value: failed / n, n: n, unit: :ratio}}
  end

  defp resolved_statuses(subject_ids) do
    Validation
    |> join(:inner, [v], s in Stage, on: s.id == v.stage_id)
    |> join(:inner, [v, s], p in Plan, on: p.id == s.plan_id)
    |> where([v, s, p], p.task_id in ^subject_ids)
    |> where([v], v.status in ^@resolved)
    |> select([v], v.status)
    |> Repo.all()
  end
end
