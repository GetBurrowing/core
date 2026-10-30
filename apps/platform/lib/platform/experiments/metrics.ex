defmodule Platform.Experiments.Metrics do
  @moduledoc """
  Shared machinery for the starter metrics, AND the registry of which
  metrics exist. Task 019fe6b9, ADR-0048.

  This module now carries two things: the query helpers every metric builds
  on (`subject_ids/2`, `mean/2`), and the slug registry (`known_metrics/0`,
  `metric_module/1`, `catalog/0`) that resolves an
  `experiments.primary_metric` string to the module that computes it.

  ## The registry lives here, not in the web layer

  It was previously a module attribute inside
  `PlatformWeb.ExperimentResults`, where a picker in the UI could not read
  it without the web layer owning the list. Two copies drift into a metric
  a user can SELECT but nothing can COMPUTE — the selection succeeds, the
  results page reports `:no_metric` forever, and nothing raises. One source
  only; the web module delegates.

  `description` and `direction` are registry DATA, not behaviour:
  `Platform.Experiments.Metric` declares only `compute/2`, and a metric
  module has no opinion about how a UI should read its numbers.

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

  # Keys are the strings `experiments.primary_metric` carries. An
  # unrecognised string resolves to nil and yields `:no_metric` rather than
  # a crash, because a typo in a slug must not take the Control Center page
  # down. Note the slug `validation_failure_rate` deliberately differs from
  # its file name (`metrics/failure_rate.ex`); the SLUG is what is stored.
  #
  # `direction` says how to read a movement. `:neutral` for
  # `stages_per_plan` is settled: more stages per plan is neither a win nor
  # a loss, and a UI that colours it as either is asserting a judgement the
  # metric does not support.
  @registry %{
    "validation_failure_rate" => %{
      module: Platform.Experiments.Metrics.ValidationFailureRate,
      label: "Validation failure rate",
      description: "Share of RESOLVED validations that failed, over a variant's subjects.",
      direction: :lower_is_better
    },
    "stages_per_plan" => %{
      module: Platform.Experiments.Metrics.StagesPerPlan,
      label: "Stages per plan",
      description: "Mean number of stages per plan, over the plans of a variant's subjects.",
      direction: :neutral
    },
    "cycle_time" => %{
      module: Platform.Experiments.Metrics.CycleTime,
      label: "Cycle time",
      description: "Mean total measured seconds per task, over a variant's subjects.",
      direction: :lower_is_better
    },
    "plan_revision_count" => %{
      module: Platform.Experiments.Metrics.PlanRevisionCount,
      label: "Plan revision count",
      description:
        "Mean number of plan revisions per task (plan rows plus in-place draft " <>
          "corrections), over a variant's subjects.",
      direction: :lower_is_better
    },
    # `:neutral` here is a judgement, argued in the module's moduledoc: the
    # rejection COUNT is gameable toward zero by never asking for a review,
    # and the RATE is gameable upward by asking less often. Neither
    # direction is a win on its own, so the UI must not colour one.
    "manual_gate_rejection_rate" => %{
      module: Platform.Experiments.Metrics.ManualGateRejectionRate,
      label: "Manual gate rejection rate",
      description:
        "Share of RESOLVED review requests with at least one needs_revision item, " <>
          "over a variant's subjects. Read only alongside a human-recorded count of " <>
          "escaped post-merge UI defects.",
      direction: :neutral
    },
    # `:lower_is_better` here is a judgement, argued in the module's
    # moduledoc: a gate on a stage that renders nothing has no legitimate
    # purpose, so downward movement can only mean planners stopped adding
    # them. The zero-by-gating-nothing strategy is caught by
    # `manual_gate_rejection_rate` and the missed-UI advisory.
    "overscoped_gate_count" => %{
      module: Platform.Experiments.Metrics.OverscopedGateCount,
      label: "Overscoped gate count",
      description:
        "Mean number of manual_approval validations on stages with no UI-touching tokens, " <>
          "per plan, over the plans of a variant's subjects.",
      direction: :lower_is_better
    },
    # Task 01a13867 stage 1, for the `memory.insight_synthesis` surface.
    # Counts dreaming-run subjects, not tasks, and each judged insight once
    # under its worst label (see the module).
    "meeting_synthesis_resolution_rate" => %{
      module: Platform.Experiments.Metrics.MeetingSynthesisResolutionRate,
      label: "Meeting synthesis resolution rate",
      description: "Share of judged findings confirmed or aligned rather than dismissed.",
      direction: :higher_is_better
    },
    "insight_acceptance_rate" => %{
      module: Platform.Experiments.Metrics.InsightAcceptanceRate,
      label: "Insight acceptance rate",
      description:
        "Share of judged insights acted on and not later flagged " <>
          "(accepted / (accepted + rejected + flagged)), over a variant's dreaming runs.",
      direction: :higher_is_better
    },
    "time_in_phase" => %{
      module: Platform.Experiments.Metrics.TimeInPhase,
      label: "Time in phase",
      description: "Mean seconds spent in ONE named phase, over a variant's subjects.",
      direction: :lower_is_better
    }
  }

  @doc """
  Computes an experiment's data-defined `metric_spec` for one variant
  (task 01a0d415, see `Platform.Experiments.MetricKind`).

  An EMPTY `metric_spec` falls back to the `registered` kind over
  `primary_metric`, so every experiment written before metric specs existed
  computes exactly what it computed before. Returns `:no_metric` when there is
  neither, or `{:error, reasons}` for a spec that does not validate.
  """
  @spec compute_spec(Platform.Experiments.Experiment.t(), String.t()) ::
          Platform.Experiments.MetricKind.result() | :no_metric | {:error, [String.t()]}
  def compute_spec(%Platform.Experiments.Experiment{} = experiment, variant_slug) do
    spec =
      case experiment.metric_spec do
        spec when is_map(spec) and map_size(spec) > 0 -> spec
        _ -> registered_fallback(experiment.primary_metric)
      end

    case Platform.Experiments.MetricKind.parse(spec) do
      {:ok, module, params} -> module.compute(experiment, variant_slug, params)
      :none -> :no_metric
      {:error, reasons} -> {:error, reasons}
    end
  end

  defp registered_fallback(slug) do
    if metric_module(slug), do: %{"kind" => "registered", "slug" => slug}, else: %{}
  end

  @doc "Core's own metric slugs, without any extension's."
  @spec core_metric_slugs() :: [String.t()]
  def core_metric_slugs, do: @registry |> Map.keys() |> Enum.sort()

  # Core's registry plus every extension's metrics (ADR 0055), read per call.
  # Core's own entry wins a slug an extension also names.
  defp registry, do: Map.merge(Platform.Extensions.experiment_metrics(), @registry)

  @doc "The metric slugs this platform can compute, sorted."
  @spec known_metrics() :: [String.t()]
  def known_metrics, do: registry() |> Map.keys() |> Enum.sort()

  @doc "Resolves a `primary_metric` slug to a module, or nil when unrecognised."
  @spec metric_module(String.t() | nil) :: module() | nil
  def metric_module(slug) when is_binary(slug) do
    case Map.get(registry(), slug) do
      nil -> nil
      %{module: module} -> module
    end
  end

  def metric_module(_), do: nil

  @doc """
  Every registered metric as `%{slug:, label:, description:, direction:}`,
  sorted by slug. This is what a picker renders — it carries the direction
  so the UI never has to infer one.
  """
  @spec catalog() :: [
          %{
            slug: String.t(),
            label: String.t(),
            description: String.t(),
            direction: :lower_is_better | :higher_is_better | :neutral
          }
        ]
  def catalog do
    registry()
    |> Enum.map(fn {slug, entry} -> Map.put(entry, :slug, slug) |> Map.delete(:module) end)
    |> Enum.sort_by(& &1.slug)
  end

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
