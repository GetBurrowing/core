defmodule Platform.Goals.GoalClock do
  @moduledoc "Storage for goal_clocks (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_clocks" do
    field(:goal_id, :binary_id)
    field(:time_zone, :string)
    field(:wake_hour, :integer, default: 6)
    field(:next_wake_at, :utc_datetime_usec)
    field(:anchor_on, :date)
    field(:schedule_key, :string)
    field(:last_woken_at, :utc_datetime_usec)
    field(:stalled_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :time_zone,
      :wake_hour,
      :next_wake_at,
      :anchor_on,
      :schedule_key,
      :last_woken_at,
      :stalled_at
    ])
    |> validate_required([
      :goal_id,
      :time_zone,
      :wake_hour,
      :next_wake_at,
      :anchor_on,
      :schedule_key
    ])
    |> validate_number(:wake_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> check_constraint(:wake_hour, name: :goal_clocks_wake_hour)
    |> unique_constraint([:goal_id], name: :goal_clocks_goal_id_index)
    |> foreign_key_constraint(:goal_id)
  end
end
