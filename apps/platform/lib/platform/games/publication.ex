defmodule Platform.Games.Publication do
  use Ecto.Schema
  @primary_key {:slug, :string, autogenerate: false}
  schema "game_publications" do
    field(:manifest, :map)
    timestamps(type: :utc_datetime_usec)
  end
end
