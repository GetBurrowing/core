defmodule Platform.Vault.AccessLog do
  @moduledoc """
  An immutable access log entry for Vault credential operations.

  Append-only — no changeset, never updated or deleted.
  Uses a bigserial integer PK (ADR-0005 pattern, same as `audit_events`).

  Actions: use | read | create | update | rotate | revoke
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_access_log" do
    belongs_to(:credential, Platform.Vault.Credential)
    field(:accessor_type, :string)
    field(:accessor_id, :binary_id)
    field(:action, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
