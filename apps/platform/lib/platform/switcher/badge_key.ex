defmodule Platform.Switcher.BadgeKey do
  @moduledoc """
  A counts-only credential another install's web switcher holds for this
  install (task 01a1ccd4). See `Platform.Switcher`.

  Only the SHA-256 of the key is stored, in `token_hash` (`redact: true`).
  `bound_origin` is the one origin allowed to present it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "switcher_badge_keys" do
    belongs_to(:user, Platform.Accounts.User)
    field(:token_hash, :binary, redact: true)
    field(:bound_origin, :string)
    field(:label, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:user_id, :token_hash, :bound_origin, :label, :expires_at])
    |> validate_required([:user_id, :token_hash, :bound_origin, :expires_at])
    |> validate_length(:bound_origin, max: 300)
    |> validate_length(:label, max: 200)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
