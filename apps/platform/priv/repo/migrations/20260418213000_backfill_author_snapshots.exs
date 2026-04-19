defmodule Platform.Repo.Migrations.BackfillAuthorSnapshots do
  @moduledoc """
  ADR 0038 Phase 2. Backfill author identity snapshot columns on
  chat_messages, chat_pins, and chat_canvases from the current
  chat_participants rows that they reference.

  Rows with `author_display_name IS NULL` are backfilled; rows that the
  Phase 1 write path already populated are left alone. The join uses
  `chat_participants.id`, which is the stable FK target — it works whether
  the participant has `left_at` set or not, so dismissed authors keep
  their historical identity.

  Dev/staging runs as a single UPDATE. For very large tables a chunked
  version would be wanted; at current suite scale the single-statement
  path is fine.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_messages m
    SET author_display_name = p.display_name,
        author_avatar_url = NULL,
        author_participant_type = p.participant_type,
        author_agent_id = CASE WHEN p.participant_type = 'agent' THEN p.participant_id END,
        author_user_id = CASE WHEN p.participant_type = 'user' THEN p.participant_id END
    FROM chat_participants p
    WHERE m.participant_id = p.id
      AND m.author_display_name IS NULL
    """)

    execute("""
    UPDATE chat_pins pin
    SET pinned_by_display_name = p.display_name,
        pinned_by_participant_type = p.participant_type
    FROM chat_participants p
    WHERE pin.pinned_by = p.id
      AND pin.pinned_by_display_name IS NULL
    """)

    execute("""
    UPDATE chat_canvases c
    SET created_by_display_name = p.display_name,
        created_by_participant_type = p.participant_type
    FROM chat_participants p
    WHERE c.created_by = p.id
      AND c.created_by_display_name IS NULL
    """)
  end

  def down do
    # The Phase 1 migration adds the columns; Phase 2 only populates them.
    # A down-migration would null out anything we backfilled, but we can't
    # distinguish backfilled rows from Phase-1-write rows anymore. Leave
    # this as a no-op — to revert, drop and re-add the columns via the
    # Phase 1 migration rollback.
    :ok
  end
end
