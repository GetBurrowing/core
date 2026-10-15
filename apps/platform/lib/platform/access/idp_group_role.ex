defmodule Platform.Access.IdpGroupRole do
  @moduledoc "A stored IdP group to guest or custom-role mapping."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "access_idp_group_roles" do
    field(:group_value, :string)
    field(:role_key, :string)
    belongs_to(:org, Platform.Tenancy.Org)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:group_value, :role_key, :org_id])
    |> update_change(:group_value, &Platform.Tenancy.OrgGroupClaim.normalize/1)
    |> validate_required([:group_value, :role_key])
    |> validate_length(:group_value, min: 1)
    |> unique_constraint([:group_value, :role_key, :org_id],
      name: :access_idp_group_roles_tuple_index
    )
    |> foreign_key_constraint(:role_key)
    |> foreign_key_constraint(:org_id)
    |> check_constraint(:org_id, name: :access_idp_group_roles_guest_org_check)
  end
end
