defmodule Platform.Repo.Migrations.BackfillStaleAgentParticipantDisplayNames do
  @moduledoc """
  Bring every agent `chat_participants.display_name` back in line with the
  agent's current name (task 01a1f0d1).

  `display_name` is the copy the mention router and the members sheet read.
  Until `Platform.Agents.Agent.changeset/2` started syncing it on rename, a
  renamed agent kept its old name in every space it had already joined: the
  old name still mentioned it, the new one did not, and the members sheet
  showed the old one. This repairs the rows written before that fix, plus any
  NULL rows the earlier backfill
  (`20260819090000_backfill_null_agent_participant_display_names`) missed.

  NO EXCLUSIONS for per-space nicknames: that is not a product concept. No UI
  sets one, and every production caller of `Chat.add_agent_participant`
  passes `agent.name`. So every mismatched agent row is rewritten.

  FEDERATED participants are excluded by the join: their `participant_id` is
  derived deterministically from the peer and never equals an `agents.id`.

  `IS DISTINCT FROM`, not `<>`, so a NULL `display_name` is repaired too.
  Plain SQL, no schema modules. IDEMPOTENT: a second run matches zero rows.
  """
  # old-code-compatible: data-only UPDATE of chat_participants.display_name to the agent's current name; no schema change, and the previous release reads the column the same way.
  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_participants AS p
       SET display_name = a.name
      FROM agents AS a
     WHERE p.participant_type = 'agent'
       AND p.participant_id = a.id
       AND a.name IS NOT NULL
       AND a.name <> ''
       AND p.display_name IS DISTINCT FROM a.name
    """)
  end

  # Irreversible on purpose: the old names are not recoverable, and restoring
  # a stale name is never the intent.
  def down, do: :ok
end
