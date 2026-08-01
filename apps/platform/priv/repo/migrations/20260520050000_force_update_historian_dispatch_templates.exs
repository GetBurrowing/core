defmodule Platform.Repo.Migrations.ForceUpdateHistorianDispatchTemplates do
  use Ecto.Migration

  @moduledoc """
  Refresh historian + dispatch prompt templates for ADR-0041 T6.

  T6 introduces three new historian-scoped slugs and adds the
  "Journal-by-default for non-Historian agents" rule (with the
  `<correction target=...>` block convention) to the existing
  `dispatch.planning` and `dispatch.in_progress` templates. These slugs
  are seeded by `PromptTemplates.seed_defaults/0` on first boot — but
  `seed_defaults/0` only INSERTs when a slug is missing; it never
  overwrites existing rows.

  For deployments that seeded the dispatch templates pre-T6 (or got the
  T5-rewritten copy via the prior force-update migration), this
  migration force-updates the affected slugs to the current
  `default_content_for_slug/1` output. The three new `historian.*` slugs
  are typically missing on a pre-T6 deployment — those rows are simply
  skipped here, and `seed_defaults/0` inserts them on next boot.

  Mirrors the well-established `force_update_*` / `refresh_*` migration
  pattern at 20260505010000, 20260505020000, 20260506173000,
  20260506210000, 20260514210000, 20260520000000, 20260520010000.
  """
  @slugs [
    "historian.scheduled",
    "historian.meeting_ended",
    "historian.threshold",
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
