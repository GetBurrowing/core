defmodule Platform.Repo.Migrations.RefreshDispatchTemplatesForSkillDiscovery do
  use Ecto.Migration

  @slugs [
    "dispatch.planning",
    "dispatch.in_progress",
    "dispatch.in_review",
    "dispatch.review_e2e",
    "dispatch.deploying",
    "dispatch.fallback"
  ]

  @doc """
  Refresh the dispatch templates to pick up the explicit skill-discovery step
  added to the shared `skills_reference` text (task 019e280d).

  `PromptTemplates.seed_defaults/0` only INSERTs when a slug is missing — it
  never overwrites existing rows. Deployments that already seeded the dispatch
  templates would keep serving the OLD `skills_reference` content without an
  explicit overwrite, so this migration force-updates each affected slug to the
  current `default_content_for_slug/1` output. Slugs with no DB row are skipped.
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
