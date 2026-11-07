defmodule Platform.Repo.Migrations.CreateUnblockAsks do
  @moduledoc """
  Create `unblock_asks` (task 01a1b6de stage 4).

  One row is one ask the lead agent puts to the one human who can unstick a
  subject: an agent blocked by a classified cause (`Platform.Agents.TeamCheck`)
  or a person stuck on setup steps (`Platform.Onboarding.PersonSetup`). The
  `agent_unblock_ask` Inbox row points at it (`source_type: "unblock_ask"`).

  The partial unique index keeps ONE live (not resolved) ask per subject and
  class, so a repeated check updates or re-asks the existing row instead of
  filing a second one. `state_fingerprint` is the classified state the ask was
  written for; a re-ask needs it unchanged and the interval elapsed.
  """

  use Ecto.Migration

  def change do
    create table(:unblock_asks, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:subject_type, :string, null: false)
      add(:subject_id, :binary_id, null: false)
      add(:class, :string, null: false)
      add(:state_fingerprint, :string, null: false)

      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:status, :string, null: false, default: "open")
      add(:evidence, :text)
      add(:details, :map, null: false, default: %{})
      add(:still_missing, :text)
      add(:variant, :string)
      add(:reask_after_hours, :integer)
      add(:ask_count, :integer, null: false, default: 1)
      add(:asked_at, :utc_datetime_usec, null: false)
      add(:last_asked_at, :utc_datetime_usec, null: false)
      add(:checked_at, :utc_datetime_usec)
      add(:resolved_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:unblock_asks, :unblock_asks_subject_type_check,
        check: "subject_type IN ('agent', 'person')"
      )
    )

    create(
      constraint(:unblock_asks, :unblock_asks_status_check,
        check: "status IN ('open', 'verifying', 'resolved', 'dismissed')"
      )
    )

    create(
      unique_index(:unblock_asks, [:subject_type, :subject_id, :class],
        where: "status <> 'resolved'",
        name: :unblock_asks_live_subject_class_index
      )
    )

    create(index(:unblock_asks, [:owner_user_id, :status]))
    create(index(:unblock_asks, [:variant]))
  end
end
