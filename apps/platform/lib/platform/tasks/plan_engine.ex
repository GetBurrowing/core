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
      # A newly failed validation should fail a running stage immediately, while
      # a later failed->passed flip must be able to reopen and re-advance a stage
      # that had already entered failed.
      stage = Repo.get!(Stage, updated.stage_id)

      cond do
        stage.status == "running" and status == "failed" ->
          advance_stage(stage)

        all_validations_resolved?(stage.id) ->
          maybe_advance_resolved_stage(stage)

        true ->
          :ok
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

  # ── Plan ingestion: e2e_behavior routing + UI heuristic ───────────────────

  # File-path / module-name tokens that strongly imply a stage actually renders
  # or modifies user-visible UI. Used by the heuristic safety net (see
  # `check_manual_approval_heuristic/1`) — purely advisory; planner authority wins.
  @ui_tokens [
    ".heex",
    "tasks_live.ex",
    "assets/js/",
    "assets/css/",
    "compose_input",
    "app.css",
    "chat_live",
    "_web/live/",
    "_web/components/"
  ]

  @doc """
  Re-route any `e2e_behavior` validations in a list of planner-authored
  stage_input maps to a single task-level review stage.

  Behavior:
  - If any stage already has `kind: "e2e_behavior"` validations, strip them
    from that stage and collect them all into one final review stage.
  - If a stage already exists whose name matches "review"/"validation" (the
    final task-level review stage), append the e2e_behavior validations to its
    validations list. Otherwise, synthesize a new "Task-level review" stage at
    `max_position + 1` carrying just the lifted e2e_behavior validations.
  - If multiple e2e_behavior validations were emitted, all are kept (the
    planner template forbids this; we don't enforce here so a misbehaving
    planner can still surface for the human reviewer to catch).

  Stage maps use string OR atom keys (planner output is JSON-derived → strings;
  in-process callers may use atoms). The returned list preserves the input
  shape (string-keyed if input was string-keyed).
  """
  @spec route_e2e_behavior_validations([map()]) :: [map()]
  def route_e2e_behavior_validations(stages_input) when is_list(stages_input) do
    {stripped_stages, e2e_validations} =
      Enum.map_reduce(stages_input, [], fn stage, acc ->
        validations = stage_validations_field(stage)

        {kept, lifted} =
          Enum.split_with(validations, fn v ->
            (Map.get(v, "kind") || Map.get(v, :kind)) != "e2e_behavior"
          end)

        new_stage = put_stage_validations(stage, kept)
        {new_stage, acc ++ lifted}
      end)

    case e2e_validations do
      [] ->
        stripped_stages

      _ ->
        attach_e2e_validations_to_review_stage(stripped_stages, e2e_validations)
    end
  end

  def route_e2e_behavior_validations(other), do: other

  @doc """
  Log warnings about manual_approval scoping based on a hybrid heuristic.

  - Warns when a stage description contains UI tokens (`.heex`, `assets/js/`, etc.)
    but the planner did NOT include a `manual_approval` validation — likely a
    missed UI gate.
  - Warns when a stage has a `manual_approval` validation but the description
    contains zero UI tokens — likely overscoping.

  Always returns the input untouched. Planner authority wins; heuristics only
  surface likely mistakes for human reviewers.
  """
  @spec check_manual_approval_heuristic([map()]) :: [map()]
  def check_manual_approval_heuristic(stages_input) when is_list(stages_input) do
    Enum.each(stages_input, fn stage ->
      desc = stage_field(stage, "description") || ""
      name = stage_field(stage, "name") || "<unnamed stage>"
      validations = stage_validations_field(stage)

      has_manual_approval? =
        Enum.any?(validations, fn v ->
          (Map.get(v, "kind") || Map.get(v, :kind)) == "manual_approval"
        end)

      ui_touching? = ui_touching?(desc)

      cond do
        ui_touching? and not has_manual_approval? ->
          Logger.warning(
            "[PlanEngine] likely missed UI manual_approval — stage \"#{name}\" description " <>
              "contains UI-touching tokens but no manual_approval validation. " <>
              "Planner authority wins; flagging for human review."
          )

        has_manual_approval? and not ui_touching? ->
          Logger.warning(
            "[PlanEngine] likely overscoped manual_approval — stage \"#{name}\" carries a " <>
              "manual_approval validation but description has zero UI-touching tokens. " <>
              "Planner authority wins; flagging for human review."
          )

        true ->
          :ok
      end
    end)

    stages_input
  end

  def check_manual_approval_heuristic(other), do: other

  # Pure helper exposed for the heuristic and for tests.
  @spec ui_touching?(String.t() | nil) :: boolean()
  def ui_touching?(nil), do: false

  def ui_touching?(description) when is_binary(description) do
    Enum.any?(@ui_tokens, &String.contains?(description, &1))
  end

  def ui_touching?(_), do: false

  defp stage_field(stage, key) when is_map(stage) do
    Map.get(stage, key) || Map.get(stage, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(stage, key)
  end

  defp stage_validations_field(stage) when is_map(stage) do
    Map.get(stage, "validations") || Map.get(stage, :validations) || []
  end

  defp put_stage_validations(stage, validations) when is_map(stage) do
    cond do
      Map.has_key?(stage, "validations") ->
        Map.put(stage, "validations", validations)

      Map.has_key?(stage, :validations) ->
        Map.put(stage, :validations, validations)

      # Originally absent — pick a key style consistent with other stage keys.
      Map.has_key?(stage, "name") or Map.has_key?(stage, "description") ->
        Map.put(stage, "validations", validations)

      true ->
        Map.put(stage, :validations, validations)
    end
  end

  defp attach_e2e_validations_to_review_stage(stages_input, e2e_validations) do
    review_idx =
      Enum.find_index(stages_input, fn stage ->
        name = String.downcase(stage_field(stage, "name") || "")

        # An existing "task-level review" or generic "review"/"validation" stage
        # is reused; "Deploy: ..." stages are NEVER reused as the e2e gate.
        not String.starts_with?(name, "deploy:") and
          (String.contains?(name, "review") or String.contains?(name, "validation"))
      end)

    case review_idx do
      nil ->
        stages_input ++ [synthesize_task_level_review_stage(stages_input, e2e_validations)]

      idx ->
        List.update_at(stages_input, idx, fn stage ->
          existing = stage_validations_field(stage)
          put_stage_validations(stage, existing ++ e2e_validations)
        end)
    end
  end

  defp synthesize_task_level_review_stage(existing_stages, e2e_validations) do
    next_position =
      existing_stages
      |> Enum.map(&(stage_field(&1, "position") || 0))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    %{
      "name" => "Task-level review",
      "description" =>
        "Synthesized by the plan engine to host the planner-authored e2e_behavior validation " <>
          "as a single per-task review gate. The review agent executes the behavioral script " <>
          "in a dev environment and dispositions the validation.",
      "position" => next_position,
      "validations" => e2e_validations
    }
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

  defp maybe_advance_resolved_stage(%Stage{} = stage) do
    case stage.status do
      "running" ->
        advance_stage(stage)

      "failed" ->
        case stage_verdict(stage) do
          :all_passed ->
            {:ok, reopened_stage} = transition_stage(stage, "running")
            advance_stage(reopened_stage)

          :has_failures ->
            :ok

          :pending ->
            :ok
        end

      _other ->
        :ok
    end
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
      attrs =
        %{
          stage_id: deploy_stage.id,
          kind: validation_def.kind
        }
        |> maybe_put_evaluation_payload(validation_def)

      {:ok, _} = Tasks.create_validation(attrs)
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

        # Broadcast plan update so the board refreshes
        Tasks.broadcast_board({:plan_updated, Repo.get!(Plan, plan.id)})

        Repo.preload(Repo.get!(Plan, plan.id), stages_query())

      {:error, reason} ->
        Logger.warning(
          "[PlanEngine] failed to transition task #{task.id} to deploying: #{inspect(reason)}"
        )

        # Roll back the deploy stage so we don't leave an orphaned running
        # stage when the task couldn't actually enter the deploying status.
        transition_stage(deploy_stage, "failed")

        # Still broadcast so the board shows the current state
        Tasks.broadcast_board({:plan_updated, Repo.get!(Plan, plan.id)})

        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  # Pull `:evaluation_payload` (or string-keyed equivalent) out of a validation
  # definition map and merge it into the create-validation attrs map. Used both
  # for deploy-stage builder output (which won't carry one) and for plan ingestion
  # paths that pass planner-authored e2e_behavior payloads through.
  defp maybe_put_evaluation_payload(attrs, validation_def) when is_map(validation_def) do
    case Map.get(validation_def, :evaluation_payload) ||
           Map.get(validation_def, "evaluation_payload") do
      nil -> attrs
      payload -> Map.put(attrs, :evaluation_payload, payload)
    end
  end

  defp maybe_put_evaluation_payload(attrs, _), do: attrs

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
