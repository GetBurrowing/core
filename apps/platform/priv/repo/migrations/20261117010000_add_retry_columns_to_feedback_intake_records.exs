defmodule Platform.Repo.Migrations.AddRetryColumnsToFeedbackIntakeRecords do
  @moduledoc """
  Task 01a1e670 stage 2: the bounded retry sweep for pending feedback intake
  records (`Platform.Feedback.Intake.retry_pending/1`).

  `attempts` counts sweep attempts since the last delivery, `next_attempt_at`
  is the backoff deadline and `last_attempt_at` the last try. Existing rows
  get `attempts = 0` and a null deadline, so they are eligible on the first
  sweep with no data migration. The partial index serves the sweep's due
  query, which only ever reads pending rows.
  """
  use Ecto.Migration

  def change do
    alter table(:feedback_intake_records) do
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_attempt_at, :utc_datetime_usec)
    end

    create(
      index(:feedback_intake_records, [:next_attempt_at],
        where: "status = 'pending'",
        name: :feedback_intake_records_pending_next_attempt_index
      )
    )
  end
end
