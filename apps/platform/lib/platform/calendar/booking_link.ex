defmodule Platform.Calendar.BookingLink do
  @moduledoc "Owner-controlled booking policy. Public callers cannot change these fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_booking_links" do
    belongs_to(:owner, Platform.Accounts.User)
    belongs_to(:project, Platform.Tasks.Project)
    field(:token, :string)
    field(:title, :string)
    field(:time_zone, :string, default: "Etc/UTC")
    field(:duration_minutes, :integer, default: 30)
    field(:buffer_before_minutes, :integer, default: 0)
    field(:buffer_after_minutes, :integer, default: 0)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:windows, {:array, :map}, default: [])
    field(:create_meeting, :boolean, default: false)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :title,
      :time_zone,
      :duration_minutes,
      :buffer_before_minutes,
      :buffer_after_minutes,
      :start_date,
      :end_date,
      :windows,
      :create_meeting,
      :project_id
    ])
    |> validate_required([
      :title,
      :time_zone,
      :duration_minutes,
      :start_date,
      :end_date,
      :windows
    ])
    |> validate_length(:title, min: 1, max: 120)
    |> validate_number(:duration_minutes, greater_than_or_equal_to: 5, less_than_or_equal_to: 480)
    |> validate_number(:buffer_before_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 240
    )
    |> validate_number(:buffer_after_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 240
    )
    |> validate_change(:time_zone, fn _, zone ->
      case DateTime.shift_zone(DateTime.utc_now(), zone) do
        {:ok, _} -> []
        _ -> [time_zone: "is unsupported"]
      end
    end)
    |> validate_change(:windows, fn _, windows ->
      if length(windows) in 1..21 and Enum.all?(windows, &valid_window?/1),
        do: [],
        else: [windows: "must contain weekday (1-7), start and end (HH:MM)"]
    end)
    |> validate_bounds()
    |> foreign_key_constraint(:project_id)
  end

  defp valid_window?(%{"weekday" => day, "start" => first, "end" => last}) do
    day in 1..7 and match?({:ok, _}, parse_time(first)) and
      match?({:ok, _}, parse_time(last)) and first < last
  end

  defp valid_window?(_), do: false

  def parse_time(value) when is_binary(value) and byte_size(value) == 5,
    do: Time.from_iso8601(value <> ":00")

  def parse_time(_), do: {:error, :invalid_time}

  defp validate_bounds(cs) do
    case {get_field(cs, :start_date), get_field(cs, :end_date)} do
      {%Date{} = first, %Date{} = last} ->
        if Date.diff(last, first) in 0..365,
          do: cs,
          else: add_error(cs, :end_date, "must be within one year of start date")

      _ ->
        cs
    end
  end
end
