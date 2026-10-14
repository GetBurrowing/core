defmodule Platform.Push.RelayInstall do
  @moduledoc """
  One install allowed to push through this install's push relay (task
  01a1261e stage 2). Exists only on an install running relay mode
  (`config :platform, :push_relay_server, enabled: true`).

  The relay stores NOTHING else: no device, no token, no notification, no
  payload. This row holds the install's name and host (for the operator)
  and `credential_hash`, the SHA-256 of a 32-byte random secret, the same
  hash-only storage as `app_sessions`. The raw credential is printed once by
  `mix platform.push_relay_install` and never stored or logged.
  `credential_hash` is `redact: true` so it never appears in `inspect/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  schema "push_relay_installs" do
    field(:name, :string)
    field(:host, :string)
    field(:credential_hash, :binary, redact: true)
    field(:revoked_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(install, attrs) do
    install
    |> cast(attrs, [:name, :host, :credential_hash])
    |> validate_required([:name, :host, :credential_hash])
    |> validate_length(:name, max: 200)
    |> validate_length(:host, max: 253)
    |> unique_constraint(:credential_hash)
  end
end
