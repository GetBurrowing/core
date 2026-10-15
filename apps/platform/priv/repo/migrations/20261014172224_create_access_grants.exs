defmodule Platform.Repo.Migrations.CreateAccessGrants do
  @moduledoc """
  Task 01a1386d-e528 stage 2 (stack `rbac-roles`), recorded in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`: the
  `access_grants` table, owned by `Platform.Access`. One row is an explicit
  allow or deny of one permission on one resource for one principal.

    * `principal_type` is `user`, `role` or `agent`. A user or agent row sets
      `principal_id`; a role row sets `principal_role_key` (FK to
      `access_roles.key`). A CHECK keeps exactly the matching one set.
    * `resource_type` is `project`, `space`, `canvas` or `memory_node`. A
      memory row's `resource_id` is an `org_memory_nodes.id`, never a path.
      The column is polymorphic, so no FK is possible;
      `Platform.Access.Grants.merge_memory_nodes/2` re-points rows when a
      rename displaces a node.
    * `effect` is `allow` or `deny`. The unique index over (principal,
      permission, resource), `NULLS NOT DISTINCT`, means one tuple cannot be
      both an allow and a deny.

  The name is free: the vault's table is `vault_access_grants`. It is NOT in
  the `Platform.Roles` namespace, which is the agent responsibility system.

  ## Nothing existing changes

  The table is new and empty. No existing table, column or row is touched,
  so no production data changes meaning. `down/0` drops the table.
  """

  use Ecto.Migration

  def up do
    require_pg15!()

    create table(:access_grants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:principal_type, :text, null: false)
      add(:principal_id, :uuid)

      add(
        :principal_role_key,
        references(:access_roles, column: :key, type: :text, on_delete: :delete_all)
      )

      add(:permission, :text, null: false)
      add(:resource_type, :text, null: false)
      add(:resource_id, :uuid, null: false)
      add(:effect, :text, null: false)
      add(:granted_by, :uuid)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:access_grants, :access_grants_principal_type_check,
        check: "principal_type IN ('user', 'role', 'agent')"
      )
    )

    create(
      constraint(:access_grants, :access_grants_principal_check,
        check: """
        (principal_type = 'role' AND principal_role_key IS NOT NULL AND principal_id IS NULL)
        OR (principal_type IN ('user', 'agent') AND principal_id IS NOT NULL AND principal_role_key IS NULL)
        """
      )
    )

    create(
      constraint(:access_grants, :access_grants_resource_type_check,
        check: "resource_type IN ('project', 'space', 'canvas', 'memory_node')"
      )
    )

    create(
      constraint(:access_grants, :access_grants_effect_check,
        check: "effect IN ('allow', 'deny')"
      )
    )

    create(
      unique_index(
        :access_grants,
        [
          :principal_type,
          :principal_id,
          :principal_role_key,
          :permission,
          :resource_type,
          :resource_id
        ],
        nulls_distinct: false,
        name: :access_grants_tuple_index
      )
    )

    create(index(:access_grants, [:principal_id]))
    create(index(:access_grants, [:principal_role_key, :org_id]))
    create(index(:access_grants, [:resource_type, :resource_id]))
  end

  def down do
    drop(table(:access_grants))
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. The one-effect-per-tuple
      index on access_grants cannot be built without it. Upgrade the server.
      """
    end
  end
end
