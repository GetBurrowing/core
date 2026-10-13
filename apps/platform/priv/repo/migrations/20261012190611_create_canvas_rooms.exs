defmodule Platform.Repo.Migrations.CreateCanvasRooms do
  @moduledoc """
  Task 01a1316b-84fa stage 1: durable shared state for a canvas room, one
  room per `(canvas_id, node_id)` (`Platform.Chat.CanvasRoom`).

    * `chat_canvas_rooms` — the snapshot: the room's whole `state` and the
      `seq` of the last op folded into it. Upserted by the room's debounced
      flush.
    * `chat_canvas_room_events` — the append-only op log: one row per
      accepted op, `(room_id, seq)` unique. It is the write audit (who, what,
      when) and the future replay / fork source. Nothing updates or deletes
      a row except the cascade when the room (and so the canvas) goes.
  """

  use Ecto.Migration

  def change do
    create table(:chat_canvas_rooms, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:node_id, :text, null: false)
      add(:state, :map, null: false, default: %{"keys" => %{}, "collections" => %{}})
      add(:seq, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:chat_canvas_rooms, [:canvas_id, :node_id]))

    create table(:chat_canvas_room_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:room_id, references(:chat_canvas_rooms, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:seq, :bigint, null: false)
      add(:op, :map, null: false)
      add(:actor_type, :text)
      add(:actor_id, :binary_id)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:chat_canvas_room_events, [:room_id, :seq]))
  end
end
