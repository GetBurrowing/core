defmodule Platform.Repo.Migrations.CreateMeetingCandidateEvents do
  use Ecto.Migration

  @moduledoc """
  The candidate activity log — one row per lifecycle write a candidate
  actually took (task 01a03fba).

  Stage 2 of the meeting card shows a short "thinking" log. Written into
  the template, that log is a progress bar that lies: it renders the same
  lines whether the gates ran, failed, or never fired. This table is the
  other half of the fix — the lines are rows, and a row exists only
  because a write happened.

  ## Why this is not `meeting_candidates.threading_events`

  `threading_events` is per-ATTACHMENT: it records why an utterance
  joined a card, and only that. A retraction attaches nothing, a close
  attaches nothing, a classification attaches nothing — three of the six
  things a reader most wants narrated leave no entry there. It is also a
  jsonb array on the candidate row, so it cannot be ordered against, or
  read for, the whole meeting without loading every candidate. Both
  survive; they answer different questions.

  ## Why this is not the audit log

  `Platform.Chat.TelemetryHandler` deliberately refuses to bridge the
  per-chunk classifier events into `audit_events` (per-chunk flood), so
  the audit log is already ruled out as the place this goes.

  ## No foreign keys, on purpose

  `meeting_id`, `candidate_id` and `org_id` are plain `:uuid` columns,
  exactly the call `20260827094944_create_meeting_candidates.exs` makes
  and documents for the same reason: this is a denormalized record of
  something that happened, and a deleted meeting must not cascade away
  the record that it once did.

  ## `seq` is a bigserial, and `inserted_at` is not enough

  The whole value of this table is the ORDER, and two events on one
  candidate routinely land inside the same microsecond — `close/2`
  immediately after `record_disposition/3` on the classifier's
  `close_skeleton/4` path is exactly that pair. Ordering by
  `inserted_at` would leave those two free to swap between reads, so a
  reload could show the disposition landing after the close that carried
  it. A bigserial is a strict total order the database assigns, and it
  is what both the query and the broadcast payload carry, so the live
  stream and the reloaded log sort identically.

  The primary key stays a UUIDv7 like every other table here; `seq` is
  an ordering column, not an identity.

  ## Append-only

  `updated_at` is omitted rather than defaulted. Nothing edits an event:
  a line that could be rewritten after the fact is a line a reader
  cannot trust, which is the defect this ticket exists to remove.
  """

  def change do
    create table(:meeting_candidate_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      # Strict total order, assigned by Postgres. See moduledoc.
      add(:seq, :bigserial, null: false)

      # Cross-schema pointers, NOT foreign keys — see moduledoc.
      add(:meeting_id, :uuid, null: false)
      add(:candidate_id, :uuid, null: false)
      add(:org_id, :uuid)

      # Ecto.Enum in the schema; a plain string column here, matching
      # `meeting_candidates`. Adding a kind is then a schema change
      # rather than a migration.
      add(:kind, :string, null: false)

      # Whatever the gate computed, verbatim. jsonb with a '{}' default
      # so a reader never has to distinguish "no detail" from "unknown".
      add(:detail, :map, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The card's own log: every event for one candidate, in order.
    create(index(:meeting_candidate_events, [:candidate_id, :seq]))

    # The whole meeting's rail, and the reload path for a board that
    # mounts mid-meeting.
    create(index(:meeting_candidate_events, [:meeting_id, :seq]))
  end
end
