defmodule Platform.Repo.Migrations.CreateMeetingCandidates do
  use Ecto.Migration

  @moduledoc """
  The durable candidate-lifecycle store (task 01a03fb8 stage 1).

  A "candidate" is one thing a meeting produced that might become work:
  heard in the transcript, thought about by the classifier, shaped into
  a task or an artifact, acted on, and eventually closed. The intent
  queue already tracks that arc — but as meeting-lifetime ETS state that
  dies with its owning GenServer, per the standing
  `feedback_ets_for_ephemeral_state` rule. This table is the deliberate
  exception, for the same reason `meeting_intent_corrections` is: the
  question this ticket exists to answer ("how many candidates did we
  accept vs reject, by kind, for this org") is a question about meetings
  that have already ended. An answer that vanished with the meeting
  would be no answer at all.

  ## No foreign keys, on purpose

  `meeting_id`, `org_id`, `room_id`, `intent_id`, `transcript_chunk_id`,
  `assigned_agent_id`, `task_id` and `canvas_id` are plain `:uuid`
  columns rather than `references/2` — exactly the call
  `20260726000000_create_meeting_intent_corrections.exs` makes and
  documents. A candidate row is a denormalized measurement record. A
  deleted meeting (or task, or canvas) must not cascade away the record
  that it once existed, and `:nilify_all` is not available for a
  `null: false` column. `evidence_quote` is copied in at write time for
  the same reason the corrections table copies
  `transcript_chunk_excerpt`: the ETS row carrying the utterance is
  reclaimed when the meeting's queue owner stops, so by the time anyone
  reads this table the original is gone.

  ## `intent_id` is the idempotence key

  `intent_id` is the ETS row id from
  `Platform.Meetings.IntentQueue.Server` (a UUIDv7, the ETS key). The
  stage-3 mirror writes one candidate per queue row and must be safe to
  re-run against a queue it has already seen, so the column carries a
  UNIQUE index and the mirror upserts on it.

  ## `transcript_chunk_id` is both scalar and array

  The ticket asks for "source segment reference(s)". A candidate
  accretes evidence: the utterance that created it, then later segments
  that elaborate it. `transcript_chunk_id` holds the originating segment
  (stable, the thing the card cites); `transcript_chunk_ids` accumulates
  the rest.

  ## `queue_status` alongside `state`

  `state` is the coarse five-value lifecycle the board renders. It
  cannot distinguish `:timed_out` from `:dispatch_failed` from
  `:no_ack_spawn_failed` — all three are simply "closed". Keeping the
  raw nine-value `IntentQueue` status the mirror last saw means a
  measurement query can still tell those apart without re-deriving them
  from a queue that no longer exists.

  ## Enums are plain strings

  Every enum column (`state`, `outcome_kind`, `closed_reason`,
  `disposition`, `queue_status`, `classified_intent`, `target_role`) is
  a `:string` here with `Ecto.Enum` in the schema — the same call the
  corrections migration makes, so adding a value later is a schema
  change rather than a migration.

  ## Indexes

    * UNIQUE `(intent_id)` — the stage-3 mirror's idempotence key.
    * `(meeting_id, inserted_at)` — the per-meeting candidate board.
    * `(org_id, inserted_at)` — org-scoped recency.
    * `(org_id, outcome_kind, disposition)` — the measurement query
      ("accepted vs rejected, by kind, for this org") is the whole
      reason this ticket exists, so it gets its own index rather than a
      seq scan over a table that only grows.

  Reversible: `change/0` with `create table` + `create index` inverts to
  the matching drops.
  """

  def change do
    create table(:meeting_candidates, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      # Cross-schema pointers, NOT foreign keys — see moduledoc.
      add(:meeting_id, :uuid, null: false)
      add(:org_id, :uuid)
      add(:room_id, :uuid)

      # The ETS row id from IntentQueue.Server — stage 3's idempotence key.
      add(:intent_id, :uuid)

      add(:transcript_chunk_id, :uuid)
      add(:transcript_chunk_ids, {:array, :uuid}, default: [])

      # Denormalized at write time: the ETS row holding this utterance is
      # reclaimed when the meeting's queue owner stops.
      add(:evidence_quote, :text)

      # Ecto.Enum in the schema; plain string columns here.
      add(:state, :string, null: false, default: "heard")
      add(:outcome_kind, :string, null: false, default: "task")

      add(:assigned_agent_id, :uuid)
      add(:assigned_agent_slug, :string)
      add(:target_role, :string)

      add(:task_id, :uuid)
      add(:canvas_id, :uuid)

      add(:closed_reason, :string)
      add(:closed_note, :text)
      add(:closed_at, :utc_datetime_usec)

      add(:classified_intent, :string)
      add(:classifier_confidence, :float)
      add(:classifier_model, :string)

      add(:disposition, :string)
      add(:disposition_at, :utc_datetime_usec)

      # The raw nine-value queue status the mirror last saw — see moduledoc.
      add(:queue_status, :string)

      add(:heard_at, :utc_datetime_usec)
      add(:dispatched_at, :utc_datetime_usec)
      add(:acted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_candidates, [:intent_id]))
    create(index(:meeting_candidates, [:meeting_id, :inserted_at]))
    create(index(:meeting_candidates, [:org_id, :inserted_at]))
    create(index(:meeting_candidates, [:org_id, :outcome_kind, :disposition]))
  end
end
