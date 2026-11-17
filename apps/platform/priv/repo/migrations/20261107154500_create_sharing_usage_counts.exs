# old-code-compatible: Creates only the new sharing_usage_counts table and its indexes; previous code never reads it.
defmodule Platform.Repo.Migrations.CreateSharingUsageCounts do
  @moduledoc """
  Task `01a1b678-8bb4-7000-96d2-c691eb9b13b5`, stage 2: the broker host's
  store of anonymous usage counts. One row per (sharing install id, window
  start, pinned event name), written by `Platform.Sharing.UsageReceiver`
  behind `POST /api/feedback-broker/v1/usage`.

  `sharing_install_id` is the random per-install sharing id, not a
  federation id and linked to no account. `event` is validated against
  `Platform.Sharing.UsageEvents.events/0` before insert. A retried batch hits
  the unique index and replaces its own count, so a resend cannot double it.
  """

  use Ecto.Migration

  def change do
    create table(:sharing_usage_counts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:sharing_install_id, :uuid, null: false)
      add(:window_start, :utc_datetime, null: false)
      add(:window_seconds, :integer, null: false)
      add(:event, :string, size: 64, null: false)
      add(:count, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:sharing_usage_counts, :sharing_usage_counts_count_non_negative,
        check: "count >= 0 AND window_seconds >= 0"
      )
    )

    create(
      unique_index(:sharing_usage_counts, [:sharing_install_id, :window_start, :event],
        name: :sharing_usage_counts_install_window_event_index
      )
    )

    create(index(:sharing_usage_counts, [:window_start]))
  end
end
