defmodule Platform.Repo.Migrations.PathStyleFileKeysAndAliasBackfill do
  use Ecto.Migration

  @moduledoc """
  T1 stage 4 — data migration.

  Translates legacy uppercase `file_key` values in `org_wiki_pages`
  (`ORG_IDENTITY.md`, `ORG_MEMORY.md`, `ORG_AGENTS.md`, plus any other
  `ORG_*.md` form) into path-style keys (`org/identity.md`, …) and writes a
  corresponding row to `org_wiki_aliases` so that V1 callers (and the
  alias-compat resolver in `Platform.Org.Context`) continue to resolve the
  legacy keys.

  ## Schema snapshot at the time this migration runs

  Stage 2 (`20260515224500_rename_org_context_to_org_wiki.exs`) renamed:

    * `org_context_files` → `org_wiki_pages`
    * `org_memory_entries` → `org_wiki_journal_entries`

  Stage 3 (`20260516013500_create_org_wiki_links_and_aliases.exs`) added:

    * `org_wiki_links` (`source_id`/`target_path`/`target_id`/`position`/`display_text`)
    * `org_wiki_aliases` (`old_path` text PK, `current_id` uuid FK,
      `inserted_at`)

  ## Mapping rule

      ORG_IDENTITY.md → org/identity.md
      ORG_MEMORY.md   → org/memory.md
      ORG_AGENTS.md   → org/agents.md
      ORG_<X>.md      → org/<downcase X>.md      (defensive — covers any
                                                    custom legacy key
                                                    seeded by an installer)

  Any `file_key` that already contains a `/` is treated as already
  path-style and left alone.

  ## Idempotency

  Per stage-2 lesson, this migration uses raw SQL only (no Ecto schema
  references) so it stays safe under fresh `ecto.migrate` runs. The page
  UPDATE is gated by `WHERE file_key = old_key`, so re-running is a
  no-op once the row's been moved. The alias INSERT uses
  `ON CONFLICT (old_path) DO NOTHING`. Both halves can run multiple
  times safely.

  On a fresh database where stage 2's seed migration already emits
  path-style keys, the UPDATE half is a no-op; the INSERT half still
  writes the standard three legacy alias rows so V1 lookups resolve.

  ## Down

  Reverse only the canonical three mappings: rename the path-style row
  back to its uppercase key, then delete the alias row. Other legacy
  keys that landed via the defensive lowercase transform are not
  reversed (they're out-of-spec; reversal would require remembering the
  original casing, which we don't store).
  """

  # Canonical legacy → path-style mapping. Kept here (not as a module
  # attribute referenced from a schema) so the migration is fully
  # self-contained per ADR-0041 + stage-2 conventions.
  @canonical_mappings [
    {"ORG_IDENTITY.md", "org/identity.md"},
    {"ORG_MEMORY.md", "org/memory.md"},
    {"ORG_AGENTS.md", "org/agents.md"}
  ]

  def up do
    # Step 1 — defensive sweep for any uppercase ORG_*.md keys still in
    # the table. Rewrite to org/<downcased-suffix>.md and stash the
    # mapping in a temp table for the alias INSERT below.
    execute("""
    CREATE TEMP TABLE _migration_key_renames (
      old_key text NOT NULL,
      new_key text NOT NULL,
      page_id uuid NOT NULL
    ) ON COMMIT DROP
    """)

    # Find every page whose key matches the legacy uppercase pattern AND
    # has no '/' (defensive — skip anything already path-style).
    execute("""
    INSERT INTO _migration_key_renames (old_key, new_key, page_id)
    SELECT
      p.file_key AS old_key,
      'org/' || lower(regexp_replace(p.file_key, '^ORG_(.*)\\.md$', '\\1')) || '.md' AS new_key,
      p.id AS page_id
    FROM org_wiki_pages p
    WHERE p.file_key ~ '^ORG_[A-Z0-9_]+\\.md$'
      AND position('/' in p.file_key) = 0
    """)

    # Update the page rows to their new path-style keys. Use a join on
    # the temp table so we can keep workspace scoping implicit (the page
    # id uniquely identifies the row regardless of workspace_id).
    execute("""
    UPDATE org_wiki_pages p
    SET file_key = r.new_key,
        updated_at = now()
    FROM _migration_key_renames r
    WHERE p.id = r.page_id
    """)

    # Insert alias rows for every renamed page. Idempotent — duplicate
    # old_path is a no-op.
    execute("""
    INSERT INTO org_wiki_aliases (old_path, current_id, inserted_at)
    SELECT r.old_key, r.page_id, now()
    FROM _migration_key_renames r
    ON CONFLICT (old_path) DO NOTHING
    """)

    # Step 2 — backfill alias rows for the canonical three keys even
    # when the page was already path-style (e.g. on a fresh DB where the
    # seed migration emits path-style keys directly). This ensures V1
    # lookups (`get_context_file("ORG_IDENTITY.md")`) resolve regardless
    # of how the row first landed.
    for {legacy, path_style} <- @canonical_mappings do
      execute("""
      INSERT INTO org_wiki_aliases (old_path, current_id, inserted_at)
      SELECT '#{legacy}', p.id, now()
      FROM org_wiki_pages p
      WHERE p.file_key = '#{path_style}'
      ON CONFLICT (old_path) DO NOTHING
      """)
    end
  end

  def down do
    # Reverse only the canonical three mappings — out-of-spec defensive
    # renames are not reversed (we don't preserve the original casing).
    for {legacy, path_style} <- @canonical_mappings do
      execute("""
      UPDATE org_wiki_pages p
      SET file_key = '#{legacy}',
          updated_at = now()
      FROM org_wiki_aliases a
      WHERE a.old_path = '#{legacy}'
        AND a.current_id = p.id
        AND p.file_key = '#{path_style}'
      """)

      execute("""
      DELETE FROM org_wiki_aliases WHERE old_path = '#{legacy}'
      """)
    end
  end
end
