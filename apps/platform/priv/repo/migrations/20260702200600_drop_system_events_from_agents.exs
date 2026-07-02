defmodule Platform.Repo.Migrations.DropSystemEventsFromAgents do
  @moduledoc """
  Historian retirement (task 019f2444) stage 5: drop the legacy
  `agents.system_events` column.

  The flag (`system_events @> '["historian"]'`) was the pre-Roles
  mechanism for pinning the Historian responsibility onto a specific
  agent. Stage 1 backfilled matching `role_assignments` rows keyed by
  `role_key = "historian"`; stages 2-3 rewired `Routing.historian?/1`
  and `HistorianDispatcher.agent_for_event/1` to consult Roles; stage 4
  removed the last UI toggle.

  `down/0` restores an empty column so a rollback compiles, but does
  NOT re-backfill Historian flags from `role_assignments`. This is a
  one-way door by design: Roles is now source-of-truth, and any
  reverted deploy must re-onboard the Historian by re-running stage 4
  UI (or re-inserting a role assignment directly). Attempting to
  synthesize the flag on rollback would risk drift between Roles and
  the resurrected column.
  """
  use Ecto.Migration

  def up do
    alter table(:agents) do
      remove(:system_events)
    end
  end

  def down do
    alter table(:agents) do
      add(:system_events, :jsonb, null: false, default: "[]")
    end
  end
end
