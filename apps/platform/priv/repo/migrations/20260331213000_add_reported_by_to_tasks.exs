defmodule Platform.Repo.Migrations.AddReportedByToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :reported_by, :string
    end
  end
end
