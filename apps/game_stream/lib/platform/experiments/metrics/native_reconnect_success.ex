defmodule Platform.Experiments.Metrics.NativeReconnectSuccess do
  @moduledoc "Reconnect guardrail: successful re-admissions / reconnect reservations."
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
              not is_nil(s.ended_at) and s.reconnect_attempts > 0,
          select: fragment("?::float / ?", s.reconnect_count, s.reconnect_attempts)
        )
      )

    Experiments.Metrics.mean(rows, :ratio)
  end
end
