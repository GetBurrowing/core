defmodule Platform.Repo.Migrations.RelaxTranscriptsRoomId do
  use Ecto.Migration

  def up do
    alter table(:meeting_transcripts) do
      modify(:room_id, :string, null: false)
    end
  end

  def down do
    alter table(:meeting_transcripts) do
      modify(:room_id, :uuid, null: false)
    end
  end
end
