defmodule Platform.SupportAccess.SignInCode do
  @moduledoc """
  A single-use sign-in code for an admin support session
  (`support_sign_in_codes`). Only the sha256 of the code is stored; the code
  itself exists once, in the grant response.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "support_sign_in_codes" do
    belongs_to(:support_session, Platform.SupportAccess.Session)
    field(:code_hash, :binary)
    field(:expires_at, :utc_datetime_usec)
    field(:used_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
