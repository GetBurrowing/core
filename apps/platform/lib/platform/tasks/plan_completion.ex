defmodule Platform.Tasks.PlanCompletion do
  @moduledoc """
  Owns the task-status advance that follows a plan reaching `completed`.

  ## Why this module exists (task 019fa2fc)

  Before this module, `deploying -> done` existed in exactly one place: the
  `handle_info({:plan_updated, %{status: "completed"}}, %State{task_id: task_id})`
  clause in `Platform.Orchestration.TaskRouter`. That clause is guarded on the
  router's own `task_id`, so it fires only if a per-task router GenServer
  happens to be alive AND subscribed at the instant the broadcast goes out.
  `PlanEngine.complete_plan/2` writes the plan row and broadcasts; it never
  touched task status.

  When no router was alive — no agent assignee, a router that had stopped, a
  restart between the deploy stage passing and the broadcast landing — the
  broadcast went to nobody and the task sat in `deploying` forever. Three
  production tasks (`019fa06a`, `019fa209`, `019fa298`) did exactly that on
  2026-07-27, with merged PRs, passed `pr_merged` validations and fully
  `completed` plans, and had to be cleared by hand. Production logs for those
  tasks carry no `deploy completed` info line, no `failed to transition`
  warning and no `held task ... at deploying` warning — the handler did not
  run at all, as opposed to running and erroring.

  Compare `PlanEngine.inject_deploy_stage/4`, which transitions the task
  *into* `deploying` synchronously in the same call stack that writes the
  stage. This module is the missing counterpart that takes it back out.

  ## Shape

  The completion *reason* is supplied by the call site rather than re-derived
  from the task's current status. Each `complete_plan/2` branch in `PlanEngine`
  already knows why it is completing the plan; passing that through means the
  target is a function of why the plan finished, not of a status table read
  after the fact. That is what makes the advance idempotent and what keeps the
  stack-member branch (which must NOT advance here) structurally separate from
  the solo-deploy branch.

  Deliberately NOT a polling sweeper: a sweeper leaves the transition
  timing-dependent and patches the symptom. The advance runs inside the same
  `Repo.transaction/1` that `PlanEngine.advance/1` opens, and in production
  that whole chain runs synchronously inside the GitHub webhook process, so
  there is no process boundary to drop it on.
  """

  require Logger

  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Task

  @typedoc """
  Why the plan completed. Supplied by the `PlanEngine.complete_plan/2` call
  site — see the module doc for why the reason is threaded rather than
  re-derived.
  """
  @type reason ::
          :deploy_stage_passed
          | :no_deploy_strategy
          | :awaiting_rollup
          | :stack_member
          | :not_deployable
          | :degenerate_plan

  @doc """
  Advance the plan's task to its terminal status for `reason`.

  Returns `{:ok, task}` when a transition was performed, `:noop` when the
  reason or the task's current status means there is nothing to do, and
  `{:error, term}` if the transition itself was rejected.
  """
  @spec advance_task(Plan.t(), reason()) :: {:ok, Task.t()} | :noop | {:error, term()}
  def advance_task(%Plan{} = plan, reason) do
    case Tasks.get_task_record(plan.task_id) do
      nil -> :noop
      task -> advance(task, plan, reason)
    end
  end

  # Idempotence, as a STATUS GUARD rather than a rescue on the error tuple.
  # `@valid_task_transitions` (`Platform.Tasks`) maps `"done" => ~w(planning)`,
  # so an unguarded retry would return `{:error, :invalid_transition}` and emit
  # a spurious warning — one of the noise sources task 019fa2fc calls out. A
  # second completion broadcast for an already-terminal task is not an error,
  # it is a no-op, so it logs nothing.
  defp advance(%Task{status: status}, _plan, _reason) when status in ~w(done cancelled),
    do: :noop

  defp advance(%Task{status: "deploying"} = task, %Plan{} = plan, :deploy_stage_passed) do
    if deploy_stages_settled?(plan.id) do
      transition_to_done(task, plan, "deploy completed")
    else
      # A `completed` plan is NOT sufficient evidence that the deploy landed —
      # see task 019f9b34 / incident 019f9ae5, where a stale `completed`
      # broadcast flipped a task to `done` eight minutes before its PR merged,
      # with the deploy stage still `running`. That invariant predates this
      # module and has to survive the move off the router.
      Logger.warning(
        "[PlanCompletion] held task #{task.id} at deploying — plan #{plan.id} is " <>
          "`completed` but its deploy stage is #{inspect(unsettled_deploy_statuses(plan.id))}. " <>
          "Something upstream completed the plan early (see task 019f9b34)."
      )

      :noop
    end
  end

  # Strategy `"none"`: no deploy step will ever run for this task, and by the
  # time `complete_plan/2` is reached every stage on the plan — including the
  # engine-synthesized task-level review gate (`PlanEngine`'s
  # `synthesize_task_level_review_stage/2`) — is `passed`/`skipped`. There is nothing
  # left to do, so the task is finished. `done` is a legal target from both
  # `in_progress` and `in_review` per `@valid_task_transitions` in
  # `Platform.Tasks`.
  #
  # This replaces the router's legacy status-mapping arm, which walked
  # `in_progress -> in_review` and `in_review -> deploying` instead. Both of
  # those are dead ends in the single-plan model: review already passed (it is
  # in this same plan), and a `none`-strategy task moved to `deploying` has no
  # deploy stage and no deploy strategy to ever move it back out. That legacy
  # mapping MANUFACTURED the class of stall this task is about, so it is
  # deliberately not preserved.
  defp advance(%Task{status: status} = task, %Plan{} = plan, :no_deploy_strategy)
       when status in ~w(in_progress in_review),
       do: transition_to_done(task, plan, "no deploy strategy")

  # `no_op_wait_for_rollup` — the deploy has NOT happened. It ships via a stack
  # rollup PR, which may not even be open yet. `DeployStageBuilder.build_stage/2`
  # collapses this and `"none"` to a single `:skip`; `PlanEngine.skip_reason/1`
  # is what keeps them apart, because sweeping this task to `done` would mark an
  # undeployed task deployed. Never advance here.
  defp advance(%Task{}, %Plan{}, :awaiting_rollup), do: :noop

  # SCOPE BOUNDARY — unconditional `:noop`, and it must stay unconditional.
  #
  # Stack members ship via the rollup PR (ADR 0041/0046). Their terminal path is
  # owned by `Stacks.dispatch_stack_deploy/1` + `StackDeployer.handle_member_transition/3`,
  # the rollup-merge fan-out, and the 019f708f sweep — not by this seam.
  #
  # The eight ADR-0046 members sitting at `deploying` on 2026-07-27 are there
  # because their rollup PR was NEVER OPENED: a deploy that genuinely has not
  # happened. They are not evidence about the dropped-broadcast bug this module
  # fixes, and advancing them to `done` would report undeployed work as shipped.
  # This `:noop` is precisely what keeps this change away from them.
  defp advance(%Task{}, %Plan{}, :stack_member), do: :noop

  # Task is in `backlog`/`planning`/`blocked` when its plan completes — it never
  # entered the deploy pipeline, so there is no terminal advance to make. The
  # engine already logs the skipped injection at this call site.
  defp advance(%Task{}, %Plan{}, :not_deployable), do: :noop

  # A plan with zero stages is not evidence that any work happened. Completing
  # it says only "there was nothing here", never "the task is done".
  defp advance(%Task{}, %Plan{}, :degenerate_plan), do: :noop

  # Any remaining (status, reason) pair — e.g. `:deploy_stage_passed` for a task
  # that is not `deploying`, or `:no_deploy_strategy` for one in `backlog` — is
  # silently a no-op.
  defp advance(%Task{}, %Plan{}, _reason), do: :noop

  defp transition_to_done(%Task{} = task, %Plan{} = plan, why) do
    case Tasks.transition_task(task, "done") do
      {:ok, updated} ->
        Logger.info(
          "[PlanCompletion] #{why} — transitioned task #{task.id} to done (plan #{plan.id})"
        )

        {:ok, updated}

      {:error, reason} ->
        Logger.warning(
          "[PlanCompletion] failed to transition task #{task.id} to done: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  True when every deploy stage on the plan has reached a terminal state.

  `Enum.all?/2` over an empty list is `true`, which is the right default: a
  plan with no deploy stage at all is unaffected by this guard.

  Hoisted out of `Platform.Orchestration.TaskRouter` (task 019fa2fc stage 1)
  so the deploy-settled invariant lives next to the transition it guards.
  """
  @spec deploy_stages_settled?(Ecto.UUID.t() | nil) :: boolean()
  def deploy_stages_settled?(nil), do: true

  def deploy_stages_settled?(plan_id) do
    plan_id
    |> deploy_stages()
    |> Enum.all?(&(&1.status in ~w(passed skipped)))
  end

  @doc """
  Diagnostic companion to `deploy_stages_settled?/1` — the `name=status` pairs
  of the deploy stages that are holding the task back, for the warning log.
  """
  @spec unsettled_deploy_statuses(Ecto.UUID.t() | nil) :: [String.t()]
  def unsettled_deploy_statuses(plan_id) do
    plan_id
    |> deploy_stages()
    |> Enum.reject(&(&1.status in ~w(passed skipped)))
    |> Enum.map(&"#{&1.name}=#{&1.status}")
  end

  defp deploy_stages(nil), do: []

  defp deploy_stages(plan_id) do
    plan_id
    |> Tasks.list_stages()
    |> Enum.filter(&PlanEngine.deploy_stage?/1)
  end
end
