defmodule Platform.Repo.Migrations.BackfillExternalAgentHttpRuntimeType do
  @moduledoc """
  External HTTP-delegated agents (`kind = 'external'` with an
  `endpoint_kind`) were saved with the schema default
  `runtime_type = 'built_in'`, which claims the built-in BEAM runtime they
  do not run in. `Platform.ExternalAgents.create_external_agent/1` now
  forces `runtime_type = 'http'`; this backfills the rows written before it.

  Federated websocket agents (`runtime_type = 'external'`) and native agents
  are not touched. `down/0` reverses only external rows carrying `'http'`.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE agents
       SET runtime_type = 'http'
     WHERE kind = 'external'
       AND runtime_type = 'built_in'
       AND endpoint_kind IS NOT NULL
    """)
  end

  def down do
    execute("""
    UPDATE agents
       SET runtime_type = 'built_in'
     WHERE kind = 'external'
       AND runtime_type = 'http'
    """)
  end
end
