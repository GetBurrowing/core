defmodule Platform.Repo.Migrations.AddTaskRouterAssignments do
  use Ecto.Migration

  def change do
    create table(:task_router_assignments, primary_key: false) do
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:assignee_type, :string, null: false)
      add(:assignee_id, :string, null: false)
      add(:execution_space_id, references(:chat_spaces, type: :uuid, on_delete: :nilify_all))
      add(:assigned_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:status, :string, null: false, default: "active")
    end

    create(index(:task_router_assignments, [:status]))
  end
end
