defmodule Platform.Experiments.Metrics.UnblockAsksResolvedPerSent do
  @moduledoc """
  Asks resolved over asks sent, over a variant's subjects on the
  `agents.unblock_ask.reask_interval` surface (task 01a1b6de stage 4).

    * sent: every send of an ask, the first and each re-ask
      (`unblock_asks.ask_count`);
    * resolved: an ask whose status is `resolved`.

  An ask counts for an arm when its `variant` is the arm's slug and its
  subject is an assigned, non-excluded `unblock_subject` of the experiment.
  No ask means `:insufficient_data`, never zero over zero.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Agents.UnblockAsk
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Repo

  @impl true
  def compute(experiment_id, variant_slug) do
    rows =
      Repo.all(
        from(u in UnblockAsk,
          join: a in Assignment,
          on: a.subject_id == u.subject_id,
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == "unblock_subject" and is_nil(a.excluded_reason) and
              u.variant == ^variant_slug,
          distinct: u.id,
          select: {u.status, u.ask_count}
        )
      )

    sent = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if sent == 0 do
      :insufficient_data
    else
      resolved = Enum.count(rows, &(elem(&1, 0) == "resolved"))
      {:ok, %Result{value: resolved / sent, n: sent, unit: :ratio}}
    end
  end
end
