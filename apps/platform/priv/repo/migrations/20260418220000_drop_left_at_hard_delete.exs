defmodule Platform.Repo.Migrations.DropLeftAtHardDelete do
  @moduledoc """
  ADR 0038 Phase 4. Collapse the participant lifecycle to a single
  present-tense fact: either the row exists or it doesn't.

    1. Relax the FKs that point at `chat_participants.id` (message author,
       pin author, canvas creator, reaction author) to `ON DELETE SET NULL`.
       The live participant_id becomes a nullable back-reference; author
       attribution lives on the owning row via the Phase 1 author_* /
       pinned_by_* / created_by_* snapshot columns.
    2. Hard-delete every participant row with `left_at IS NOT NULL`.
       Rendering already filtered these out; attribution survives via
       snapshots. Threads / messages / pins / canvases they authored keep
       displaying their name and avatar as they were at write time.
    3. Drop the `left_at` column. No more soft-delete state. No more
       silent resurrection.

  Reversible only by re-adding the column and restoring the NOT NULL FK
  (deleted rows can't be reconstructed; restore from backup if needed).
  """
  use Ecto.Migration

  def up do
    # chat_messages.participant_id
    execute("ALTER TABLE chat_messages ALTER COLUMN participant_id DROP NOT NULL")

    execute("""
    ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_participant_id_fkey
    """)

    execute("""
    ALTER TABLE chat_messages
      ADD CONSTRAINT chat_messages_participant_id_fkey
      FOREIGN KEY (participant_id) REFERENCES chat_participants(id) ON DELETE SET NULL
    """)

    # chat_reactions.participant_id
    execute("ALTER TABLE chat_reactions ALTER COLUMN participant_id DROP NOT NULL")

    execute("""
    ALTER TABLE chat_reactions DROP CONSTRAINT IF EXISTS chat_reactions_participant_id_fkey
    """)

    execute("""
    ALTER TABLE chat_reactions
      ADD CONSTRAINT chat_reactions_participant_id_fkey
      FOREIGN KEY (participant_id) REFERENCES chat_participants(id) ON DELETE SET NULL
    """)

    # chat_pins.pinned_by
    execute("ALTER TABLE chat_pins ALTER COLUMN pinned_by DROP NOT NULL")

    execute("""
    ALTER TABLE chat_pins DROP CONSTRAINT IF EXISTS chat_pins_pinned_by_fkey
    """)

    execute("""
    ALTER TABLE chat_pins
      ADD CONSTRAINT chat_pins_pinned_by_fkey
      FOREIGN KEY (pinned_by) REFERENCES chat_participants(id) ON DELETE SET NULL
    """)

    # chat_canvases.created_by
    execute("ALTER TABLE chat_canvases ALTER COLUMN created_by DROP NOT NULL")

    execute("""
    ALTER TABLE chat_canvases DROP CONSTRAINT IF EXISTS chat_canvases_created_by_fkey
    """)

    execute("""
    ALTER TABLE chat_canvases
      ADD CONSTRAINT chat_canvases_created_by_fkey
      FOREIGN KEY (created_by) REFERENCES chat_participants(id) ON DELETE SET NULL
    """)

    # Hard-delete dismissed participants. Cascading SET NULL on FKs lets
    # this succeed without touching child rows; author attribution lives
    # on those children via the Phase 1 snapshot columns.
    execute("DELETE FROM chat_participants WHERE left_at IS NOT NULL")

    alter table(:chat_participants) do
      remove(:left_at)
    end
  end

  def down do
    alter table(:chat_participants) do
      add(:left_at, :utc_datetime_usec)
    end

    # The NOT NULL + ON DELETE RESTRICT shape is not restored because
    # messages/reactions/pins/canvases authored by deleted participants
    # legitimately have NULL FKs after this migration; tightening the
    # column back to NOT NULL would reject those rows. Operators rolling
    # back should be aware of this asymmetry.
  end
end
