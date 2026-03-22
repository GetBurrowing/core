defmodule Platform.Chat.Canvas do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @canvas_types ~w(table form code diagram dashboard custom)

  schema "chat_canvases" do
    field(:space_id, :binary_id)
    field(:message_id, :binary_id)
    field(:created_by, :binary_id)
    field(:title, :string)
    field(:canvas_type, :string)
    field(:state, :map, default: %{})
    field(:component_module, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(canvas, attrs) do
    canvas
    |> cast(attrs, [
      :space_id,
      :message_id,
      :created_by,
      :title,
      :canvas_type,
      :state,
      :component_module,
      :metadata
    ])
    |> validate_required([:space_id, :created_by, :canvas_type])
    |> validate_inclusion(:canvas_type, @canvas_types)
  end
end
