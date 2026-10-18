defmodule Platform.Experiments.Metrics.InsightAcceptanceRate do
  @moduledoc """
  Share of JUDGED insights that were acted on and not later flagged, over a
  variant's dreaming runs. Task `01a13867-3213-7001-a128-6b4c6b34283f`,
  stage 1, for the `memory.insight_synthesis` surface.

  `accepted / (accepted + rejected + flagged)`, read off the
  `experiment_signals` rows `Platform.Memory.Insights` records
  (`source_type` `"memory_insight"`).

  ## What `n` counts: judged INSIGHTS

  One insight can carry two signals (acted on, then flagged), so signals are
  grouped by insight first and each insight counts once, under its worst
  label: `flagged` over `rejected` over `accepted`. An acted-then-flagged
  insight is a failure, not half a success. Insights with no signal (still
  open, dismissed without a reason, or expired untouched) are in neither
  side: they were never judged.

  No judged insight is `:insufficient_data`, never `0.0`.

  ## Subjects

  The variant's `"dreaming_run"` assignments, not task assignments, so this
  does not use `Metrics.subject_ids/2` (task-only by design).
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Signal
  alias Platform.Repo

  @subject_type "dreaming_run"
  @source_type "memory_insight"
  @rank %{"flagged" => 3, "rejected" => 2, "accepted" => 1}

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    subject_ids =
      Repo.all(
        from(a in Assignment,
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == ^@subject_type and is_nil(a.excluded_reason),
          select: a.subject_id
        )
      )

    case subject_ids do
      [] -> :insufficient_data
      ids -> ids |> labels(experiment_id) |> rate()
    end
  end

  defp labels(subject_ids, experiment_id) do
    Repo.all(
      from(s in Signal,
        where:
          s.experiment_id == ^experiment_id and s.subject_id in ^subject_ids and
            s.source_type == ^@source_type and s.status == "labelled",
        select: {s.source_id, s.label}
      )
    )
    |> Enum.filter(fn {_source_id, label} -> Map.has_key?(@rank, label) end)
    |> Enum.group_by(fn {source_id, _} -> insight_id(source_id) end, fn {_, label} -> label end)
    |> Enum.map(fn {_insight, labels} -> Enum.max_by(labels, &Map.fetch!(@rank, &1)) end)
  end

  # `source_id` is "<insight id>:<label>".
  defp insight_id(source_id), do: source_id |> String.split(":", parts: 2) |> hd()

  defp rate([]), do: :insufficient_data

  defp rate(labels) do
    n = length(labels)
    {:ok, %Result{value: Enum.count(labels, &(&1 == "accepted")) / n, n: n, unit: :ratio}}
  end
end
