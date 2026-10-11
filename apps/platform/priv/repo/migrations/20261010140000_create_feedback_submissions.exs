defmodule Platform.Repo.Migrations.CreateFeedbackSubmissions do
  @moduledoc """
  Task 01a11ec3 stage 2: idempotency and rate accounting for
  `feedback.submit` (`Platform.Feedback.SubmissionRecord`).

  The unique index on `fingerprint` is the duplicate check that runs before
  any external call: a retried or concurrent identical submission conflicts
  here instead of publishing a second issue. `(actor_agent_id, inserted_at)`
  and `inserted_at` back the per-actor and per-installation rate windows.

  No submission text is stored; see the schema moduledoc.
  """
  use Ecto.Migration

  def change do
    create table(:feedback_submissions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:fingerprint, :string, size: 64, null: false)
      add(:category, :string, null: false)
      add(:actor_agent_id, :binary_id)
      add(:status, :string, null: false, default: "pending")
      add(:external_repository, :string)
      add(:external_issue_number, :integer)
      add(:error_code, :string)
      add(:published_at, :utc_datetime_usec)
      add(:attempted_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:feedback_submissions, [:fingerprint]))
    create(index(:feedback_submissions, [:actor_agent_id, :inserted_at]))
    create(index(:feedback_submissions, [:inserted_at]))

    create(
      constraint(:feedback_submissions, :feedback_submissions_status_check,
        check: "status IN ('pending', 'published', 'failed')"
      )
    )

    create(
      constraint(:feedback_submissions, :feedback_submissions_published_identity_check,
        check:
          "status <> 'published' OR (external_repository IS NOT NULL AND external_issue_number IS NOT NULL)"
      )
    )
  end
end
