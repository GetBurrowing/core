defmodule Platform.Repo.Migrations.CreateMeetingRings do
  @moduledoc """
  Task 01a10db7 stage 2: one row per ring (a PushKit VoIP push that the iOS
  app reports to CallKit as an incoming call).

  `trigger` says why the ring happened: `meeting_started` (an invitee of a
  meeting that just started) or `live_invite` (invited into a meeting that is
  already live). The unique index on `(meeting_id, user_id, trigger)` is the
  idempotency key: `Platform.Meetings.Ringing` inserts with
  `on_conflict: :nothing` and rings only when a row was actually written, so
  a re-broadcast of `{:meeting_started, _}` or a repeated invite can never
  ring the same person twice for the same reason.

  `inviter_user_id` is who the ring is reported back to on decline/missed.
  Nilified, not cascaded: the ring outlives the attribution.
  """
  use Ecto.Migration

  def change do
    create table(:meeting_rings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:inviter_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:trigger, :text, null: false)
      add(:state, :text, null: false, default: "ringing")
      add(:answered_at, :utc_datetime_usec)
      add(:declined_at, :utc_datetime_usec)
      add(:missed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_rings, [:meeting_id, :user_id, :trigger]))
    create(index(:meeting_rings, [:user_id]))

    create(
      constraint(:meeting_rings, :meeting_rings_trigger_check,
        check: "trigger IN ('meeting_started', 'live_invite')"
      )
    )

    create(
      constraint(:meeting_rings, :meeting_rings_state_check,
        check: "state IN ('ringing', 'answered', 'declined', 'missed', 'cancelled')"
      )
    )
  end
end
