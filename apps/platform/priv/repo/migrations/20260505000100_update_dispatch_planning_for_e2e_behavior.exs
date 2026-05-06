defmodule Platform.Repo.Migrations.UpdateDispatchPlanningForE2eBehavior do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Refresh the seeded `dispatch.planning` prompt template content with the new
  e2e_behavior + manual_approval scoping guidance.

  `seed_defaults/0` only inserts when a slug is missing; it does not overwrite
  existing rows. This migration explicitly overwrites the row for #{@slug}
  using the latest hardcoded default content from PromptTemplates.

  Force-update path: this migration always writes the current default content
  for the slug if the template exists. Skips silently if the template was
  never seeded (next call to seed_defaults/0 will pick up the new content).
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
