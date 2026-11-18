defmodule Platform.Goals.Reading do
  @moduledoc "A dated number with immutable population, source and author provenance (task 01a1dfc0-cce8)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "goal_readings" do
    belongs_to(:goal, Platform.Goals.Goal)
    field(:value, :decimal)
    field(:unit, :string)
    field(:source_key, :string)
    field(:population, :string)
    field(:origin, :string)
    field(:measured_at, :utc_datetime_usec)
    field(:note, :string)
    field(:details, :map, default: %{})
    field(:author_type, :string)
    belongs_to(:author_user, Platform.Accounts.User)
    belongs_to(:author_agent, Platform.Agents.Agent)
    timestamps()
  end

  def changeset(reading, attrs) do
    reading
    |> cast(attrs, [:value, :measured_at, :note, :origin, :details])
    |> validate_required([:value, :measured_at])
    |> validate_inclusion(:origin, ~w(manual practice measured))
    |> validate_change(:measured_at, fn :measured_at, time ->
      if DateTime.compare(time, DateTime.utc_now()) == :gt,
        do: [measured_at: "cannot be in the future"],
        else: []
    end)
    |> check_constraint(:origin, name: :goal_readings_origin)
    |> check_constraint(:author_type, name: :goal_readings_author_type)
    |> foreign_key_constraint(:goal_id)
  end
end
