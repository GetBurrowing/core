defmodule Platform.Repo.Migrations.AddWorkspaceIdToOrgWikiAliases do
  use Ecto.Migration

  @moduledoc """
  T1 stage 6 fix — make `org_wiki_aliases` per-workspace.

  ## The defect

  Stage 3 (`20260516013500_create_org_wiki_links_and_aliases.exs`) created
  `org_wiki_aliases` with `old_path` (text) as the sole primary key. That's
  fine for a single-tenant install, but Suite is multi-workspace: every
  workspace gets its own `org/identity.md` page, and the V1 federation
  surface still calls them by the legacy uppercase key (`ORG_IDENTITY.md`).
  With one global alias row per legacy key, only one workspace's row can
  win — every other workspace's legacy lookups either miss or resolve to
  the wrong tenant's page.

  ## The fix

  Add `workspace_id uuid NOT NULL` and swap the PK to the composite
  `(workspace_id, old_path)`. Each workspace gets its own alias row
  pointing at its own canonical page. Postgres cannot put NULL in a
  composite PK column, so org-scoped (no-workspace) aliases use a
  sentinel UUID — `00000000-0000-0000-0000-000000000000` — which is
  effectively a "null workspace" placeholder. The resolver translates
  `workspace_id == nil` into the sentinel at query time.

  ## Idempotency / fresh-DB behavior

  Stage 4's data migration (`20260519210000_path_style_file_keys_and_alias_backfill.exs`)
  is updated in the same commit to write `workspace_id` directly into
  every alias row it inserts, using the page's own `workspace_id` (or
  the sentinel when it's NULL). So on a fresh `ecto.migrate`, stage 4
  produces per-workspace rows directly; this migration is then a no-op
  schema-wise (the `ALTER` runs but finds the column already created…
  actually no — see below).

  Actually, ordering matters: stage 4 runs BEFORE this migration, so on
  a fresh migrate stage 4 inserts rows into a `workspace_id`-less table.
  That's fine: we add the column nullable here, backfill from the joined
  `org_wiki_pages.workspace_id`, then NOT NULL it. The composite PK
  swap happens last.

  Raw SQL throughout, per the stage-2/4 convention — schema modules can
  rename out from under early migrations.
  """

  # NIL sentinel for org-scoped aliases (no workspace). Postgres can't put
  # NULL in a composite PK, so we use a fixed sentinel UUID.
  @nil_sentinel "00000000-0000-0000-0000-000000000000"

  def up do
    # 1. Add the column nullable so existing rows survive the ALTER.
    execute("""
    ALTER TABLE org_wiki_aliases
      ADD COLUMN workspace_id uuid
    """)

    # 2. Backfill from org_wiki_pages — the page each alias points at owns
    #    the canonical workspace_id. COALESCE handles org-scoped pages
    #    (workspace_id IS NULL) by stamping the sentinel.
    execute("""
    UPDATE org_wiki_aliases a
       SET workspace_id = COALESCE(p.workspace_id, '#{@nil_sentinel}'::uuid)
      FROM org_wiki_pages p
     WHERE a.current_id = p.id
    """)

    # 3. Any leftover rows (current_id refers to a page that vanished
    #    between stage 4 and now — possible if a page was deleted): pin
    #    them to the sentinel rather than dropping the row.
    execute("""
    UPDATE org_wiki_aliases
       SET workspace_id = '#{@nil_sentinel}'::uuid
     WHERE workspace_id IS NULL
    """)

    # 4. Tighten the column and swap the primary key.
    execute("ALTER TABLE org_wiki_aliases ALTER COLUMN workspace_id SET NOT NULL")
    execute("ALTER TABLE org_wiki_aliases DROP CONSTRAINT IF EXISTS org_wiki_aliases_pkey")
    execute("ALTER TABLE org_wiki_aliases ADD PRIMARY KEY (workspace_id, old_path)")
  end

  def down do
    # Reverse the composite-PK swap; drop the column. Data on disposed
    # workspaces is lost, which matches the original single-PK semantics.
    execute("ALTER TABLE org_wiki_aliases DROP CONSTRAINT IF EXISTS org_wiki_aliases_pkey")
    execute("ALTER TABLE org_wiki_aliases ADD PRIMARY KEY (old_path)")
    execute("ALTER TABLE org_wiki_aliases DROP COLUMN workspace_id")
  end
end
