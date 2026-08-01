defmodule Platform.Repo.Migrations.ForceUpdatePromptTemplatesMemoryV2 do
  use Ecto.Migration

  @moduledoc """
  Refresh `dispatch.assigned` and `dispatch.in_progress` to pick up the
  ADR-0041 T5 rewrite of the "## Writing to Org Memory" paragraph. The
  old copy described the V1 tool surface (`suite_org_memory_append` /
  `suite_org_context_write`); the new copy describes the V2 memory_*
  tool family + path-routing model (`memory_create` against
  `org/journal/<date>.md`, `memory_str_replace` against `org/page/...`,
  Historian-only writes for curated pages).

  `PromptTemplates.seed_defaults/0` only INSERTs when a slug is missing
  — it never overwrites existing rows. Deployments that seeded the
  dispatch templates pre-T5 would otherwise keep serving the old
  org-memory copy without an explicit overwrite, so this migration
  force-updates each affected slug to the current
  `default_content_for_slug/1` output. Slugs with no DB row are skipped
  (covered by `seed_defaults/0` on first boot).

  Mirrors the well-established `force_update_*` / `refresh_*` migration
  pattern at 20260505010000, 20260505020000, 20260506173000,
  20260506210000, 20260514210000, 20260520000000.
  """
  @slugs [
    "dispatch.planning",
    "dispatch.in_progress"
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
