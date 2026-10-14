defmodule Platform.Repo.Migrations.IndexAgentUsageEventsDispatchKeys do
  @moduledoc """
  Task 01a114a8 stage 1: `Platform.Orchestration.DispatchMetrics` joins
  client usage reports to a dispatch by `task_id` and `metadata.stage_id`.
  No new columns: `stage_id`, `turns`, `wall_ms`, `harness` and
  `client_tool_calls` ride in `metadata`.
  """
  use Ecto.Migration

  def change do
    create(index(:agent_usage_events, [:task_id]))

    create(
      index(:agent_usage_events, ["(metadata->>'stage_id')"],
        name: :agent_usage_events_metadata_stage_id_index
      )
    )
  end
end
