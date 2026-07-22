defmodule Platform.Tenancy.ExternalDmAllowlistEntry do
  @moduledoc """
  Ecto schema for `external_dm_allowlist_entries` — the per-org DM
  allowlist that M8 enforces (stack member 1, rbac-external-users, stage 2).

  Granularity is **per-org**: one row means "`user_id` may DM anyone in
  `allowed_org_id`". See `Platform.Tenancy.allow_dm/2`, `may_dm_org?/2`,
  `list_dm_allowlist/1`, and `revoke_dm/2` for the context API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "external_dm_allowlist_entries" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:allowed_org, Platform.Tenancy.Org, foreign_key: :allowed_org_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts + requires `user_id` and `allowed_org_id`, and enforces the
  `(user_id, allowed_org_id)` uniqueness and both FK constraints.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :allowed_org_id])
    |> validate_required([:user_id, :allowed_org_id])
    |> unique_constraint([:user_id, :allowed_org_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:allowed_org_id)
  end
end
