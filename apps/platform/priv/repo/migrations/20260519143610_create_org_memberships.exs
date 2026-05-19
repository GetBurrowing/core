defmodule Platform.Repo.Migrations.CreateOrgMemberships do
  @moduledoc """
  `org_memberships` — join table between users and orgs with a role.

  Lands stack member 1 of the MT/RBAC foundation per Plan 1 v3.

  ## Roles

  Application-side enum, DB-enforced via CHECK constraint:

    * `"admin"` — full admin rights within the org. Fabrikam admins are the
      product-team operators. Tenant admins are tenant-internal operators.
    * `"member"` — default. Read/write within the org, no admin operations.

  CHECK constraint is named `org_memberships_role_check` and lives at the
  DB level so any direct-SQL path (psql, audits, ad-hoc backfills) sees
  the same enforcement as Ecto callers.

  ## Cascades

    * `on_delete: :delete_all` on both FKs — when a user or org is deleted,
      its memberships disappear. Org deletion is itself restricted by
      `runtime_events` / `execution_leases` / `audit_events` FKs (see
      `create_orgs` migration), so this only fires for truly orphaned orgs.

  ## Indexes

    * `(user_id, org_id)` unique — one membership row per (user, org) pair.
    * `user_id` — supports "what orgs is this user in?" lookups
      (`Platform.Tenancy.list_user_memberships/1`).
  """

  use Ecto.Migration

  def change do
    create table(:org_memberships, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :org_id,
        references(:orgs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:role, :string, null: false)

      timestamps()
    end

    create(unique_index(:org_memberships, [:user_id, :org_id]))
    create(index(:org_memberships, [:user_id]))

    execute(
      """
      ALTER TABLE org_memberships
        ADD CONSTRAINT org_memberships_role_check
        CHECK (role IN ('admin', 'member'))
      """,
      """
      ALTER TABLE org_memberships
        DROP CONSTRAINT org_memberships_role_check
      """
    )
  end
end
