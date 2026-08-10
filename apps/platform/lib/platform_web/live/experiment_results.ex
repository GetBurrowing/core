defmodule PlatformWeb.ExperimentResults do
  @moduledoc """
  Turns an experiment into the figures `PlatformWeb.ExperimentsLive` may
  render, and decides which of them have been EARNED. Task 019fe6ba, ADR-0048.

  This module exists because two things the UI needs are genuinely absent
  from the context layer, and inventing them inside a template would scatter
  the decision across every call site:

    * `experiments.primary_metric` is a free-text string and nothing upstream
      maps it onto a `Platform.Experiments.Metric` implementation; and
    * `experiments.stop_rule` is an unconstrained `:map` with no evaluator.

  Both are resolved here, once, so there is a single place to change when the
  context grows its own registry.

  ## The stop rule fails CLOSED

  `min_subjects/1` reads `stop_rule["min_subjects"]`. An experiment whose
  stop rule is empty, malformed, or names no subject count has **not** earned
  a figure and never will until someone writes one down.

  The alternative — treating "no stop rule" as "no threshold to clear", and
  therefore printing the number — is the failure ADR-0048 is about. It makes
  the honest state the one that requires configuration and the misleading
  state the default, so every experiment created in a hurry reports a
  confident figure over four subjects. Absent evidence of sufficiency is not
  evidence of sufficiency.

  ## `n` is the metric's count, and the stop rule is measured against IT

  The comparison is `Result.n >= min_subjects`, not `assignment count >=
  min_subjects`. Those differ, deliberately and by a lot: `n` counts units
  actually measured (resolved validations, plans, tasks — each metric's
  moduledoc says which) after excluded subjects have left both sides, while
  the assignment count includes subjects whose work has not been evaluated
  yet. Comparing the stop rule against assignments would clear the threshold
  on the strength of data nobody has measured, which is a figure with a
  smaller basis than it claims.

  The assignment counts are still reported alongside — see
  `PlatformWeb.ExperimentsLive` — because a reader needs both "how many
  subjects are in this arm" and "how much of that has been measured", and
  neither substitutes for the other.

  ## No comparison between arms, and no projection

  Every variant's figure is computed and presented on its own. There is no
  lift, no delta against control, no projection, and no extrapolation to a
  final value — for the reason `Platform.Experiments.Metric` gives at
  length: an effect size over forty subjects lends a precision the data does
  not have, and a projected lift is the specific shape that makes noise read
  as measurement.
  """

  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result

  @typedoc """
  One variant's row on the results view.

  `earned?` is the ONLY thing the view may branch on to decide whether a
  number appears; `value`/`unit` are nil unless it is true, so a caller that
  ignores the flag still has nothing to print.
  """
  @type row :: %{
          variant_slug: String.t(),
          earned?: boolean(),
          value: float() | nil,
          unit: atom() | nil,
          n: non_neg_integer(),
          subjects: non_neg_integer(),
          excluded: non_neg_integer(),
          min_subjects: pos_integer() | nil,
          reason: :measured | :insufficient_data | :below_stop_rule | :no_stop_rule | :no_metric
        }

  # The registry the context does not have. Keys are the strings
  # `experiments.primary_metric` is expected to carry; an unrecognised string
  # resolves to nil and yields `:no_metric` rather than a crash, because a
  # typo in a slug must not take the whole Control Center page down.
  @metrics %{
    "validation_failure_rate" => Platform.Experiments.Metrics.ValidationFailureRate,
    "stages_per_plan" => Platform.Experiments.Metrics.StagesPerPlan,
    "cycle_time" => Platform.Experiments.Metrics.CycleTime,
    "plan_revision_count" => Platform.Experiments.Metrics.PlanRevisionCount,
    "time_in_phase" => Platform.Experiments.Metrics.TimeInPhase
  }

  @doc "The metric slugs this UI can compute."
  @spec known_metrics() :: [String.t()]
  def known_metrics, do: @metrics |> Map.keys() |> Enum.sort()

  @doc "Resolves `primary_metric` to a module, or nil when unrecognised."
  @spec metric_module(String.t() | nil) :: module() | nil
  def metric_module(slug) when is_binary(slug), do: Map.get(@metrics, slug)
  def metric_module(_), do: nil

  @doc """
  The subject count a figure must reach before it may be shown, or nil.

  Fails closed — see the moduledoc. Accepts the integer under either an
  atom or string key, because `stop_rule` is a `:map` column and round-trips
  through JSON as strings while an in-memory changeset may still hold atoms.
  """
  @spec min_subjects(Experiment.t()) :: pos_integer() | nil
  def min_subjects(%Experiment{stop_rule: stop_rule}) when is_map(stop_rule) do
    case Map.get(stop_rule, "min_subjects", Map.get(stop_rule, :min_subjects)) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  def min_subjects(_), do: nil

  @doc """
  Human-readable stop rule, always a sentence — never blank.

  A missing stop rule renders as a statement that none is set, not as an
  empty string: the basis line has to say something in every state, or the
  reader cannot tell "no threshold recorded" from "the label failed to
  render".
  """
  @spec stop_rule_label(Experiment.t()) :: String.t()
  def stop_rule_label(%Experiment{} = experiment) do
    case min_subjects(experiment) do
      nil -> "no stop rule set"
      n -> "stop rule #{n}"
    end
  end

  @doc """
  Every variant's row for one experiment, control first.

  Control is ordered first because it is the thing the others are read
  against; the remainder stay in slug order so the list does not reshuffle
  between renders.
  """
  @spec rows(Experiment.t()) :: [row()]
  def rows(%Experiment{} = experiment) do
    assignments = Assignments.list_assignments(experiment)

    experiment
    |> Experiments.list_variants()
    |> Enum.sort_by(&{&1.slug != Experiment.control_slug(), &1.slug})
    |> Enum.map(&row(experiment, &1.slug, assignments))
  end

  @doc """
  The experiment's headline row — the control arm's, or a metric-less
  placeholder when there are no variants yet.

  A draft with no variants still gets a row, so the list renders a complete
  cell for it rather than a hole. That is the sparse state, and a page that
  looks broken when data is thin gets assumed broken.
  """
  @spec headline_row(Experiment.t()) :: row()
  def headline_row(%Experiment{} = experiment) do
    case rows(experiment) do
      [] -> empty_row(experiment)
      [first | _] -> first
    end
  end

  defp empty_row(experiment) do
    %{
      variant_slug: Experiment.control_slug(),
      earned?: false,
      value: nil,
      unit: nil,
      n: 0,
      subjects: 0,
      excluded: 0,
      min_subjects: min_subjects(experiment),
      reason: :insufficient_data
    }
  end

  defp row(experiment, variant_slug, assignments) do
    arm = Enum.filter(assignments, &(&1.variant_slug == variant_slug))
    excluded = Enum.count(arm, &(&1.excluded_reason != nil))
    minimum = min_subjects(experiment)

    base = %{
      variant_slug: variant_slug,
      earned?: false,
      value: nil,
      unit: nil,
      n: 0,
      # Every assigned subject, excluded ones included. The excluded count
      # sits beside it rather than being subtracted out of sight: rule 4 of
      # ADR-0048 is that an exclusion stays legible in the denominator it
      # left.
      subjects: length(arm),
      excluded: excluded,
      min_subjects: minimum,
      reason: :insufficient_data
    }

    case compute(experiment, variant_slug) do
      {:ok, %Result{value: value, n: n, unit: unit}} ->
        earned? = is_integer(minimum) and n >= minimum

        %{
          base
          | n: n,
            # value/unit are carried ONLY when the figure was earned. A view
            # that forgets to check `earned?` still has nil to render, so the
            # stop rule is enforced here rather than trusted to every caller.
            value: if(earned?, do: value),
            unit: if(earned?, do: unit),
            earned?: earned?,
            reason: reason_for(earned?, minimum)
        }

      :insufficient_data ->
        %{base | reason: :insufficient_data}

      :no_metric ->
        %{base | reason: :no_metric}
    end
  end

  defp reason_for(true, _minimum), do: :measured
  defp reason_for(false, nil), do: :no_stop_rule
  defp reason_for(false, _minimum), do: :below_stop_rule

  defp compute(experiment, variant_slug) do
    case metric_module(experiment.primary_metric) do
      nil -> :no_metric
      module -> module.compute(experiment.id, variant_slug)
    end
  end

  @doc """
  Why a figure is absent, in the reader's words.

  Rule 3 of ADR-0048 — the view states its own insufficiency next to where
  the number would be — is only implementable if the absence has a specific
  cause attached. "No effect yet" alone does not tell a reader whether to
  wait, to fix the stop rule, or to fix the metric slug.
  """
  @spec confound(row()) :: String.t()
  def confound(%{reason: :no_metric}),
    do: "no metric configured — nothing is being measured"

  def confound(%{reason: :no_stop_rule}),
    do: "no stop rule set, so no figure has been earned"

  def confound(%{reason: :insufficient_data, subjects: 0}),
    do: "no subjects assigned yet"

  def confound(%{reason: :insufficient_data}),
    do: "subjects assigned but nothing measured yet"

  def confound(%{reason: :below_stop_rule, n: n, min_subjects: minimum}),
    do: "#{n} of #{minimum} measured"

  def confound(%{reason: :measured}), do: ""

  @doc """
  Formats an earned figure. Returns nil for an unearned row, so this cannot
  be used to smuggle a number past the stop rule.
  """
  @spec figure(row()) :: String.t() | nil
  def figure(%{earned?: false}), do: nil
  def figure(%{value: nil}), do: nil

  def figure(%{value: value, unit: :ratio}),
    do: "#{:erlang.float_to_binary(value * 100, decimals: 1)}%"

  def figure(%{value: value, unit: :seconds}), do: duration(value)

  def figure(%{value: value, unit: _}),
    do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp duration(seconds) when seconds < 3600,
    do: "#{:erlang.float_to_binary(seconds / 60, decimals: 1)} min"

  defp duration(seconds) when seconds < 86_400,
    do: "#{:erlang.float_to_binary(seconds / 3600, decimals: 1)} h"

  defp duration(seconds), do: "#{:erlang.float_to_binary(seconds / 86_400, decimals: 1)} d"

  @doc "The unit's label, for the basis line."
  @spec unit_label(atom()) :: String.t()
  def unit_label(:ratio), do: "of resolved validations"
  def unit_label(:seconds), do: "mean"
  def unit_label(:count), do: "mean"
  def unit_label(_), do: ""
end
