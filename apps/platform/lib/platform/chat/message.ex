defmodule Platform.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  # Integer (bigserial) primary key — NOT binary_id.
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  @content_types ~w(text system agent_action canvas)

  schema "chat_messages" do
    field(:space_id, :binary_id)
    field(:thread_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:content_type, :string, default: "text")
    field(:content, :string)
    field(:structured_content, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    # Only inserted_at — no updated_at (no timestamps() macro).
    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :space_id,
      :thread_id,
      :participant_id,
      :content_type,
      :content,
      :structured_content,
      :metadata,
      :edited_at,
      :deleted_at
    ])
    |> validate_required([:space_id, :participant_id, :content_type])
    |> validate_inclusion(:content_type, @content_types)
  end
end
