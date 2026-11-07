defmodule Platform.Experiments.Metrics.UxFindingKeepRate do
  @moduledoc """
  Share of UX DECISIONS a human keeps rather than dismisses, over a variant's
  workspace subjects on the `ux.friction_detection` surface. Task 01a1af00
  stage 1, narrowed to decisions in stage 4.

    * kept: the finding is `answered`, i.e. "Build it" or "Try the other
      option" (`Platform.Ux.Decisions.answer/4`);
    * dismissed: the finding is `dismissed` ("Not now"), OR it is still open
      but its recipient dismissed the `ux_decision` Inbox row (swiped it,
      cleared the Inbox) without answering.

  Only `decision` findings count: an `fyi` asks nothing, and the weekly
  digest marks it `posted`, never answered. A finding counts for an arm
  when its `variant` is that arm's slug and its workspace (the nil UUID for
  an org-wide fire) is an assigned, non-excluded subject of the experiment.
  An open decision whose row is still listed is unresolved and enters
  neither side; no resolved decision means `:insufficient_data`, never a
  zero over zero rows.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Ux.Finding

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @impl true
  def compute(experiment_id, variant_slug) do
    statuses =
      Repo.all(
        from(f in Finding,
          join: a in Assignment,
          on:
            a.subject_id ==
              fragment("coalesce(?, ?)", f.workspace_id, type(^@nil_uuid, Ecto.UUID)),
          left_join: i in Item,
          on:
            i.source_type == "ux_finding" and i.kind == "ux_decision" and
              i.source_id == f.id and i.user_id == f.recipient_user_id and
              not is_nil(i.dismissed_at),
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == "workspace" and is_nil(a.excluded_reason) and
              f.variant == ^variant_slug and f.kind == "decision" and
              (f.status in ["answered", "dismissed"] or
                 (f.status == "open" and not is_nil(i.id))),
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
