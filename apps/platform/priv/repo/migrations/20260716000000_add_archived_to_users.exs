defmodule Platform.Repo.Migrations.AddArchivedToUsers do
  use Ecto.Migration

  # User archival (task 019f671f) — soft-archive columns on `users` mirror
  # the `spaces.archived_at` precedent used by `Platform.Chat.archive_space/2`
  # (see apps/platform/lib/platform/chat.ex:287-317). Rows stay resident so
  # historical attribution (past-authored messages, task `reported_by`,
  # memory-entry authorship) keeps resolving; downstream reads filter by
  # `is_nil(archived_at)`.
  #
  #  * `archived_at`          — nullable timestamp; presence == archived.
  #  * `archived_by_user_id`  — nullable FK to `users(id)` with
  #    `on_delete: :nilify_all` so archiving an archiver keeps the archived
  #    user's row valid (historical actor becomes nil, not orphan).
  #  * `archived_reason`      — nullable free text for admin note.
  #
  # An index on `archived_at` lets `list_users(include_archived: false)`
  # (accounts.ex, this task Stage 1) rely on it for the hot active-list path.
  def change do
    alter table(:users) do
      add(:archived_at, :utc_datetime_usec)
      add(:archived_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:archived_reason, :text)
    end

    create(index(:users, [:archived_at]))
    create(index(:users, [:archived_by_user_id]))
  end
end
