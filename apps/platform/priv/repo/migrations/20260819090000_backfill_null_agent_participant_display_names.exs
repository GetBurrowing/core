defmodule Platform.Repo.Migrations.BackfillNullAgentParticipantDisplayNames do
  @moduledoc """
  Repair agent `chat_participants` rows whose `display_name` is NULL or blank.

  ADR-0037 (`@[Display Name]` mention routing) treats the participant column as
  the agent's mention identity. This migration repairs the rows that column was
  silently written NULL on.

  `display_name` is a denormalised cache of the principal's name. It is
  nullable and was absent from `Participant.changeset/2`'s `validate_required`,
  so callers reaching `Platform.Chat.add_participant/2` directly — RPC channel
  creation being the common one, and the module doc actively demonstrated the
  call without the field — silently wrote NULL.

  A NULL agent name broke three unrelated surfaces from one column: the roster
  rendered the literal "Agent", the @-mention autocomplete could only offer
  "Agent", and `AttentionRouter.mentioned?/2` consulted only this column, so
  every `@[Name]` mention of the affected agent produced no routing decision,
  no dispatch and no error.

  The write path now resolves the name and the router falls back to the
  `agents` row, so this migration only cleans up rows created before those
  landed.

  IDEMPOTENT: the UPDATE is guarded by `display_name IS NULL OR trim(...) = ''`
  and only ever writes a non-empty name, so a second run matches zero rows.
  Re-runnable at any time; safe on a database with no affected rows.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_participants AS p
       SET display_name = COALESCE(NULLIF(btrim(a.name), ''), a.slug)
      FROM agents AS a
     WHERE p.participant_id = a.id
       AND p.participant_type = 'agent'
       AND (p.display_name IS NULL OR btrim(p.display_name) = '')
       AND COALESCE(NULLIF(btrim(a.name), ''), a.slug) IS NOT NULL
       AND btrim(COALESCE(NULLIF(btrim(a.name), ''), a.slug)) <> ''
    """)
  end

  # Deliberately irreversible: the pre-migration state is "this column is NULL
  # and mentions are silently dropped". Restoring that is never the intent, and
  # we cannot distinguish a backfilled row from one legitimately holding the
  # same name.
  def down, do: :ok
end
