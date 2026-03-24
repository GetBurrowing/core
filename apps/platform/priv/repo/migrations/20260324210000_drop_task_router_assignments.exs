defmodule Platform.Repo.Migrations.DropTaskRouterAssignments do
  use Ecto.Migration

  def up do
    drop table(:task_router_assignments)
  end

  def down do
    create table(:task_router_assignments, primary_key: false) do
      add :task_id, :binary_id, primary_key: true
      add :assignee_type, :string, null: false
      add :assignee_id, :string, null: false
      add :execution_space_id, :binary_id
      add :assigned_at, :utc_datetime_usec
      add :status, :string, default: "active"
    end
  end
end
