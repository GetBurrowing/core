defmodule Platform.Repo.Migrations.AddIntentMutedAtToMeetings do
  use Ecto.Migration

  @moduledoc """
  Task 019fbaac stage 1: per-meeting mute for the intent classifier.

  Adds `meetings.intent_muted_at` so a human in a live meeting can tell
  the Meeting Producer to stop acting on classified intent for THIS
  meeting only, without unassigning the org-wide `meeting_producer`
  role. `Platform.Meetings.set_intent_muted/2` stamps this column and
  `intent_muted?/1` reads it; the classifier consults it before it
  spends a model call.

  Nullable + no default — NULL means "not muted", which is the correct
  state for every meeting that already exists and for every meeting
  created after this lands. There is deliberately no boolean: the
  timestamp records WHEN the hold was placed, which is what an operator
  wants when they return to a meeting and find the agents quiet.

  Why a column on `meetings` rather than `meeting_rooms.config`: that
  map is keyed per chat SPACE (`unique_index(:meeting_rooms,
  [:space_id])`), so a mute set in Monday's standup would still be on
  next Monday's, with nothing on screen to explain it. The mute is a
  property of THIS meeting.
  """

  def up do
    alter table(:meetings) do
      add(:intent_muted_at, :utc_datetime_usec, null: true)
    end
  end

  def down do
    alter table(:meetings) do
      remove(:intent_muted_at)
    end
  end
end
