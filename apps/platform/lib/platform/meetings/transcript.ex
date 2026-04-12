defmodule Platform.Meetings.Transcript do
  @moduledoc """
  Schema for meeting transcripts.

  Each transcript belongs to a meeting room and accumulates segments
  (speaker-attributed text chunks) as JSONB. A summary is generated
  after the meeting ends.

  Status lifecycle: recording → processing → complete | failed
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(recording processing complete failed)

  schema "meeting_transcripts" do
    field(:room_id, :binary_id)
    field(:space_id, :binary_id)
    field(:segments, {:array, :map}, default: [])
    field(:summary, :string)
    field(:status, :string, default: "recording")
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(room_id)a
  @optional_fields ~w(space_id segments summary status started_at completed_at)a

  @doc "Changeset for creating or updating a transcript."
  def changeset(transcript, attrs) do
    transcript
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses
end
