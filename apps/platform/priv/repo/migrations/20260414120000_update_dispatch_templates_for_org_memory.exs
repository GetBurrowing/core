defmodule Platform.Repo.Migrations.UpdateDispatchTemplatesForOrgMemory do
  use Ecto.Migration

  @slugs ["dispatch.planning", "dispatch.in_progress"]

  @doc """
  Refresh the `dispatch.planning` and `dispatch.in_progress` prompt template rows
  with the latest default content so deployments that seeded templates before the
  org-memory guidance was added pick up the new text.

  `seed_defaults/0` only inserts when a slug is missing; it does not overwrite
  existing rows. This migration explicitly overwrites the two slugs that changed.
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@slugs, fn slug ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          :skip

        template ->
          content = PromptTemplates.default_content_for_slug(slug)

          if content do
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})
          end
      end
    end)

    :ok
  end

  def down do
    :ok
  end
end
