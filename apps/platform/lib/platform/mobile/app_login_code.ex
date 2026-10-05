defmodule Platform.Mobile.AppLoginCode do
  @moduledoc """
  A single-use, 60-second code in the native app login flow (task 01a10882).

    * `purpose: "exchange"`: minted by the OIDC callback for an app login,
      bound to the app's PKCE S256 `code_challenge`, redeemed by
      `POST /api/app/session` for a bearer token.
    * `purpose: "handoff"`: minted by that exchange, redeemed by
      `GET /auth/app/handoff?code=...` to sign the app's web view in.

  Only `code_hash` (SHA-256 of the raw code) is stored, `redact: true`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @purposes ~w(exchange handoff)

  schema "app_login_codes" do
    belongs_to(:user, Platform.Accounts.User)
    field(:code_hash, :binary, redact: true)
    field(:code_challenge, :string)
    field(:purpose, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def purposes, do: @purposes

  def changeset(code, attrs) do
    code
    |> cast(attrs, [:user_id, :code_hash, :code_challenge, :purpose, :expires_at])
    |> validate_required([:user_id, :code_hash, :purpose, :expires_at])
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint(:code_hash)
    |> foreign_key_constraint(:user_id)
  end
end
