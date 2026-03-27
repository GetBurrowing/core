defmodule Platform.Tasks.PlanEngine do
  @moduledoc """
  Deterministic plan engine — drives stage progression without LLM involvement.

  ## Stage Progression

      pending ──[start_stage]──► running
      running ──[all validations passed]──► passed
      running ──[any validation failed]──► failed
      failed  ──[retry]──► running
      any     ──[skip]──► skipped

  ## Key functions

  - `advance/1`            — check current stage validations, move to next or complete plan
  - `evaluate_validation/2` — record a pass/fail result, auto-advance if last pending
  - `start_stage/1`        — transition stage from pending to running

  All transitions emit telemetry events for observability.
  """

  import Ecto.Query

  alias Platform.Repo
  require Logger

  alias Platform.Tasks
  alias Platform.Tasks.{DeployStageBuilder, Plan, Stage, Task, Validation}

  @valid_stage_transitions %{
    "pending" => ~w(running skipped),
    "running" => ~w(passed failed),
    "failed" => ~w(running skipped),
    "passed" => [],
    "skipped" => []
  }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Start a stage by transitioning it from `pending` to `running`.

  Returns `{:error, :invalid_transition}` if the stage is not in `pending` status.
  """
  @spec start_stage(Ecto.UUID.t()) :: {:ok, Stage.t()} | {:error, term()}
  def start_stage(stage_id) do
    with {:ok, stage} <- fetch_stage(stage_id) do
      transition_stage(stage, "running")
    end
  end

  @doc """
  Reopen a failed manual-approval validation so review can be attempted again.

  If the owning stage is failed, it is moved back to `running` and the failed
  validation is reset to `pending` with cleared evaluation metadata.
  """
  @spec reopen_manual_approval(Ecto.UUID.t()) :: {:ok, Validation.t()} | {:error, term()}
  def reopen_manual_approval(validation_id) do
    Repo.transaction(fn ->
      validation = Repo.get!(Validation, validation_id)

      if validation.kind != "manual_approval" do
        Repo.rollback(:not_manual_approval)
      end

      stage = Repo.get!(Stage, validation.stage_id)

      cond do
        validation.status == "passed" ->
          Repo.rollback(:already_passed)

        stage.status == "failed" ->
          {:ok, _stage} = transition_stage(stage, "running")

        stage.status in ["running", "pending"] ->
          :ok

        true ->
          Repo.rollback(:invalid_stage_state)
      end

      {:ok, updated} =
        validation
        |> Validation.changeset(%{
          status: "pending",
          evidence: %{},
          evaluated_by: nil,
          evaluated_at: nil
        })
        |> Repo.update()

      updated
    end)
    |> case do
      {:ok, validation} -> {:ok, validation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Record a validation result and auto-advance if this was the last pending
  validation for its stage.

  `result` must be a map with at least `:status` (`"passed"` or `"failed"`)
  and optionally `:evidence` and `:evaluated_by`.
  """
  @spec evaluate_validation(Ecto.UUID.t(), map()) :: {:ok, Validation.t()} | {:error, term()}
  def evaluate_validation(validation_id, result) do
    status = Map.get(result, :status) || Map.get(result, "status")
    evidence = Map.get(result, :evidence) || Map.get(result, "evidence", %{})
    evaluated_by = Map.get(result, :evaluated_by) || Map.get(result, "evaluated_by", "system")

    unless status in ~w(passed failed) do
      raise ArgumentError,
            "validation result status must be \"passed\" or \"failed\", got: #{inspect(status)}"
    end

    Repo.transaction(fn ->
      validation = Repo.get!(Validation, validation_id)

      {:ok, updated} =
        validation
        |> Validation.changeset(%{
          status: status,
          evidence: evidence,
          evaluated_by: evaluated_by,
          evaluated_at: DateTime.utc_now()
        })
        |> Repo.update()

      emit_validation_telemetry(updated)

      # Auto-advance: if no more pending/running validations on this stage, advance.
      # For any stage, a single validation failure is enough to fail the stage
      # immediately — no point waiting for remaining validations.
      stage = Repo.get!(Stage, updated.stage_id)

      should_advance =
        stage.status == "running" and
          (all_validations_resolved?(stage.id) or status == "failed")

      if should_advance do
        advance_stage(stage)
      end

      updated
    end)
  end

  @doc """
  Check the current stage's validations and advance the plan accordingly.

  For the current (first running or first pending) stage:
  - If all validations passed → mark stage passed, move to next stage or complete plan
  - If any validation failed → mark stage failed
  - If validations still pending → no-op

  Returns `{:ok, plan}` with the updated plan (preloaded with stages).
  """
  @spec advance(Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, term()}
  def advance(plan_id) do
    Repo.transaction(fn ->
      plan = Repo.get!(Plan, plan_id)
      stages = ordered_stages(plan_id)

      case current_stage(stages) do
        nil ->
          # All stages are terminal — complete the plan
          {:ok, completed} = complete_plan(plan)
          Repo.preload(completed, stages_query())

        stage ->
          case stage_verdict(stage) do
            :all_passed ->
              {:ok, _passed_stage} = transition_stage(stage, "passed")
              maybe_advance_next(plan, stages, stage.position)

            :has_failures ->
              {:ok, _failed_stage} = transition_stage(stage, "failed")
              Repo.preload(Repo.get!(Plan, plan_id), stages_query())

            :pending ->
              Repo.preload(plan, stages_query())
          end
      end
    end)
  end

  @doc """
  Build deploy stages for a task based on its resolved deploy strategy.

  Looks up the task's project deploy strategy via `Tasks.resolve_deploy_strategy/1`,
  then calls `DeployStageBuilder.build_stage/2` to produce stage definitions.

  If the task already has an approved plan, the deploy stage position is set to
  follow the last existing stage. Otherwise, it starts at position 1.

  Returns `{:ok, [stage_def]}` with a list of stage definition maps, or
  `{:ok, :skip}` if the strategy is `"none"`.

  This provides TaskRouter a clean API to request deploy stage injection
  without needing to understand strategy resolution or stage construction.
  """
  @spec build_deploy_plan(Ecto.UUID.t()) :: {:ok, [map()] | :skip} | {:error, term()}
  def build_deploy_plan(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        task = Repo.preload(task, :project)
        strategy = Tasks.resolve_deploy_strategy(task)

        # Determine position: after last existing stage if plan exists
        next_position =
          case Repo.one(
                 from(p in Plan,
                   where: p.task_id == ^task_id and p.status in ~w(approved),
                   order_by: [desc: p.inserted_at],
                   limit: 1
                 )
               ) do
            nil ->
              1

            plan ->
              stages = ordered_stages(plan.id)
              max_position(stages) + 1
          end

        case DeployStageBuilder.build_stage(strategy, next_position) do
          :skip -> {:ok, :skip}
          stage_def -> {:ok, [stage_def]}
        end
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp fetch_stage(stage_id) do
    case Repo.get(Stage, stage_id) do
      nil -> {:error, :not_found}
      stage -> {:ok, stage}
    end
  end

  defp transition_stage(stage, new_status) do
    allowed = Map.get(@valid_stage_transitions, stage.status, [])

    if new_status in allowed do
      now = DateTime.utc_now()

      extra =
        case new_status do
          "running" -> %{started_at: now, completed_at: nil}
          s when s in ~w(passed failed skipped) -> %{completed_at: now}
          _ -> %{}
        end

      {:ok, updated} =
        stage
        |> Stage.changeset(Map.put(extra, :status, new_status))
        |> Repo.update()

      emit_stage_telemetry(updated, stage.status)
      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  defp ordered_stages(plan_id) do
    Stage
    |> where([s], s.plan_id == ^plan_id)
    |> order_by([s], asc: s.position)
    |> Repo.all()
  end

  defp current_stage(stages) do
    # First running stage, or first pending stage
    Enum.find(stages, &(&1.status == "running")) ||
      Enum.find(stages, &(&1.status == "pending"))
  end

  defp stage_verdict(stage) do
    validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))

    cond do
      validations == [] -> :all_passed
      Enum.any?(validations, &(&1.status == "failed")) -> :has_failures
      Enum.all?(validations, &(&1.status == "passed")) -> :all_passed
      true -> :pending
    end
  end

  defp all_validations_resolved?(stage_id) do
    pending_count =
      Validation
      |> where([v], v.stage_id == ^stage_id and v.status in ~w(pending running))
      |> Repo.aggregate(:count)

    pending_count == 0
  end

  defp advance_stage(stage) do
    case stage_verdict(stage) do
      :all_passed ->
        {:ok, _} = transition_stage(stage, "passed")
        plan = Repo.get!(Plan, stage.plan_id)
        stages = ordered_stages(plan.id)
        maybe_advance_next(plan, stages, stage.position)

      :has_failures ->
        {:ok, failed_stage} = transition_stage(stage, "failed")

        if deploy_stage?(failed_stage) do
          emit_deploy_failure_telemetry(failed_stage)
        end

        {:ok, failed_stage}

      :pending ->
        :ok
    end
  end

  @doc """
  Returns true if the stage is a deploy stage (has ci_passed or pr_merged validations,
  or its name starts with "Deploy:").
  """
  @spec deploy_stage?(Stage.t()) :: boolean()
  def deploy_stage?(%Stage{} = stage) do
    name_match = String.starts_with?(stage.name || "", "Deploy:")

    if name_match do
      true
    else
      validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))

      Enum.any?(validations, fn v ->
        v.kind in ~w(ci_passed pr_merged)
      end)
    end
  end

  defp emit_deploy_failure_telemetry(%Stage{} = stage) do
    # Collect failure evidence from failed validations
    failed_validations =
      Repo.all(
        from(v in Validation,
          where: v.stage_id == ^stage.id and v.status == "failed"
        )
      )

    failure_reason =
      failed_validations
      |> Enum.map(fn v -> "#{v.kind}: #{inspect(v.evidence)}" end)
      |> Enum.join("; ")

    # Extract merge SHA from any validation evidence (for potential revert)
    merge_sha =
      failed_validations
      |> Enum.find_value(fn v ->
        get_in(v.evidence, ["sha"]) || get_in(v.evidence, ["merge_sha"])
      end)

    :telemetry.execute(
      [:platform, :tasks, :deploy_stage_failed],
      %{system_time: System.system_time()},
      %{
        stage_id: stage.id,
        plan_id: stage.plan_id,
        failure_reason: failure_reason,
        merge_sha: merge_sha,
        failed_validations: Enum.map(failed_validations, & &1.kind)
      }
    )
  end

  defp maybe_advance_next(plan, _old_stages, current_position) do
    # Re-fetch stages to get current statuses after transitions
    fresh_stages = ordered_stages(plan.id)
    next = Enum.find(fresh_stages, &(&1.position > current_position and &1.status == "pending"))

    case next do
      nil ->
        # No more stages — complete the plan if all are terminal
        all_terminal? = Enum.all?(fresh_stages, &(&1.status in ~w(passed skipped)))

        if all_terminal? do
          maybe_inject_deploy_or_complete(plan, fresh_stages)
        else
          # Some stages failed; reload plan
          Repo.preload(Repo.get!(Plan, plan.id), stages_query())
        end

      next_stage ->
        # Auto-start the next pending stage so the agent can proceed immediately
        {:ok, _started} = transition_stage(next_stage, "running")
        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  # Statuses from which a task can transition to "deploying"
  @deployable_statuses ~w(in_progress in_review)

  # Check if a deploy stage needs to be injected before completing the plan.
  # If a deploy stage already exists (was previously injected), complete normally.
  # If no deploy stage exists and the strategy isn't "none", inject one.
  # Only injects when the task is in a status that can transition to deploying.
  defp maybe_inject_deploy_or_complete(plan, stages) do
    has_deploy_stage? = Enum.any?(stages, &String.starts_with?(&1.name, "Deploy: "))

    if has_deploy_stage? do
      # Deploy stage already ran and passed — complete the plan
      {:ok, completed} = complete_plan(plan)
      Repo.preload(completed, stages_query())
    else
      # No deploy stage yet — check strategy and maybe inject one
      task =
        Task
        |> Repo.get!(plan.task_id)
        |> Repo.preload(:project)

      strategy = Tasks.resolve_deploy_strategy(task)

      case DeployStageBuilder.build_stage(strategy, max_position(stages) + 1) do
        :skip ->
          # Strategy is "none" — complete normally
          {:ok, completed} = complete_plan(plan)
          Repo.preload(completed, stages_query())

        stage_def ->
          if task.status in @deployable_statuses do
            inject_deploy_stage(plan, task, stage_def, strategy)
          else
            # Task can't transition to deploying (e.g. backlog, planning) — complete normally
            Logger.info(
              "[PlanEngine] skipping deploy injection for task #{task.id} " <>
                "(status: #{task.status}, not deployable)"
            )

            {:ok, completed} = complete_plan(plan)
            Repo.preload(completed, stages_query())
          end
      end
    end
  end

  defp inject_deploy_stage(plan, task, stage_def, strategy) do
    # Create the deploy stage record
    {:ok, deploy_stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: stage_def.position,
        name: stage_def.name,
        description: stage_def.description
      })

    # Create validation records for the deploy stage
    for validation_def <- stage_def.validations do
      {:ok, _} =
        Tasks.create_validation(%{
          stage_id: deploy_stage.id,
          kind: validation_def.kind
        })
    end

    # Start the deploy stage immediately
    {:ok, _started} = transition_stage(deploy_stage, "running")

    # Transition the task to "deploying"
    case Tasks.transition_task(task, "deploying") do
      {:ok, _updated_task} ->
        Logger.info(
          "[PlanEngine] injected deploy stage (#{stage_def.name}) for task #{task.id}, " <>
            "strategy: #{strategy["type"]}"
        )

      {:error, reason} ->
        Logger.warning(
          "[PlanEngine] failed to transition task #{task.id} to deploying: #{inspect(reason)}"
        )
    end

    # Broadcast plan update so the board refreshes
    Tasks.broadcast_board({:plan_updated, Repo.get!(Plan, plan.id)})

    Repo.preload(Repo.get!(Plan, plan.id), stages_query())
  end

  defp max_position(stages) do
    stages
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> 0 end)
  end

  defp complete_plan(%Plan{} = plan) do
    case plan
         |> Plan.changeset(%{status: "completed"})
         |> Repo.update() do
      {:ok, completed} ->
        Tasks.broadcast_board({:plan_updated, completed})
        {:ok, completed}

      error ->
        error
    end
  end

  defp stages_query do
    [stages: from(s in Stage, order_by: [asc: s.position])]
  end

  # ── Telemetry ───────────────────────────────────────────────────────────

  defp emit_stage_telemetry(%Stage{} = stage, from_status) do
    :telemetry.execute(
      [:platform, :tasks, :stage_transitioned],
      %{system_time: System.system_time()},
      %{
        stage_id: stage.id,
        plan_id: stage.plan_id,
        from: from_status,
        to: stage.status
      }
    )

    # Broadcast to the board PubSub topic so TaskRouter can react
    Tasks.broadcast_board({:stage_transitioned, stage})
  end

  defp emit_validation_telemetry(%Validation{} = validation) do
    :telemetry.execute(
      [:platform, :tasks, :validation_evaluated],
      %{system_time: System.system_time()},
      %{
        validation_id: validation.id,
        stage_id: validation.stage_id,
        kind: validation.kind,
        status: validation.status
      }
    )
  end
end
