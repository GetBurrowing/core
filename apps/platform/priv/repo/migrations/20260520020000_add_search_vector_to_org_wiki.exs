defmodule Platform.Repo.Migrations.AddSearchVectorToOrgWiki do
  use Ecto.Migration

  @moduledoc """
  Adds a Postgres `tsvector` `search_vector` column (`GENERATED ALWAYS AS …
  STORED`) to both `org_wiki_pages` and `org_wiki_journal_entries`, plus a
  GIN index on each.

  Mirrors the `chat_messages.search_vector` pattern from
  `priv/repo/migrations/20260314080000_create_chat_tables.exs` so
  `Platform.Org.Wiki.Search` can run `to_tsvector` / `websearch_to_tsquery`
  queries with the same shape — edits to `content` auto-refresh the
  vector at the DB level, no application-side re-ingest needed.

  Stage 1 recon (`docs/stack/0041-org-memory-impl/t5-design-lock.md` §8)
  flagged the column as missing. Stage 4 ships the migration alongside
  the `Search` module so the lexical channel uses tsvector rather than
  the noisier `ilike` fallback.
  """

  def up do
    execute("""
    ALTER TABLE org_wiki_pages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
    """)

    execute("CREATE INDEX idx_org_wiki_pages_search ON org_wiki_pages USING gin(search_vector)")

    execute("""
    ALTER TABLE org_wiki_journal_entries
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
    """)

    execute(
      "CREATE INDEX idx_org_wiki_journal_entries_search ON org_wiki_journal_entries USING gin(search_vector)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_org_wiki_journal_entries_search")
    execute("ALTER TABLE org_wiki_journal_entries DROP COLUMN IF EXISTS search_vector")
    execute("DROP INDEX IF EXISTS idx_org_wiki_pages_search")
    execute("ALTER TABLE org_wiki_pages DROP COLUMN IF EXISTS search_vector")
  end
end
