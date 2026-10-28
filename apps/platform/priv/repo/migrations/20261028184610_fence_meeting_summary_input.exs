defmodule Platform.Repo.Migrations.FenceMeetingSummaryInput do
  use Ecto.Migration

  def change do
    alter table(:meeting_transcripts) do
      add(:summary_input_hash, :text)
      add(:summary_epoch, :integer, null: false, default: 0)
    end
  end
end
