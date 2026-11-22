defmodule Platform.Social.IdeaSelectionEvent do
  @moduledoc """
  One entry in an idea's selection log: a person `selected` or `unselected` it
  for research. Written ONLY by `Platform.Social.Ideas.select_for_research/3`
  and `unselect_for_research/3`, in the transaction that changes the marker.
  Append-only: no code updates or deletes a row (a source test holds this).
  `actor_id` is a plain uuid, not a foreign key, so the log keeps the actor
  after the user is erased.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @type t :: %__MODULE__{}

  schema "social_idea_selection_events" do
    belongs_to(:idea, Platform.Social.Idea)
    field(:action, :string)
    field(:actor_kind, :string, default: "human")
    field(:actor_id, :binary_id)

    timestamps()
  end
end
