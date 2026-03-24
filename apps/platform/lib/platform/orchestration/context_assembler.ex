defmodule Platform.Orchestration.ContextAssembler do
  @moduledoc """
  Deterministic context snapshot for task dispatch.

  Walks the task hierarchy (project → epic → task → plan → stages → validations)
  and assembles a plain map suitable for sending to an executing agent. No LLM —
  pure Repo queries via `Platform.Tasks`.
  """

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Skills
  alias Platform.Tasks

  @doc """
  Build a full context snapshot for the given task.

  Returns a map with `:project`, `:epic`, `:task`, `:plan`, and
  `:execution_space_id` keys.
  """
  @spec build(String.t()) :: map() | nil
  def build(task_id) do
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

        %{
          project: serialize_project(task.project),
          epic: serialize_epic(task.epic),
          task: serialize_task(task),
          plan: serialize_plan(plan),
          execution_space_id: execution_space_id,
          skills: skills
        }
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
      acceptance_criteria: epic.acceptance_criteria
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
end
