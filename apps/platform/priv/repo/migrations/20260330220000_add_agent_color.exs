defmodule Platform.Repo.Migrations.AddAgentColor do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :color, :string, null: true
    end
  end
end
