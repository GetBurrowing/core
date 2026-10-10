defmodule Platform.Meetings.Meeting do
  @moduledoc """
  Schema for the `meetings` table — the durable meeting entity (ADR 0042).

  A meeting is project-scoped, has a human-readable `slug` (unique per
  project), a status lifecycle (`scheduled → live → ended`, with `cancelled`
  reachable from the first two — see `status_changeset/3`), an embedded
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

  @statuses ~w(scheduled live ended cancelled)

  schema "meetings" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:host_participant, Platform.Chat.Participant)
    belongs_to(:chat_space, Platform.Chat.Space)
    # Who called the meeting off (task 019fb954-c848). Nilified rather than
    # cascaded if the participant row goes: the cancellation is the durable
    # fact, the attribution is the nice-to-have.
    belongs_to(:cancelled_by_participant, Platform.Chat.Participant)
    # Who started the meeting (task 01a10db7 stage 1): stamped by
    # `Platform.Meetings.start_meeting/2` from `:started_by_user_id`, so the
    # native ringing path can tell who to ring and whom not to. Nilified, not
    # cascaded, when the user goes: `started_at` stays the durable fact.
    # Nil for meetings started before this column existed, and for a start
    # with no authenticated user behind it.
    belongs_to(:started_by_user, Platform.Accounts.User)

    field(:slug, :string)
    field(:name, :string)
    field(:status, :string, default: "scheduled")
    field(:livekit_room_name, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    # INTENDED time, as opposed to the actuals above (task 019fb953). Both
    # endpoints are stored rather than a start plus a duration, so the
    # calendar grid, the .ics renderer and the notification copy read one
    # source instead of each recomputing a duration. Both nil means "ad hoc
    # — started, never scheduled", which is a supported state.
    field(:scheduled_start_at, :utc_datetime_usec)
    field(:scheduled_end_at, :utc_datetime_usec)
    # Idempotency stamp for `:meeting_started` push fan-out (task 019edbc1
    # stage 3). `Platform.Meetings.mark_notified/1` uses an atomic
    # compare-and-swap on this column to guarantee exactly-one notification
    # even when two callers race `start_meeting/1` for the same row.
    field(:notified_at, :utc_datetime_usec)
    # Cancellation actuals (task 019fb954-c848). `cancelled_at` is the
    # ordering key the archive reads and the value a cancellation notice
    # quotes; `status == "cancelled"` stays authoritative for "is it off".
    field(:cancelled_at, :utc_datetime_usec)
    # Idempotency stamp for `:meeting_cancelled` fan-out, the exact analogue
    # of `notified_at` above. A SEPARATE column deliberately: a meeting can
    # be both started-and-notified and later cancelled-and-notified, and one
    # column cannot carry both stamps.
    field(:cancellation_notified_at, :utc_datetime_usec)
    # Weighted full-text vector over `name`, weight `A` — the strongest
    # signal the archive ranks on (task 019fb954-c848). A STORED GENERATED
    # column: Postgres owns the value, so it is `read_after_writes` and
    # deliberately absent from every cast list. Casting it would make Ecto
    # send the column on INSERT and Postgres would reject the write.
    field(:search_vector, Platform.Types.TSVector, read_after_writes: true)
    # Per-meeting hold on the intent classifier (task 019fbaac stage 1).
    # NULL means "not muted"; a timestamp records when the hold was
    # placed. Deliberately NOT in `@cast_fields` — mute is never set at
    # create time, only by `Platform.Meetings.set_intent_muted/2` via
    # `intent_mute_changeset/2`, so a stray attrs map cannot silently
    # create a meeting the agents are already ignoring.
    field(:intent_muted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses

  @cast_fields ~w(project_id host_participant_id chat_space_id slug name status
                  livekit_room_name started_at ended_at
                  scheduled_start_at scheduled_end_at)a
  @required_fields ~w(project_id chat_space_id slug name livekit_room_name)a

  @doc """
  Changeset for creating a meeting.

  Validates required fields, the status enum, the intended-time window, and
  the per-project slug + global livekit_room_name unique constraints.

  The intended-time pair (`scheduled_start_at` / `scheduled_end_at`) is
  optional — deliberately absent from `@required_fields`, because the ad-hoc
  "start a meeting now" path creates a row with neither.
  """
  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_scheduled_window()
    |> unique_constraint([:project_id, :slug], name: :meetings_project_id_slug_index)
    |> unique_constraint(:livekit_room_name)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:host_participant_id)
    |> foreign_key_constraint(:chat_space_id)
  end

  # The intended-time pair is both-nil or both-present with the end strictly
  # after the start. Every failure keys on `:scheduled_end_at`, because in all
  # three cases it is the end that is wrong or missing.
  #
  # A start with no end is rejected rather than defaulted. A calendar block
  # and an iCal `VEVENT` both need an end, and with no `duration` column there
  # is nothing to synthesise one from — a schema-level default duration is the
  # duration column under another name, so a caller that only collects a start
  # must pick an explicit end at its own call site.
  defp validate_scheduled_window(changeset) do
    case {get_field(changeset, :scheduled_start_at), get_field(changeset, :scheduled_end_at)} do
      {nil, nil} ->
        changeset

      {nil, _end_at} ->
        add_error(changeset, :scheduled_end_at, "cannot be set without scheduled_start_at")

      {_start_at, nil} ->
        add_error(changeset, :scheduled_end_at, "is required when scheduled_start_at is set")

      {start_at, end_at} ->
        if DateTime.compare(end_at, start_at) == :gt do
          changeset
        else
          add_error(changeset, :scheduled_end_at, "must be after scheduled_start_at")
        end
    end
  end

  @doc """
  Changeset for transitioning a meeting's status.

  Only legal transitions are allowed:

    * `scheduled → live` (stamps `started_at`)
    * `live → ended` (stamps `ended_at`)
    * `scheduled → cancelled` (stamps `cancelled_at`)
    * `live → cancelled` (stamps `cancelled_at`)

  Any other transition adds an error on `:status` rather than silently
  flipping the value.

  `ended → cancelled` is deliberately NOT legal (task 019fb954-c848). A
  meeting that already happened cannot be un-happened: it has a transcript,
  possibly a recording, and attendees who were in it. Cancelling it would
  claim to every reader that it never took place, and would send a
  cancellation notice to people who already attended. Correcting an ended
  meeting is a different operation from calling one off, and this changeset
  refuses to conflate them.
  """
  def status_changeset(%__MODULE__{status: from} = meeting, to, attrs \\ %{}) do
    meeting
    |> cast(attrs, [
      :started_at,
      :ended_at,
      :cancelled_at,
      :cancelled_by_participant_id,
      :started_by_user_id
    ])
    |> put_change(:status, to)
    |> validate_inclusion(:status, @statuses)
    |> validate_transition(from, to)
    |> foreign_key_constraint(:cancelled_by_participant_id)
    |> foreign_key_constraint(:started_by_user_id)
  end

  @doc """
  Changeset for RESUMING an ended meeting: `ended → live` (task 01a1265f
  stage 2).

  This is deliberately NOT a transition in `status_changeset/3`, which keeps
  refusing `ended → live` ("no resurrection"). Resumption is a different
  operation with exactly one caller, `Platform.Meetings.resume_meeting/2`,
  which is reached only when someone joins the call from the meeting's OWN
  page. Keeping it out of the general transition table means every other
  path that writes a status (`start_meeting/2`, the LiveKit webhooks, the
  native app) still cannot bring an ended meeting back.

  Accepts only `status: "ended"`. Sets status `"live"`, clears `ended_at`
  (an ended_at on a live row would make `Platform.Meetings.meeting_id_for_space/2`
  apply the #902 bound against a meeting that is happening now), and keeps
  `started_at`: the meeting started when it first started. Any other status,
  `cancelled` included, gets an error on `:status`. A cancelled meeting never
  happened and is never resumable.
  """
  @spec resume_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def resume_changeset(%__MODULE__{status: "ended"} = meeting) do
    meeting
    |> change()
    |> put_change(:status, "live")
    |> put_change(:ended_at, nil)
  end

  def resume_changeset(%__MODULE__{status: from} = meeting) do
    meeting
    |> change()
    |> add_error(
      :status,
      "cannot resume a meeting that is #{from}; only an ended meeting resumes"
    )
  end

  @doc """
  Changeset for placing or lifting the per-meeting intent mute
  (task 019fbaac stage 1).

  Only ever touches `:intent_muted_at`, and does so with `put_change/3`
  rather than `cast/3`: the caller is `Platform.Meetings.set_intent_muted/2`,
  which supplies the value itself (a `DateTime` to mute, `nil` to
  unmute). There is no attrs map to cast from, and routing this through
  `changeset/2` would drag the full `@required_fields` validation into a
  single-column toggle on an already-valid row.
  """
  @spec intent_mute_changeset(%__MODULE__{}, DateTime.t() | nil) :: Ecto.Changeset.t()
  def intent_mute_changeset(%__MODULE__{} = meeting, muted_at)
      when is_nil(muted_at) or is_struct(muted_at, DateTime) do
    meeting
    |> change()
    |> put_change(:intent_muted_at, muted_at)
  end

  defp validate_transition(changeset, "scheduled", "live"), do: changeset
  defp validate_transition(changeset, "live", "ended"), do: changeset
  defp validate_transition(changeset, "scheduled", "cancelled"), do: changeset
  defp validate_transition(changeset, "live", "cancelled"), do: changeset

  defp validate_transition(changeset, from, to) do
    add_error(changeset, :status, "illegal transition from #{from} to #{to}")
  end
end
