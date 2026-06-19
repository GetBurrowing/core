defmodule Platform.Meetings.Meeting do
  @moduledoc """
  Schema for the `meetings` table — the durable meeting entity (ADR 0042).

  A meeting is project-scoped, has a human-readable `slug` (unique per
  project), a status lifecycle (`scheduled → live → ended`), an embedded
  `chat_space` (the placeholder for what becomes the intent panel), and a
  globally-unique `livekit_room_name` for the voice/video room.

  This is distinct from `Platform.Meetings.Room`, which tracks ephemeral
  LiveKit call state keyed 1:1 to a chat space. A `Meeting` is the persistent
  record the Meeting LiveView reads from.

  SCAFFOLD CO-OWNERSHIP — task 019e2475-87a8 (embedded chat panel as
  intent-panel placeholder), sibling task 019e2475-4395 (left rail), and
  this task 019e2474-11c1 ("Meetings: schema, context, MCP create_meeting
  tool") all ship a `Platform.Meetings.Meeting` module bound to this table.
  The definitions are kept bit-for-bit in sync so the meeting-module-basic-v2
  stack rollup is a no-op merge. The fields stage 1 of the embedded-chat-panel
  task reads are: `name`, `slug`, `chat_space_id`, plus the preloaded
  `:chat_space` association (we need the space's `slug` to drive the embedded
  chat panel's live_render session). Anything else is owned by 019e2474-11c1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(scheduled live ended)

  schema "meetings" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:host_participant, Platform.Chat.Participant)
    belongs_to(:chat_space, Platform.Chat.Space)

    field(:slug, :string)
    field(:name, :string)
    field(:status, :string, default: "scheduled")
    field(:livekit_room_name, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    # Idempotency stamp for `:meeting_started` push fan-out (task 019edbc1
    # stage 3). `Platform.Meetings.mark_notified/1` uses an atomic
    # compare-and-swap on this column to guarantee exactly-one notification
    # even when two callers race `start_meeting/1` for the same row.
    field(:notified_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses

  @cast_fields ~w(project_id host_participant_id chat_space_id slug name status
                  livekit_room_name started_at ended_at)a
  @required_fields ~w(project_id chat_space_id slug name livekit_room_name)a

  @doc """
  Changeset for creating a meeting.

  Validates required fields, the status enum, and the per-project slug +
  global livekit_room_name unique constraints.
  """
  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:project_id, :slug], name: :meetings_project_id_slug_index)
    |> unique_constraint(:livekit_room_name)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:host_participant_id)
    |> foreign_key_constraint(:chat_space_id)
  end

  @doc """
  Changeset for transitioning a meeting's status.

  Only legal transitions are allowed:

    * `scheduled → live` (stamps `started_at`)
    * `live → ended` (stamps `ended_at`)

  Any other transition adds an error on `:status` rather than silently
  flipping the value.
  """
  def status_changeset(%__MODULE__{status: from} = meeting, to, attrs \\ %{}) do
    meeting
    |> cast(attrs, [:started_at, :ended_at])
    |> put_change(:status, to)
    |> validate_inclusion(:status, @statuses)
    |> validate_transition(from, to)
  end

  defp validate_transition(changeset, "scheduled", "live"), do: changeset
  defp validate_transition(changeset, "live", "ended"), do: changeset

  defp validate_transition(changeset, from, to) do
    add_error(changeset, :status, "illegal transition from #{from} to #{to}")
  end
end
