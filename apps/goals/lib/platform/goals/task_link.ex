defmodule Platform.Goals.TaskLink do
  @moduledoc "Storage for goal_task_links (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_task_links" do
    field(:goal_id, :binary_id)
    field(:task_id, :binary_id)
    field(:wake_up_id, :binary_id)
    field(:entry_id, :binary_id)
    field(:created_by_agent_id, :binary_id)
    field(:reported_wake_up_id, :binary_id)
    timestamps(updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:task_id, :wake_up_id, :entry_id, :reported_wake_up_id])
    |> validate_required([:goal_id, :task_id])
    |> unique_constraint([:task_id])
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:wake_up_id)
    |> foreign_key_constraint(:entry_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:reported_wake_up_id)
  end
end
