defmodule Platform.Repo.Migrations.CreateOrgs do
  @moduledoc """
  MT/RBAC foundation — `orgs` schema + FK enforcement on owner-org columns.

  Lands stack member 1 of the MT/RBAC foundation per Plan 1 v3
  (task 019e3c49-c1b1-75f1-9f61-e62877ef1641).

  ## Schema

    * `orgs` — two-tier hierarchy (root org + named tenants beneath it).
      - `parent_org_id` is nullable; a NULL parent means this row is the
        root. A partial unique index enforces "exactly one root row" at the
        DB level so we cannot accidentally seed two roots.
      - `slug` is unique system-wide and url-safe.
      - `on_delete: :restrict` on the self-FK prevents accidental deletion
        of a parent while it still has tenant children.

  ## FK additions on pre-existing org columns

  ADR 0040 Stages 1 + 2 introduced `owner_org_id` and `actor_org_id`
  columns as bare `:binary_id` (no FK) so existing data could land without
  a destination table. Now that `orgs` exists, this migration converts the
  columns to real foreign keys:

    * `runtime_events.owner_org_id` → `orgs.id`
    * `execution_leases.owner_org_id` → `orgs.id`
    * `audit_events.actor_org_id` → `orgs.id`
    * `invocation_visibility_grants.grantee_org_id` → `orgs.id`
    * `invocation_visibility_grants.granted_by_org_id` → `orgs.id`

  All FKs use `on_delete: :restrict`. Tenants are durable concepts — an
  attempt to delete an org that still owns runtime/audit history must
  surface to the operator, not cascade-delete history.

  ## workspace_id bridge note

  `workspace_id` (ADR 0033) is the legacy precursor to `org_id`. Per
  Dalton audit 2026-05-19: ~170 references across 6+ schemas,
  1/117 populated in `org_memory_entries`, 0 elsewhere. The full rename
  is deferred until stack member 2+. **Do NOT introduce new code that
  reads or writes `workspace_id` for tenancy decisions** — use
  `Platform.Tenancy` instead.

  ## Fixture impact

  Pre-existing tests under `apps/platform/test/platform/audit/`,
  `apps/platform/test/platform/orchestration/`, and
  `apps/platform/test/platform/federation/` insert rows with arbitrary
  `Ecto.UUID.generate()` values into the now-FK'd columns. Those tests
  have been updated in the same commit to use the seeded Fabrikam org id via
  the new `Platform.TestFixtures.fabrikam_org_id/0` helper.

  ## Reversibility

  Rollback drops the FK constraints first (returning the columns to
  bare `:binary_id`), then drops the `orgs` table. Existing data in the
  FK'd columns is preserved across rollback.
  """

  use Ecto.Migration

  def change do
    create table(:orgs, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :parent_org_id,
        references(:orgs, type: :binary_id, on_delete: :restrict),
        null: true
      )

      add(:name, :string, null: false)
      add(:slug, :string, null: false)

      timestamps()
    end

    create(unique_index(:orgs, [:slug]))
    create(index(:orgs, [:parent_org_id]))

    # DB-enforced "exactly one root org" — a partial unique index over
    # the constant expression `(parent_org_id IS NULL)`. PostgreSQL
    # allows at most one row matching the WHERE predicate to share the
    # same indexed value, so any second insert with parent_org_id=NULL
    # is rejected at the DB level.
    create(
      unique_index(:orgs, ["(parent_org_id IS NULL)"],
        where: "parent_org_id IS NULL",
        name: :orgs_single_root
      )
    )

    # ── FK conversions on pre-existing org columns ──────────────────────
    alter table(:runtime_events) do
      modify(:owner_org_id, references(:orgs, type: :binary_id, on_delete: :restrict),
        from: :binary_id
      )
    end

    alter table(:execution_leases) do
      modify(:owner_org_id, references(:orgs, type: :binary_id, on_delete: :restrict),
        from: :binary_id
      )
    end

    alter table(:audit_events) do
      modify(:actor_org_id, references(:orgs, type: :binary_id, on_delete: :restrict),
        from: :binary_id
      )
    end

    alter table(:invocation_visibility_grants) do
      modify(:grantee_org_id, references(:orgs, type: :binary_id, on_delete: :restrict),
        from: :binary_id
      )

      modify(:granted_by_org_id, references(:orgs, type: :binary_id, on_delete: :restrict),
        from: :binary_id
      )
    end
  end
end
