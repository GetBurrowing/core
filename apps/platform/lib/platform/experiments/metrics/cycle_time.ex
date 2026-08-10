defmodule Platform.Experiments.Metrics.CycleTime do
  @moduledoc """
  Mean total measured seconds per task, over a variant's subjects.
  Task 019fe6b9, ADR-0048.

  Measured time comes from `Platform.Tasks.PhaseTransitions.decompose/2` —
  arity 2, `decompose(task_id, repo \\\\ Platform.Repo)` — summed across the
  decomposition's `phases`.

  ## What `n` counts: TASKS with at least one closed phase

  ## A task with no transition rows is EXCLUDED, not zero seconds

  `decompose/2` returns `phases: %{}` for a task that predates the
  instrumentation or has simply not moved yet. Such a task is dropped from
  the sample. Counting it as zero seconds would say it was completed
  instantly, and since older tasks are the ones most likely to be
  uninstrumented, the bias runs in a consistent direction: whichever arm
  holds more of them looks faster. If every subject decomposes empty, the
  metric returns `:insufficient_data`.

  ## Open intervals are excluded, and this is the decision worth arguing with

  Only phases with `open?: false` contribute. An open interval is measured
  against `DateTime.utc_now()`, so its duration grows between two reads —
  a metric that returns a different number each time you call it is not a
  measurement, and two dashboards side by side would disagree with each
  other for no reason a reader could see.

  The cost is that a task's currently-running phase is invisible, so the
  metric understates elapsed time for in-flight work. That is the intended
  trade: understating by a known, stable rule beats a number that drifts.

  Tasks with `complete?: false` are otherwise INCLUDED. Their closed phases
  are real measured time, and excluding unfinished tasks entirely would
  restrict the sample to whatever finished first — the fastest work — which
  is a selection effect strong enough to invert a result.
  """

  @behaviour Platform.Experiments.Metric

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Tasks.PhaseTransitions

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> Enum.flat_map(&measured_seconds/1)
        |> Metrics.mean(:seconds)
    end
  end

  # A list of nought or one element, so a task with nothing measurable
  # disappears from the sample rather than contributing a value.
  defp measured_seconds(task_id) do
    case PhaseTransitions.decompose(task_id) do
      {:ok, %{phases: phases}} ->
        closed =
          phases
          |> Map.values()
          |> Enum.reject(& &1.open?)
          |> Enum.map(& &1.total_seconds)

        if closed == [], do: [], else: [Enum.sum(closed)]

      {:error, :task_not_found} ->
        []
    end
  end
end
