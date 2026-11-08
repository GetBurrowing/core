defmodule Platform.Calendar.EventDraft do
  @moduledoc """
  The one event draft Calendar authors from (task 01a1b8a5 stage 1): new,
  edit, click, drag and agent drafts all load into this shape and save
  through `Platform.Calendar.Authoring`.

  It is NOT persisted. There is no table: a draft is an in-memory adapter
  over the two existing stores, `calendar_events` (native event attributes)
  and `meetings` (the call record: people, guests, notes and the call).
  Field by field:

    * `title`, the window (`starts_at`/`ends_at`, or `all_day` with
      `start_date`/`end_date`), `time_zone`, `recurrence`, `visibility` and
      `preset` map to the native event.
    * `notes` maps to `meetings.description` when the event has a call
      record, and to `calendar_events.description` when it does not. Never
      both.
    * `call_enabled` maps to `meetings.call_enabled`. A native event with no
      call record is OFF.
    * `add_invitees` / `remove_invite_ids` are the staged people, passed to
      the Meetings create and edit paths unchanged in meaning.

  Unsupported combinations are refused here with a changeset error rather
  than dropped: a preset with a call or people, a call or people on a
  repeating event, a call record with no project, and turning a call on for
  a viewer who may not have one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:source, :string, default: "new")
    field(:event_id, :binary_id)
    field(:meeting_id, :binary_id)
    field(:project_id, :binary_id)
    field(:space_id, :binary_id)
    field(:title, :string)
    field(:notes, :string)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:time_zone, :string, default: "Etc/UTC")
    field(:all_day, :boolean, default: false)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:recurrence, :string)
    field(:visibility, :string, default: "details")
    field(:preset, :string, default: "event")
    field(:call_enabled, :boolean, default: false)
    field(:add_invitees, {:array, :map}, default: [])
    field(:remove_invite_ids, {:array, :string}, default: [])
    # Whether Meetings says this viewer may edit the call record
    # (`Meetings.can_edit_meeting?/3`); informational, every save re-checks.
    field(:editable, :boolean, default: true, virtual: true)
  end

  @type t :: %__MODULE__{}

  @editable ~w(project_id space_id title notes starts_at ends_at time_zone all_day
               start_date end_date recurrence visibility preset call_enabled
               add_invitees remove_invite_ids)a

  @doc "Cast `attrs` onto `draft` without validating: a prefill, not a save."
  @spec prefill(t(), map()) :: t()
  def prefill(%__MODULE__{} = draft, attrs) when is_map(attrs) do
    draft |> cast(attrs, @editable) |> apply_changes()
  end

  @doc """
  The draft `attrs` would make of `draft`, validated. `call_available?` is
  the server-side answer to "may this viewer turn a call on"; it only
  matters when the call goes from off to on, so an existing call is never
  refused for it.
  """
  @spec changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = draft, attrs, opts \\ []) do
    call_available? = Keyword.get(opts, :call_available?, false)

    draft
    |> cast(attrs, @editable)
    |> update_change(:title, &trim/1)
    |> update_change(:notes, &blank_to_nil/1)
    |> update_change(:recurrence, &blank_to_nil/1)
    |> validate_required([:title, :time_zone, :visibility, :preset, :call_enabled])
    |> validate_inclusion(:visibility, ~w(busy details))
    |> validate_inclusion(:preset, Platform.Calendar.Event.presets())
    |> validate_preset()
    |> validate_call_turned_on(draft, call_available?)
    |> validate_call_record()
  end

  @doc "Does this draft need a call record (a meeting row)?"
  @spec call_record?(t()) :: boolean()
  def call_record?(%__MODULE__{} = d),
    do: d.call_enabled == true or d.add_invitees != [] or is_binary(d.meeting_id)

  @doc """
  Does this draft carry a native-only attribute that a meeting row cannot
  hold? A legacy meeting with any of these gets a linked native event.
  """
  @spec native_attributes?(t()) :: boolean()
  def native_attributes?(%__MODULE__{} = d),
    do: d.preset != "event" or d.visibility != "details" or d.all_day == true

  defp validate_preset(changeset) do
    if get_field(changeset, :preset) in [nil, "event"] do
      changeset
    else
      changeset
      |> then(fn cs ->
        if get_field(cs, :call_enabled) == true,
          do: add_error(cs, :call_enabled, "is not available for Focus time or Out of office"),
          else: cs
      end)
      |> then(fn cs ->
        if (get_field(cs, :add_invitees) || []) != [],
          do: add_error(cs, :add_invitees, "cannot be added to Focus time or Out of office"),
          else: cs
      end)
    end
  end

  defp validate_call_turned_on(changeset, %__MODULE__{call_enabled: was}, available?) do
    if get_field(changeset, :call_enabled) == true and was != true and not available? do
      add_error(changeset, :call_enabled, "is not available to you")
    else
      changeset
    end
  end

  defp validate_call_record(changeset) do
    draft = apply_changes(changeset)

    if call_record?(draft) do
      changeset
      |> then(fn cs ->
        if is_binary(draft.recurrence),
          do: add_error(cs, :recurrence, "cannot repeat with people or a Burrow call"),
          else: cs
      end)
      |> then(fn cs ->
        if is_nil(draft.meeting_id) and is_nil(draft.project_id),
          do: add_error(cs, :project_id, "is required for people or a Burrow call"),
          else: cs
      end)
    else
      changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value
end
