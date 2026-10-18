defmodule Platform.Repo.Migrations.EnforceAgentSlugUniquenessAcrossNullWorkspace do
  @moduledoc """
  Task 01a0e77c stage 4 — make `agents_unique_slug` actually constrain the
  rows production has.

  ## The defect

  `20260314205846_create_agent_tables` created

      unique_index(:agents, [:workspace_id, :slug], name: :agents_unique_slug)

  with no `nulls_distinct:` option, so Postgres built it `NULLS DISTINCT` (the
  default): the conflict check is skipped for any row whose `workspace_id` is
  NULL. Measured read-only on 2026-09-28 against the four Suite installs on the production host
  (`core_platform` = prod, `installb_platform`, `installc_platform`,
  `core_platform_exp`; server 16.15):

    * every agent row has `workspace_id IS NULL` (prod 22 of 22, install B 1 of 1,
      install C 1 of 1, exp has no rows);
    * `pg_indexes` shows the plain `(workspace_id, slug)` unique index;
    * the NULL-aware `SELECT slug, count(*) FROM agents GROUP BY slug
      HAVING count(*) > 1` returned zero rows on all four.

  So this index has never rejected a duplicate slug in production; there is
  simply no duplicate yet. The same finding was recorded before in the org
  journal on 2026-08-02 (task 019fb955) and in the moduledoc of
  `Platform.Meetings.SenderSeed`, which serializes its own insert on an
  advisory lock precisely because this index would not. It is the same
  defect `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes`
  fixed on `vault_credentials`, and this migration mirrors that one.

  Readers were made fail-closed first (stages 1-3: every
  `Repo.get_by(Agent, slug:)` now goes through
  `Platform.Agents.SlugLookup.resolve/2`); this migration stops duplicates
  being written.

  ## What it does, in order

  ### 1. Park duplicates instead of deleting them

  Within each `(workspace_id, slug)` group — `PARTITION BY` compares NULLs as
  equal, which is the comparison the index is about to start making — one row
  is kept and the rest are renamed to

      left(slug, 200) || '__dup_' || id

  Deleting would be wrong: agents are referenced by chat participants,
  sessions, workspace files, memories and runtimes, several through
  `ON DELETE CASCADE`, so a delete would silently take history with it.
  Renaming keeps every reference pointing at the row it was written for,
  satisfies the index (ids are unique, so the parked slug is too), and leaves
  the row for an operator to inspect and remove deliberately. A parked row no
  longer answers to its original slug, which is the point: exactly one does.

  ### 2. Which row wins

  `status = 'active' DESC, updated_at DESC, inserted_at DESC, id DESC`. A live
  agent beats a paused or archived one because the live one is what dispatch,
  chat and meetings are actually addressing by that slug; parking it would
  break routing to the agent people are using in favour of one nobody is.
  Among equals, the most recently updated row is the one being maintained.
  The trailing terms only make the order total, so a re-run parks the same
  rows.

  ### 3. Then the constraint

  `DROP INDEX IF EXISTS agents_unique_slug`, then
  `CREATE UNIQUE INDEX agents_unique_slug ON agents (workspace_id, slug)
  NULLS NOT DISTINCT`. Same name, so `Agent.changeset/2`'s
  `unique_constraint(:slug, name: :agents_unique_slug)` keeps turning a
  violation into a changeset error rather than a raise. Same columns, so
  uniqueness stays per workspace: one slug in two different non-NULL
  workspaces still inserts.

  Every row the parking pass renames is named in a `RAISE NOTICE` (id,
  workspace, old and new slug), with a `RAISE WARNING` carrying the count, so
  the migration output is the record of what changed. On the four measured
  installs it parks nothing.

  ## Postgres version

  `NULLS NOT DISTINCT` is Postgres 15+. `up/0` reads `server_version_num` and
  raises a sentence naming what it found on an older server instead of a
  syntax error. Production is 16.15 and CI is PG16.

  ## down/0

  Restores the `NULLS DISTINCT` index. It does not un-park renamed rows:
  un-parking would recreate duplicates that the next `up/0` would park again,
  and a parked slug is a plain column an operator can edit by hand.
  """

  use Ecto.Migration

  @index_name "agents_unique_slug"

  def up do
    require_pg15!()
    park_duplicate_slugs()

    execute("DROP INDEX IF EXISTS #{@index_name}")

    execute("""
    CREATE UNIQUE INDEX #{@index_name}
      ON agents (workspace_id, slug)
      NULLS NOT DISTINCT
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index_name}")

    execute("""
    CREATE UNIQUE INDEX #{@index_name}
      ON agents (workspace_id, slug)
    """)
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. Upgrade the server, or
      replace the index in this migration with one over
      (COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000'), slug) —
      an expression index gets the same uniqueness on older servers, at the
      cost of no longer matching Ecto's constraint inference from a bare
      column list.
      """
    end
  end

  # Renames every duplicate but the winner. `PARTITION BY` compares NULLs as
  # equal (unlike `=`), which is exactly the comparison the new index will
  # make, so the grouping here and the constraint below agree by construction.
  defp park_duplicate_slugs do
    execute("""
    DO $$
    DECLARE
      parked RECORD;
      n INT := 0;
    BEGIN
      FOR parked IN
        WITH ranked AS (
          SELECT id,
                 slug,
                 workspace_id,
                 ROW_NUMBER() OVER (
                   PARTITION BY workspace_id, slug
                   ORDER BY (status = 'active') DESC,
                            updated_at DESC,
                            inserted_at DESC,
                            id DESC
                 ) AS rn
            FROM agents
        )
        UPDATE agents AS a
           SET slug = left(ranked.slug, 200) || '__dup_' || ranked.id::text
          FROM ranked
         WHERE a.id = ranked.id
           AND ranked.rn > 1
        RETURNING a.id, ranked.slug AS old_slug, a.slug AS new_slug, a.workspace_id
      LOOP
        n := n + 1;
        RAISE NOTICE
          'agent slug dedupe: parked agent % (workspace=%) slug % -> %',
          parked.id, parked.workspace_id, parked.old_slug, parked.new_slug;
      END LOOP;

      IF n = 0 THEN
        RAISE NOTICE 'agent slug dedupe: no duplicate slugs found; nothing parked.';
      ELSE
        RAISE WARNING
          'agent slug dedupe: parked % duplicate agent row(s) under __dup_ slugs; every reference to them is intact. Review and remove deliberately.',
          n;
      END IF;
    END $$;
    """)
  end
end
