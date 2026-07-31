defmodule Platform.Repo.Migrations.CreateFederationDeadLetters do
  @moduledoc """
  Durable ledger for federation delivery failures — task 019fa56b-ca2d stage 1.

  ## What this replaces, and why the ticket's premise was wrong

  The ticket said the dead letter "writes a row". It did not.
  `Platform.Federation.DeadLetterBuffer` was an in-process GenServer holding a
  plain list capped at 50 entries, started from `Platform.Application`, wiped on
  every BEAM restart. On 2026-07-27 there were 39 responsibility drops sharing
  that 50-entry buffer with every chat-path drop, so the day's own evidence was
  already partially self-erased by the time the audit read it — and
  podman-auto-update on moon erases the remainder on each deploy.

  Worse for replay: the recorded map was
  `%{runtime_id, agent_id, agent_slug, space_id, reason, timestamp}`. No
  payload, no responsibility_key, no trigger_kind, no subject. Replay was not
  merely unimplemented, it was *impossible* — there was nothing in a dead
  letter to replay from. This table exists to make the envelope recoverable.

  ## Why Ecto and not ETS

  Org convention prefers ETS for ephemeral, session-lifetime state. This is the
  deliberate exception: (a) the whole point is surviving a core restart, since a
  runtime can be offline across one; (b) the cumulative loss measure stage 4
  adds must not reset when the BEAM does — that is precisely the snapshot
  failure this ticket exists to correct. The cleanup obligation Ecto creates is
  discharged explicitly by `DeadLetters.prune/1` plus stage 3's periodic timer,
  which only ever delete TERMINAL rows.

  ## Column notes

  `runtime_id` is the PRESENCE TOKEN (`agent_runtimes.runtime_id`), not the
  primary key. It is the key `RuntimePresence.online?/1` and the `runtime:<id>`
  topic use; storing the pk here instead would make every replay lookup miss.
  `runtime_pk` carries the `agent_runtimes.id` FK separately, for joins and UI
  only. No FK constraint on `agent_id` / `space_id` either: a dead letter is
  forensic evidence and must outlive the deletion of the thing it is about.

  `source` distinguishes the two producers that write this ledger —
  `"system_event"` (responsibility fires, the subject of this ticket) and
  `"chat"` (mentions/DMs). Only one of them is replayable, and a ledger that
  cannot tell them apart cannot support the per-source policy stage 2 adds.

  `payload` is the load-bearing column: the exact envelope that failed to
  broadcast, `%{signal: build_system_event_signal(agent, context)}`. Nullable
  because chat rows deliberately store none — the chat envelope is DERIVED
  (ContextPlane bundle + 12-message history + live tool surface) and replaying a
  stale bundle is worse than not replaying at all.

  ## The partial unique index

  `(runtime_id, responsibility_key, subject_id) WHERE disposition = 'pending'
  AND subject_id IS NOT NULL` — two pending fires about the same stage must not
  queue twice, while cron rows (which have no subject) must not collide with
  each other. Restricting to `pending` is what lets a subject be dead-lettered
  again later after an earlier fire was already replayed or dropped; a
  full-table unique index would silently swallow the second loss.
  """
  use Ecto.Migration

  def change do
    create table(:federation_dead_letters, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:runtime_id, :string, null: false)
      add(:runtime_pk, :binary_id)
      add(:agent_id, :binary_id)
      add(:agent_slug, :string)
      add(:space_id, :binary_id)

      add(:source, :string, null: false)
      add(:responsibility_key, :string)
      add(:feature, :string)
      add(:trigger_kind, :string)

      add(:subject_type, :string)
      add(:subject_id, :binary_id)

      add(:payload, :map)

      add(:reason, :string)
      add(:disposition, :string, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:dispositioned_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:federation_dead_letters, [:runtime_id, :disposition, :occurred_at]))
    create(index(:federation_dead_letters, [:responsibility_key, :disposition]))

    create(
      unique_index(
        :federation_dead_letters,
        [:runtime_id, :responsibility_key, :subject_id],
        where: "disposition = 'pending' AND subject_id IS NOT NULL",
        name: :federation_dead_letters_pending_subject_index
      )
    )
  end
end
