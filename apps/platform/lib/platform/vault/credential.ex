defmodule Platform.Vault.Credential do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @credential_types ~w(api_key oauth2 token keypair custom)
  @scope_types ~w(platform workspace agent integration)

  schema "vault_credentials" do
    field(:workspace_id, Ecto.UUID)
    field(:slug, :string)
    field(:name, :string)
    field(:credential_type, :string)
    field(:provider, :string)
    field(:encrypted_data, Platform.Vault.EncryptedBinary)
    field(:metadata, :map, default: %{})
    field(:scope_type, :string)
    field(:scope_id, Ecto.UUID)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:rotated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :workspace_id,
      :slug,
      :name,
      :credential_type,
      :provider,
      :encrypted_data,
      :metadata,
      :scope_type,
      :scope_id,
      :expires_at,
      :last_used_at,
      :rotated_at
    ])
    |> validate_required([:slug, :name, :credential_type, :encrypted_data, :scope_type])
    |> validate_inclusion(:credential_type, @credential_types)
    |> validate_inclusion(:scope_type, @scope_types)
    |> unique_constraint(:slug, name: :vault_credentials_unique_slug_per_scope)
  end
end
