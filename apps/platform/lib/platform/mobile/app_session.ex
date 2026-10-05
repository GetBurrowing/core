defmodule Platform.Mobile.AppSession do
  @moduledoc """
  A signed-in native app install (task 01a10882).

  The app authenticates with a bearer token; this row stores only its SHA-256
  in `token_hash` (`redact: true`, so a changeset or struct never prints it).
  `revoked_at` set means the bearer no longer authenticates.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "app_sessions" do
    belongs_to(:user, Platform.Accounts.User)
    field(:token_hash, :binary, redact: true)
    field(:app_install_id, :string)
    field(:device_name, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :app_install_id, :device_name, :last_used_at])
    |> validate_required([:user_id, :token_hash])
    |> validate_length(:app_install_id, max: 200)
    |> validate_length(:device_name, max: 200)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
