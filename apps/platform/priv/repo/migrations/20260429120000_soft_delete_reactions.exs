defmodule Platform.Repo.Migrations.SoftDeleteReactions do
  @moduledoc """
  Switch `chat_reactions` from hard-delete to soft-delete (Activity panel v2,
  precondition for per-item restore on reactions).

  Adds `deleted_at` and replaces the existing unique index
  `chat_reactions_unique` on `(message_id, participant_id, emoji)` with a
  *partial* unique index that only enforces uniqueness on active rows
  (`WHERE deleted_at IS NULL`). Without the partial index, soft-deleting a
  reaction and then re-reacting with the same emoji would violate the
  constraint and the second add would fail.

  Application-side resurrection (in `Chat.add_reaction/1`) prefers updating
  the existing soft-deleted row rather than inserting a duplicate, so the
  history table stays clean. The partial index is the correctness backstop
  in case any future write path bypasses that check.

  Reversible: rollback drops the partial index and restores the original
  full unique index on the same columns.
  """

  use Ecto.Migration

  def change do
    alter table(:chat_reactions) do
      add(:deleted_at, :utc_datetime_usec)
    end

    drop(
      unique_index(:chat_reactions, [:message_id, :participant_id, :emoji],
        name: :chat_reactions_unique
      )
    )

    create(
      unique_index(:chat_reactions, [:message_id, :participant_id, :emoji],
        name: :chat_reactions_unique,
        where: "deleted_at IS NULL"
      )
    )
  end
end
