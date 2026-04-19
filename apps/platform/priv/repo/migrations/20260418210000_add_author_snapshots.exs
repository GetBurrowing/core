defmodule Platform.Repo.Migrations.AddAuthorSnapshots do
  @moduledoc """
  ADR 0038 Phase 1. Add nullable author-identity snapshot columns to
  chat_messages, chat_pins, and chat_canvases. New rows populate these at
  write time; old rows render via the legacy `chat_participants` JOIN
  fallback until the Phase 2 backfill copies values in.

  Fully additive and reversible — Phase 1 cannot break the current app.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add(:author_display_name, :text)
      add(:author_avatar_url, :text)
      add(:author_participant_type, :text)
      add(:author_agent_id, :binary_id)
      add(:author_user_id, :binary_id)
    end

    alter table(:chat_pins) do
      add(:pinned_by_display_name, :text)
      add(:pinned_by_participant_type, :text)
    end

    alter table(:chat_canvases) do
      add(:created_by_display_name, :text)
      add(:created_by_participant_type, :text)
    end
  end
end
