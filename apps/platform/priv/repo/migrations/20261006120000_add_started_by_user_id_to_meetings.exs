defmodule Platform.Repo.Migrations.AddStartedByUserIdToMeetings do
  @moduledoc """
  Task 01a10db7 stage 1: record WHO started a meeting.

  `Platform.Meetings.start_meeting/2` stamps it from `:started_by_user_id`
  when a user's join flips a `scheduled` meeting to `live` (MeetingLive's
  `maybe_start_meeting/1` and the native app's `NativeCall.join/2`). The
  native ringing path reads it to know who started the call.

  Nullable with no backfill: every existing row predates the column, and a
  start with no authenticated user behind it has no one to name.
  `on_delete: :nilify_all`, because `started_at` is the durable fact and the
  attribution is the nice-to-have — deleting a user must not delete meetings.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add(:started_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:meetings, [:started_by_user_id]))
  end
end
