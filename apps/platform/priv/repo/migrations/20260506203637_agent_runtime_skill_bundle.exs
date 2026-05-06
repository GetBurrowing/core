defmodule Platform.Repo.Migrations.AgentRuntimeSkillBundle do
  @moduledoc "Task 019dfaea phase 2: grant the `skill` bundle to every existing runtime."

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_append(allowed_bundles, 'skill')
    WHERE NOT ('skill' = ANY(allowed_bundles))
    """)
  end

  def down do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_remove(allowed_bundles, 'skill')
    """)
  end
end
