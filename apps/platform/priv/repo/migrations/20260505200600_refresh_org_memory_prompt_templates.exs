defmodule Platform.Repo.Migrations.RefreshOrgMemoryPromptTemplates do
  use Ecto.Migration

  @slugs ["dispatch.planning", "dispatch.in_progress"]

  @doc """
  Refresh `dispatch.planning` and `dispatch.in_progress` to pick up the new
  org-memory guidance after dropping the `long_term` memory type.

  `seed_defaults/0` only inserts when a slug is missing, so deployments that
  already seeded these templates need an explicit overwrite.
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
