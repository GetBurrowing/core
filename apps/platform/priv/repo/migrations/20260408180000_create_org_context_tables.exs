defmodule Platform.Repo.Migrations.CreateOrgContextTables do
  use Ecto.Migration

  def change do
    create table(:org_context_files, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_id, :uuid)
      add(:file_key, :string, null: false)
      add(:content, :text, null: false, default: "")
      add(:version, :integer, null: false, default: 1)
      add(:updated_by, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    # Coalesce NULL workspace_id to a sentinel so uniqueness works correctly.
    # Without this, Postgres treats NULL != NULL and allows duplicate file_keys.
    execute(
      "CREATE UNIQUE INDEX org_context_files_workspace_id_file_key_index ON org_context_files (COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid), file_key)",
      "DROP INDEX org_context_files_workspace_id_file_key_index"
    )

    create table(:org_memory_entries) do
      add(:workspace_id, :uuid)
      add(:memory_type, :string, null: false, default: "daily")
      add(:date, :date, null: false)
      add(:content, :text, null: false)
      add(:authored_by, :uuid)
      add(:metadata, :map, default: %{})

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:org_memory_entries, [:workspace_id, :date]))
    create(index(:org_memory_entries, [:workspace_id, :memory_type]))
  end
end
