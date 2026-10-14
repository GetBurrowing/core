defmodule Platform.Repo.Migrations.VaultSharedScopeAndFetchTickets do
  @moduledoc """
  Task 01a131c5 stage 1: the `shared` vault scope and single-use fetch
  tickets.

  `scope_type` is a plain string column with no CHECK constraint, so the new
  `"shared"` value needs no column change — `Platform.Vault.Credential`'s
  `validate_inclusion/3` is the only gate, and it is widened in code.

  `vault_credentials_unique_shared_slug` makes a shared slug unique whatever
  its `scope_id` / `workspace_id`. The existing
  `vault_credentials_unique_slug_per_scope` (NULLS NOT DISTINCT since
  20260829140000) already rejects two `{:shared, nil}` rows with one slug; this
  partial index additionally rejects a second shared row at a different
  scope_id or workspace_id, because the slug is the name an agent fetches by
  and the filename it writes, and `Platform.Vault.Fetch` resolves on slug +
  `scope_type` alone.

  `vault_fetch_tickets` holds only the SHA-256 of each single-use token; the
  raw token is never stored. It is DB-backed rather than ETS so single-use
  holds across nodes.
  """
  use Ecto.Migration

  def change do
    create(
      unique_index(:vault_credentials, [:slug],
        where: "scope_type = 'shared'",
        name: :vault_credentials_unique_shared_slug
      )
    )

    create table(:vault_fetch_tickets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token_hash, :binary, null: false)

      add(
        :credential_id,
        references(:vault_credentials, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:agent_id, :binary_id, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:vault_fetch_tickets, [:token_hash]))
    create(index(:vault_fetch_tickets, [:credential_id]))
  end
end
