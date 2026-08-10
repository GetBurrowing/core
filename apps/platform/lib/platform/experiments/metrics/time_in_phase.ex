defmodule Platform.Experiments.Metrics.TimeInPhase do
  @moduledoc """
  Mean seconds spent in ONE named phase, over a variant's subjects.
  Task 019fe6b9, ADR-0048.

  Reads `phases[phase][:total_seconds]` from
  `Platform.Tasks.PhaseTransitions.decompose/2`, whose `phases` entries are
  `%{total_seconds: float, visits: integer, open?: boolean}`.

  ## An ABSENT phase key means the phase never happened — it is not `0.0`

  This is the rule the whole metric turns on. `decompose/2` omits a phase a
  task never entered rather than reporting it as zero, and this metric
  preserves that: such a task leaves the sample entirely.

  `Map.get(phases, phase, %{total_seconds: 0.0})` is the one-character
  version of this mistake and it is silent. A variant whose tasks skip
  `in_review` altogether would report a mean review time near zero — an
  outstandingly good result — when the correct answer is that it has no
  review time to report at all. The two readings point in opposite
  directions and no number on the chart distinguishes them.

  ## What `n` counts: TASKS that entered this phase and closed it

  Open intervals are excluded for the same reason as in
  `Platform.Experiments.Metrics.CycleTime`: an open interval is measured
  against the current time and grows between reads, so a metric including it
  answers differently each time it is called. A phase that is present but
  still open therefore also leaves the sample — present-but-unfinished is
  not the same as absent, but neither is it a measurement.

  ## `compute/3` is the real function

  The phase is a parameter, so `compute/3` is the honest signature.
  `compute/2` exists only to satisfy `Platform.Experiments.Metric` and
  applies `#{inspect("in_progress")}`, the phase this metric was introduced
  to watch. Callers should name the phase.
  """

  @behaviour Platform.Experiments.Metric

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Tasks.PhaseTransitions

  @default_phase "in_progress"

  @doc """
  Computes for the default phase. Prefer `compute/3`, which names it.
  """
  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug),
    do: compute(experiment_id, variant_slug, @default_phase)

  @doc """
  Mean closed seconds in `phase`, over the variant's non-excluded subjects.

  Returns `:insufficient_data` when no subject has a closed interval in that
  phase — including when no subject entered it at all.
  """
  @spec compute(Ecto.UUID.t(), String.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug, phase) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> Enum.flat_map(&phase_seconds(&1, phase))
        |> Metrics.mean(:seconds)
    end
  end

  defp phase_seconds(task_id, phase) do
    case PhaseTransitions.decompose(task_id) do
      {:ok, %{phases: phases}} -> from_phases(phases, phase)
      {:error, :task_not_found} -> []
    end
  end

  # Deliberately a fetch with no default. An absent key produces an empty
  # list — no measurement — and never a zero.
  defp from_phases(phases, phase) do
    case Map.fetch(phases, phase) do
      {:ok, %{open?: false, total_seconds: seconds}} -> [seconds]
      {:ok, %{open?: true}} -> []
      :error -> []
    end
  end
end
