defmodule Platform.Repo.Migrations.AddOwnerIdentityToRuntimeTables do
  @moduledoc """
  Add `invoked_by_user_id`, `owner_org_id`, and `owner_attribution_status` to
  `runtime_events` and `execution_leases` per ADR 0040 Stage 1.

  All columns are NULL-permissive on this migration. Existing rows are
  populated with `owner_attribution_status = 'legacy_pre_migration'` and
  NULL owner ids — these rows are anonymous forever (per ADR 0040 §D3,
  best-effort backfill is impossible because `tasks` has no
  `created_by_user_id` field).

  New rows written via `Platform.Orchestration.RuntimeSupervision.record_event/1`
  populate the columns when the caller supplies them, set
  `owner_attribution_status = 'attributed'` when populated, and
  `'attribution_failed'` (with NULL owner ids) when not — making the
  "owner unknown" gap observable in production telemetry.

  Stage 2 will introduce a check constraint requiring the columns be
  populated when `owner_attribution_status != 'legacy_pre_migration'`,
  after a soak window where the `runtime_event_owner_unknown` breadcrumb
  count drops below 5/day for 7 consecutive days.

  No FK constraints on `invoked_by_user_id` at this stage (Stage 2 will
  decide whether the column references `users.id` directly for intra-org
  invocations, an opaque-handle table for federated, or both).

  Reversible: rollback drops the three columns and their indexes. Existing
  data in those columns is lost on rollback — coordinate with the team
  before rolling back if any production attribution has accrued.
  """

  use Ecto.Migration

  @attribution_statuses ~w(legacy_pre_migration attributed attribution_failed pseudonymous)

  def change do
    alter table(:runtime_events) do
      add(:invoked_by_user_id, :uuid)
      add(:owner_org_id, :binary_id)

      add(:owner_attribution_status, :string,
        null: false,
        default: "legacy_pre_migration"
      )
    end

    alter table(:execution_leases) do
      add(:invoked_by_user_id, :uuid)
      add(:owner_org_id, :binary_id)

      add(:owner_attribution_status, :string,
        null: false,
        default: "legacy_pre_migration"
      )
    end

    # Partial indexes — only index rows where attribution is actually populated.
    # Avoids bloating indexes with the (potentially large) backlog of legacy NULL rows.
    create(
      index(:runtime_events, [:invoked_by_user_id],
        where: "invoked_by_user_id IS NOT NULL",
        name: :runtime_events_invoked_by_user_id_idx
      )
    )

    create(
      index(:runtime_events, [:owner_org_id],
        where: "owner_org_id IS NOT NULL",
        name: :runtime_events_owner_org_id_idx
      )
    )

    create(
      index(:execution_leases, [:invoked_by_user_id],
        where: "invoked_by_user_id IS NOT NULL",
        name: :execution_leases_invoked_by_user_id_idx
      )
    )

    create(
      index(:execution_leases, [:owner_org_id],
        where: "owner_org_id IS NOT NULL",
        name: :execution_leases_owner_org_id_idx
      )
    )

    # Document the attribution status enum at migration time so SQL-level
    # tooling (psql, audits, ad-hoc queries) can find the canonical values
    # without reading Elixir code.
    execute(
      """
      COMMENT ON COLUMN runtime_events.owner_attribution_status IS
        'Owner-identity provenance. One of: #{Enum.join(@attribution_statuses, ", ")}. See ADR 0040.'
      """,
      "COMMENT ON COLUMN runtime_events.owner_attribution_status IS NULL"
    )

    execute(
      """
      COMMENT ON COLUMN execution_leases.owner_attribution_status IS
        'Owner-identity provenance. One of: #{Enum.join(@attribution_statuses, ", ")}. See ADR 0040.'
      """,
      "COMMENT ON COLUMN execution_leases.owner_attribution_status IS NULL"
    )
  end
end
