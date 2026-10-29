defmodule Platform.Repo.Migrations.ResumePendingAnalyticsBaselines do
  @moduledoc """
  Task 01a16664: retain unfinished per-post baselines and their retry deadline so pending analytics can recover without delaying established delta feeds.
  """
  use Ecto.Migration

  def change do
    alter table(:social_analytics_sync_states) do
      add(:baseline_retry_at, :utc_datetime_usec)
      add(:pending_baseline_ids, {:array, :binary_id}, null: false, default: [])
    end
  end
end
