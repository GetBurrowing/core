defmodule Platform.Repo.Migrations.AddExecutionSpacesAndLogOnly do
  use Ecto.Migration

  def change do
    # Add log_only flag to chat_messages for orchestration log messages
    alter table(:chat_messages) do
      add(:log_only, :boolean, default: false, null: false)
    end

    # No DB-level check constraint on chat_spaces.kind — validation is in the
    # Elixir schema. The "execution" kind is added to Space.@kinds directly.
  end
end
