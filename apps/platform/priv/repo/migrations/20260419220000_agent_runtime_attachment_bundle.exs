defmodule Platform.Repo.Migrations.AgentRuntimeAttachmentBundle do
  @moduledoc "ADR 0039 phase 4+5: grant the `attachment` bundle to every existing runtime."

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_append(allowed_bundles, 'attachment')
    WHERE NOT ('attachment' = ANY(allowed_bundles))
    """)
  end

  def down do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_remove(allowed_bundles, 'attachment')
    """)
  end
end
