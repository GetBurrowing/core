defmodule Platform.Social.Trends.IdeaLink do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_trend_ideas" do
    field(:profile_id, :binary_id)
    field(:idea_id, :binary_id)
    field(:source, :string)
    field(:story_id, :string)
  end
end
