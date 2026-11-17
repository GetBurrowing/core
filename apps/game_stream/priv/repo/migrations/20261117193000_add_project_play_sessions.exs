defmodule Platform.Repo.Migrations.AddProjectPlaySessions do
  use Ecto.Migration

  def change do
    alter table(:game_stream_sessions) do
      modify(:task_id, :binary_id, null: true, from: {:binary_id, null: false})
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all))
    end

    create(index(:game_stream_sessions, [:project_id]))
    create(constraint(:game_stream_sessions, :game_stream_build_source,
      check: "task_id IS NOT NULL OR project_id IS NOT NULL"))
  end
end
