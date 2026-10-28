defmodule Platform.Repo.Migrations.FenceMeetingSummaryInput do
  use Ecto.Migration

  def change do
    alter table(:meeting_completion_runs) do
      add(:generation, :integer, null: false, default: 0)
    end

    alter table(:meeting_transcripts) do
      add(:summary_input_hash, :text)
      add(:summary_epoch, :integer, null: false, default: 0)
    end
  end
end
