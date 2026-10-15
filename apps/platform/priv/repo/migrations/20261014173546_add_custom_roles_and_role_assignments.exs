defmodule Platform.Repo.Migrations.AddCustomRolesAndRoleAssignments do
  @moduledoc """
  Task 01a1386e-59d1 stage 1 (stack `rbac-roles`, member 8;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`):
  custom roles as per-org permission sets, and assignments that let a
  principal hold one.

    * `access_roles.org_id` — nullable FK to `orgs`, `on_delete: :delete_all`.
      NULL on the three built-in rows, which this migration does not touch.
      A CHECK keeps `builtin OR org_id IS NOT NULL`, so every custom role
      belongs to an org, and a partial unique index keeps a custom role's
      name unique per org, case-insensitively. A custom role's `key` is
      minted by `Platform.Access.Roles` as `"custom:" <> uuidv7`, so it never
      collides with `admin` / `member` / `guest` and plugs straight into
      `access_grants.principal_role_key`'s FK with no further migration.
    * `access_role_assignments` — one row per (org, principal, role, source).
      `principal_type` is `user` or `agent`; `source` is `manual` or `idp`.
      `role_key` references `access_roles(key)` with `on_delete: :delete_all`,
      so deleting a custom role drops its assignments.

  ## The base role stays derived (departure from member 2's forecast)

  Member 2's migration moduledoc forecasts converting
  `org_memberships.access_role_key` into an assignable column (`DROP
  EXPRESSION`). This migration does NOT: the base role stays the generated
  column, and extra roles are additive assignment rows. The 13 membership
  writers stay drift-free, and with zero assignment rows every Scope is the
  one member 2 and 3 built.
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles` records
  this choice.

  ## Nothing existing changes meaning

  No existing row is rewritten. `down/0` drops the new table, then the
  index, the CHECK and the column. It also deletes every non-built-in
  `access_roles` row first: a custom role cannot exist without its org, and
  before this migration no API could create one (the delete cascades to the
  custom roles' `access_grants` rows through member 3's FK).
  """

  use Ecto.Migration

  def up do
    alter table(:access_roles) do
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all))
    end

    create(
      constraint(:access_roles, :access_roles_custom_org_check, check: "builtin OR org_id IS NOT NULL")
    )

    execute("""
    CREATE UNIQUE INDEX access_roles_org_name_index
      ON access_roles (org_id, lower(name))
      WHERE org_id IS NOT NULL
    """)

    create table(:access_role_assignments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:principal_type, :text, null: false)
      add(:principal_id, :binary_id, null: false)

      add(
        :role_key,
        references(:access_roles, column: :key, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:source, :text, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:access_role_assignments, :access_role_assignments_principal_type_check,
        check: "principal_type IN ('user', 'agent')"
      )
    )

    create(
      constraint(:access_role_assignments, :access_role_assignments_source_check,
        check: "source IN ('manual', 'idp')"
      )
    )

    create(
      unique_index(
        :access_role_assignments,
        [:org_id, :principal_type, :principal_id, :role_key, :source],
        name: :access_role_assignments_tuple_index
      )
    )

    create(index(:access_role_assignments, [:principal_type, :principal_id]))
    create(index(:access_role_assignments, [:role_key]))
  end

  def down do
    drop(table(:access_role_assignments))
    execute("DELETE FROM access_roles WHERE NOT builtin")
    execute("DROP INDEX access_roles_org_name_index")
    drop(constraint(:access_roles, :access_roles_custom_org_check))

    alter table(:access_roles) do
      remove(:org_id)
    end
  end
end
