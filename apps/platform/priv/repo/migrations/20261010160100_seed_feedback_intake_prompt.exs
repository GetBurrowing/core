defmodule Platform.Repo.Migrations.SeedFeedbackIntakePrompt do
  use Ecto.Migration

  @slug "feedback.intake.v1"

  @moduledoc """
  Seeds (or refreshes) the `feedback.intake.v1` prompt template: the system
  prompt of the tool-less external-feedback classifier
  (`Platform.Feedback.Classifier`). Task 01a11ec3 stage 3.

  The template tells the model that the wrapped issue is DATA TO CLASSIFY and
  never instructions, and fixes the closed JSON verdict shape the classifier
  parses.

  Shape mirrors `20260924190000_seed_experiments_labeler_prompt.exs`:
  insert-or-force-update from the matching `default_templates/0` descriptor,
  so the row and its source cannot drift (`render_template/2` prefers the row,
  and `seed_defaults/0` is INSERT-only). A missing descriptor raises.

  `def down, do: :ok`, as in the precedent.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedFeedbackIntakePrompt] no default descriptor for slug=#{@slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    attrs = %{
      slug: @slug,
      name: descriptor.name,
      description: descriptor.description,
      content: content,
      variables: descriptor.variables
    }

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        case PromptTemplates.create_template(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end

      %PromptTemplate{} = template ->
        case PromptTemplates.update_template(template, %{
               content: content,
               variables: descriptor.variables
             }) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
