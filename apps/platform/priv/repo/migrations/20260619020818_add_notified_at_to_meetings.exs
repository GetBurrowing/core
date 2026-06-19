defmodule Platform.Repo.Migrations.AddNotifiedAtToMeetings do
  use Ecto.Migration

  # Task 019edbc1 stage 3: race-defense for double-notification on
  # `:meeting_started`. `Meetings.mark_notified/1` performs an atomic
  # compare-and-swap against this column (`WHERE id = ? AND notified_at
  # IS NULL`) so two simultaneous `start_meeting/1` calls (e.g. the
  # `:auto_join` path firing for two clients within ms) result in
  # exactly one push fan-out.
  #
  # Nullable + no default — pre-existing meetings remain NULL and become
  # notifiable; the column is only stamped the first time the notifier
  # actually fires for that meeting.

  def up do
    alter table(:meetings) do
      add(:notified_at, :utc_datetime_usec, null: true)
    end
  end

  def down do
    alter table(:meetings) do
      remove(:notified_at)
    end
  end
end
