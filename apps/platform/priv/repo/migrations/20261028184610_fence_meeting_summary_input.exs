defmodule Platform.Repo.Migrations.FenceMeetingSummaryInput do
  @moduledoc """
  Task 01a1830b: fence transcript summary producers and completion generations so stale summaries and callbacks cannot satisfy current briefing readiness.
  """
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
