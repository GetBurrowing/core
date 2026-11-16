defmodule Platform.Repo.Migrations.CreateSocialTrendSnapshots do
  @moduledoc """
  Social (ADR 0055) retains bounded source observations across restarts so
  everyone compares ranks from the same two complete snapshots.
  """
  use Ecto.Migration

  # old-code-compatible: this new table is never read or written by the old release.
  def change do
    create table(:social_trend_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:source, :text, null: false)
      add(:sample_limit, :integer, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:reporting_date, :date)
      add(:payload, :map, null: false)
    end

    create(index(:social_trend_snapshots, [:source, :observed_at]))

    create(
      unique_index(:social_trend_snapshots, [:source, :reporting_date],
        where: "reporting_date IS NOT NULL"
      )
    )

    create table(:social_trend_source_states, primary_key: false) do
      add(:source, :text, primary_key: true)
      add(:retry_at, :utc_datetime_usec)
      add(:status, :text)
      add(:last_attempt_at, :utc_datetime_usec)
    end
  end
end
