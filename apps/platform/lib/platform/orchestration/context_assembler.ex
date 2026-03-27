defmodule Platform.Orchestration.ContextAssembler do
  @moduledoc """
  Deterministic context snapshot for task dispatch.

  Walks the task hierarchy (project → epic → task → plan → stages → validations)
  and assembles a plain map suitable for sending to an executing agent. No LLM —
  pure Repo queries via `Platform.Tasks`.
  """

  alias Platform.Execution.CredentialLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Skills
  alias Platform.Tasks

  @doc """
  Build a full context snapshot for the given task.

  Returns a map with `:project`, `:epic`, `:task`, `:plan`,
  `:execution_space_id`, and optionally `:deploy_credentials` keys.

  The optional `deploy_lease` argument, when provided, causes the lease's
  env vars to be included under `:deploy_credentials` so the executing agent
  has SSH keys, API tokens, etc. available in its dispatch context.
  """
  @spec build(String.t(), CredentialLease.t() | nil) :: map() | nil
  def build(task_id, deploy_lease \\ nil) do
    case Tasks.get_task_detail(task_id) do
      nil ->
        nil

      task ->
        # Use the plan from the fully-preloaded task detail (includes stages
        # with validations) rather than current_plan/1 which only preloads stages.
        plan = find_current_plan(task.plans)

        execution_space_id =
          case ExecutionSpace.find_or_create(task_id) do
            {:ok, space} -> space.id
            _ -> nil
          end

        skills =
          task_id
          |> Skills.resolve_skills()
          |> Enum.map(fn {skill, _source} -> %{name: skill.name, content: skill.content} end)

        resolved_deploy_strategy = Tasks.resolve_deploy_strategy(task)

        base = %{
          project: serialize_project(task.project),
          epic: serialize_epic(task.epic),
          task: serialize_task(task),
          plan: serialize_plan(plan),
          execution_space_id: execution_space_id,
          skills: skills,
          resolved_deploy_strategy: resolved_deploy_strategy
        }

        maybe_add_deploy_credentials(base, deploy_lease)
    end
  end

  # Find the latest approved plan from the preloaded plans list
  defp find_current_plan(nil), do: nil
  defp find_current_plan([]), do: nil

  defp find_current_plan(plans) do
    plans
    |> Enum.filter(&(&1.status in ["approved", "completed"]))
    |> Enum.sort_by(& &1.version, :desc)
    |> List.first()
  end

  defp serialize_project(nil), do: nil

  defp serialize_project(project) do
    %{
      name: project.name,
      repo_url: project.repo_url,
      tech_stack: project.tech_stack,
      deploy_config: project.deploy_config
    }
  end

  defp serialize_epic(nil), do: nil

  defp serialize_epic(epic) do
    %{
      name: epic.name,
      description: epic.description,
      acceptance_criteria: epic.acceptance_criteria,
      target_branch: epic.target_branch,
      deploy_target: epic.deploy_target
    }
  end

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      dependencies: task.dependencies,
      metadata: task.metadata
    }
  end

  defp serialize_plan(nil), do: nil

  defp serialize_plan(plan) do
    %{
      id: plan.id,
      version: plan.version,
      status: plan.status,
      stages: Enum.map(plan.stages || [], &serialize_stage/1)
    }
  end

  defp serialize_stage(stage) do
    validations =
      case stage.validations do
        %Ecto.Association.NotLoaded{} -> []
        nil -> []
        vals -> Enum.map(vals, &serialize_validation/1)
      end

    %{
      id: stage.id,
      position: stage.position,
      name: stage.name,
      description: stage.description,
      status: stage.status,
      validations: validations
    }
  end

  defp serialize_validation(validation) do
    %{
      id: validation.id,
      kind: validation.kind,
      status: validation.status
    }
  end

  defp maybe_add_deploy_credentials(context, nil), do: context

  defp maybe_add_deploy_credentials(context, %CredentialLease{} = lease) do
    if CredentialLease.valid?(lease) do
      Map.put(context, :deploy_credentials, CredentialLease.to_env(lease))
    else
      context
    end
  end
end
