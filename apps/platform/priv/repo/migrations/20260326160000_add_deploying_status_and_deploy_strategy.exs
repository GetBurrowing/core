defmodule Platform.Repo.Migrations.AddDeployingStatusAndDeployStrategy do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:deploy_strategy, :map)
    end
  end
end
