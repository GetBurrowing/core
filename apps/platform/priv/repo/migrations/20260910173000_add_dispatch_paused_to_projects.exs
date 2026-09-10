defmodule Platform.Repo.Migrations.AddDispatchPausedToProjects do
  use Ecto.Migration

  @moduledoc """
  Task 01a08c1e stage 3: `projects.dispatch_paused`. A paused project is
  invisible to `Platform.Orchestration.TaskRouterWatcher` — no TaskRouter is
  started for any of its tasks, however they are assigned — so a project
  can hold agent-assigned tasks (a queue of Process work, say) without
  spending agent throughput on them. Set through the `project_update` MCP
  tool; there is no project settings form.

  NOT NULL with a false default: an absent flag must read as "dispatching",
  never as an unknown the watcher has to interpret.
  """

  def up do
    alter table(:projects) do
      add(:dispatch_paused, :boolean, default: false, null: false)
    end
  end

  def down do
    alter table(:projects) do
      remove(:dispatch_paused)
    end
  end
end
