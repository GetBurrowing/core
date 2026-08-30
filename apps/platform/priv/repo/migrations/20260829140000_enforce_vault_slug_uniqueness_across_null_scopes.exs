defmodule Platform.Repo.Migrations.EnforceVaultSlugUniquenessAcrossNullScopes do
  @moduledoc """
  Task 01a04e18 — make `vault_credentials_unique_slug_per_scope` actually
  constrain anything.

  ## The defect is wider than "the platform scope"

  `20260314060001_create_vault_tables` created

      unique_index(:vault_credentials, [:workspace_id, :scope_type, :scope_id, :slug],
        name: :vault_credentials_unique_slug_per_scope)

  with no `nulls_distinct:` option, so Postgres built it `NULLS DISTINCT` (the
  default). A btree unique index skips the conflict check for any row where
  **any** indexed column is NULL. Two of the four columns are nullable, and
  measured on Postgres 16.14 against this schema:

      workspace_id | scope                | second put/4 | rows
      -------------+----------------------+--------------+------
      NULL         | {:platform, nil}     | {:ok, _}     | 2
      NULL         | {:agent, <uuid>}     | {:ok, _}     | 2
      <uuid>       | {:platform, nil}     | {:ok, _}     | 2
      <uuid>       | {:agent, <uuid>}     | {:error, cs} | 1

  Only the last row — every indexed column populated — is constrained. The
  ticket framed this as a platform-scope problem on the reasoning that
  `{:platform, nil}` nulls both `workspace_id` and `scope_id`. That is true but
  it is not the boundary: `workspace_id` alone is enough, and **nothing in
  `lib/` passes `:workspace_id` to `Platform.Vault.put/4`**. The only mention of
  the option outside the moduledoc is the `Keyword.get(opts, :workspace_id)`
  inside `put/4` that reads it. `Platform.Vault`'s own moduledoc calls the
  column "vestigial scaffolding" and there is no `workspaces` table for it to
  reference.

  So every credential this system has ever written has `workspace_id IS NULL`,
  and this index has never rejected a duplicate at any scope. Agent- and
  integration-scoped credentials are as unconstrained as platform-scoped ones.

  ## What this migration does, in order

  A unique index cannot be built over existing duplicates, so the duplicates go
  first.

  ### 1. Park the losers instead of deleting them

  Within each `(workspace_id, scope_type, scope_id, slug)` group — comparing
  NULLs as equal, which is the comparison the index is about to start making —
  one row is kept and the rest are renamed to

      left(slug, 200) || '__dup_' || id

  rather than deleted.

  **Deleting was the obvious move and it is the wrong one for a vault.** The
  losing row's `encrypted_data` is live key material; a migration that destroys
  it leaves an operator nothing to inspect and nothing to recover, and `down/0`
  could not put it back. Renaming satisfies the index (ids are unique, so the
  parked slug is too), is re-runnable, and leaves every byte on disk for an
  operator to look at and delete deliberately. A parked row no longer answers
  to its original slug, which is the whole point — exactly one row does.

  It also disposes of the `AccessGrant` question the ticket raises. Had this
  deleted the losers, `vault_access_grants.credential_id` is `ON DELETE CASCADE`
  and their grants would have gone silently — and re-pointing them at the winner
  would then have to merge against `vault_access_grants_unique_grant`. Nothing
  is deleted, so grants stay attached to the row they were written for and no
  merge policy has to be invented inside a migration.

  Likewise the access log: no `credential_id` changes, so no history is
  re-attributed. Those rows really did describe the parked credential.

  ### 2. Which row wins

  `COALESCE(rotated_at, updated_at, inserted_at) DESC, inserted_at DESC, id DESC`
  — the most recently rotated row, because a rotation is the strongest available
  evidence of which duplicate someone is actually maintaining. The trailing
  `inserted_at`/`id` terms only exist to make the order total, so the choice is
  deterministic and a re-run parks the same rows.

  ### 3. Then the constraint

  Recreated as `NULLS NOT DISTINCT`, which makes the four-column comparison
  treat NULL as a value. This closes all three unconstrained rows in the table
  above at once — it is not specific to the platform scope.

  Uniqueness stays **per scope**. The index columns are unchanged; the same slug
  at a different `scope_type`/`scope_id` still inserts cleanly, which is
  deliberate and covered by a test.

  ## Postgres version

  `NULLS NOT DISTINCT` is Postgres 15+. Rather than assume, `up/0` reads
  `server_version_num` and raises a message naming the version it found if the
  server is older, so an unexpected environment fails on a sentence instead of a
  syntax error. Two migrations already in `main` ship the same syntax —
  `20260714000000_relax_org_historian_cursors_null_workspace` and
  `20260728000100_create_federation_dead_letter_stats` — so any environment that
  is migrated up to `main` has already executed it successfully.

  ## Safety on production data

  Whether production holds duplicates today could not be checked from the box
  this was written on. It does not need to be known: the parking pass is
  unconditional and a no-op on a clean table, and it runs before the index, so
  the migration cannot abort on duplicates it did not expect. Every row it parks
  is named in a `RAISE NOTICE` (id, scope, old and new slug — never the value),
  so the migration output is the record of what changed.

  `down/0` restores the `NULLS DISTINCT` index. It deliberately does **not**
  un-park the renamed rows: un-parking would recreate duplicates underneath an
  index that is about to stop tolerating them on the next `up`, and the parked
  slug is a plain column an operator can edit by hand.
  """

  use Ecto.Migration

  @index_name "vault_credentials_unique_slug_per_scope"

  def up do
    require_pg15!()
    park_duplicate_slugs()

    execute("DROP INDEX IF EXISTS #{@index_name}")

    execute("""
    CREATE UNIQUE INDEX #{@index_name}
      ON vault_credentials (workspace_id, scope_type, scope_id, slug)
      NULLS NOT DISTINCT
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index_name}")

    execute("""
    CREATE UNIQUE INDEX #{@index_name}
      ON vault_credentials (workspace_id, scope_type, scope_id, slug)
    """)
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. Upgrade the server, or
      replace the index in this migration with one over
      COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000') and the
      same for scope_id — an expression index gets the same uniqueness on older
      servers, at the cost of no longer matching Ecto's constraint inference
      from a bare column list.
      """
    end
  end

  # Renames every duplicate but the winner. `GROUP BY` and `PARTITION BY` both
  # compare NULLs as equal (unlike `=`), which is exactly the comparison the new
  # index will make, so the grouping here and the constraint below agree by
  # construction rather than by a hand-written `IS NOT DISTINCT FROM` chain.
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
                 scope_type,
                 scope_id,
                 workspace_id,
                 ROW_NUMBER() OVER (
                   PARTITION BY workspace_id, scope_type, scope_id, slug
                   ORDER BY COALESCE(rotated_at, updated_at, inserted_at) DESC,
                            inserted_at DESC,
                            id DESC
                 ) AS rn
            FROM vault_credentials
        )
        UPDATE vault_credentials AS c
           SET slug = left(ranked.slug, 200) || '__dup_' || ranked.id::text
          FROM ranked
         WHERE c.id = ranked.id
           AND ranked.rn > 1
        RETURNING c.id, ranked.slug AS old_slug, c.slug AS new_slug,
                  c.scope_type, c.scope_id, c.workspace_id
      LOOP
        n := n + 1;
        RAISE NOTICE
          'vault dedupe: parked credential % (scope=%:% workspace=%) slug % -> %',
          parked.id, parked.scope_type, parked.scope_id, parked.workspace_id,
          parked.old_slug, parked.new_slug;
      END LOOP;

      IF n = 0 THEN
        RAISE NOTICE 'vault dedupe: no duplicate slugs found; nothing parked.';
      ELSE
        RAISE WARNING
          'vault dedupe: parked % duplicate credential row(s). Their values are intact under the __dup_ slugs; review and delete deliberately.',
          n;
      END IF;
    END $$;
    """)
  end
end
