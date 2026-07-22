defmodule Platform.Repo.Migrations.CreateExternalDmAllowlistEntries do
  @moduledoc """
  Stack member 1 (rbac-external-users) — stage 2.

  Per-org DM allowlist that M8 enforces. Granularity is **per-org** (an
  external user may DM anyone in an allowlisted org), not per-individual.

  ## Columns

    * `user_id` — the external user (FK `users`, `on_delete: :delete_all`).
    * `allowed_org_id` — the org whose members this user may DM
      (FK `orgs`, `on_delete: :delete_all`).

  ## Indexes

    * `(user_id, allowed_org_id)` unique — one entry per pair
      (idempotent `allow_dm/2`).
    * `user_id` — the "which orgs may this user DM?" lookup M8 issues.
  """

  use Ecto.Migration

  def change do
    create table(:external_dm_allowlist_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :allowed_org_id,
        references(:orgs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:external_dm_allowlist_entries, [:user_id, :allowed_org_id]))
    create(index(:external_dm_allowlist_entries, [:user_id]))
  end
end
