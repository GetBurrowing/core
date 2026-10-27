defmodule Platform.Repo.Migrations.CreateMeetingCompletionRuns do
  use Ecto.Migration

  def change do
    create table(:meeting_completion_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:meeting_id, references(:meetings, type: :uuid, on_delete: :delete_all), null: false)
      add(:transcript_id, references(:meeting_transcripts, type: :uuid, on_delete: :nilify_all))
      add(:canvas_id, references(:chat_canvases, type: :uuid, on_delete: :nilify_all))
      add(:status, :text, null: false, default: "waiting")
      add(:snapshot, :map, null: false, default: %{})
      add(:snapshot_hash, :text)
      add(:item_results, :map, null: false, default: %{})
      add(:last_error, :text)
      add(:dispatched_at, :utc_datetime_usec)
      add(:capture_finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_completion_runs, [:meeting_id]))
  end
end
