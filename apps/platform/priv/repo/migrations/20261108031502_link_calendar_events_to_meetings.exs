defmodule Platform.Repo.Migrations.LinkCalendarEventsToMeetings do
  @moduledoc """
  Task 01a1b8a5 stage 1 (one event draft for native events and calls).

    * `meetings.call_enabled` — whether the call record still offers a call.
      NOT NULL DEFAULT true, so every existing meeting keeps its call (the
      backward mapping: existing meetings are ON). Turning it off keeps the
      row, its id, slug, chat space and every invite and guest link.
    * `calendar_events.meeting_id` — the one call record a native event is
      backed by. UNIQUE where set, so a meeting is linked from at most one
      native event and each logical event projects exactly once. NILIFY on
      delete: meetings are soft-deleted, a hard delete must not take the
      calendar entry with it. Unlinked native events are the old plain
      events (call OFF).
    * `calendar_events.preset` — `event`, `focus` or `ooo`. Every existing
      row is an ordinary `event`. Focus time and Out of office are
      availability-blocking native events with no call.

  These are durable columns, not parallel-UI shims, so they carry no
  `parallel-ui:` comment. Raw `alter` only.
  """
  use Ecto.Migration

  # old-code-compatible: purely additive. The previous release never writes
  # `calendar_events.meeting_id` (so the partial unique index sees only NULLs
  # from it) and never writes `preset` (its default satisfies the check).

  def change do
    alter table(:meetings) do
      add(:call_enabled, :boolean, null: false, default: true)
    end

    alter table(:calendar_events) do
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))
      add(:preset, :string, null: false, default: "event")
    end

    create(
      unique_index(:calendar_events, [:meeting_id],
        name: :calendar_events_meeting_id_index,
        where: "meeting_id IS NOT NULL"
      )
    )

    create(
      constraint(:calendar_events, :calendar_events_preset,
        check: "preset IN ('event', 'focus', 'ooo')"
      )
    )
  end
end
