defmodule Platform.Repo.Migrations.AddSystemEventsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:system_events, :jsonb, null: false, default: "[]")
    end
  end
end
