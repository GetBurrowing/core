defmodule Platform.SignIn.SetupChallenge do
  @moduledoc "Short-lived browser-bound first-sign-in challenge. No raw code or email is stored."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sign_in_setup_challenges" do
    belongs_to(:user, Platform.Accounts.User)
    field(:binding_hash, :binary, redact: true)
    field(:email_hash, :binary, redact: true)
    field(:code_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
  end
end
