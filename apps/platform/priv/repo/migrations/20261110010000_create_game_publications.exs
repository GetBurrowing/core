defmodule Platform.Repo.Migrations.CreateGamePublications do
  @moduledoc """
  Persist reviewed game publications so release updates and player communities
  can be managed inside Burrow instead of requiring host configuration.
  Admitted by PR #145, the Voltron hosting and distribution prototype.
  """
  # old-code-compatible: Adds a new table; old code still reads environment
  # manifests and never queries this table. No existing rows or columns change.
  use Ecto.Migration

  def change do
    create table(:game_publications, primary_key: false) do
      add(:slug, :string, primary_key: true)
      add(:manifest, :map, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
