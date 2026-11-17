defmodule Platform.Goals.WakeUp do
  @moduledoc "Storage for goal_wake_ups (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_wake_ups" do
    belongs_to(:goal, Platform.Goals.Goal)
    field(:kind, :string, default: "check_in")
    field(:due_at, :utc_datetime_usec)
    field(:fired_at, :utc_datetime_usec)
    field(:respond_by, :utc_datetime_usec)
    belongs_to(:coach_agent, Platform.Agents.Agent)
    field(:status, :string, default: "open")
    field(:outcome, :string)
    field(:closed_at, :utc_datetime_usec)
    field(:catch_up, :boolean, default: false)
    field(:delivery, :string, default: "pending")
    belongs_to(:reading, Platform.Goals.Reading)
    field(:briefing, :map, default: %{})
    belongs_to(:entry, Platform.Goals.Entry)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :kind,
      :due_at,
      :fired_at,
      :respond_by,
      :status,
      :outcome,
      :closed_at,
      :catch_up,
      :delivery,
      :reading_id,
      :briefing,
      :entry_id
    ])
    |> validate_required([
      :goal_id,
      :kind,
      :due_at,
      :fired_at,
      :respond_by,
      :status,
      :catch_up,
      :delivery,
      :briefing
    ])
    |> validate_inclusion(:kind, ~w(check_in retro))
    |> check_constraint(:kind, name: :goal_wake_ups_kind)
    |> validate_inclusion(:status, ~w(open closed unanswered))
    |> check_constraint(:status, name: :goal_wake_ups_status)
    |> validate_inclusion(:outcome, ~w(do ask wait retro))
    |> check_constraint(:outcome, name: :goal_wake_ups_outcome)
    |> check_constraint(:outcome, name: :goal_wake_ups_retro_outcome)
    |> validate_inclusion(:delivery, ~w(pending sent offline failed no_runtime))
    |> check_constraint(:delivery, name: :goal_wake_ups_delivery)
    |> validate_outcome()
    |> check_constraint(:outcome, name: :goal_wake_ups_outcome_matches_status)
    |> unique_constraint([:goal_id, :kind], name: :goal_wake_ups_one_open)
    |> unique_constraint([:goal_id, :kind, :due_at],
      name: :goal_wake_ups_goal_id_kind_due_at_index
    )
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:coach_agent_id)
    |> foreign_key_constraint(:reading_id)
    |> foreign_key_constraint(:entry_id)
  end

  defp validate_outcome(changeset) do
    if get_field(changeset, :status) == "closed" == not is_nil(get_field(changeset, :outcome)),
      do: changeset,
      else: add_error(changeset, :outcome, "must be present exactly when closed")
  end
end
