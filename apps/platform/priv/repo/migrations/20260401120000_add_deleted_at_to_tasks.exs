defmodule Platform.Repo.Migrations.AddDeletedAtToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:deleted_at, :utc_datetime_usec)
    end

    create(index(:tasks, [:deleted_at]))
  end
end
