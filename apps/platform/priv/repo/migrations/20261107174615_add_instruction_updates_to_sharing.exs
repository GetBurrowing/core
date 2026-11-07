defmodule Platform.Repo.Migrations.AddInstructionUpdatesToSharing do
  use Ecto.Migration

  @moduledoc "Task 01a1b6e1: adds consent and an install-wide stop to the existing Sharing singleton; existing installs remain off unless explicitly enabled."

  def change do
    alter table(:install_sharing) do
      add(:instruction_updates, :boolean, default: false, null: false)
      add(:instruction_updates_stopped, :boolean, default: false, null: false)
    end
  end
end
