defmodule Platform.Vault.Credential do
  @moduledoc """
  A stored credential. `encrypted_data` holds the value; Cloak encrypts it at
  the database boundary through `Platform.Vault.EncryptedBinary`.

  ## `encrypted_data` is `redact: true`, and that is load-bearing

  Cloak encrypts on dump and decrypts on load, so in memory — and in a
  changeset's `changes` — this field holds **plaintext**. Without `redact: true`
  every `inspect/1` of a credential or of a changeset over one prints the
  secret, and `inspect` is what a `MatchError`, a `Logger` call and a crash
  dump all reach for.

  That is not hypothetical. `Platform.Agents.Config.import_auth_profile!/4`
  hard-matches `{:ok, credential} = Platform.Vault.put(...)`, so a `put/4` that
  returns `{:error, changeset}` raises a `MatchError` whose message is the
  inspected changeset. Before this field was redacted, that message contained
  the API key in `changes.encrypted_data`, measured directly.

  `put/4` only returns that error on a unique-slug conflict, which is why this
  matters now: until
  `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes`, the
  `vault_credentials_unique_slug_per_scope` index was `NULLS DISTINCT` over two
  nullable columns and rejected nothing, so the error path was effectively
  unreachable. Making the constraint work makes that path live.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @credential_types ~w(api_key oauth2 token keypair custom)
  @scope_types ~w(platform workspace agent integration shared)

  schema "vault_credentials" do
    field(:workspace_id, Ecto.UUID)
    field(:slug, :string)
    field(:name, :string)
    field(:credential_type, :string)
    field(:provider, :string)
    field(:encrypted_data, Platform.Vault.EncryptedBinary, redact: true)
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
    |> unique_constraint(:slug, name: :vault_credentials_unique_shared_slug)
  end
end
