defmodule Platform.Repo.Migrations.AddCreatedByUserIdToMeetings do
  @moduledoc """
  Task 01a19e7f stage 1: record WHO scheduled a meeting, the organizer.

  `Platform.Meetings.can_cancel_meeting?/2` lets the creator call a meeting
  off. Without this column a meeting created from the Calendar/Meetings
  scheduling sheet, which has no host, could be cancelled only by an admin.

  Nullable with no backfill: no existing row records its creator. For those
  rows the cancel rule falls back to host or admin. `on_delete: :nilify_all`,
  because the meeting is the durable fact and the attribution is the
  nice-to-have: deleting a user must not delete meetings.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add(:created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:meetings, [:created_by_user_id]))
  end
end
