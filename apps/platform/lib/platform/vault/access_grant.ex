defmodule Platform.Vault.AccessGrant do
  @moduledoc """
  Grants a grantee (agent, integration, or automation) access to a Vault credential.

  Each grant specifies the list of allowed `:permissions` (e.g. `["use", "read"]`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @required_fields ~w(credential_id grantee_type grantee_id permissions)a
  @optional_fields ~w(granted_by)a

  schema "vault_access_grants" do
    belongs_to(:credential, Platform.Vault.Credential)
    field(:grantee_type, :string)
    field(:grantee_id, :binary_id)
    field(:permissions, {:array, :string}, default: [])
    field(:granted_by, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:credential_id, :grantee_type, :grantee_id],
      name: :vault_access_grants_unique_grant
    )
  end
end
