defmodule Platform.Repo.Migrations.FixVaultAccessLogFk do
  use Ecto.Migration

  @doc """
  Changes vault_access_log.credential_id FK from ON DELETE NO ACTION to
  ON DELETE CASCADE so that deleting a credential also removes its log entries.

  Previously, the NO ACTION behavior made it impossible to delete credentials
  that had associated access log entries. CASCADE is the correct semantic here:
  log entries are subordinate to the credential they describe.
  """
  def up do
    execute("""
    ALTER TABLE vault_access_log
      DROP CONSTRAINT vault_access_log_credential_id_fkey,
      ADD CONSTRAINT vault_access_log_credential_id_fkey
        FOREIGN KEY (credential_id)
        REFERENCES vault_credentials(id)
        ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE vault_access_log
      DROP CONSTRAINT vault_access_log_credential_id_fkey,
      ADD CONSTRAINT vault_access_log_credential_id_fkey
        FOREIGN KEY (credential_id)
        REFERENCES vault_credentials(id)
        ON DELETE NO ACTION
    """)
  end
end
