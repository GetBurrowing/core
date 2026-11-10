defmodule Platform.Repo.Migrations.CreateGamePublications do
  use Ecto.Migration
  def change do
    create table(:game_publications, primary_key: false) do
      add :slug, :string, primary_key: true
      add :manifest, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
