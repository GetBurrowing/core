defmodule Platform.Repo.Migrations.Uuidv7AndPersistentUnread do
  use Ecto.Migration

  def change do
    alter table(:chat_participants) do
      remove(:last_read_message_id, :bigint)
      add(:last_read_message_id, :binary_id)
    end
  end
end
