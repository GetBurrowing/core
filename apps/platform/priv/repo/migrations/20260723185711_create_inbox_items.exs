defmodule Platform.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    create table(:inbox_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:source_type, :string, null: false)
      # Deliberately a plain :uuid, NOT a references/FK — source rows live in
      # other schemas (chat_messages, tasks, review_requests, …), so this is a
      # cross-schema pointer, not a foreign key.
      add(:source_id, :uuid, null: false)
      add(:title, :string)
      add(:body, :text)
      add(:url, :string)
      add(:read_at, :utc_datetime_usec)
      add(:dismissed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Unread-list hot path: rows for a user, filtered by dismissal.
    create(index(:inbox_items, [:user_id, :dismissed_at]))
    # Producer dedup checks on the (user, source_type, source_id) triple.
    create(index(:inbox_items, [:user_id, :source_type, :source_id]))
  end
end
