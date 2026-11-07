defmodule Platform.SupportAccess.GrantNonce do
  @moduledoc """
  A used support-grant nonce (`support_grant_nonces`). Kept until the grant's
  own `expires_at`, after which the grant is refused as expired anyway, so a
  replay is refused across restarts and nodes.
  """
  use Ecto.Schema

  @primary_key {:nonce, :string, autogenerate: false}

  schema "support_grant_nonces" do
    field(:expires_at, :utc_datetime_usec)
  end
end
