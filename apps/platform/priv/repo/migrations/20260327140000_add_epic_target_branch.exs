defmodule Platform.Repo.Migrations.AddEpicTargetBranch do
  use Ecto.Migration

  def change do
    alter table(:epics) do
      add(:target_branch, :string)
      add(:deploy_target, :string)
    end
  end
end
