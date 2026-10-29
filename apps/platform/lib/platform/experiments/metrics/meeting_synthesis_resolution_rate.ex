defmodule Platform.Experiments.Metrics.MeetingSynthesisResolutionRate do
  @moduledoc """
  Share of judged meeting synthesis findings confirmed/aligned rather than
  dismissed. Counts each finding once, by its origin meeting assignment;
  unresolved findings do not enter the denominator. Task 01a16974 stage 3.
  """
  @behaviour Platform.Experiments.Metric
  import Ecto.Query
  alias Platform.{Repo, Experiments.Assignment, Meetings.SynthesisFinding}
  alias Platform.Experiments.Metric.Result
  @impl true
  def compute(experiment_id, variant_slug) do
    labels =
      Repo.all(
        from(f in SynthesisFinding,
          join: a in Assignment,
          on: a.subject_id == f.origin_meeting_id,
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == "meeting" and is_nil(a.excluded_reason) and not is_nil(f.receipt),
          distinct: f.id,
          select: f.receipt
        )
      )
      |> Enum.map(& &1["verb"])
      |> Enum.filter(
        &(&1 in ["confirm", "confirmed", "align", "aligned", "dismiss", "dismissed"])
      )

    case labels do
      [] ->
        :insufficient_data

      labels ->
        {:ok,
         %Result{
           value:
             Enum.count(labels, &(&1 in ["confirm", "confirmed", "align", "aligned"])) /
               length(labels),
           n: length(labels),
           unit: :ratio
         }}
    end
  end
end
