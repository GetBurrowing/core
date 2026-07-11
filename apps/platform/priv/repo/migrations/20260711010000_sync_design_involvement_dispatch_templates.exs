defmodule Platform.Repo.Migrations.SyncDesignInvolvementDispatchTemplates do
  use Ecto.Migration

  @moduledoc """
  Sync `dispatch.planning` and `dispatch.in_review` to the current
  `default_content_for_slug/1` output (task 019f4f1d).

  The Designer-gate sections ("Design involvement (UI/UX tasks)" in
  planning, "Design review (Saru) — before the human gate" in in_review)
  were first applied to the live rows via the `prompt_template_update`
  MCP tool on 2026-07-11. This migration upstreams them into the code
  defaults so future force-update migrations don't clobber the live
  edits, and brings any environment still serving the pre-Designer
  content up to date.

  Force-update pattern (NOT `seed_defaults` — that path is insert-only
  and ignores existing rows). On environments where the live content
  already matches (production, where the MCP edit landed first), the
  update is a changeset no-op. Slugs with no DB row are skipped.
  """

  @slugs [
    "dispatch.planning",
    "dispatch.in_review"
  ]

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
