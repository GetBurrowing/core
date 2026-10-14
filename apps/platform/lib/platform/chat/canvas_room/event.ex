defmodule Platform.Chat.CanvasRoom.Event do
  @moduledoc """
  One accepted op in a canvas room's append-only log
  (`chat_canvas_room_events`). `(room_id, seq)` is unique.

  This is the room's write audit — who (`actor_type`, `actor_id`), what
  (`op`, exactly as applied; a `collection.add` carries the id the room
  assigned, so a replay reproduces it) and when (`inserted_at` is the time
  the room ACCEPTED the op, not the time the debounced flush wrote it).

  Append-only by construction: rows are written only by the room's flush via
  `Repo.insert_all/3`, and no function in the codebase updates or deletes
  one. Rows go only with their room, by the `on_delete: :delete_all` cascade.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "chat_canvas_room_events" do
    field(:room_id, :binary_id)
    field(:seq, :integer)
    field(:op, :map)
    field(:actor_type, :string)
    field(:actor_id, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
