defmodule Platform.Repo.Migrations.CreateSharingInstructionOutcomes do
  use Ecto.Migration

  def change do
    create table(:sharing_instruction_outcomes, primary_key: false) do
      add :sharing_install_id, :uuid, null: false
      add :window_start, :utc_datetime, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:sharing_instruction_outcomes, [:sharing_install_id, :window_start])
  end
end
