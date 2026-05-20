defmodule Platform.Repo.Migrations.RefreshDispatchTemplatesForWikiPreamble do
  use Ecto.Migration

  # Refresh `dispatch.planning` and `dispatch.in_progress` to pick up the
  # ADR-0041 T4 rewrite of the "## Organization Context" paragraph. The
  # old copy described the V1 shape (ORG_NOTES-yyyy-mm-dd flattened with
  # workspace files); the new copy describes the V2 shape (annotated
  # wiki pages from accessible namespaces, BEGIN/END HTML-comment
  # markers, ~4096-token budget).
  #
  # `PromptTemplates.seed_defaults/0` only INSERTs when a slug is
  # missing — it never overwrites existing rows. Deployments that
  # seeded the dispatch templates pre-T4 would otherwise keep serving
  # the old org-context copy without an explicit overwrite, so this
  # migration force-updates each affected slug to the current
  # `default_content_for_slug/1` output. Slugs with no DB row are
  # skipped (covered by `seed_defaults/0` on first boot).
  #
  # Mirrors the well-established `force_update_*` / `refresh_*`
  # migration pattern at 20260505010000, 20260505020000,
  # 20260506173000, 20260506210000, 20260514210000.
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
