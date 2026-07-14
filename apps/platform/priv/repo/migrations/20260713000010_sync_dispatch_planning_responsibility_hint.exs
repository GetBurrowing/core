defmodule Platform.Repo.Migrations.SyncDispatchPlanningResponsibilityHint do
  use Ecto.Migration

  @moduledoc """
  Sync `dispatch.planning` to the current `default_content_for_slug/1`
  output (task 019f5d47 — stage-level responsibility routing).

  The code default gains a new bullet under item 2 ("Add an early
  advisory design stage — Design direction (Saru)") teaching planners to
  set `responsibility: "designer"` on that stage. The bullet must land
  on the live DB row too, otherwise the next `render_template/2` call
  for `dispatch.planning` will serve the stale content and planners
  won't emit the field.

  Force-update pattern (NOT `seed_defaults` — that path is insert-only
  and ignores existing rows). Mirrors the shape of
  `20260711010000_sync_design_involvement_dispatch_templates.exs`. On
  environments where the live content already matches, the update is a
  changeset no-op. Slugs with no DB row are skipped.
  """

  @slugs [
    "dispatch.planning"
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
