defmodule Platform.Repo.Migrations.AddDeletionScheduledAtToChatSpaces do
  use Ecto.Migration

  # Task 019e95ea stage 3 — scheduled channel deletion. A Fabrikam admin can
  # flag an archived channel for permanent deletion; the flag stamps this
  # column and `Platform.Chat.SpacePurger` hard-deletes the space (children
  # cascade via existing FKs) once the retention window has elapsed.
  #
  # NULL means "not scheduled" — the overwhelmingly common case — so the
  # sweep's observability index is partial on the non-NULL predicate to
  # keep it lean.

  def up do
    alter table(:chat_spaces) do
      add(:deletion_scheduled_at, :utc_datetime_usec, null: true)
    end

    create(
      index(:chat_spaces, [:deletion_scheduled_at],
        where: "deletion_scheduled_at IS NOT NULL",
        name: :chat_spaces_deletion_scheduled_at_index
      )
    )
  end

  def down do
    drop(
      index(:chat_spaces, [:deletion_scheduled_at],
        name: :chat_spaces_deletion_scheduled_at_index
      )
    )

    alter table(:chat_spaces) do
      remove(:deletion_scheduled_at)
    end
  end
end
