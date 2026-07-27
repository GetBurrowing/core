defmodule Platform.Tasks.ArchitectureRejection do
  @moduledoc """
  ADR-0046 member 6 — everything downstream of a `"rejected"` architecture
  verdict. This stage is STATE AND ARITHMETIC ONLY: how many times in a row
  the architect has objected, what the bound on that is, and what the
  accumulated disagreement looks like. The writer, the lifecycle seam and
  the escalation land in later stages.

  Member 5 owns the verdict payload shape and the gate state machine
  (`Plan.architecture_verdict_changeset/2`, `Tasks.resolve_architecture_gate/3`).
  This module only READS what those wrote.

  ## The counter is DERIVED from the verdict history, not stored

  `streak/1` walks the task's plan versions newest-first and counts how many
  consecutive versions carry an `architecture_verdict["state"] == "rejected"`.
  Nothing is persisted. The length of that run IS the iteration count.

  The requirement is a count that SURVIVES v2 supersession, and the warning
  that motivates it — a per-PLAN counter resets on every new version — is
  correct. This design satisfies it more strongly than a column does: the
  streak is stored on neither the plan nor the task, so there is nothing to
  reset and therefore nothing that can be reset wrongly.

  That is not a hopeful reading of the supersession path, it is a
  structural property of the schema. `approve_plan/3`'s supersession
  rewrites older siblings through `Plan.changeset/2`, and
  `:architecture_verdict` is DELIBERATELY ABSENT from that changeset's cast
  list — it is castable only through `Plan.architecture_verdict_changeset/2`.
  Supersession cannot touch a verdict even by accident. (It is narrower
  still: it only rewrites siblings whose status is `approved` or
  `completed`, so an already-`rejected` v1 is not written at all.) `plans`
  rows are immutable history as far as this module is concerned.

  ### Rejected alternative: a `tasks.architecture_reject_count` column

  An integer column (`default: 0, null: false`) with a writer on each
  rejection was considered and rejected on three counts:

    1. It needs an explicit RESET rule for the third edge case — architect
       passes v2, a human rejects v2 later, v3 must not inherit the old
       count. Every reset rule is a second source of truth that can
       disagree with the verdict history.
    2. The escalation payload is derived from the SAME walk as the count
       (see `objection_history/1`). A column makes it possible to escalate
       saying "2 iterations" while only one objection exists to show the
       human — the number and the evidence would come from different
       places.
    3. It costs a migration, a T4 allow-list append, and a new writer on
       `tasks` while sibling members are concurrently editing that table
       and that module.

  If a reviewer wants the column anyway, the thing to reject is this
  section rather than the diff: `streak/1` is five lines and the swap is
  local.

  ## Why a non-reject verdict BREAKS the streak

  The walk stops at the first version whose verdict state is anything other
  than `"rejected"`. See `streak/1` for the soundness argument that makes
  the bound in `reject_limit/0` terminate.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanRejection
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task

  # The bound on consecutive architecture rejections before a human is
  # pulled in. See `reject_limit/0` for why this is a module attribute and
  # NOT `Application.get_env/3`.
  @architecture_reject_limit 2

  # A task whose execution has begun. Rejecting a plan whose executor
  # already has commits on a branch strands that branch, and this codebase
  # has no recovery path for it.
  @in_flight_task_statuses ~w(in_progress in_review deploying done)

  @doc """
  How many consecutive most-recent plan versions the architect has
  rejected, for `task_id`.

  Versions are walked in `version` DESCENDING order — `Tasks.list_plans/1`
  orders ascending by `version`, and this reverses it, so insertion order
  is irrelevant. The count stops at the first version whose verdict state
  is not `"rejected"`.

  ## What breaks the streak, and why that is conservative

  `"passed"`, `"human_override"`, `"expired"`, `"dispatch_failed"`, and
  `nil` (the gate never opened for that version) all end the run.

  So v1 rejected -> v2 passed -> v3 rejected yields 1, not 2. The pass
  ended the disagreement; a later architect objection is a fresh one. This
  deliberately UNDER-counts rather than over-counts, because an over-count
  escalates a human into an argument that was already settled.

  ## Why under-counting cannot hide an unbounded loop

  Checked against `Tasks.resolve_architecture_gate/3` rather than assumed:
  every terminal state other than `"rejected"` stops the architecture gate
  from blocking that version.

    * `:pass` and the two fall-open resolutions (`:expired`,
      `:dispatch_failed`) settle through `settle_plan_submission/1`, which
      hands the version to the normal approval path.
    * `:human_override` stops in the gate precisely BECAUSE `approve_plan/3`
      is mid-flight approving that version already.

  The property the bound actually rests on is weaker than "it approves" and
  is the one that matters: none of those states is a rejection, so none of
  them asks the planner for another version. A `nil` verdict means no
  architect held the slot for that version, which likewise produced no
  rejection. The only state that requests a new version is the one the run
  counts, so a run that keeps growing is exactly a loop that keeps going,
  and bounding the run bounds the loop.
  """
  @spec streak(binary()) :: non_neg_integer()
  def streak(task_id) when is_binary(task_id) do
    task_id |> rejected_run() |> length()
  end

  @doc """
  The maximum number of consecutive architecture rejections before the
  disagreement is escalated to a human.

  ## Deliberately NOT `Application.get_env/3`, and the asymmetry is the point

  Member 5's `architecture_gate_timeout_ms/0` IS a config knob. This is
  not, and the inconsistency is intentional — do not "fix" it.

  A timeout is an OPERATIONAL TUNING parameter: a deployment with slower
  architects wants a longer one, and getting it wrong costs latency. A loop
  bound is a CORRECTNESS INVARIANT: it is the only thing standing between
  an architect and a planner that will not converge. Exposing it as config
  means `architecture_reject_limit: 99` in a config file removes the bound
  with no code review — the amend-the-safety-net lever ADR-0046:20
  catalogues. Changing this number should require a diff to this file.

  Callers — including tests — read this accessor and never the literal. A
  guard that hardcodes its own copy of a value is how the class comes back.
  """
  @spec reject_limit() :: pos_integer()
  def reject_limit, do: @architecture_reject_limit

  @doc """
  Whether `task_id` has hit the bound and a human should be brought in.

  Every other module asks this question through this function rather than
  comparing `streak/1` to `reject_limit/0` itself, so the comparison
  operator exists in exactly one place.
  """
  @spec escalation_due?(binary()) :: boolean()
  def escalation_due?(task_id) when is_binary(task_id) do
    streak(task_id) >= reject_limit()
  end

  @doc """
  The accumulated disagreement: every version inside the current rejection
  streak, newest first.

  The SAME walk as `streak/1`, truncated at the SAME boundary — both call
  `rejected_run/1`, so `length(objection_history(task_id)) == streak(task_id)`
  holds by construction and is asserted directly in the tests. The count
  can never disagree with the evidence shown to the human.

  Each entry:

    * `:version`, `:plan_id` — which plan version this objection is against
    * `:summary`, `:resolved_at` — from the verdict, verbatim
    * `:findings` — the verdict's `"findings"` list VERBATIM, member 5's
      shape (`"stage_id"`, `"stage_name"`, `"constraint"`, `"detail"`).
      Consumed, never redefined: the `"constraint"` vocabulary is closed by
      `Plan.architecture_constraints/0` at the schema layer and again at
      the tool boundary, so anything reaching here has already passed both.
      This module does not re-validate it and does not contain a copy of
      it.
    * `:stage_names` — that version's stage names in position order

  `:stage_names` is what makes this the DISAGREEMENT rather than the
  verdict. The human sees what the architect asked for AND what the planner
  produced, for each version, side by side. A digest carrying only the
  latest verdict does not answer the question "have these two converged".
  """
  @spec objection_history(binary()) :: [map()]
  def objection_history(task_id) when is_binary(task_id) do
    task_id
    |> rejected_run()
    |> Repo.preload(stages: from(s in Stage, order_by: [asc: s.position]))
    |> Enum.map(&objection/1)
  end

  # THE ONE WALK. `streak/1` and `objection_history/1` are its only two
  # consumers and they must stay that way — a second copy of this walk is
  # how the count and the evidence drift apart.
  #
  # Newest-first, stopping at the first non-rejection.
  @spec rejected_run(binary()) :: [Plan.t()]
  defp rejected_run(task_id) do
    task_id
    |> Tasks.list_plans()
    |> Enum.reverse()
    |> Enum.take_while(&architecture_rejected?/1)
  end

  defp architecture_rejected?(%Plan{architecture_verdict: %{"state" => "rejected"}}), do: true
  defp architecture_rejected?(%Plan{}), do: false

  defp objection(%Plan{} = plan) do
    verdict = plan.architecture_verdict || %{}

    %{
      version: plan.version,
      plan_id: plan.id,
      summary: Map.get(verdict, "summary"),
      findings: Map.get(verdict, "findings", []),
      stage_names: Enum.map(plan.stages, & &1.name),
      resolved_at: Map.get(verdict, "resolved_at")
    }
  end

  # ── stage 3: the loop ─────────────────────────────────────────────────

  @doc """
  Everything that happens after the architect rejects `plan`.

  Called from `Tasks.resolve_architecture_gate/3`'s `:reject` branch, which
  is the only exit from the gate. Order of operations:

    1. Refuse outright if the plan is IN FLIGHT (see below).
    2. Otherwise consult `streak/1`, which ALREADY INCLUDES this version —
       `record_architecture_verdict/3` wrote `"rejected"` before this
       function was called, so the first rejection reads 1, not 0. That
       ordering is asserted in the tests rather than commented, because an
       off-by-one here escalates a version late, which is the unbounded
       loop in miniature.
    3. At or over `reject_limit/0`, escalate: the plan is left UNTOUCHED in
       `pending_review` and no new version is asked for.
    4. Below it, send the architect's findings back to the planner.

  ## Why there is no dedup key, no escalation flag and no `has_escalated` column

  `record_architecture_verdict/3` is ONE-SHOT: it arbitrates on the
  persisted row with an `UPDATE ... WHERE state = 'pending'`, so a second
  `:reject` against a resolved gate returns `{:error, :gate_already_resolved}`
  and NEVER reaches this function. Idempotence is therefore a property of
  the caller, not of this module — the gate can only resolve once per plan
  VERSION, and each version gets its own verdict row. A guard added here
  would do nothing. (The tests assert this from the outside, as a count
  delta on the second call.)

  ## Two delivery channels, both free, both carrying the IDENTICAL string

    * `Tasks.reject_plan/3` persists `status: "rejected"` +
      `rejection_reason` and broadcasts `{:plan_updated, _}`, which puts
      `TaskRouter` into `:waiting_human` so the router stops nagging. The
      persisted reason is also what
      `ContextAssembler.find_latest_rejected_reason/1` lifts into
      `previous_rejection_reason` on every dispatch context, so the
      findings survive a restart that eats the chat wake-up.
    * `PlanRejection.post_feedback/3` posts the same body as a NON-log-only
      engagement message, which is what actually wakes the planner via
      `AttentionRouter` and causes a v2 to be authored.

  Do not compose two bodies. The persisted reason is the durable truth and
  the post is best-effort on top of it — a failed post leaves the plan
  rejected with its reason intact and still returns `{:ok, :feedback_sent, _}`.

  ## Must not raise, ever

  This runs on the gate-resolution path, reached from the
  `plan_architecture_verdict` MCP tool and from `handle_output/3` inside
  `run_external_dispatch/5`. Mirrors `fire_architecture_review_plan/1`:
  errors are RETURNED, never raised.
  """
  @spec handle(Plan.t()) :: {:ok, :feedback_sent | :escalated, Plan.t()} | {:error, term()}
  def handle(%Plan{} = plan) do
    plan = Repo.preload(plan, :stages)
    task = Repo.get(Task, plan.task_id)

    cond do
      in_flight?(plan, task) -> refuse_in_flight(plan, task)
      escalation_due?(plan.task_id) -> escalate(plan)
      true -> send_feedback(plan)
    end
  rescue
    e ->
      Logger.warning(
        "[ArchitectureRejection] handle/1 crashed plan=#{inspect(Map.get(plan, :id))}: " <>
          Exception.message(e)
      )

      {:error, :architecture_rejection_crashed}
  catch
    :exit, reason ->
      Logger.warning(
        "[ArchitectureRejection] handle/1 exited plan=#{inspect(Map.get(plan, :id))}: " <>
          inspect(reason)
      )

      {:error, :architecture_rejection_crashed}
  end

  @doc """
  The structured feedback body the planner reads, and the same string
  persisted as the plan's `rejection_reason`.

  Generated from the verdict's `"findings"` and never from free text: prose
  alone produces a differently-worded v2 rather than a better one.

  The `iteration <k> of <limit>` line is not decoration — it is the
  planner's only signal that it is on its last attempt before a human is
  pulled in.

  `constraint` is rendered VERBATIM from the verdict and is never mapped to
  prettier prose: the planner and the validator must speak one vocabulary,
  and `Plan.architecture_constraints/0` is that closed contract. This module
  contains no copy of those literals — a test asserts the source text does
  not contain one.

  A finding's stage name comes from the verdict's own `"stage_name"` when
  present, else from `plan.stages`, else renders `(plan-wide)`: member 5's
  shape allows a nil `stage_id`.

  Empty `findings` still renders, with the summary and the instruction and
  no findings block. Member 5's tool refuses an empty-findings reject at the
  boundary, so this branch is unreachable through the sanctioned surface; it
  exists only so a hand-written verdict cannot produce an empty message.
  """
  @spec compose_feedback(Plan.t()) :: String.t()
  def compose_feedback(%Plan{} = plan) do
    verdict = plan.architecture_verdict || %{}
    findings = Map.get(verdict, "findings") || []
    iteration = streak(plan.task_id)

    header =
      "Architecture gate: plan v#{plan.version} rejected " <>
        "(iteration #{iteration} of #{reject_limit()})."

    [header, Map.get(verdict, "summary"), findings_block(findings, plan), instruction()]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp findings_block([], _plan), do: nil

  defp findings_block(findings, plan) do
    body =
      findings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {finding, index} ->
        "#{index}. Stage: #{stage_label(finding, plan)}\n" <>
          "   Constraint: #{Map.get(finding, "constraint")}\n" <>
          "   Change: #{Map.get(finding, "detail")}"
      end)

    "Findings:\n" <> body
  end

  defp stage_label(finding, plan) do
    stage_id = Map.get(finding, "stage_id")

    case finding_stage_name(finding, plan, stage_id) do
      nil -> "(plan-wide)"
      name -> ~s("#{name}") <> " (#{stage_id})"
    end
  end

  defp finding_stage_name(_finding, _plan, nil), do: nil

  defp finding_stage_name(finding, plan, stage_id) do
    case Map.get(finding, "stage_name") do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case Enum.find(plan_stages(plan), &(&1.id == stage_id)) do
          %Stage{name: name} -> name
          _ -> nil
        end
    end
  end

  defp plan_stages(%Plan{stages: stages}) when is_list(stages), do: stages
  defp plan_stages(_plan), do: []

  # The count is read from `Plan.architecture_constraints/0` rather than
  # written as a word, so the sentence cannot go stale if member 5 widens
  # the vocabulary — and so this file contains no copy of the literals.
  defp instruction do
    """
    Every finding names a stage and one of the #{length(Plan.architecture_constraints())} architecture constraints. Produce a v2
    plan that resolves all of them. A finding is resolved by changing the plan's structure,
    not by rewording the stage description.
    """
    |> String.trim_trailing()
  end

  # THE FEEDBACK PATH. Persist first (the durable truth), post second (the
  # wake-up). A failed post is swallowed by `post_feedback/3` itself.
  defp send_feedback(%Plan{} = plan) do
    body = compose_feedback(plan)
    actor = architect_actor(plan)

    case Tasks.reject_plan(plan, actor, body) do
      {:ok, rejected} ->
        _ = PlanRejection.post_feedback(rejected, actor, body)
        {:ok, :feedback_sent, rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stage 4 lands the digest, the recipient chain and the escalation
  # telemetry here. The BOUND is already whole without them: the plan is
  # left untouched in `pending_review`, so nothing asks for another version
  # and the loop has stopped. What stage 4 adds is the human's
  # notification, not the stop.
  defp escalate(%Plan{} = plan), do: {:ok, :escalated, plan}

  # THE IN-FLIGHT GUARD, asserted rather than assumed. Two tests bracket
  # it: one calls `handle/1` directly on an in-flight plan and sees the
  # refusal, the other proves the sanctioned path cannot reach that state
  # (an approved plan's gate is already resolved, so
  # `record_architecture_verdict/3` refuses before this function runs).
  defp in_flight?(%Plan{} = plan, task) do
    Enum.any?(plan_stages(plan), &(&1.status != "pending")) or
      match?(%Task{status: status} when status in @in_flight_task_statuses, task)
  end

  defp refuse_in_flight(%Plan{} = plan, task) do
    :telemetry.execute(
      [:platform, :plan, :architecture_reject_refused_in_flight],
      %{count: 1},
      %{
        task_id: plan.task_id,
        plan_id: plan.id,
        task_status: task && task.status,
        resource_type: "plan",
        resource_id: plan.id,
        action: "architecture_reject_refused_in_flight",
        actor_type: "system"
      }
    )

    {:error, :plan_in_flight}
  end

  # Who the rejection is attributed to. The verdict's own `"resolved_by"`
  # is the architect that answered; `PlanRejection.actor_display_name/1`
  # resolves it through the user tier and then the AGENT tier, which is the
  # widening stage 2 landed for exactly this caller.
  defp architect_actor(%Plan{architecture_verdict: %{"resolved_by" => id}}) when is_binary(id),
    do: id

  defp architect_actor(%Plan{}), do: nil
end
