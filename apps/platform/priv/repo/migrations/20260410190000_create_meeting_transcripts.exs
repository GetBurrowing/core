defmodule Platform.Repo.Migrations.CreateMeetingTranscripts do
  use Ecto.Migration

  def change do
    create table(:meeting_transcripts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:room_id, :uuid, null: false)
      add(:space_id, :uuid)
      add(:segments, :jsonb, null: false, default: "[]")
      add(:summary, :text)
      add(:status, :string, null: false, default: "recording")
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_transcripts, [:room_id]))
    create(index(:meeting_transcripts, [:space_id]))
    create(index(:meeting_transcripts, [:status]))
  end
end
