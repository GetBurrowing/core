defmodule Platform.Tasks.ContextHydrator do
  @moduledoc """
  Loads the persistent task hierarchy into ETS context sessions at run start.

  This is a one-time, deterministic data load — no LLM calls. Reads from
  Postgres (project, epic, task, plan+stages) and pushes config/description
  items into the appropriate scoped ETS sessions via `Platform.Context`.

  ## Scope hierarchy

      project_id  →  epic_id  →  task_id

  Each level gets its own context session with items pushed at the correct
  kind (:project_config, :epic_context, :task_description, :task_metadata).

  ## Usage

      {:ok, version} = ContextHydrator.hydrate_for_run(task_id, run_id)
  """

  alias Platform.Context
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks.{DeployResolver, Plan, Task}

  import Ecto.Query

  @doc """
  Hydrates the ETS context plane with the full task hierarchy for a run.

  Loads the task (with project, epic, and approved plan+stages) from Postgres
  and pushes items into project-, epic-, and task-scoped context sessions.

  ## Options

    * `:deploy_target` — name of a deploy target from the project's deploy
      config. When provided, the target's config is resolved and pushed into
      the project-scoped context session with kind `:project_config`.

  Returns `{:ok, version}` where version is the final context version after
  all items have been pushed, or `{:error, reason}` if the task is not found.
  """
  @spec hydrate_for_run(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def hydrate_for_run(task_id, _run_id, opts \\ []) do
    with {:ok, task} <- load_task(task_id) do
      project = task.project
      epic = task.epic
      plan = current_approved_plan(task_id)

      # 1. Hydrate project-scoped session
      project_scope = %{project_id: project.id}
      {:ok, _} = Context.ensure_session(project_scope)
      {:ok, _} = push_project_items(project_scope, project)

      # 1b. Hydrate deploy target into project session (if requested)
      maybe_hydrate_deploy_target(project_scope, project, opts)

      # 2. Hydrate epic-scoped session (if epic exists)
      if epic do
        epic_scope = %{project_id: project.id, epic_id: epic.id}
        {:ok, _} = Context.ensure_session(epic_scope)
        {:ok, _} = push_epic_items(epic_scope, epic)
      end

      # 3. Hydrate task-scoped session
      task_scope = %{project_id: project.id, epic_id: epic && epic.id, task_id: task.id}
      {:ok, _} = Context.ensure_session(task_scope)
      {:ok, version} = push_task_items(task_scope, task)

      # 4. Hydrate plan stages into task session (if approved plan exists)
      version =
        if plan do
          {:ok, v} = push_plan_items(task_scope, plan)
          v
        else
          version
        end

      # 5. Hydrate attached skills into task session
      version =
        case push_skill_items(task_scope, task_id) do
          {:ok, v} when v > 0 -> v
          _ -> version
        end

      emit_telemetry(task_id, version)

      {:ok, version}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp load_task(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        task = Repo.preload(task, [:project, :epic])
        {:ok, task}
    end
  end

  defp current_approved_plan(task_id) do
    Plan
    |> where([p], p.task_id == ^task_id and p.status == "approved")
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        nil

      plan ->
        Repo.preload(plan, stages: from(s in Platform.Tasks.Stage, order_by: [asc: s.position]))
    end
  end

  defp push_project_items(scope, project) do
    items = [
      {"project.name", project.name},
      {"project.repo_url", project.repo_url},
      {"project.tech_stack", Jason.encode!(project.tech_stack || %{})},
      {"project.deploy_targets", Jason.encode!(project.deploy_config || %{})},
      {"project.description", project.config["description"] || ""}
    ]

    push_items(scope, items, kind: :project_config)
  end

  defp push_epic_items(scope, epic) do
    items = [
      {"epic.name", epic.name},
      {"epic.description", epic.description || ""},
      {"epic.acceptance_criteria", epic.acceptance_criteria || ""}
    ]

    push_items(scope, items, kind: :epic_context)
  end

  defp push_task_items(scope, task) do
    items = [
      {"task.title", task.title},
      {"task.description", task.description || ""},
      {"task.dependencies", Jason.encode!(task.dependencies || [])},
      {"task.priority", task.priority || "medium"}
    ]

    push_items(scope, items, kind: :task_description)
  end

  defp push_plan_items(scope, plan) do
    stages = plan.stages || []

    items =
      Enum.flat_map(stages, fn stage ->
        pos = stage.position

        validations =
          stage
          |> Repo.preload(:validations)
          |> Map.get(:validations, [])
          |> Enum.map(& &1.kind)

        [
          {"plan.stage.#{pos}.title", stage.name || ""},
          {"plan.stage.#{pos}.description", stage.description || ""},
          {"plan.stage.#{pos}.validations", Jason.encode!(validations)}
        ]
      end)

    push_items(scope, items, kind: :task_metadata)
  end

  defp push_skill_items(scope, task_id) do
    case Skills.resolve_skills(task_id) do
      [] ->
        {:ok, 0}

      skills ->
        items =
          Enum.map(skills, fn {skill, _source} ->
            {"skill.#{skill.name}", skill.content}
          end)

        push_items(scope, items, kind: :skill_context)
    end
  end

  defp maybe_hydrate_deploy_target(_scope, _project, opts) when opts == [], do: :ok

  defp maybe_hydrate_deploy_target(scope, project, opts) do
    case Keyword.get(opts, :deploy_target) do
      nil ->
        :ok

      target_name ->
        case DeployResolver.resolve(project, target_name) do
          {:ok, target} ->
            items = DeployResolver.to_context_items(target)
            push_items(scope, items, kind: :project_config)

            :telemetry.execute(
              [:platform, :tasks, :deploy_target_resolved],
              %{system_time: System.system_time()},
              %{project_id: project.id, target_name: target_name, target_type: target["type"]}
            )

            :ok

          {:error, _reason} ->
            :ok
        end
    end
  end

  defp push_items(_scope, [], _opts), do: {:ok, 0}

  defp push_items(scope, items, opts) do
    Enum.reduce(items, {:ok, 0}, fn {key, value}, _acc ->
      Context.put_item(scope, key, value, opts)
    end)
  end

  defp emit_telemetry(task_id, version) do
    :telemetry.execute(
      [:platform, :tasks, :context_hydrated],
      %{system_time: System.system_time(), item_count: version},
      %{task_id: task_id}
    )
  end
end
