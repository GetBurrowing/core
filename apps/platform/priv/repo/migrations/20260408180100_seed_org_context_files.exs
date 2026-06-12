defmodule Platform.Repo.Migrations.SeedOrgContextFiles do
  use Ecto.Migration

  # Seed default org context files on first boot. Idempotent — only inserts
  # missing file keys.
  #
  # NOTE: this migration uses raw SQL (not the Ecto schema) because at the
  # time this migration runs the table is named `org_context_files`. The
  # T1 rename migration (20260515224500) later renames it to `org_wiki_pages`.
  # If we referenced the Ecto schema here, queries would target the
  # post-rename table name and crash on a fresh migrate-from-scratch run.
  #
  # T1 stage 4: emit path-style file_keys (`org/identity.md`, …) directly
  # so fresh databases land in the canonical V2 shape. The data migration
  # at 20260519210000 still writes alias rows for the legacy uppercase
  # keys so V1 callers continue to resolve, and also acts as the upgrade
  # path for existing databases where this migration originally seeded
  # the uppercase form.

  @org_identity """
  # Org Identity

  _Describe your organization here — mission, values, what you're building._

  This file is shared with all agents on session start. Keep it concise and current.
  """

  @org_memory """
  # Org Memory

  _Curated long-term memory for the organization._

  Record key decisions, architectural choices, lessons learned, and anything
  agents should remember across sessions. Agents can read and append to this file.
  """

  @org_agents """
  # Org Agents

  _Shared conventions and guidelines for all agents in this organization._

  Document workflows, coding standards, review processes, deployment procedures,
  and any other conventions agents should follow.
  """

  def up do
    seeds = [
      {"org/identity.md", String.trim(@org_identity)},
      {"org/memory.md", String.trim(@org_memory)},
      {"org/agents.md", String.trim(@org_agents)}
    ]

    for {file_key, content} <- seeds do
      execute("""
      INSERT INTO org_context_files (id, workspace_id, file_key, content, version, inserted_at, updated_at)
      SELECT gen_random_uuid(), NULL, '#{file_key}', $$#{content}$$, 1, now(), now()
      WHERE NOT EXISTS (
        SELECT 1 FROM org_context_files
        WHERE workspace_id IS NULL AND file_key = '#{file_key}'
      )
      """)
    end
  end

  def down do
    :ok
  end
end
