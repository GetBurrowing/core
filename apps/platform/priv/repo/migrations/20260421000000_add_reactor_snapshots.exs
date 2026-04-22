defmodule Platform.Repo.Migrations.AddReactorSnapshots do
  @moduledoc """
  Mirror of ADR 0038 for reactions. Add nullable reactor-identity snapshot
  columns to `chat_reactions` so a reactor's display name + participant
  type survive the participant being hard-deleted from the space.

  New rows populate these at write time; existing rows are backfilled
  separately in the next migration (`BackfillReactorSnapshots`). Fully
  additive and reversible.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_reactions) do
      add(:reactor_display_name, :text)
      add(:reactor_avatar_url, :text)
      add(:reactor_participant_type, :text)
    end
  end
end
