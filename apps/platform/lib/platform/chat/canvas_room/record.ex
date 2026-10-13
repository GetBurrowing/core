defmodule Platform.Chat.CanvasRoom.Record do
  @moduledoc """
  The durable snapshot of one canvas room (`chat_canvas_rooms`): the room's
  whole shared `state` and the `seq` of the last op folded into it. One row
  per `(canvas_id, node_id)`. Written only by `Platform.Chat.CanvasRoom`'s
  flush, as an upsert.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "chat_canvas_rooms" do
    field(:canvas_id, :binary_id)
    field(:node_id, :string)
    field(:state, :map, default: %{"keys" => %{}, "collections" => %{}})
    field(:seq, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end
end
