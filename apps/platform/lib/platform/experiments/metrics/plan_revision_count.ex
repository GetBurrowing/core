defmodule Platform.Experiments.Metrics.PlanRevisionCount do
  @moduledoc """
  Mean number of plan REVISIONS per task, over a variant's subjects.
  Task 019fe6b9, ADR-0048; extended by task 01a05bef.

  ## What a REVISION is: a plan row PLUS an in-place draft correction

  A revision is any act of re-planning, and there are two ways to perform
  one:

    * **Discard and re-plan** — a new `plans` row for the task. Counted by
      `plan_counts/1`.
    * **Correct the draft in place** — `plan_update` over MCP, which calls
      `Tasks.replace_plan_stages/3` to swap the stage tree on the SAME plan
      row. `plan_id` and `version` deliberately do not move.

  The two sources are ADDITIVE, not alternatives: they are disjoint writers
  on disjoint tables. A new plan row never emits `plan_updated`, and an
  in-place correction never inserts a plan row, so no revision is counted
  twice.

  This matters because the metric is registered `:lower_is_better` — it
  asserts that fewer revisions is a better planner, i.e. it measures how
  much re-planning a prompt variant causes. Counting only plan rows made an
  in-place corrector score identically to a planner that got it right first
  time, and ADR-0048 Decision 5(d) gates auto-promotion on secondary-metric
  regression, so that blind spot was a promotion hazard, not a rounding
  error.

  `replace_plan_stages/3`'s stable-`version` semantics are endorsed and
  deliberately unchanged by this metric: the fix belongs in the measurement,
  not in the write path.

  ### KNOWN RESIDUAL GAP

  The `[:platform, :tasks, :plan_updated]` audit row is written by the MCP
  tool layer — `Platform.Federation.ToolSurface.do_plan_update/4`
  (`apps/platform/lib/platform/federation/tool_surface.ex`, the
  `emit_plan_updated/4` call) — and NOT by `Tasks.replace_plan_stages/3`
  itself. An in-process caller of the context function therefore performs a
  revision this metric cannot see. That is acceptable today only because the
  tool is the sole non-test caller of `replace_plan_stages/3` in `lib/`. A
  second caller would silently reintroduce the undercount, so it is a known
  thing to fix rather than a surprise: either move the emit into the context
  function, or count from a source the context function writes.

  ## What `n` counts: TASKS that have at least one plan

  A task with no plans contributes nothing and is not a zero — it has not
  been planned yet, which is a different fact from having been planned once.

  This is why the combine below is keyed on the PLAN map and never on the
  union of the two maps. A `plan_updated` audit row for a task with no
  surviving plan row must not manufacture a unit — that would fabricate the
  very zero the grouping avoids, and would move `n`.

  ## Counting plan ROWS, and the trap that made that the right choice

  A task's versions are exactly its plan rows, so this counts rows per task.
  The alternative — counting supersessions — is where the trap is, and it is
  worth writing down because the obvious query is wrong.

  Approving a plan supersedes the task's older `approved`/`completed`
  siblings inside the approval transaction. The supersession sets the OLD
  sibling's `superseded_by_plan_id` to point FORWARD at the new plan, and
  sets that sibling's `status` to `"rejected"` — the SAME value a human
  rejection writes. The two are distinguishable only by
  `superseded_by_plan_id` being non-nil.

  So `count(status == "rejected")` silently sums re-planning and human
  disapproval and returns a perfectly plausible number while doing it. If a
  supersession count is ever wanted, the predicate is
  `superseded_by_plan_id IS NOT NULL` and never the status. Same disease as
  collapsing `stopped` into `concluded`: one value carrying two meanings, so
  the difference is unrecoverable after the write.

  Counting rows sidesteps the question entirely: every version is a row
  whether it was superseded, rejected, or is the one currently in force.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Audit.Event
  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.Plan

  # `event_type` is the dotted join of the telemetry event name, persisted by
  # Platform.Audit.TelemetryHandler.
  @plan_updated_event "platform.tasks.plan_updated"

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        plans = plan_counts(subject_ids)
        rewrites = rewrite_counts(subject_ids)

        plans
        |> Enum.map(fn {task_id, plan_count} ->
          plan_count + Map.get(rewrites, task_id, 0)
        end)
        |> Metrics.mean(:count)
    end
  end

  # Grouped over the plans table, so only tasks that HAVE plans appear. An
  # inner grouping cannot manufacture a zero for a task with none. This map's
  # KEYS define the units of the metric; see the moduledoc.
  @spec plan_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  defp plan_counts(subject_ids) do
    Plan
    |> where([p], p.task_id in ^subject_ids)
    |> group_by([p], p.task_id)
    |> select([p], {p.task_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  # In-place draft corrections, read from the append-only audit stream. The
  # task id lives in the metadata jsonb (`resource_id` holds the PLAN id), as
  # a canonical UUID string, which compares directly against the
  # `Ecto.UUID`-loaded subject ids with no cast.
  @spec rewrite_counts([Ecto.UUID.t()]) :: %{String.t() => non_neg_integer()}
  defp rewrite_counts(subject_ids) do
    Event
    |> where([e], e.event_type == @plan_updated_event)
    |> where([e], fragment("?->>'task_id'", e.metadata) in ^subject_ids)
    |> group_by([e], fragment("?->>'task_id'", e.metadata))
    |> select([e], {fragment("?->>'task_id'", e.metadata), count(e.id)})
    |> Repo.all()
    |> Map.new()
  end
end
