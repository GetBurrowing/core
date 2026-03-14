defmodule Platform.Repo.Migrations.CreateVaultTables do
  use Ecto.Migration

  def change do
    create table(:vault_credentials, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # TODO: add foreign key to workspaces once the workspaces table exists.
      add(:workspace_id, :binary_id)

      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:credential_type, :string, null: false)
      add(:provider, :string)
      add(:encrypted_data, :binary, null: false)
      add(:metadata, :map, default: %{})
      add(:scope_type, :string, null: false)
      add(:scope_id, :binary_id)
      add(:expires_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)
      add(:rotated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :vault_credentials,
        [:workspace_id, :scope_type, :scope_id, :slug],
        name: :vault_credentials_unique_slug_per_scope
      )
    )

    create(index(:vault_credentials, [:provider]))
    create(index(:vault_credentials, [:scope_type, :scope_id]))

    create table(:vault_access_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :credential_id,
        references(:vault_credentials, type: :binary_id, on_delete: :delete_all), null: false)

      add(:grantee_type, :string, null: false)
      add(:grantee_id, :binary_id, null: false)
      add(:permissions, {:array, :string}, null: false, default: [])

      # TODO: add foreign key once grant authorship tables are defined.
      add(:granted_by, :binary_id)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(
        :vault_access_grants,
        [:credential_id, :grantee_type, :grantee_id],
        name: :vault_access_grants_unique_grant
      )
    )

    create table(:vault_access_log) do
      add(:credential_id, references(:vault_credentials, type: :binary_id, on_delete: :nothing),
        null: false
      )

      add(:accessor_type, :string, null: false)
      add(:accessor_id, :binary_id, null: false)
      add(:action, :string, null: false)
      add(:metadata, :map, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:vault_access_log, [:credential_id]))
    create(index(:vault_access_log, [:accessor_type, :accessor_id]))
    create(index(:vault_access_log, [:inserted_at]))
  end
end
