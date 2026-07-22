defmodule Platform.Tenancy.PendingExternalGrant do
  @moduledoc """
  Ecto schema for `pending_external_grants` (stack member 1,
  rbac-external-users, stage 3).

  A grant an operator pre-stages before an external user's first login. M2
  consumes it via `Platform.Tenancy.ExternalGrants.apply_grant/2`.

  Keyed on `email` OR `oidc_sub` — at least one must be present, enforced
  by `validate_identity_present/1` (changeset) and the DB CHECK constraint
  `pending_external_grants_identity_check`. `apply_grant/2` matches on
  whichever identity the OIDC login carries.

    * `space_grants` — list of `%{"space_id" => ..., "role" => ...}` maps;
      each becomes a `chat_participants` row on apply.
    * `dm_allowlist_org_ids` — list of org-id strings; each seeds a per-org
      DM allowlist entry on apply.
    * `applied_at` — set once the grant has been consumed (idempotency).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pending_external_grants" do
    field(:email, :string)
    field(:oidc_sub, :string)

    belongs_to(:target_org, Platform.Tenancy.Org, foreign_key: :target_org_id)

    field(:space_grants, {:array, :map}, default: [])
    field(:dm_allowlist_org_ids, {:array, :string}, default: [])
    field(:applied_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts the grant fields, requires `target_org_id`, requires at least one
  identity (`email` or `oidc_sub`) via `validate_identity_present/1`, and
  enforces the FK + partial-unique constraints.
  """
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :email,
      :oidc_sub,
      :target_org_id,
      :space_grants,
      :dm_allowlist_org_ids,
      :applied_at
    ])
    |> validate_required([:target_org_id])
    |> validate_identity_present()
    |> foreign_key_constraint(:target_org_id)
    |> unique_constraint(:email, name: :pending_external_grants_email_unique)
    |> unique_constraint(:oidc_sub, name: :pending_external_grants_oidc_sub_unique)
    |> check_constraint(:email,
      name: :pending_external_grants_identity_check,
      message: "at least one of email or oidc_sub must be present"
    )
  end

  @doc """
  Validates that at least one identity column (`email` or `oidc_sub`) is
  present on the changeset — mirrors the DB `pending_external_grants_identity_check`
  CHECK constraint at the changeset layer so the error surfaces on `:email`
  rather than as an opaque DB failure.
  """
  def validate_identity_present(changeset) do
    email = get_field(changeset, :email)
    sub = get_field(changeset, :oidc_sub)

    if blank?(email) and blank?(sub) do
      add_error(changeset, :email, "at least one of email or oidc_sub must be present")
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
