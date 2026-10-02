defmodule Platform.Experiments.Metrics.GameStreamInputToPhoton do
  @moduledoc """
  Mean median input-to-photon round trip, in milliseconds, over a variant's
  play sessions. Task 01a0db5f stage 2, the metric for the
  `game_stream.encoder_preset` surface. Lower is better.

  ## What one measurement is

  One ENDED session's `rtt_p50_ms` from `game_stream_sessions` — the median
  of that session's probe round trips, as the viewer's browser last reported
  them. The unit is the session, not the probe: a long session must not
  outweigh a short one fifty to one, and the per-probe samples are not kept.

  ## Which sessions count

  Sessions whose task is a non-excluded subject of the variant
  (`Metrics.subject_ids/2`) AND whose row records the same experiment and
  variant, either as its encoder arm (`experiment_id` / `variant_slug`) or,
  since task 01a0dbd6, as its roster arm (`roster_experiment_id` /
  `roster_variant_slug`). The second condition matters: a task can be played more than
  once, and a session that ran after the experiment stopped resolved a
  different arm (or the default) — its latency is not evidence about this
  one. Sessions that never reported stats (`rtt_p50_ms IS NULL`) are
  EXCLUDED, not zero: a stream that never went live measured nothing, and
  zero would read as a perfect result.

  ## Several players

  A multiplayer row's `rtt_p50_ms` is its WORST slot's median
  (`Platform.GameStream.SessionRecord`), so a session is as good as its
  worst-served player. A one-player row is unchanged.

  An empty sample is `:insufficient_data`.
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
          where: not is_nil(s.rtt_p50_ms),
          select: s.rtt_p50_ms
        )
        |> Repo.all()
        |> Metrics.mean(:ms)
    end
  end
end
