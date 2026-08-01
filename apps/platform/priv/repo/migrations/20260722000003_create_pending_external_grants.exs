defmodule Platform.Repo.Migrations.CreatePendingExternalGrants do
  @moduledoc """
  Stack member 1 (rbac-external-users) — stage 3.

  A `pending_external_grant` is what an operator pre-stages before an
  external user's first login. M2 (login provisioning) consumes it via
  `Platform.Tenancy.ExternalGrants.apply_grant/2`.

  Keyed on `email` OR `oidc_sub` so it matches whichever identity the login
  carries. At least one identity column must be present, enforced by the
  `pending_external_grants_identity_check` CHECK constraint.

  ## Columns

    * `email` / `oidc_sub` — both nullable; the identity CHECK requires at
      least one.
    * `target_org_id` — org the external membership is created in
      (FK `orgs`, `on_delete: :delete_all`).
    * `space_grants` — jsonb array of `%{"space_id" => ..., "role" => ...}`;
      each becomes a `chat_participants` row on apply.
    * `dm_allowlist_org_ids` — jsonb array of org-id strings; each seeds a
      per-org DM allowlist entry on apply.
    * `applied_at` — consumption / idempotency marker (nullable).

  ## Indexes

    * partial `unique_index([:email]) WHERE email IS NOT NULL` and partial
      `unique_index([:oidc_sub]) WHERE oidc_sub IS NOT NULL` — at most one
      pending grant per identity.
    * plain `index` on each of `email` / `oidc_sub` to support
      lookup-by-either.

  Admitted by task 019f8837 stages 1-3 — external-users schema foundation
  (rbac-external-users stack member M1, the only member adding migrations).
  """

  use Ecto.Migration

  def change do
    create table(:pending_external_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:email, :string)
      add(:oidc_sub, :string)

      add(
        :target_org_id,
        references(:orgs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:space_grants, :map, default: fragment("'[]'::jsonb"))
      add(:dm_allowlist_org_ids, :map, default: fragment("'[]'::jsonb"))
      add(:applied_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:pending_external_grants, :pending_external_grants_identity_check,
        check: "(email IS NOT NULL OR oidc_sub IS NOT NULL)"
      )
    )

    create(
      unique_index(:pending_external_grants, [:email],
        where: "email IS NOT NULL",
        name: :pending_external_grants_email_unique
      )
    )

    create(
      unique_index(:pending_external_grants, [:oidc_sub],
        where: "oidc_sub IS NOT NULL",
        name: :pending_external_grants_oidc_sub_unique
      )
    )

    create(index(:pending_external_grants, [:email]))
    create(index(:pending_external_grants, [:oidc_sub]))
  end
end
