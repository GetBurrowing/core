defmodule Platform.Repo.Migrations.AddKindToTasks do
  @moduledoc """
  Task 019fa1ac adds a first-class task kind taxonomy and a composite index so
  task automation can select maintenance work without title inference.
  """

  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :kind, :string, null: false, default: "feature"
    end

    create index(:tasks, [:kind, :status])
  end
end
