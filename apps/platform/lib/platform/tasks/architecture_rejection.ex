defmodule Platform.Tasks.ArchitectureRejection do
  @moduledoc """
  ADR-0046 member 6 — everything downstream of a `"rejected"` architecture
  verdict: how many times in a row the architect has objected (`streak/1`),
  what the bound on that is (`reject_limit/0`), what the accumulated
  disagreement looks like (`objection_history/1`), and what happens on each
  side of the bound (`handle/1` — feedback to the planner below it, an
  escalation to a human at it).

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

  alias Platform.Inbox
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanRejection
  alias Platform.Tasks.Stack
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
  with no code review — the amend-the-safety-net lever catalogued by
  `0046-design-and-architecture-phases-in-planning.md § Context`.
  Changing this number should require a diff to this file.

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
    * `:stages` — the same stages as `%{id:, name:}` maps, in the same
      order. `:stage_names` is derived from it, so the two cannot
      disagree. The digest needs the ids as well as the names: a finding
      may carry a `"stage_id"` and no `"stage_name"` (member 5's shape
      allows it, and the MCP tool does not backfill), and rendering
      `(plan-wide)` for a finding that names a real stage would tell the
      human the architect objected to the plan as a whole when it did
      not.

  `:stage_names` is what makes this the DISAGREEMENT rather than the
  verdict. The human sees what the architect asked for AND what the planner
  produced, for each version, side by side. A digest carrying only the
  latest verdict does not answer the question "have these two converged".
  """
  @spec objection_history(binary()) :: [map()]
  def objection_history(task_id) when is_binary(task_id) do
    task_id
    |> rejected_run()
    # A query-level preload REPLACES `Plan.has_many(:stages)`'s own
    # `preload_order` rather than merging with it, so the tiebreak is repeated
    # here. `position` is not unique — no unique index on `(plan_id, position)`
    # and no uniqueness validation; see the argument at
    # `PlanEngine.open_remediation_stage_for/1` — so `asc: :position` alone is
    # not a total order, and `:stage_names` below is a POSITIONAL list a human
    # reads next to the architect's finding. Two stages sharing a position and
    # no tiebreak means the same rejection history can render in two different
    # orders on two refreshes. `asc: :id` makes it total and stable; it does
    # not promise creation order, since `Platform.Types.UUIDv7`'s counter wraps
    # at 4096 per millisecond and its timestamp is a wall clock. Ticket
    # 01a089e6.
    |> Repo.preload(stages: from(s in Stage, order_by: [asc: s.position, asc: s.id]))
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
    stages = Enum.map(plan.stages, &%{id: &1.id, name: &1.name})

    %{
      version: plan.version,
      plan_id: plan.id,
      summary: Map.get(verdict, "summary"),
      findings: Map.get(verdict, "findings", []),
      stages: stages,
      stage_names: Enum.map(stages, & &1.name),
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
      escalation_due?(plan.task_id) -> escalate(plan, task)
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

  The version the planner is asked to produce is DERIVED from
  `plan.version`, never written as a literal: a second rejection must ask for
  a v3, not re-ask for the v2 the architect has just turned down.

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

    [header, Map.get(verdict, "summary"), findings_block(findings, plan), instruction(plan)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp findings_block([], _plan), do: nil

  defp findings_block(findings, plan) do
    body =
      findings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {finding, index} ->
        "#{index}. Stage: #{stage_label(finding, plan_stages(plan))}\n" <>
          "   Constraint: #{Map.get(finding, "constraint")}\n" <>
          "   Change: #{Map.get(finding, "detail")}"
      end)

    "Findings:\n" <> body
  end

  defp stage_label(finding, stages) do
    stage_id = Map.get(finding, "stage_id")

    case finding_stage_name(finding, stages, stage_id) do
      nil -> "(plan-wide)"
      name -> ~s("#{name}") <> " (#{stage_id})"
    end
  end

  # ONE fallback order — the verdict's own `"stage_name"`, else a lookup by
  # id, else nil — shared by the feedback body and the escalation digest.
  # `stages` is a list of anything carrying `:id` and `:name`, which is both
  # `%Stage{}` (the feedback path, holding `plan.stages`) and the
  # `objection_history/1` entry's `:stages` maps (the digest path). Two
  # copies of this order is how the two messages would come to name the
  # same finding differently.
  defp finding_stage_name(_finding, _stages, nil), do: nil

  defp finding_stage_name(finding, stages, stage_id) do
    case Map.get(finding, "stage_name") do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case Enum.find(stages, &(&1.id == stage_id)) do
          %{name: name} when is_binary(name) -> name
          _ -> nil
        end
    end
  end

  defp plan_stages(%Plan{stages: stages}) when is_list(stages), do: stages
  defp plan_stages(_plan), do: []

  # The count is read from `Plan.architecture_constraints/0` rather than
  # written as a word, so the sentence cannot go stale if member 5 widens
  # the vocabulary — and so this file contains no copy of the literals.
  #
  # The VERSION is derived for the same reason. This sentence used to name
  # version 2 literally, which is true only of the FIRST rejection: at
  # iteration 2 the planner is being asked for a v3, and on a task that
  # reached the gate with a v3 already in hand, a v4. Naming a version the
  # planner has already superseded asks for the wrong artefact at exactly the
  # moment the header is telling it this is its last attempt. Nothing caught
  # it because no `expected` clause reads this string — hence the source
  # guard in `ArchitectureRejectionLoopTest`, which is why this comment does
  # not quote the old wording verbatim.
  defp instruction(%Plan{} = plan) do
    """
    Every finding names one of the #{length(Plan.architecture_constraints())} architecture constraints, and names the stage it applies to unless it objects to the plan AS A WHOLE — those read `(plan-wide)` and mean the decomposition itself, not any one stage. Produce #{next_version_phrase(plan)}
    plan that resolves all of them. A finding is resolved by changing the plan's structure,
    not by rewording the stage description.
    """
    |> String.trim_trailing()
  end

  # `plan.version` is the version the architect just rejected, so the planner
  # is being asked for the one after it.
  defp next_version_phrase(%Plan{version: version}) when is_integer(version),
    do: "a v#{version + 1}"

  # `plans.version` is NOT NULL, so a plan with no version only reaches here
  # through a hand-built struct. Say "the next" rather than crash or guess a
  # number — guessing is the defect this clause exists to avoid repeating.
  defp next_version_phrase(%Plan{}), do: "the next"

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

  # THE ESCALATION PATH. The BOUND was already whole before this stage: the
  # plan is left untouched in `pending_review`, so nothing asks for another
  # version and the loop has stopped. What this adds is the human's
  # notification, not the stop — which is why every step of it is
  # best-effort and none of it can change the outcome returned to the gate.
  #
  # Order: digest first (the evidence), inbox second (the summons), then
  # telemetry naming which tier was actually reached. `plan` is returned
  # UNTOUCHED — no reject, no new lifecycle state, no new gate state.
  defp escalate(%Plan{} = plan, task) do
    history = objection_history(plan.task_id)

    _ = post_digest(plan, history)
    recipient = emit_escalation_inbox(plan, task, history)

    :telemetry.execute(
      [:platform, :plan, :architecture_reject_loop_escalated],
      %{count: 1},
      %{
        task_id: plan.task_id,
        plan_id: plan.id,
        iterations: length(history),
        recipient: recipient,
        resource_type: "plan",
        resource_id: plan.id,
        action: "architecture_escalated",
        actor_type: "system"
      }
    )

    {:ok, :escalated, plan}
  end

  @doc """
  Whether `task_id` is parked on a human because the architect and the
  planner did not converge.

  DERIVED, like the streak itself: `escalation_due?/1` (the bound was hit)
  AND the newest plan is still `pending_review` (nobody has decided yet).
  There is no `escalated` column, no `escalated_at`, and deliberately no new
  value in `Plan.architecture_gate_states/0` — member 5 owns that enum, and
  `"rejected"` is what the architect said. "We escalated" is a task-level
  fact about the CONVERSATION, not a sixth thing the architect could have
  answered.

  The `pending_review` half is what makes this go false again. A human who
  approves v2 over the objection, or rejects it with their own direction,
  moves the plan out of `pending_review` — while the streak stays at 2,
  because approving does NOT rewrite v2's verdict (a resolved gate refuses a
  second write). Reading `escalation_due?/1` alone would leave the task
  flagged as awaiting a human forever after that human answered.

  Exposed for member 8, which renders the card. This stage renders nothing.
  """
  @spec escalated?(binary()) :: boolean()
  def escalated?(task_id) when is_binary(task_id) do
    escalation_due?(task_id) and
      match?(%Plan{status: "pending_review"}, Tasks.latest_plan(task_id))
  end

  @doc """
  The digest a human reads: what the architect asked for and what the
  planner produced, for EVERY version in the streak, newest first.

  Not the latest verdict. The question the human has to answer is "have
  these two converged", and the latest verdict cannot answer it — it looks
  identical whether the planner ignored the objection or addressed it and
  drew a new one. Each round therefore carries BOTH sides: the planner's
  stage names and the architect's findings against them.

  The footer names the decision, because the plan is not in a new state and
  the board card is the ordinary `pending_review` one: approve v2 over the
  objection, or reject it with your own direction. Both buttons already
  work — member 5's gate is RESOLVED, so `approve_plan/3`'s guard is inert.
  """
  @spec compose_digest(Plan.t(), [map()]) :: String.t()
  def compose_digest(%Plan{} = plan, history) do
    count = length(history)

    header =
      "Architecture gate: #{count} consecutive rejections. Escalating to a human.\n\n" <>
        "The architect and the planner have not converged. All #{count} rounds below."

    footer =
      "Plan v#{plan.version} is still awaiting review at /tasks/#{plan.task_id}. Approve it to " <>
        "proceed over the\narchitect's objection, or reject it with your own direction."

    ([header] ++ Enum.map(history, &round_block/1) ++ [footer])
    |> Enum.join("\n\n")
  end

  defp round_block(round) do
    [
      "--- Plan v#{round.version} (rejected #{round.resolved_at || "at an unrecorded time"}) ---",
      "Stages: #{stage_list(round.stage_names)}",
      summary_line(round.summary) | finding_lines(round)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp stage_list([]), do: "(none)"
  defp stage_list(names), do: Enum.join(names, " | ")

  defp summary_line(nil), do: nil
  defp summary_line(""), do: nil
  defp summary_line(summary), do: "Architect: #{summary}"

  # `constraint` verbatim, for the same reason the feedback body renders it
  # verbatim: the vocabulary is closed by `Plan.architecture_constraints/0`
  # and this module holds no copy of it.
  defp finding_lines(%{findings: []}), do: ["  (no findings recorded)"]

  defp finding_lines(round) do
    Enum.map(round.findings, fn finding ->
      "  * #{Map.get(finding, "constraint")} @ #{digest_stage_label(finding, round.stages)}" <>
        " -> #{Map.get(finding, "detail")}"
    end)
  end

  defp digest_stage_label(finding, stages) do
    case finding_stage_name(finding, stages, Map.get(finding, "stage_id")) do
      nil -> "(plan-wide)"
      name -> ~s("#{name}")
    end
  end

  # THE DIGEST IS `log_only: true`, AND THAT IS THE POINT.
  #
  # `AttentionRouter` silently skips `log_only` messages in execution spaces
  # (`chat/attention_router.ex:8`, `:220-221`). Stage 3's feedback post is
  # `post_engagement/3` — NOT log-only — precisely BECAUSE it must wake the
  # planner and get a v2 written. This post must NOT wake the planner: a v3
  # is exactly the spin the bound exists to stop, and an engagement message
  # here would author one. The asymmetry between the two posts IS the
  # mechanism; do not "tidy" them into one call. Both halves are asserted in
  # `architecture_escalation_test.exs` ("the wake-up asymmetry").
  #
  # Best-effort, like the feedback post: the human is also reachable through
  # the inbox row and through the board card, and a missing execution space
  # must not turn a resolved gate into an error.
  defp post_digest(%Plan{} = plan, history) do
    case ExecutionSpace.find_by_task_id(plan.task_id) do
      nil ->
        :ok

      space ->
        case ExecutionSpace.post_log(space.id, compose_digest(plan, history)) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[ArchitectureRejection] failed to post escalation digest for plan " <>
                "#{plan.id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  # WHO GETS SUMMONED, and the honest third tier.
  #
  #   1. `task.sponsor_user_id` — the ADR-0042 human who owns this task.
  #   2. else `task.stack.sponsor_user_id` — a stack member inherits its
  #      stack's sponsor.
  #   3. else NOBODY. The digest is still posted, the telemetry still fires,
  #      and the plan still sits in `pending_review` on the board where a
  #      human sees it.
  #
  # Tier 3 is a deliberate refusal, not a gap. There is no admin or owner
  # concept on `Platform.Accounts.User` or `Platform.Tenancy.Org` to fall
  # back to, and `task.reported_by` is NOT a user id — it is a free-form
  # string that one writer fills with a user and another with an agent, so
  # resolving it would miss in both real cases while looking like coverage.
  # Paging an arbitrary human is worse than paging none.
  #
  # Shape mirrors `ReviewRequests.maybe_emit_reviewer_inbox/1`: post-commit,
  # best-effort, rescue -> log -> carry on. Returns the telemetry's
  # `recipient` value, and returns `"none"` when the emit FAILED as well as
  # when there was nobody to emit to — the field records who was actually
  # notified, and a changeset error notified nobody.
  @spec emit_escalation_inbox(Plan.t(), Task.t() | nil, [map()]) :: String.t()
  defp emit_escalation_inbox(%Plan{} = plan, %Task{} = task, history) do
    task = Repo.preload(task, :stack)

    case escalation_recipient(task) do
      {tier, user_id} ->
        case Inbox.emit(%{
               user_id: user_id,
               # REUSED, not invented. `Inbox.Item`'s `@kinds` is a closed
               # enum whose members each need a label, an icon and a
               # grouping entry in the inbox UI — and this task ships no
               # UI. `task_plan_review` is also semantically exact: a plan
               # is awaiting this human's decision.
               kind: "task_plan_review",
               source_type: "task",
               source_id: task.id,
               title: "Architecture escalation: #{task.title}",
               body: inbox_body(history),
               url: "/tasks/#{task.id}"
             }) do
          {:ok, _item} ->
            tier

          {:error, reason} ->
            Logger.warning(
              "[ArchitectureRejection] escalation inbox emit failed for task " <>
                "#{task.id}: #{inspect(reason)}"
            )

            "none"
        end

      :none ->
        "none"
    end
  rescue
    e ->
      Logger.warning(
        "[ArchitectureRejection] escalation inbox emit crashed for plan " <>
          "#{plan.id}: #{Exception.message(e)}"
      )

      "none"
  end

  defp emit_escalation_inbox(%Plan{}, _task, _history), do: "none"

  defp escalation_recipient(%Task{sponsor_user_id: uid}) when is_binary(uid), do: {"sponsor", uid}

  defp escalation_recipient(%Task{stack: %Stack{sponsor_user_id: uid}}) when is_binary(uid),
    do: {"stack_sponsor", uid}

  defp escalation_recipient(%Task{}), do: :none

  # Names the ROUNDS, not just the count: the inbox row is the only part of
  # the escalation a human sees before deciding whether to open it.
  defp inbox_body(history) do
    versions = Enum.map_join(history, ", ", &"v#{&1.version}")

    "#{length(history)} consecutive architecture rejections (#{versions}). " <>
      "The architect and the planner have not converged."
  end

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
