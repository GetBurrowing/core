defmodule Platform.Repo.Migrations.CreateFeedbackInbox do
  @moduledoc """
  Task `01a1b678-8bb4-7000-96d2-c691eb9b13b5`, stage 4: the broker host's
  feedback inbox, and the reporting install's shipped-notice bookkeeping.

    * `feedback_inbox_requests`: one row per fingerprint the broker created
      or deduped. `title` is the sanitized title, the same text the public
      issue already carries. `shipped_at` is set when the issue closes as
      completed.
    * `feedback_inbox_installs`: one row per (fingerprint, sharing install
      id), so the inbox counts distinct installs. The id is the random
      sharing id, linked to no account.
    * `feedback_submissions.shipped_notified_at` and `notice_space_id`: the
      reporting install's own rows. When the notice was posted, and the space
      an agent filed from.
  """

  use Ecto.Migration

  def change do
    create table(:feedback_inbox_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:fingerprint, :string, size: 64, null: false)
      add(:title, :string)
      add(:external_repository, :string)
      add(:external_issue_number, :integer)
      add(:shipped_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:feedback_inbox_requests, [:fingerprint]))
    create(index(:feedback_inbox_requests, [:external_repository, :external_issue_number]))

    create table(:feedback_inbox_installs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:fingerprint, :string, size: 64, null: false)
      add(:sharing_install_id, :uuid, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:feedback_inbox_installs, [:fingerprint, :sharing_install_id],
        name: :feedback_inbox_installs_fingerprint_install_index
      )
    )

    alter table(:feedback_submissions) do
      add(:shipped_notified_at, :utc_datetime_usec)
      add(:notice_space_id, :binary_id)
    end
  end
end
