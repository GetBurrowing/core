defmodule Platform.Experiments.Metric do
  @moduledoc """
  What an experiment measures. Task 019fe6b9, ADR-0048.

  A metric reduces one variant of one experiment to a single number, and is
  required to report how much data that number came from.

  ## Rule 1 — sample size travels with the result, always

  Every successful return is a `Platform.Experiments.Metric.Result` carrying
  `value`, `n` and `unit`. No metric may return a bare float, a bare number,
  or a tuple without `n`.

  A bare float invites a confident chart drawn from four subjects. Nothing
  downstream can recover the sample size once it has been dropped — the
  number renders identically whether it summarises four tasks or four
  hundred — and the "no effect yet, too little data" rule the UI needs is
  only implementable if this layer says how much data it had.

  `unit` is there so a reader cannot mistake a ratio for a count or seconds
  for minutes, and so a chart can label an axis without guessing from the
  metric's name.

  ## Rule 2 — `:insufficient_data`, never `0.0`

  A metric that cannot be computed returns the bare atom `:insufficient_data`.

  No data and zero are DIFFERENT ANSWERS. A validation failure rate of `0.0`
  says every resolved validation passed; `:insufficient_data` says nothing
  has been resolved yet. Collapsing the second into the first is how a
  dashboard reports a real-looking number about nothing, and it is worse than
  an error, because an error stops the reader and a plausible zero does not.

  The precedent is `PhaseTransitions.decompose/2` in the tasks context, whose
  moduledoc section "No data is not zero data" makes the same commitment: a
  task with no transition rows gets `phases: %{}` and `waits: %{...  :none}`,
  never a decomposition of zeros reconstructed from timestamps. An absent
  phase there is an absent KEY, and this layer copies that discipline —
  absence is represented by absence.

  ## The behaviour is generic; the implementations are not

  `compute/2` takes an experiment id and a variant slug. It never takes a
  task, a task id, or anything else that names the thing being experimented
  on — the subjects are found through `experiment_assignments`, which is
  what makes a `"dispatch"` subject work here later with no change to this
  contract.

  Concrete metrics under `metrics/` DO query task tables, and that is fine:
  the knowledge lives in the implementation, where it can be replaced, not
  in the contract, where it would have to be honoured forever. A
  source-level test asserts this file specifically stays clean of it.

  ## Deliberately absent

  No aggregation across experiments, no comparison between variants, no
  significance test, no confidence interval, no p-value. The effect sizes
  worth acting on here are large, and a p-value over forty subjects lends a
  precision the data does not have. Sample size and effect size, honestly
  reported, is the whole v1 contract.
  """

  defmodule Result do
    @moduledoc """
    A metric's answer, inseparable from its sample size.

    `n` is not optional and not defaulted: a metric must state which
    population it counted, and every implementation's moduledoc says which
    units `n` is counting — plans, tasks, or resolved validations. A metric
    whose `n` is ambiguous is very nearly as bad as one with no `n` at all,
    because a reader who cannot tell what was counted cannot tell whether
    there was enough of it.

    `pending` (task 01a0d415) counts subjects still inside an outcome
    metric's observation window. They are in NEITHER the value nor `n` —
    they have not had the chance to produce an outcome, and scoring them as
    non-responses would bias the rate toward zero. It defaults to 0 for
    every metric with no window; `n` stays enforced.
    """

    @type t :: %__MODULE__{
            value: float(),
            n: non_neg_integer(),
            unit: atom(),
            pending: non_neg_integer()
          }

    @enforce_keys [:value, :n, :unit]
    defstruct [:value, :n, :unit, pending: 0]
  end

  @type result :: {:ok, Result.t()} | :insufficient_data

  @doc """
  Computes the metric for one variant of one experiment.

  Returns `:insufficient_data` rather than a zero whenever the underlying
  population is empty.
  """
  @callback compute(experiment_id :: Ecto.UUID.t(), variant_slug :: String.t()) :: result()
end
