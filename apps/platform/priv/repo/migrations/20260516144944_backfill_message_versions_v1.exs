defmodule Platform.Repo.Migrations.BackfillMessageVersionsV1 do
  @moduledoc """
  Task 019e2ce2 Stage 2 — catch-up backfill for v1 message version rows.

  Context: the initial `20260511170000_add_message_edit_history` migration
  created `chat_message_versions` and ran a paginated backfill against
  every then-existing `chat_messages` row. After that migration ran,
  new messages should have been getting their v1 row inserted by
  `Platform.Chat.MessageVersions.record_v1!/1` inside the message-create
  transaction — but that wiring was never landed in `lib/`. Stage 1 of
  this task fixed the wiring.

  This migration covers the gap: messages that were CREATED AFTER the
  initial schema migration ran but BEFORE Stage 1's fix shipped have
  zero version rows. Without their v1 row, the first edit lands the
  count at 1 (not 2), and the `(edited)` affix at
  `chat_message.ex:137` (gate: `versions_count > 1`) stays hidden.

  Approach: a single INSERT … SELECT that inserts a v1 row for every
  message that lacks one. Idempotent on two layers:

    * `WHERE NOT EXISTS` skips messages that already have a v1 row.
    * `ON CONFLICT (message_id, version_number) DO NOTHING` survives
      a race where Stage 1's `record_v1!/1` fires for a new message
      while this migration is in flight.

  No new schema; no indexes touched. The unique index on
  `(message_id, version_number)` from the original migration is what
  the ON CONFLICT targets.
  """
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO chat_message_versions (
      id,
      message_id,
      version_number,
      content,
      edited_at,
      edited_by_participant_id,
      edited_by_display_name,
      inserted_at
    )
    SELECT
      gen_random_uuid(),
      m.id,
      1,
      COALESCE(m.content, ''),
      m.inserted_at,
      m.participant_id,
      COALESCE(m.author_display_name, '(unknown)'),
      now()
    FROM chat_messages m
    WHERE NOT EXISTS (
      SELECT 1
      FROM chat_message_versions v
      WHERE v.message_id = m.id
        AND v.version_number = 1
    )
    ON CONFLICT (message_id, version_number) DO NOTHING
    """)
  end

  def down do
    # Backfill is historical — rolling it back would orphan edit
    # history from existing messages and re-introduce the original bug
    # for those rows. Intentionally a no-op.
    :ok
  end
end
