defmodule Platform.Repo.Migrations.AddCancellationToMeetings do
  use Ecto.Migration

  @moduledoc """
  Task `019fb954-c848`: give a meeting a way to be called off.

  `meetings.status` is `scheduled | live | ended`, and
  `Meeting.status_changeset/3` admits exactly `scheduled -> live` and
  `live -> ended`. Nothing under `lib/platform/meetings/` writes a
  cancellation, so a meeting that is not going to happen has only two
  representations available to it: stay `scheduled` forever, or be deleted.
  The first lies to every reader (a calendar keeps placing it, the archive
  keeps listing it as upcoming); the second destroys the transcript,
  recordings and invite rows hanging off the row.

  ## Why a status plus a timestamp, not just a status

  `status` answers "is it cancelled"; `cancelled_at` answers "when did that
  become true", which is the ordering key the archive needs and the value a
  notice quotes. The pair mirrors the `started_at` / `ended_at` actuals
  already on the row rather than inventing a second convention.

  ## Why `cancelled_by_participant_id`

  Calling off other people's meeting is an accountable act, so the row
  records who did it. It references `chat_participants` — the same table
  `host_participant_id` points at — because the actor is always a
  participant of the meeting's backing space, and because
  `Platform.Chat.Participant` declares `@participant_types ~w(user agent)`,
  which is exactly the set of actors that can cancel. `on_delete:
  :nilify_all`: losing the actor row must not take the cancellation record
  with it. The cancellation is the durable fact; the attribution is the
  nice-to-have.

  ## Why `cancellation_notified_at`

  The archive states "attendees were notified" as a fact. That claim needs
  something to be true of, and it needs to survive a retry: the notifier
  claims the right to fan out with a compare-and-swap
  (`UPDATE ... WHERE id = ? AND cancellation_notified_at IS NULL`), exactly
  as `notified_at` already does for `:meeting_started`. A separate column
  rather than reusing `notified_at` because a meeting can legitimately be
  both started-and-notified and later cancelled-and-notified; one column
  cannot carry both stamps.

  ## NULLable, no default, no backfill

  All three columns are NULL for every existing row and that is the correct
  reading: nothing has ever been cancelled, so there is no historical
  cancellation to reconstruct. `status` stays authoritative — NULL
  `cancelled_at` and `status != "cancelled"` are the same statement.
  """

  def change do
    alter table(:meetings) do
      add(:cancelled_at, :utc_datetime_usec)

      add(
        :cancelled_by_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all)
      )

      add(:cancellation_notified_at, :utc_datetime_usec)
    end
  end
end
