defmodule Platform.Experiments.Metrics.OverscopedGateCount do
  @moduledoc """
  Mean number of OVERSCOPED manual_approval gates per plan, over the plans of
  a variant's subjects. Task 01a00c96, ADR-0048.

  An overscoped gate is a `manual_approval` validation on a stage whose
  description contains no UI-touching token — the exact condition
  `Platform.Tasks.PlanEngine.check_manual_approval_heuristic/1` already logs
  as "likely overscoped manual_approval". This metric adds no detection; it
  counts what the advisory has been emitting into the log all along.

  ## What `n` counts: PLANS, not tasks and not gates

  One plan is one unit. A task with three plans contributes three units, and
  a plan carrying four overscoped gates is still ONE unit with the value 4.
  Reading `n` as tasks or as gates misreports the sample a human is deciding
  on.

  ## A plan with no gates is a real zero

  The plan ids are loaded in their own query rather than derived from the
  gate rows, so a plan with zero overscoped gates contributes a genuine `0`.
  Deriving the units from the gate rows would make the common no-gate plan
  invisible and inflate every mean toward the behaviour of the small subset
  of plans that gate at all. A task with NO plans is still absent rather than
  zero — it is not a planned unit, so there is nothing to measure.

  ## The predicate is borrowed, never re-stated

  The UI test is `PlanEngine.ui_touching?/1`. Its token list stays in
  `PlanEngine`. A second copy here would drift from the advisory, and this
  metric would then measure a rule the platform no longer applies — the
  precise failure task 01a006d1 was filed for.

  ## Direction: `:lower_is_better`, argued

  There is no legitimate reason to put a human review gate on a stage that
  renders nothing, so a fall in this number can only mean planners stopped
  doing that. The `:neutral` argument that settled
  `manual_gate_rejection_rate` does not transfer: that metric is gameable in
  BOTH directions (ask for fewer reviews and the count falls; ask for fewer
  and worse and the rate rises), whereas driving this one to zero by
  attaching no gates at all sacrifices the UI gates too — and losing those
  is exactly what the sibling advisory ("likely missed UI manual_approval")
  and `manual_gate_rejection_rate` are watching for. A gaming strategy that
  another registered metric catches is not a reason to refuse to read this
  one.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @manual_approval "manual_approval"

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        case plan_ids(subject_ids) do
          [] -> :insufficient_data
          plan_ids -> plan_ids |> overscoped_counts() |> Metrics.mean(:count)
        end
    end
  end

  defp plan_ids(subject_ids) do
    Plan
    |> where([p], p.task_id in ^subject_ids)
    |> select([p], p.id)
    |> Repo.all()
  end

  # The UI predicate is Elixir, not SQL, so the rows come back unfiltered on
  # the description and the tally happens here.
  defp overscoped_counts(plan_ids) do
    tally =
      Plan
      |> where([p], p.id in ^plan_ids)
      |> join(:inner, [p], s in Stage, on: s.plan_id == p.id)
      |> join(:inner, [p, s], v in Validation, on: v.stage_id == s.id)
      |> where([p, s, v], v.kind == ^@manual_approval)
      |> select([p, s, v], {p.id, s.description})
      |> Repo.all()
      |> Enum.reject(fn {_plan_id, description} -> PlanEngine.ui_touching?(description) end)
      |> Enum.frequencies_by(fn {plan_id, _description} -> plan_id end)

    Enum.map(plan_ids, &Map.get(tally, &1, 0))
  end
end
