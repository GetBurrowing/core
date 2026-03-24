defmodule Platform.Skills do
  @moduledoc """
  Context for the Skills domain (Skill Library).

  Skills are markdown playbooks that describe how agents should work within a
  domain. They can be attached to projects, epics, or tasks and are bundled
  into dispatch context for federated agents.

  ## Inheritance

  `resolve_skills/1` walks the task hierarchy (project → epic → task) and
  returns a deduplicated list of `{skill, source}` tuples. Skills attached at
  the project level apply to all tasks in that project, epic-level skills apply
  to tasks in that epic, and task-level skills are task-specific.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Skills.{Skill, SkillAttachment}
  alias Platform.Tasks.Task

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc "List all skills, ordered by name."
  def list_skills do
    Skill
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "Get a skill by ID."
  def get_skill(id), do: Repo.get(Skill, id)

  @doc "Get a skill by slug."
  def get_skill_by_slug(slug), do: Repo.get_by(Skill, slug: slug)

  @doc "Create a new skill."
  def create_skill(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing skill."
  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a skill. Cascades to all attachments."
  def delete_skill(%Skill{} = skill) do
    Repo.delete(skill)
  end

  # ── Attachments ──────────────────────────────────────────────────────────

  @doc """
  Attach a skill to an entity (project, epic, or task).

  Returns `{:ok, attachment}` or `{:error, changeset}`. The unique constraint
  on `(skill_id, entity_type, entity_id)` prevents duplicate attachments.
  """
  def attach_skill(skill_id, entity_type, entity_id) do
    %SkillAttachment{}
    |> SkillAttachment.changeset(%{
      skill_id: skill_id,
      entity_type: entity_type,
      entity_id: entity_id
    })
    |> Repo.insert()
  end

  @doc """
  Detach a skill from an entity.

  Returns `:ok` or `{:error, :not_found}`.
  """
  def detach_skill(skill_id, entity_type, entity_id) do
    case Repo.get_by(SkillAttachment,
           skill_id: skill_id,
           entity_type: entity_type,
           entity_id: entity_id
         ) do
      nil ->
        {:error, :not_found}

      attachment ->
        {:ok, _} = Repo.delete(attachment)
        :ok
    end
  end

  @doc """
  Return all skills attached to a specific entity.
  """
  def skills_for_entity(entity_type, entity_id) do
    Skill
    |> join(:inner, [s], sa in SkillAttachment,
      on: sa.skill_id == s.id and sa.entity_type == ^entity_type and sa.entity_id == ^entity_id
    )
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc """
  Resolve all skills for a task by walking the hierarchy.

  Returns a list of `{%Skill{}, source}` tuples where source is
  `"project"`, `"epic"`, or `"task"`. Skills are deduplicated by ID —
  task-level wins over epic, epic over project.
  """
  @spec resolve_skills(String.t()) :: [{Skill.t(), String.t()}]
  def resolve_skills(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        []

      task ->
        task = Repo.preload(task, [:project, :epic])

        # Gather skills at each level, task first (for dedup priority)
        task_skills = skills_with_source("task", task.id)

        epic_skills =
          if task.epic, do: skills_with_source("epic", task.epic.id), else: []

        project_skills =
          if task.project, do: skills_with_source("project", task.project.id), else: []

        # Task-level wins, then epic, then project (dedup by skill.id)
        (task_skills ++ epic_skills ++ project_skills)
        |> Enum.uniq_by(fn {skill, _source} -> skill.id end)
    end
  end

  @doc """
  Return all entities a skill is attached to, grouped by entity_type.

  Returns `%{"project" => [{id, name}], "epic" => [...], "task" => [...]}`.
  """
  def entities_for_skill(skill_id) do
    attachments =
      SkillAttachment
      |> where([sa], sa.skill_id == ^skill_id)
      |> Repo.all()

    grouped = Enum.group_by(attachments, & &1.entity_type)

    %{
      "project" => resolve_entity_names("project", Map.get(grouped, "project", [])),
      "epic" => resolve_entity_names("epic", Map.get(grouped, "epic", [])),
      "task" => resolve_entity_names("task", Map.get(grouped, "task", []))
    }
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp skills_with_source(entity_type, entity_id) do
    Skill
    |> join(:inner, [s], sa in SkillAttachment,
      on: sa.skill_id == s.id and sa.entity_type == ^entity_type and sa.entity_id == ^entity_id
    )
    |> order_by([s], asc: s.name)
    |> Repo.all()
    |> Enum.map(fn skill -> {skill, entity_type} end)
  end

  defp resolve_entity_names("project", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Project
    |> where([p], p.id in ^ids)
    |> select([p], {p.id, p.name})
    |> Repo.all()
  end

  defp resolve_entity_names("epic", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Epic
    |> where([e], e.id in ^ids)
    |> select([e], {e.id, e.name})
    |> Repo.all()
  end

  defp resolve_entity_names("task", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Task
    |> where([t], t.id in ^ids)
    |> select([t], {t.id, t.title})
    |> Repo.all()
  end
end
