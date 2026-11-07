defmodule Platform.Habits.Signal do
  @moduledoc """
  One learnable choice (`0061-learned-defaults.md` § 1): who chose which
  target for which action, in which room, with what outcome, at which rung of
  the trust ladder. Written only through `Platform.Habits` (stage 2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Habits.Actions

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @outcomes ~w(accepted overridden ignored chosen)
  @rungs ~w(none rank prefill act)
  @target_types ~w(user agent)

  @type t :: %__MODULE__{}

  schema "habit_signals" do
    field(:actor_user_id, :binary_id)
    field(:space_id, :binary_id)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, Ecto.UUID)
    field(:outcome, :string)
    field(:rung, :string)
    field(:source_message_id, Ecto.UUID)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The closed set of outcomes."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "The closed set of rungs a signal may record."
  @spec rungs() :: [String.t()]
  def rungs, do: @rungs

  @fields ~w(actor_user_id space_id action target_type target_id outcome rung source_message_id)a
  @required ~w(actor_user_id action target_type target_id outcome rung)a

  @doc "Validates a signal. The action must be registered in `Platform.Habits.Actions`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(signal, attrs) do
    signal
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_change(:action, fn :action, action ->
      if Actions.registered?(action), do: [], else: [action: "is not a registered action"]
    end)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:rung, @rungs)
    |> validate_inclusion(:target_type, @target_types)
    |> check_constraint(:outcome, name: :habit_signals_outcome_check)
    |> check_constraint(:rung, name: :habit_signals_rung_check)
    |> check_constraint(:target_type, name: :habit_signals_target_type_check)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:space_id)
  end
end
