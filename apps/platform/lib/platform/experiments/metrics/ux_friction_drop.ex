defmodule Platform.Experiments.Metrics.UxFrictionDrop do
  @moduledoc """
  Post-ship friction drop over a variant's workspace subjects on the
  `ux.friction_detection` surface: the UX super agent's north star (task
  01a1f048). The computation is `Platform.Ux.FrictionDrop`; this module only
  narrows it to one arm.

  A finding counts for an arm when its `variant` is that arm's slug and its
  workspace (the nil UUID for an org-wide fire) is an assigned, non-excluded
  subject of the experiment, the same subject rule
  `Platform.Experiments.Metrics.UxFindingKeepRate` uses. The value is the
  pooled drop `1 - after / before`; `n` is the number of settled findings
  with a baseline. No such finding means `:insufficient_data`.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Repo
  alias Platform.Ux.Finding
  alias Platform.Ux.FrictionDrop

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @impl true
  def compute(experiment_id, variant_slug) do
    ids =
      Repo.all(
        from(f in Finding,
          join: a in Assignment,
          on:
            a.subject_id ==
              fragment("coalesce(?, ?)", f.workspace_id, type(^@nil_uuid, Ecto.UUID)),
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == "workspace" and is_nil(a.excluded_reason) and
              f.variant == ^variant_slug and not is_nil(f.task_id),
          distinct: f.id,
          select: f.id
        )
      )

    case ids do
      [] ->
        :insufficient_data

      ids ->
        case FrictionDrop.summary(finding_ids: ids) do
          %{value: value, n: n} when is_float(value) ->
            {:ok, %Result{value: value, n: n, unit: :ratio}}

          _ ->
            :insufficient_data
        end
    end
  end
end
