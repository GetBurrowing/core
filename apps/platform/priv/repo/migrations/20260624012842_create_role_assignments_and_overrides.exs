defmodule Platform.Repo.Migrations.CreateRoleAssignmentsAndOverrides do
  use Ecto.Migration

  @moduledoc """
  Role assignments + responsibility overrides — M4 stage 2 (task
  019ef65b-a361). Builds on stage 1's `roles` + `role_responsibilities`
  tables.

  Two tables:

    * `role_assignments` — pins exactly one agent to each role. The
      `role_key` column is a hard FK to `roles(key)` (cascading on
      delete) and carries a **unique index** so a given role can have
      at most one assignee at any time. This enforces Decision 1 from
      the stack: roles map 1:1 to agents, no shared ownership. The
      reverse-lookup `(agent_id)` index supports `roles_for(agent_id)`
      queries the stage-3 resolver will issue.

    * `responsibility_overrides` — per-responsibility deviation from
      the role-bundle defaults. The `responsibility_key` column is
      uniquely indexed so a single responsibility can be pinned to at
      most one override agent (Decision 3). Mirroring stage 1's
      decision, `responsibility_key` stays a bare string with no hard
      FK to `responsibilities(key)`; the resolver simply returns the
      override agent when the key is overridden and otherwise falls
      back to the bundle lookup.

  Both tables FK `agent_id → agents(id)` with delete-cascade so deleted
  agents don't leave dangling assignments or overrides. Primary keys
  use `gen_random_uuid()` defaults matching `role_responsibilities` in
  stage 1.

  Reversible: pure `create table`/`create index`; rollback drops the
  tables.

  Forbidden in this stage (deferred to M4 stages 3-5):
    - `Platform.Roles` context module + resolver (stage 3).
    - Seeding the four canonical roles + sample assignments (stage 4).
    - End-to-end behavioral coverage (stage 5).
  """

  def change do
    create table(:role_assignments, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :role_key,
        references(:roles,
          column: :key,
          type: :string,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :agent_id,
        references(:agents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:role_assignments, [:role_key]))
    create(index(:role_assignments, [:agent_id]))

    create table(:responsibility_overrides, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:responsibility_key, :string, null: false)

      add(
        :agent_id,
        references(:agents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:responsibility_overrides, [:responsibility_key]))
    create(index(:responsibility_overrides, [:agent_id]))
  end
end
