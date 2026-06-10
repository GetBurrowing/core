defmodule Platform.Repo.Migrations.RenameOrgContextToOrgWiki do
  use Ecto.Migration

  # P1 stage 2: rename the org_context_* tables to org_wiki_*, and reseat
  # the index names so they match the new table names. Postgres RENAME TABLE
  # carries indexes along, but the index *names* still embed the old table
  # name — this migration fixes that hygiene gap.
  #
  # Schemas in lib/ still reference the old table names; stage 4 of the plan
  # renames the Elixir modules + `schema "..."` strings.

  def up do
    rename(table(:org_context_files), to: table(:org_wiki_pages))
    rename(table(:org_memory_entries), to: table(:org_wiki_journal_entries))

    execute(
      "ALTER INDEX IF EXISTS org_context_files_workspace_id_file_key_index RENAME TO org_wiki_pages_workspace_id_file_key_index",
      "ALTER INDEX IF EXISTS org_wiki_pages_workspace_id_file_key_index RENAME TO org_context_files_workspace_id_file_key_index"
    )

    execute(
      "ALTER INDEX IF EXISTS org_memory_entries_workspace_id_date_index RENAME TO org_wiki_journal_entries_workspace_id_date_index",
      "ALTER INDEX IF EXISTS org_wiki_journal_entries_workspace_id_date_index RENAME TO org_memory_entries_workspace_id_date_index"
    )
  end

  def down do
    execute(
      "ALTER INDEX IF EXISTS org_wiki_journal_entries_workspace_id_date_index RENAME TO org_memory_entries_workspace_id_date_index"
    )

    execute(
      "ALTER INDEX IF EXISTS org_wiki_pages_workspace_id_file_key_index RENAME TO org_context_files_workspace_id_file_key_index"
    )

    rename(table(:org_wiki_journal_entries), to: table(:org_memory_entries))
    rename(table(:org_wiki_pages), to: table(:org_context_files))
  end
end
