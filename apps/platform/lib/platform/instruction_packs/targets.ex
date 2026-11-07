defmodule Platform.InstructionPacks.Targets do
  @moduledoc """
  Narrow content-only writes through the existing stores. No metadata, grants,
  attachments, tool settings or template evaluator is touched. Missing targets
  are errors: matching a seeded string does not establish vendor provenance.
  """
  import Ecto.Query
  alias Platform.{Repo, Skills}
  alias Platform.Orchestration.{PromptTemplate, PromptTemplates}
  alias Platform.Skills.Skill

  def resolve("skill_markdown", target) do
    case Repo.one(from(s in Skill, where: s.slug == ^target, lock: "FOR UPDATE")) do
      nil -> {:error, :missing_target}
      row -> {:ok, {:skill, row}}
    end
  end

  def resolve("prompt_template", target) do
    if target in Platform.InstructionPacks.Guidance.slugs(),
      do: {:error, :reserved_target},
      else: template(target)
  end

  def resolve(type, target) when type in ["role_prompt", "setup_dialogue"] do
    with {:ok, slug} <- Platform.InstructionPacks.Guidance.target(type, target),
         do: template(slug)
  end

  def resolve(_, _), do: {:error, :missing_target_mapping}

  defp template(target) do
    case Repo.one(from(t in PromptTemplate, where: t.slug == ^target, lock: "FOR UPDATE")) do
      nil -> {:error, :missing_target}
      row -> {:ok, {:template, row}}
    end
  end

  def content({_, row}), do: row.content
  def content({:deleted, _, _}), do: nil
  def record_id({:deleted, _, _}), do: nil
  def record_id({_, row}), do: row.id
  def identity({:skill, row}), do: {"skills", row.id}
  def identity({:template, row}), do: {"prompt_templates", row.id}
  def identity({:deleted, type, target}), do: {type, target}

  # Retire text safely in place: deleting a Skill would cascade attachments.
  # Normal CRUD rejects blank text. This narrowly scoped system operation
  # clears only the content column after Installer proves vendor ownership.
  def write({_, row}, ""), do: Repo.update(Ecto.Changeset.change(row, content: ""))
  def write({:skill, row}, value), do: Skills.update_skill(row, %{content: value || ""})

  def write({:template, row}, value),
    do:
      PromptTemplates.update_template(row, %{content: value || "", updated_by: "instruction_pack"})
end
