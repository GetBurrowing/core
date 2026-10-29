defmodule Platform.Repo.Migrations.AddAnalyticsIdentityAndRetry do
  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      # Analytics ID differs from publisher ID; learned through scoped baseline.
      add(:analytics_external_id, :text)
    end

    alter table(:social_analytics_sync_states) do
      add(:replay_cursor, :text)
      add(:retry_at, :utc_datetime_usec)
    end
  end
end
