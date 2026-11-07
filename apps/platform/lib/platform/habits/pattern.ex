defmodule Platform.Habits.Pattern do
  @moduledoc """
  The cache over `habit_signals` plus the trust-ladder state for one
  (user, space, action, target) (`0061-learned-defaults.md` § 1, § 4).

  `space_id` is nil for an org-level action. The unique index is
  `NULLS NOT DISTINCT`, so a nil-space pattern is still exactly one row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Habits.Actions

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @rungs ~w(rank prefill act)
  @target_types ~w(user agent)
  @unique_index :habit_patterns_tuple_index

  @type t :: %__MODULE__{}

  schema "habit_patterns" do
    field(:user_id, :binary_id)
    field(:space_id, :binary_id)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, Ecto.UUID)
    field(:accepted_prefills, :integer, default: 0)
    field(:rung, :string, default: "rank")
    field(:stopped_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The rungs a pattern may sit at."
  @spec rungs() :: [String.t()]
  def rungs, do: @rungs

  @fields ~w(user_id space_id action target_type target_id accepted_prefills rung stopped_at)a
  @required ~w(user_id action target_type target_id)a

  @doc """
  Validates a pattern. The action must be registered, and the rung may not
  exceed what `Platform.Habits.Actions.max_rung_for/2` allows for the target.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_change(:action, fn :action, action ->
      if Actions.registered?(action), do: [], else: [action: "is not a registered action"]
    end)
    |> validate_inclusion(:rung, @rungs)
    |> validate_inclusion(:target_type, @target_types)
    |> validate_number(:accepted_prefills, greater_than_or_equal_to: 0)
    |> validate_rung_cap()
    |> check_constraint(:rung, name: :habit_patterns_rung_check)
    |> check_constraint(:target_type, name: :habit_patterns_target_type_check)
    |> check_constraint(:accepted_prefills, name: :habit_patterns_accepted_prefills_check)
    |> unique_constraint([:user_id, :space_id, :action, :target_type, :target_id],
      name: @unique_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:space_id)
  end

  defp validate_rung_cap(changeset) do
    action = get_field(changeset, :action)
    rung = get_field(changeset, :rung)
    target = %{target_type: get_field(changeset, :target_type)}

    with true <- Actions.registered?(action),
         true <- rung in @rungs,
         cap when not is_nil(cap) <- Actions.max_rung_for(action, target),
         false <- Actions.rung_at_least?(cap, String.to_existing_atom(rung)) do
      add_error(changeset, :rung, "exceeds the max rung for this action and target")
    else
      _ -> changeset
    end
  end
end
