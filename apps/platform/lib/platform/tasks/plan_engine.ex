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
  alias Platform.Tasks.{Plan, Stage, Validation}

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

      # Auto-advance: if no more pending/running validations on this stage, advance
      stage = Repo.get!(Stage, updated.stage_id)

      if stage.status == "running" and all_validations_resolved?(stage.id) do
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
          "running" -> %{started_at: now}
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
        transition_stage(stage, "failed")

      :pending ->
        :ok
    end
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
          {:ok, completed} = complete_plan(plan)
          Repo.preload(completed, stages_query())
        else
          # Some stages failed; reload plan
          Repo.preload(Repo.get!(Plan, plan.id), stages_query())
        end

      _next_stage ->
        # Next stage exists but don't auto-start it — caller uses start_stage/1
        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  defp complete_plan(%Plan{} = plan) do
    plan
    |> Plan.changeset(%{status: "completed"})
    |> Repo.update()
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
