defmodule Platform.Experiments.Metrics.GameStreamInputToPhotonP95 do
  @moduledoc """
  Mean WORST-SLOT p95 input-to-photon round trip, in milliseconds, over a
  variant's play sessions. Task 01a0dbd6 (multiplayer game_stream): the
  metric its plan names for the `game_stream.roster` surface. Lower is
  better.

  One measurement is one ENDED session's `rtt_p95_ms` from
  `game_stream_sessions`, which since task 01a0dbd6 is the worst player
  slot's p95 (`Platform.GameStream.SessionRecord`). The tail, not the
  median, because a fan-out that starves one player shows there first; the
  worst slot, because a session is as good as its worst-served player.

  Which sessions count is exactly `GameStreamInputToPhoton`'s rule: subjects
  of the variant whose row records the same experiment and variant as its
  encoder arm or its roster arm, excluding rows that never reported a p95
  (null, not zero). An empty sample is `:insufficient_data`.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.GameStream.SessionRecord
  alias Platform.Repo

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        from(s in SessionRecord,
          where: s.task_id in ^subject_ids,
          where:
            (s.experiment_id == ^experiment_id and s.variant_slug == ^variant_slug) or
              (s.roster_experiment_id == ^experiment_id and
                 s.roster_variant_slug == ^variant_slug),
          where: not is_nil(s.rtt_p95_ms),
          select: s.rtt_p95_ms
        )
        |> Repo.all()
        |> Metrics.mean(:ms)
    end
  end
end
