defmodule Platform.Repo.Migrations.AgentRuntimeMailBundle do
  @moduledoc """
  Task 01a0d4a0 stage 4 round 2: `mail_draft_create`/`mail_draft_update` used
  to live inside the `messaging` bundle (`ToolSurface.messaging_tools/0`), so
  any runtime holding `messaging` already got mail-drafting implicitly. That
  is how the single-purpose "Meeting Assistant" persona — whose
  `allowed_bundles` is deliberately scoped to `space messaging context_read
  memory` and explicitly excludes task/plan/review — could still call
  `mail_draft_create`, a prod write tool it was never meant to reach
  (a live test run, rollup space 01a0b5bf).

  The fix splits mail drafting into its own `mail` bundle. This migration
  backfills `mail` onto every EXISTING runtime that already has `messaging`,
  so no runtime that already relied on mail-via-messaging loses that
  capability — the same backfill pattern already used for the
  `meetings`/`attachment`/`skill` bundle additions
  (`20260908150000_agent_runtime_meetings_bundle.exs`,
  `20260419220000_agent_runtime_attachment_bundle.exs`,
  `20260506203637_agent_runtime_skill_bundle.exs`).

  ## The Meeting Assistant's own runtime is excluded on purpose

  Stage 2 (`mix platform.seed_meeting_voice_agent`) already provisioned the
  "meeting-assistant" agent's voice runtime with `messaging` in
  `allowed_bundles` BEFORE this bundle split existed — a plain
  `'messaging' = ANY(allowed_bundles)` backfill would silently hand `mail`
  right back to the one runtime this whole fix is about narrowing,
  regardless of whether the seed task happens to be re-run before or after
  this migration. So the backfill explicitly excludes runtimes owned by the
  `meeting-assistant` agent; every other pre-existing runtime keeps mail
  access unchanged.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_append(allowed_bundles, 'mail')
    WHERE 'messaging' = ANY(allowed_bundles)
      AND NOT ('mail' = ANY(allowed_bundles))
      AND (agent_id IS NULL OR agent_id NOT IN (
        SELECT id FROM agents WHERE slug = 'meeting-assistant'
      ))
    """)
  end

  def down do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_remove(allowed_bundles, 'mail')
    """)
  end
end
