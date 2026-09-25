defmodule Platform.Federation.Peers.IdentityRecord do
  @moduledoc """
  The single `federation_install_identity` row: this install's `install_id`
  and display name (task 01a0d90f stage 2, ADR 0054). The table admits exactly
  one row; see the migration's moduledoc. Read and create it through
  `Platform.Federation.Peers.InstallIdentity`, never directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "federation_install_identity" do
    field(:singleton, :boolean, default: true)
    field(:install_id, Ecto.UUID)
    field(:display_name, :string)

    timestamps()
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:install_id, :display_name])
    |> validate_required([:install_id, :display_name])
    |> unique_constraint(:singleton)
  end
end
