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
    field(:room_id, :string)
    field(:space_id, :binary_id)
    field(:segments, {:array, :map}, default: [])
    field(:summary, :string)
    field(:status, :string, default: "recording")
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:router_dispatched_at, :utc_datetime_usec)
    # Why this row is CURRENTLY failed — task 019ff6f3 stage 3. Single-valued
    # and overwritten by every `fail_transcript/3` call, so it is a latch, not
    # a history. `Meetings.complete_transcript/2` CLEARS it on success: a
    # non-nil value on a row that is not `failed` is a bug, enforced by the
    # `meeting_transcripts_no_reason_when_complete` CHECK constraint.
    # Failure HISTORY lives in `audit_events`
    # (`event_type = "platform.meetings.transcription_failed"`), not here.
    # Nullable because every row written before the column existed has no
    # reason to record.
    field(:failure_reason, :string)
    # Weighted full-text vector over `summary` (weight `C`) concatenated with
    # the text of `segments` (weight `D`) — task 019fb954-c848. Generated
    # speech ranks below a human-chosen meeting name or canvas title, and raw
    # segment text ranks below the summary. A STORED GENERATED column, so it
    # is `read_after_writes` and appears in no cast list: Postgres rejects any
    # value supplied for it.
    field(:search_vector, Platform.Types.TSVector, read_after_writes: true)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(room_id)a
  @optional_fields ~w(space_id segments summary status started_at completed_at router_dispatched_at failure_reason)a

  @doc "Changeset for creating or updating a transcript."
  def changeset(transcript, attrs) do
    transcript
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    # Surfaces the DB-level invariant as `{:error, changeset}` instead of a
    # raised `Postgrex.Error` mid-success-path — task 01a089b3-7f84 stage 3.
    |> check_constraint(:failure_reason,
      name: :meeting_transcripts_no_reason_when_complete,
      message: "cannot be set on a complete transcript"
    )
  end

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses
end
