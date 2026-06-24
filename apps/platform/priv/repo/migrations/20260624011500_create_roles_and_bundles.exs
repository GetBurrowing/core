defmodule Platform.Repo.Migrations.CreateRolesAndBundles do
  use Ecto.Migration

  @moduledoc """
  Roles & Responsibility Bundles — M4 stage 1 (task 019ef65b-a361).

  Adds the platform-defined Roles registry that bundles responsibility
  contracts (Designer / Historian / Meeting Scribe / Triage Officer per
  stack decision #2 — the role roster is fixed by the platform, not
  user-extensible). Two tables:

    * `roles` — the four fixed role rows. The natural `key` text is the
      primary key (no surrogate UUID) because rows are platform-fixed
      and every join table references key not id. The CHECK constraint
      mirrors the `org_memberships.role` enforcement style from
      `20260519143610_create_org_memberships.exs:59` and keeps any
      direct-SQL writer honest about the closed enum.

    * `role_responsibilities` — many-to-many between a role and the
      responsibility keys (from M1's `responsibilities` table) the role
      bundles. The `responsibility_key` column is NOT yet wired to a
      hard FK against `responsibilities(key)` — M1's table already
      shipped on main with a unique `key` index, but layering the FK
      here adds an ordering dependency that complicates rebuilds when
      M1 churns. Stage 4's seed migration tolerates absent
      responsibility rows (resolver returns nil for unknown keys); a
      follow-up can add the FK once M1's seed list is canonized.

  Reversible: `change/0` uses `create table` + `create index`, both of
  which Ecto can run in both directions. The cascade on
  `role_responsibilities.role_key` means dropping a role row clears its
  bundle entries; the table drop in rollback handles the rest.

  Forbidden in this stage (deferred to M4 stages 2-5):
    - role_assignments + responsibility_overrides tables (stage 2).
    - `Platform.Roles` context module + resolver (stage 3).
    - Seeding the four canonical roles (stage 4).
    - Test coverage + e2e behaviors (stage 5).
  """

  def change do
    create table(:roles, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text, null: false)
      add(:icon, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:roles, :roles_key_check,
        check: "key IN ('designer','historian','meeting_scribe','triage_officer')"
      )
    )

    create table(:role_responsibilities, primary_key: false) do
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

      add(:responsibility_key, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:role_responsibilities, [:role_key, :responsibility_key],
        name: :role_responsibilities_pair_idx
      )
    )

    create(index(:role_responsibilities, [:role_key]))
    create(index(:role_responsibilities, [:responsibility_key]))
  end
end
