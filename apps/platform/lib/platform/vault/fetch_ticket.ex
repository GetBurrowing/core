defmodule Platform.Vault.FetchTicket do
  @moduledoc """
  A single-use, short-lived ticket that lets one agent download one shared
  vault secret over `GET /vault/fetch/:token` (see `Platform.Vault.Fetch`).

  Only `token_hash` (SHA-256 of the raw token) is stored. The raw token
  exists in exactly two places: the `vault_fetch` tool result handed to the
  issuing agent, and the URL that agent curls. `consumed_at` is set by an
  atomic claim, so a ticket redeems at most once.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_fetch_tickets" do
    field(:token_hash, :binary, redact: true)
    belongs_to(:credential, Platform.Vault.Credential)
    field(:agent_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
