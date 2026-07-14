defmodule Platform.Repo.Migrations.SuppressHistorianNoOpJournalWrites do
  use Ecto.Migration

  # Task 019f5e7d stage 2 — the three historian dispatch templates
  # (`historian.scheduled`, `historian.meeting_ended`, `historian.threshold`)
  # previously instructed the Historian agent to acknowledge a drained
  # backlog by writing an empty journal entry against today's journal
  # (`historian.threshold` step 4: "call `memory_create` with an empty
  # entry against today's journal ..."). Every such write became fresh
  # unindexed content that re-crossed the pending-tokens threshold on the
  # next SystemEventScheduler tick — a self-perpetuating dispatch loop
  # that generated ~80 no-op entries in `org/journal/2026-07-13.md`.
  #
  # The code default in `PromptTemplates.default_content_for_slug/1`
  # has been updated to REMOVE that instruction and replace it with an
  # explicit "RETURN SILENTLY" directive. `seed_defaults/0` is
  # INSERT-only, so deployments that already have the historian.* rows
  # from the T6 seed migration would keep serving the pre-fix copy —
  # this force-update swaps in the current default content for all three
  # slugs.
  #
  # Skips slugs with no DB row (fresh boots pick them up via
  # `seed_defaults/0`). Mirrors the `force_update_*` migration pattern
  # at 20260520050000 and 20260711100000.
  @slugs [
    "historian.scheduled",
    "historian.meeting_ended",
    "historian.threshold"
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
