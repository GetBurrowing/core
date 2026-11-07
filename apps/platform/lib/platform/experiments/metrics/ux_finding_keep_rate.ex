defmodule Platform.Experiments.Metrics.UxFindingKeepRate do
  @moduledoc """
  Share of resolved UX findings a human KEEPS (`answered`) rather than
  `dismissed`, over a variant's workspace subjects on the
  `ux.friction_detection` surface. Task 01a1af00 stage 1.

  A finding counts for an arm when its `variant` is that arm's slug and its
  workspace (the nil UUID for an org-wide fire) is an assigned, non-excluded
  subject of the experiment. Open findings are unresolved and enter neither
  side of the ratio; no resolved finding means `:insufficient_data`, never a
  zero over zero rows.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Repo
  alias Platform.Ux.Finding

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @impl true
  def compute(experiment_id, variant_slug) do
    statuses =
      Repo.all(
        from(f in Finding,
          join: a in Assignment,
          on: a.subject_id == fragment("coalesce(?, ?::uuid)", f.workspace_id, ^@nil_uuid),
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == "workspace" and is_nil(a.excluded_reason) and
              f.variant == ^variant_slug and f.status in ["answered", "dismissed"],
          distinct: f.id,
          select: f.status
        )
      )

    case statuses do
      [] ->
        :insufficient_data

      statuses ->
        {:ok,
         %Result{
           value: Enum.count(statuses, &(&1 == "answered")) / length(statuses),
           n: length(statuses),
           unit: :ratio
         }}
    end
  end
end
