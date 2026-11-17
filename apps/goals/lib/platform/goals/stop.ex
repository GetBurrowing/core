defmodule Platform.Goals.Stop do
  @moduledoc """
  One stop on a goal's journey (task 01a1dfc0, Goals 1/8): an ordered
  milestone with an optional target, due date, caption ("the big one") and
  theme ("learn", "habit"). `criteria` is a list of maps with string keys
  `"text"`, `"needed"` and `"found"`. Positions are unique per goal.

  `goal_id` is set by the context, never cast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "goal_stops" do
    belongs_to(:goal, Platform.Goals.Goal)

    field(:position, :integer)
    field(:label, :string)
    field(:target_value, :decimal)
    field(:due_on, :date)
    field(:caption, :string)
    field(:theme, :string)
    field(:criteria, {:array, :map}, default: [])
    field(:reached_on, :date)

    timestamps()
  end

  @editable ~w(position label target_value due_on caption theme criteria reached_on)a

  @doc "Changeset for the editable fields. `goal_id` is set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = stop, attrs) do
    stop
    |> cast(attrs, @editable)
    |> validate_required([:goal_id, :position, :label, :criteria])
    |> validate_length(:label, min: 1, max: 255)
    |> name_constraints()
  end

  @doc """
  Names every database constraint on the table, so a value the database
  refuses comes back as a changeset error, not a raise. `changeset/2` pipes
  through it; a caller writing a raw `change/2` can too.
  """
  @spec name_constraints(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def name_constraints(changeset) do
    changeset
    |> unique_constraint(:position, name: :goal_stops_goal_id_position_index)
    |> foreign_key_constraint(:goal_id)
  end
end
