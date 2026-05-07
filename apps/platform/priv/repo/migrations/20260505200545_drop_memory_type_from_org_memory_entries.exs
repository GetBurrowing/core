defmodule Platform.Repo.Migrations.DropMemoryTypeFromOrgMemoryEntries do
  use Ecto.Migration

  def up do
    drop_if_exists(index(:org_memory_entries, [:workspace_id, :memory_type]))

    alter table(:org_memory_entries) do
      remove(:memory_type)
    end
  end

  def down do
    alter table(:org_memory_entries) do
      add(:memory_type, :string, null: false, default: "daily")
    end

    create(index(:org_memory_entries, [:workspace_id, :memory_type]))
  end
end
