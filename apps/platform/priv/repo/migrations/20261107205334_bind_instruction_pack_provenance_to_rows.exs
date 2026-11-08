defmodule Platform.Repo.Migrations.BindInstructionPackProvenanceToRows do
  use Ecto.Migration

  @moduledoc "Task 01a1b6e1: binds trusted pack provenance to physical content rows so recreated local targets cannot inherit vendor ownership by matching text."

  def change do
    alter table(:instruction_pack_entries) do
      add(:record_id, :uuid)
    end
  end
end
