defmodule Platform.Repo.Migrations.BindInstructionPackProvenanceToRows do
  use Ecto.Migration

  def change do
    alter table(:instruction_pack_entries) do
      add(:record_id, :uuid)
    end
  end
end
