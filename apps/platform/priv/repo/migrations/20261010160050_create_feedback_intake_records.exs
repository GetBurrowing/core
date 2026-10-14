defmodule Platform.Repo.Migrations.CreateFeedbackIntakeRecords do
  @moduledoc """
  Task 01a11ec3 stage 3: one intake record per external issue
  (`Platform.Feedback.IntakeRecord`).

  The unique index over `(lower(repository_identity), issue_number)` is the
  record's identity. GitHub resolves `owner/repo` case-insensitively, so
  `Startup-Suite/core#7` and `startup-suite/core#7` are ONE issue and must
  share one record — the same rule as `tasks_external_feedback_identity_unique`
  on `tasks`, which stays the backstop that keeps a task unique per issue.

  No issue text is stored. `content_sha256` is a digest of the last delivered
  title + body, so a later reader can tell whether the issue changed between
  deliveries without the table ever holding the hostile payload a report may
  carry.
  """
  use Ecto.Migration

  def change do
    create table(:feedback_intake_records, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:repository_identity, :string, null: false)
      add(:issue_number, :bigint, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:verdict, :string)
      add(:reason_code, :string)
      add(:classifier, :string)
      add(:note, :string)
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))
      add(:disposition, :string)
      add(:disposition_status, :string)
      add(:deliveries, :integer, null: false, default: 1)
      add(:content_sha256, :string, size: 64)
      add(:last_delivered_at, :utc_datetime_usec, null: false)
      add(:decided_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(:feedback_intake_records, ["lower(repository_identity)", :issue_number],
        unique: true,
        name: :feedback_intake_records_identity_unique
      )
    )

    create(index(:feedback_intake_records, [:task_id]))

    create(
      constraint(:feedback_intake_records, :feedback_intake_records_status_check,
        check: "status IN ('pending', 'decided')"
      )
    )

    create(
      constraint(:feedback_intake_records, :feedback_intake_records_verdict_check,
        check:
          "verdict IS NULL OR verdict IN ('accept_bug', 'accept_positive_change', 'duplicate', " <>
            "'insufficient_evidence', 'irrelevant_support', 'malicious_control_seeking')"
      )
    )

    create(
      constraint(:feedback_intake_records, :feedback_intake_records_decided_check,
        check: "status <> 'decided' OR verdict IS NOT NULL"
      )
    )

    create(
      constraint(:feedback_intake_records, :feedback_intake_records_issue_number_check,
        check: "issue_number > 0"
      )
    )
  end
end
