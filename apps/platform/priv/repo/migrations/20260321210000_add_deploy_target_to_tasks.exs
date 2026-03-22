defmodule Platform.Repo.Migrations.AddDeployTargetToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:deploy_target, :string)
    end
  end
end
