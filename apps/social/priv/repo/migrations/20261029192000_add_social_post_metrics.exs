defmodule Platform.Repo.Migrations.AddSocialPostMetrics do
  @moduledoc "Clip Studio 9/9 (task 01a16664): snapshots and restartable org sync progress."
  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:metrics, :map, null: false, default: %{})
      add(:metrics_synced_at, :utc_datetime_usec)
    end

    create table(:social_analytics_sync_states, primary_key: false) do
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), primary_key: true)

      add(:cursor, :text)
      add(:cursor_captured_at, :utc_datetime_usec)
      add(:bootstrap_after_post_id, :binary_id)
      add(:bootstrap_complete, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
