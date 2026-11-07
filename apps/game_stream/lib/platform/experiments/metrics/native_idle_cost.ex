defmodule Platform.Experiments.Metrics.NativeIdleCost do
  @moduledoc "Idle server-seconds per connected player-minute, measured only on ended native sessions."
  @behaviour Platform.Experiments.Metric
  import Ecto.Query
  alias Platform.{Repo, Experiments}
  alias Platform.GameStream.NativeSessionRecord

  def compute(experiment_id, variant_slug) do
    rows =
      Repo.all(
        from(s in NativeSessionRecord,
          join: a in Experiments.Assignment,
          on: a.subject_id == s.channel_id,
          where:
            a.subject_type == "channel" and a.experiment_id == ^experiment_id and
              a.variant_slug == ^variant_slug and is_nil(a.excluded_reason),
          where:
            s.experiment_id == ^experiment_id and s.variant_slug == ^variant_slug and
              not is_nil(s.ended_at) and s.player_seconds > 0,
          select: fragment("?::float * 60.0 / ?", s.idle_seconds, s.player_seconds)
        )
      )

    Experiments.Metrics.mean(rows, :seconds_per_player_minute)
  end
end
