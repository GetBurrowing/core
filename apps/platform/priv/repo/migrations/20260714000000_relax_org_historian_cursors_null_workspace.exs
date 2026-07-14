defmodule Platform.Repo.Migrations.RelaxOrgHistorianCursorsNullWorkspace do
  @moduledoc """
  Task 019f5e7d stage 1 — allow `workspace_id IS NULL` in `org_historian_cursors`.

  The org-scope fan-out (`Tasks.Projects.list_active_workspaces/0`) passes the
  sentinel `"00000000-0000-0000-0000-000000000000"` for the whole-org bucket.
  Corpus tables (`org_wiki_pages`, `org_wiki_journal_entries`) store their
  org-scope rows with `workspace_id IS NULL` — PR #537 (task 019f5cf4) taught
  `Historian.sum_corpus_bytes/3` + `per_day_bytes_query/4` to coerce the
  sentinel to `nil` at the query boundary so those reads resolve correctly.

  This migration extends the same "org-scope on-disk shape = NULL" invariant
  to the cursor table so the cursor read/write functions can adopt the same
  coercion pattern (this stage's code changes). Without this migration,
  `mark_run_started(nil)` would violate the composite-primary-key NOT NULL
  constraint on `workspace_id` and the loop-fix would trade one bug for
  another (silent NOT-NULL rescue → cursor never stamps → threshold fires
  unconditionally).

  Steps (Postgres 15+, production PG16):

    1. Drop the composite primary key `(workspace_id, corpus)`.
    2. `ALTER COLUMN workspace_id DROP NOT NULL`.
    3. Backfill any pre-existing legacy sentinel rows to NULL (accidental
       shape from the pre-fix write path). Sentinel-shape rows on prod are
       harmless duplicates; folding them into the canonical NULL shape lets
       the coerced reads see them.
    4. Recreate the composite uniqueness via a UNIQUE INDEX with
       `NULLS NOT DISTINCT` so two `(NULL, "journal")` rows collide the same
       way `(<uuid>, "journal")` duplicates would.

  `down/0` reverses the schema shape but does NOT re-lift the sentinel
  backfill — the pre-fix rows were legitimately org-scope data.
  """
  use Ecto.Migration

  @sentinel "00000000-0000-0000-0000-000000000000"

  def up do
    # 1. Drop composite PK so we can allow NULL in workspace_id.
    execute("ALTER TABLE org_historian_cursors DROP CONSTRAINT org_historian_cursors_pkey")

    # 2. Allow NULL for org-scope rows.
    execute("ALTER TABLE org_historian_cursors ALTER COLUMN workspace_id DROP NOT NULL")

    # 3. Backfill legacy sentinel rows into the canonical NULL shape so the
    #    coerced reads (this stage's code change) see them.
    execute("""
    UPDATE org_historian_cursors
    SET workspace_id = NULL
    WHERE workspace_id = '#{@sentinel}'
    """)

    # 4. Composite unique index that treats NULL as equal (PG15+).
    execute("""
    CREATE UNIQUE INDEX org_historian_cursors_workspace_corpus_uniq
      ON org_historian_cursors (workspace_id, corpus) NULLS NOT DISTINCT
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS org_historian_cursors_workspace_corpus_uniq")
    # Any nil-workspace rows would violate the restored NOT NULL constraint;
    # stamp them with the sentinel so the down-migration is invertible on
    # environments that already ran up/0 and started writing NULL rows.
    execute("""
    UPDATE org_historian_cursors
    SET workspace_id = '#{@sentinel}'
    WHERE workspace_id IS NULL
    """)

    execute("ALTER TABLE org_historian_cursors ALTER COLUMN workspace_id SET NOT NULL")

    execute(
      "ALTER TABLE org_historian_cursors ADD CONSTRAINT org_historian_cursors_pkey PRIMARY KEY (workspace_id, corpus)"
    )
  end
end
