defmodule Platform.Experiments.Metrics do
  @moduledoc """
  Shared machinery for the starter metrics. Task 019fe6b9, ADR-0048.

  Every metric begins the same way: turn `(experiment_id, variant_slug)` into
  the set of subjects in that arm. That query lives here once rather than
  five times, because it carries a rule that must not be reimplemented with a
  variation.

  ## Excluded subjects leave BOTH sides of every ratio

  `subject_ids/2` filters `excluded_reason IS NULL`. An excluded subject
  contributes to neither numerator nor denominator, which is the entire point
  of recording the exclusion rather than deleting the row: the assignment
  stays visible and auditable, and the analysis behaves as though it were
  never there.

  Copying this query into each metric is exactly how one of them ends up
  counting an excluded subject in the denominator only — a silent, plausible
  deflation of every rate that metric reports, indistinguishable from a real
  effect.

  ## An empty subject set stops the metric before it touches another table

  `subject_ids/2` returning `[]` means the metric returns
  `:insufficient_data` immediately. Running the rest of the query against an
  empty id list would produce a legitimate-looking zero over zero rows,
  which is precisely the answer `Platform.Experiments.Metric` forbids.
  """

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Repo

  @subject_type "task"

  @doc """
  The non-excluded subject ids assigned to one variant of one experiment.

  Only `subject_type == "task"` rows are returned, because every starter
  metric reads task-derived tables. A future dispatch-level metric passes its
  own type rather than widening this one — mixing subject types into a single
  mean would average two different populations.
  """
  @spec subject_ids(Ecto.UUID.t(), String.t()) :: [Ecto.UUID.t()]
  def subject_ids(experiment_id, variant_slug) do
    Assignment
    |> where([a], a.experiment_id == ^experiment_id)
    |> where([a], a.variant_slug == ^variant_slug)
    |> where([a], a.subject_type == ^@subject_type)
    |> where([a], is_nil(a.excluded_reason))
    |> select([a], a.subject_id)
    |> Repo.all()
  end

  @doc """
  Builds a `Result` from a list of per-unit measurements, or
  `:insufficient_data` when the list is empty.

  This is where the two rules meet: `n` is `length(values)` — the number of
  units actually measured, not the number of subjects assigned — and an
  empty list can only produce `:insufficient_data`, because there is no
  arithmetic that turns no measurements into a mean.
  """
  @spec mean([number()], atom()) :: {:ok, Result.t()} | :insufficient_data
  def mean([], _unit), do: :insufficient_data

  def mean(values, unit) do
    n = length(values)
    {:ok, %Result{value: Enum.sum(values) / n, n: n, unit: unit}}
  end
end
