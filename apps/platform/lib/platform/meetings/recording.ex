defmodule Platform.Meetings.Recording do
  @moduledoc """
  Schema for the `meeting_recordings` table.

  Represents a LiveKit egress recording for a meeting room. Tracks the
  egress lifecycle from `recording` → `processing` → `ready` (or `failed`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(recording processing ready failed)

  schema "meeting_recordings" do
    belongs_to(:room, Platform.Meetings.Room)
    belongs_to(:space, Platform.Chat.Space)
    field(:egress_id, :string)
    field(:status, :string, default: "recording")
    field(:duration_seconds, :integer)
    field(:file_url, :string)
    field(:file_size_bytes, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, [
      :room_id,
      :space_id,
      :egress_id,
      :status,
      :duration_seconds,
      :file_url,
      :file_size_bytes
    ])
    |> validate_required([:room_id, :space_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:space_id)
  end
end
