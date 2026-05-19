defmodule Platform.Repo.Migrations.BackfillFabrikamMemberships do
  @moduledoc """
  Backfill every existing user into the Fabrikam org.

  ## Strategy (Marlowe 2026-05-19)

    * Default role for everyone: `"member"`.
    * Explicit `"admin"` grants for named accounts only:
      - rowan.ellis@example.com
      - member-a@example.com
      - sloane.tyrell@example.com
      - member-b@example.com
      - marlowe.quill@example.com
    * Harper Parker intentionally stays `:member` so the non-admin code
      path is exercised against a real internal user in production.

  ## Agent / system users

  As of this migration there is **no `agent:` or `system:` prefix
  convention on `users.oidc_sub`** (grep'd; nothing matches). The accounts
  module also has no `kind` column to identify non-human rows. Every user
  in the table gets a Fabrikam membership; if a future agent-user convention
  is added, a follow-up migration will need to delete the agent rows
  from `org_memberships` (or skip them at backfill time).

  ## ON CONFLICT

  `ON CONFLICT (user_id, org_id) DO NOTHING` makes the insert idempotent
  — re-running on a DB that already has memberships is a no-op. The admin
  grant uses a separate UPDATE that's idempotent by construction.

  Reversal (`down/0`) deletes all Fabrikam memberships. The named admin
  accounts will need to be re-granted manually after a rollback.
  """

  use Ecto.Migration

  @admin_emails [
    "rowan.ellis@example.com",
    "member-a@example.com",
    "sloane.tyrell@example.com",
    "member-b@example.com",
    "marlowe.quill@example.com"
  ]

  def up do
    # Part A — every existing user gets :member in Fabrikam.
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO org_memberships (id, user_id, org_id, role, inserted_at, updated_at)
      SELECT gen_random_uuid(), u.id, o.id, 'member', NOW(), NOW()
      FROM users u, orgs o
      WHERE o.slug = 'fabrikam'
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
      WHERE org_id = (SELECT id FROM orgs WHERE slug = 'fabrikam')
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
      WHERE org_id = (SELECT id FROM orgs WHERE slug = 'fabrikam')
      """,
      []
    )
  end
end
