defmodule Platform.Repo.Migrations.AddInstructionUpdatesToSharing do
  use Ecto.Migration

  def change do
    alter table(:install_sharing) do
      add(:instruction_updates, :boolean, default: false, null: false)
      add(:instruction_updates_stopped, :boolean, default: false, null: false)
    end
  end
end
