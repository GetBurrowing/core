defmodule Platform.Federation.Peers.InstallKey do
  @moduledoc """
  One of this install's Ed25519 signing keys (task 01a0d90f stage 2, ADR
  0054). The row holds the PUBLIC key only. The private half lives in
  `Platform.Vault` under `vault_slug` and never leaves
  `Platform.Federation.Peers.InstallIdentity`.

  `status` is `current` (signs), `previous` (still verifies until
  `valid_until`, the rotation overlap) or `retired`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(current previous retired)

  @type t :: %__MODULE__{}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "federation_install_keys" do
    field(:kid, :string)
    field(:public_key, :binary)
    field(:status, :string)
    field(:vault_slug, :string)
    field(:valid_until, :utc_datetime_usec)

    timestamps()
  end

  def statuses, do: @statuses

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:kid, :public_key, :status, :vault_slug, :valid_until])
    |> validate_required([:kid, :public_key, :status, :vault_slug])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:kid)
    |> unique_constraint(:status, name: :federation_install_keys_one_current)
    |> check_constraint(:status, name: :federation_install_keys_status_check)
  end
end
