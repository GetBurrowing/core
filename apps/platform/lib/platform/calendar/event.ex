defmodule Platform.Calendar.Event do
  @moduledoc """
  A native event. Meetings remain in their own table and are projected at
  read time.

  `meeting_id` links a native event to the one call record it is backed by
  (task 01a1b8a5 stage 1). It is set only by `Platform.Calendar.Authoring`
  and is deliberately absent from `changeset/2`'s cast list, so no attrs map
  can attach or detach a call. `preset` is `event`, `focus` or `ooo`; the
  two presets block availability like any event and never carry a call.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_events" do
    belongs_to(:owner, Platform.Accounts.User)
    belongs_to(:space, Platform.Chat.Space)
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:meeting, Platform.Meetings.Meeting)
    field(:title, :string)
    field(:description, :string)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:time_zone, :string, default: "Etc/UTC")
    field(:all_day, :boolean, default: false)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:visibility, :string, default: "details")
    field(:recurrence, :string)
    field(:exception_dates, {:array, :date}, default: [])
    field(:sequence, :integer, default: 0)
    field(:cancelled_at, :utc_datetime_usec)
    field(:tentative, :boolean, default: false)
    field(:preset, :string, default: "event")
    timestamps(type: :utc_datetime_usec)
  end

  @presets ~w(event focus ooo)

  @doc "The event presets: an ordinary event, Focus time and Out of office."
  def presets, do: @presets

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :title,
      :description,
      :starts_at,
      :ends_at,
      :time_zone,
      :all_day,
      :start_date,
      :end_date,
      :visibility,
      :space_id,
      :project_id,
      :recurrence,
      :exception_dates,
      :preset
    ])
    |> validate_required([:title, :time_zone, :visibility])
    |> validate_length(:title, min: 1, max: 300)
    |> validate_length(:description, max: 10_000)
    |> validate_inclusion(:visibility, ~w(busy details))
    |> validate_inclusion(:preset, @presets)
    |> validate_change(:time_zone, fn :time_zone, zone ->
      case DateTime.shift_zone(DateTime.utc_now(), zone) do
        {:ok, _} -> []
        _ -> [time_zone: "is not a supported time zone"]
      end
    end)
    |> validate_change(:recurrence, fn :recurrence, value ->
      case Platform.Calendar.Recurrence.parse(value) do
        {:ok, _} -> []
        _ -> [recurrence: "must be a supported daily, weekly or monthly rule"]
      end
    end)
    |> normalize_window()
    |> check_constraint(:ends_at, name: :calendar_events_positive_window)
    |> check_constraint(:space_id, name: :calendar_events_one_scope)
    |> check_constraint(:preset, name: :calendar_events_preset)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Attach `event` to its call record. Used only by `Platform.Calendar.Authoring`;
  the unique index makes a second link to the same meeting an error rather than
  a second calendar entry.
  """
  def meeting_link_changeset(event, meeting_id) do
    event
    |> change(meeting_id: meeting_id)
    |> unique_constraint(:meeting_id, name: :calendar_events_meeting_id_index)
    |> foreign_key_constraint(:meeting_id)
  end

  defp normalize_window(changeset) do
    if get_field(changeset, :all_day) do
      changeset = validate_required(changeset, [:start_date, :end_date])

      with %Date{} = first <- get_field(changeset, :start_date),
           %Date{} = last <- get_field(changeset, :end_date),
           true <- Date.compare(first, last) == :lt,
           {:ok, start_at} <- DateTime.new(first, ~T[00:00:00], get_field(changeset, :time_zone)),
           {:ok, end_at} <- DateTime.new(last, ~T[00:00:00], get_field(changeset, :time_zone)) do
        changeset |> put_change(:starts_at, utc(start_at)) |> put_change(:ends_at, utc(end_at))
      else
        _ ->
          add_error(changeset, :end_date, "must follow the start date in the selected time zone")
      end
    else
      changeset = validate_required(changeset, [:starts_at, :ends_at])

      case {get_field(changeset, :starts_at), get_field(changeset, :ends_at)} do
        {%DateTime{} = first, %DateTime{} = last} ->
          if DateTime.compare(first, last) == :lt,
            do: changeset,
            else: add_error(changeset, :ends_at, "must follow the start time")

        _ ->
          changeset
      end
    end
  end

  defp utc(at) do
    at = DateTime.shift_zone!(at, "Etc/UTC")
    %{at | microsecond: {elem(at.microsecond, 0), 6}}
  end
end
