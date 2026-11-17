defmodule Platform.Goals.TaskLink do
  @moduledoc "Storage for goal_task_links (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_task_links" do
    belongs_to(:goal, Platform.Goals.Goal)
    belongs_to(:task, Platform.Tasks.Task)
    belongs_to(:wake_up, Platform.Goals.WakeUp)
    belongs_to(:entry, Platform.Goals.Entry)
    belongs_to(:created_by_agent, Platform.Agents.Agent)
    belongs_to(:reported_wake_up, Platform.Goals.WakeUp)
    timestamps(updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:task_id, :wake_up_id, :entry_id, :reported_wake_up_id])
    |> validate_required([:goal_id, :task_id])
    |> unique_constraint([:task_id], name: :goal_task_links_task_id_index)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:wake_up_id)
    |> foreign_key_constraint(:entry_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:reported_wake_up_id)
  end
end
