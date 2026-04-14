defmodule Platform.Meetings.Room do
  @moduledoc """
  Schema for the `meeting_rooms` table.

  Each chat space can have at most one meeting room. The room tracks
  the current call status and holds the LiveKit room name used to
  generate access tokens.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(idle active recording)

  schema "meeting_rooms" do
    belongs_to(:space, Platform.Chat.Space)
    field(:livekit_room_name, :string)
    field(:status, :string, default: "idle")
    field(:config, :map, default: %{})

    has_many(:participants, Platform.Meetings.Participant)
    has_many(:recordings, Platform.Meetings.Recording)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:space_id, :livekit_room_name, :status, :config])
    |> validate_required([:space_id, :livekit_room_name])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:space_id)
    |> unique_constraint(:livekit_room_name)
    |> foreign_key_constraint(:space_id)
  end
end
