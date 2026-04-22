defmodule Platform.Repo.Migrations.BackfillReactorSnapshots do
  @moduledoc """
  Backfill `reactor_display_name`, `reactor_avatar_url`, and
  `reactor_participant_type` on existing `chat_reactions` rows from the
  referenced `chat_participants` row. Only touches rows where
  `reactor_display_name IS NULL` so rows that the Phase 1 write path
  already populated are left alone.

  Reactions whose participant has already been hard-deleted keep nil
  snapshots — the read-path fallback resolves them as "Someone." Future
  reactions authored via the updated `Chat.add_reaction/1` capture the
  snapshot eagerly.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_reactions r
    SET reactor_display_name = p.display_name,
        reactor_avatar_url = p.avatar_url,
        reactor_participant_type = p.participant_type
    FROM chat_participants p
    WHERE r.participant_id = p.id
      AND r.reactor_display_name IS NULL
    """)
  end

  def down do
    # Mirror ADR 0038 Phase 2: we can't distinguish backfilled from
    # eagerly-populated rows after the fact. Leave as no-op; to revert,
    # roll back the Phase 1 migration.
    :ok
  end
end
