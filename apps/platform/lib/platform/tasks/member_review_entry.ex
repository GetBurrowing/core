defmodule Platform.Tasks.MemberReviewEntry do
  @moduledoc """
  Moves a STACK MEMBER out of `in_progress` and into `in_review` once its
  non-gate work is settled.

  ## Why this seam exists

  A stack member's terminal path is owned by `Stacks.dispatch_stack_deploy/1` +
  `StackDeployer.handle_member_transition/3`, and the deployer's
  `:member_not_in_review` precondition (`tasks/stack_deployer.ex:405/466`)
  refuses to attempt the rollup merge until the member has actually REACHED
  `in_review`. Today only two seams produce that transition automatically:

    * `orchestration/task_router.ex:3606` `review_gate_stage?` — fires when a
      stage carrying an `e2e_behavior` validation starts RUNNING;
    * `tasks/review_requests.ex:431-434` — fires when a `manual_approval`
      review request is created.

  Both are GATE-driven. A member with no gate never gets the transition, and
  `PlanCompletion`'s `defp advance(%Task{}, %Plan{}, :stack_member), do: :noop`
  (`tasks/plan_completion.ex:146`) deliberately declines to move it either.
  That leaves two distinct holes, and clause (c) of `member_work_settled?/2`
  closes BOTH with one predicate:

    * **Hole A** — a lint/test/CI-only member plan has NO gate stages at all,
      so (c) reduces to "all stages settled" and the member enters `in_review`
      at its final stage instead of parking `in_progress` forever.

    * **Hole B** — the member's LAST stage IS the gated one, and the executor
      exits before that stage completes. `task_router.ex:3617`
      `maybe_enter_in_review` therefore never observes the gate stage running,
      and the plan never completes at all, so no completion seam ever fires.
      Under (c) the gate stage is EXCLUDED from the settled check, so the
      member reaches `in_review` as soon as its non-gate work is settled.

  A fix aimed only at hole A — collapsing (c) into
  `Enum.all?(stages, &settled?/1)` — leaves hole B open. Do not collapse it.

  ## Why review-pending work is already on the rollup

  A member entering `in_review` while a gate stage is still open will be
  merged into the rollup at that moment (the `tasks.ex` stack hook fires on the
  transition). That is not new: it is exactly what already happens for an
  e2e-gated member via the router path, which moves the member to `in_review`
  when the gate stage STARTS running — i.e. before the gate has been answered.
  This seam is consistent with that existing behaviour, not a widening of it.

  ## ADR-0046

  Clause (b) is the ADR-0046 guard, expressed as a STATUS guard rather than a
  membership guard: a member already at `deploying` is not `in_progress`, so it
  is untouched. The eight members sitting at `deploying` on 2026-07-27 are
  there because their rollup PR was never opened; nothing here may move them.
  `PlanCompletion`'s `:stack_member -> :noop` clause is NOT modified.
  """

  require Logger

  alias Platform.Tasks

  @gate_kinds ~w(e2e_behavior manual_approval)
  @settled_statuses ~w(passed skipped)

  @doc """
  True when `validation` is one of the two kinds that automatically produce an
  `in_review` transition today: `e2e_behavior` (via the router's review-gate
  seam) or `manual_approval` (via review-request creation).

  Deliberately structural rather than a name match on the STAGE, mirroring the
  rationale at `task_router.ex:3600-3605`:
  `PlanEngine.attach_e2e_validations_to_review_stage/2` REUSES a
  planner-authored stage whose name merely contains "review" or "validation",
  so a name-equality check would miss every reused-stage plan.
  """
  @spec gate_validation?(map()) :: boolean()
  def gate_validation?(validation) do
    Map.get(validation, :kind) in @gate_kinds
  end

  @doc """
  True when any of `stage`'s validations is a `gate_validation?/1`.

  Validations are loaded the way `task_router.ex:3595` `stage_validations/1`
  does: the preloaded list when present, a query on
  `%Ecto.Association.NotLoaded{}`, `[]` otherwise.
  """
  @spec gate_stage?(map() | nil) :: boolean()
  def gate_stage?(nil), do: false

  def gate_stage?(stage) do
    stage
    |> stage_validations()
    |> Enum.any?(&gate_validation?/1)
  end

  @doc """
  The decision: may this stack member enter `in_review` right now?

  A four-clause conjunction, in this order:

    a. `task.stack_id != nil` — solo tasks have their own terminal path and
       must not gain a new `in_review` producer from this seam.
    b. `task.status == "in_progress"` — the ADR-0046 guard. A member already at
       `deploying` (or `in_review`, or `done`) is untouched.
    c. every stage for which `gate_stage?/1` is FALSE is settled
       (`passed`/`skipped`). Gate stages are EXCLUDED, which is what makes this
       cover hole B as well as hole A. See the moduledoc.
    d. at least one stage in the list is settled — so a plan whose stages are
       ALL still `pending` is not swept in. Without (d), an all-pending plan in
       which every stage happens to be a gate stage satisfies (c) vacuously
       (`Enum.all?/2` over an empty list is `true`) and the member would enter
       `in_review` before anything had happened at all.
  """
  @spec member_work_settled?(map() | nil, list()) :: boolean()
  def member_work_settled?(nil, _stages), do: false

  def member_work_settled?(task, stages) when is_list(stages) do
    Map.get(task, :stack_id) != nil and
      Map.get(task, :status) == "in_progress" and
      stages |> Enum.reject(&gate_stage?/1) |> Enum.all?(&settled?/1) and
      Enum.any?(stages, &settled?/1)
  end

  def member_work_settled?(_task, _stages), do: false

  @doc """
  Transition the member to `in_review` when `member_work_settled?/2` holds.

  Accepts a plan (the task is loaded via `Tasks.get_task_record/1`) or a task
  struct. Returns `:noop` when the predicate is false, `{:ok, task}` on a
  successful transition, `{:error, reason}` on a rejected one.

  Never raises: a rejected transition is logged at warning and returned as
  `{:error, reason}`, mirroring `task_router.ex:3624-3633`.

  ## Observability

  A successful transition logs at info and emits
  `[:platform, :tasks, :member_review_entry]` (measurements `%{count: 1}`,
  metadata `task_id`, `stack_id`, `plan_id`, `gate_stage_count` plus the audit
  keys used by `[:platform, :lifecycle, :edge]` in `tasks.ex`). A rejected
  transition logs at warning with the reason. The `:noop` path emits NOTHING:
  the predicate is false on nearly every stage settlement in the system, and
  an event per settlement would bury the one that matters.
  """
  @spec maybe_enter_in_review(map() | nil, list()) :: :noop | {:ok, map()} | {:error, term()}
  def maybe_enter_in_review(plan_or_task, stages) do
    task = resolve_task(plan_or_task)

    if member_work_settled?(task, stages) do
      case transition(task) do
        {:ok, updated} = ok ->
          gate_stage_count = Enum.count(stages, &gate_stage?/1)
          plan_id = resolve_plan_id(plan_or_task, stages)

          Logger.info(
            "[MemberReviewEntry] stack member #{updated.id} work settled " <>
              "(gate stages: #{gate_stage_count}) — moved to in_review"
          )

          :telemetry.execute(
            [:platform, :tasks, :member_review_entry],
            %{count: 1},
            %{
              task_id: updated.id,
              stack_id: Map.get(updated, :stack_id),
              plan_id: plan_id,
              gate_stage_count: gate_stage_count,
              resource_type: "task",
              resource_id: updated.id,
              action: "member_review_entry",
              actor_type: "system"
            }
          )

          ok

        error ->
          error
      end
    else
      :noop
    end
  end

  # A plan carries `task_id`; a task carries its own `id` and a `status`. Match
  # on the presence of `task_id` so a preloaded plan struct resolves to its
  # task rather than being mistaken for one.
  defp resolve_task(nil), do: nil

  defp resolve_task(%{task_id: task_id}) when is_binary(task_id) do
    Tasks.get_task_record(task_id)
  end

  defp resolve_task(%{status: _} = task), do: task
  defp resolve_task(_), do: nil

  # The plan id for the telemetry metadata: the plan's own `id` when the caller
  # handed us a plan, otherwise whatever the stages say they belong to.
  defp resolve_plan_id(%{task_id: task_id, id: plan_id}, _stages) when is_binary(task_id),
    do: plan_id

  defp resolve_plan_id(_plan_or_task, [stage | _]), do: Map.get(stage, :plan_id)
  defp resolve_plan_id(_plan_or_task, _stages), do: nil

  defp transition(task) do
    case Tasks.transition_task(task, "in_review") do
      {:ok, updated} ->
        {:ok, updated}

      other ->
        # `Tasks.transition_task/2` can also answer a 3-tuple
        # (`{:error, :stack_plans_pending, %{...}}`, ADR 0042 Decision 4).
        # Normalise every rejection to `{:error, reason}` so a caller never has
        # to know the shape, and never crash the settlement path.
        reason = rejection_reason(other)

        Logger.warning(
          "[MemberReviewEntry] failed to move stack member #{Map.get(task, :id)} " <>
            "to in_review: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp rejection_reason({:error, reason}), do: reason
  defp rejection_reason({:error, reason, details}), do: {reason, details}
  defp rejection_reason(other), do: other

  defp settled?(stage), do: Map.get(stage, :status) in @settled_statuses

  defp stage_validations(stage) do
    case Map.get(stage, :validations) do
      validations when is_list(validations) -> validations
      %Ecto.Association.NotLoaded{} -> Tasks.list_validations(stage.id)
      _ -> []
    end
  end
end
