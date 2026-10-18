defmodule Platform.Repo.Migrations.BackfillRootOrgMemberships do
  @moduledoc """
  Backfill every existing user into the root org.

  ## Strategy (design review 2026-05-19)

    * Default role for everyone: `"member"`.
    * Explicit `"admin"` grants for named accounts only. The list named
      the first install's admins; this migration ran there long ago, and on
      any database migrated since, the users table is empty at this point,
      so the grant matches no row. The list now holds one placeholder
      address and the UPDATE stays a no-op on a fresh database
      (task 01a14b9e stage 3).
    * One internal user intentionally stayed `:member` so the non-admin
      code path is exercised against a real internal user in production.

  ## The historical root slug is matched by digest (task 01a14b9e stage 5)

  This SQL used to compare against the first install's root slug spelled as
  a literal. It now compares the sha256 of the slug against that literal's
  digest instead, so the public tree does not spell an operator's name.
  The predicate is true for exactly the same rows as the literal comparison
  was, on every database: the version prefix is unchanged, so no existing
  install re-runs this, and a fresh migrate selects the same rows as
  before (proved by a fresh-DB dump comparison, stage 5 completion).

  ## Agent / system users

  As of this migration there is **no `agent:` or `system:` prefix
  convention on `users.oidc_sub`** (grep'd; nothing matches). The accounts
  module also has no `kind` column to identify non-human rows. Every user
  in the table gets a root-org membership; if a future agent-user convention
  is added, a follow-up migration will need to delete the agent rows
  from `org_memberships` (or skip them at backfill time).

  ## ON CONFLICT

  `ON CONFLICT (user_id, org_id) DO NOTHING` makes the insert idempotent
  — re-running on a DB that already has memberships is a no-op. The admin
  grant uses a separate UPDATE that's idempotent by construction.

  Reversal (`down/0`) deletes all root-org memberships. The named admin
  accounts will need to be re-granted manually after a rollback.
  """

  use Ecto.Migration

  @admin_emails ["admin@example.com"]

  def up do
    # Part A — every existing user gets :member in the root org.
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO org_memberships (id, user_id, org_id, role, inserted_at, updated_at)
      SELECT gen_random_uuid(), u.id, o.id, 'member', NOW(), NOW()
      FROM users u, orgs o
      WHERE encode(sha256(convert_to(o.slug, 'UTF8')), 'hex') = '9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c'
      ON CONFLICT (user_id, org_id) DO NOTHING
      """,
      []
    )

    # Part B — promote the named accounts to :admin.
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      UPDATE org_memberships
      SET role = 'admin', updated_at = NOW()
      WHERE org_id = (SELECT id FROM orgs WHERE encode(sha256(convert_to(slug, 'UTF8')), 'hex') = '9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c')
        AND user_id IN (
          SELECT id FROM users WHERE email = ANY($1)
        )
      """,
      [@admin_emails]
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      DELETE FROM org_memberships
      WHERE org_id = (SELECT id FROM orgs WHERE encode(sha256(convert_to(slug, 'UTF8')), 'hex') = '9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c')
      """,
      []
    )
  end
end
