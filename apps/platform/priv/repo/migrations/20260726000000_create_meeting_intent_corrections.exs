defmodule Platform.Repo.Migrations.CreateMeetingIntentCorrections do
  use Ecto.Migration

  @moduledoc """
  The ONE durable table task 019f70b8 introduces (stage 6).

  Everything else in the intent-queue subsystem is deliberately
  ETS-ephemeral per the standing `feedback_ets_for_ephemeral_state`
  rule — the queue is meeting-lifetime state and dies with its owning
  GenServer. This table is the deliberate exception: a correction is a
  few-shot exemplar for the classifier, and an exemplar that vanished
  when the meeting ended would teach nothing. Outliving the meeting IS
  its purpose.

  ## No foreign keys, on purpose

  `meeting_id`, `org_id`, `classified_target_agent_id`,
  `corrected_target_agent_id` and `actor_participant_id` are plain
  `:uuid` columns rather than `references/2`. The corpus is a
  denormalized training record: `transcript_chunk_excerpt` is copied in
  at write time precisely because the ETS row it came from is gone by
  the time anyone reads the corpus, and the same reasoning applies to
  the pointers. A `meetings` row being deleted must not cascade away
  the tuning signal that meeting produced, and `:nilify_all` is not
  available for a `null: false` column.

  ## `org_id` is an addition to the spec's column list

  AC16 wants few-shot exemplars scoped to the current meeting's org.
  The only path from a correction to an org otherwise is
  `meetings.project_id -> projects.org_id`, and putting that two-join
  lookup on the classifier's per-chunk hot path is the wrong trade.
  Denormalizing `org_id` at write time makes the exemplar query a
  single indexed read and matches the ADR-0042 tenancy pinning used
  elsewhere. Flagged at plan time; carried through here.

  Nullable rather than `null: false` because the write must never be
  the thing that fails: a meeting whose project/org linkage cannot be
  resolved still deserves its correction row (it is simply invisible to
  the org-scoped exemplar query until backfilled).

  ## Indexes

    * `(meeting_id, inserted_at)` — the per-meeting correction history.
    * `(org_id, inserted_at)` — `recent_exemplars/2`'s only query, which
      is `WHERE org_id = $1 ORDER BY inserted_at DESC LIMIT $2`. The
      spec asked for a bare `org_id` index; the composite serves that
      predicate strictly better and subsumes it as a prefix.
    * `(inserted_at)` — corpus-wide recency scans for the eventual
      fine-tuning export, which is not org-scoped.

  Reversible: `change/0` with `create table` + `create index` inverts to
  the matching drops.
  """

  def change do
    create table(:meeting_intent_corrections, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      # Cross-schema pointers, NOT foreign keys — see moduledoc.
      add(:meeting_id, :uuid, null: false)
      add(:org_id, :uuid)

      # Denormalized at write time: the ETS row holding this utterance is
      # reclaimed when the meeting's queue owner stops.
      add(:transcript_chunk_excerpt, :text)

      add(:classified_intent, :string, null: false)
      add(:classified_target_agent_id, :uuid)

      # Ecto.Enum in the schema; a plain string column here so adding a
      # tenth queue status later is a schema change, not a migration.
      add(:dispatch_outcome, :string)
      add(:correction, :string, null: false)

      add(:corrected_intent, :string)
      add(:corrected_target_agent_id, :uuid)
      add(:reason, :string, null: false)

      # Null for system-originated corrections (the AC14 auto-writes off
      # a rejected ack or a spawn failure), set for the stage-7 X/pencil
      # path where a human producer is the actor.
      add(:actor_participant_id, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_intent_corrections, [:meeting_id, :inserted_at]))
    create(index(:meeting_intent_corrections, [:org_id, :inserted_at]))
    create(index(:meeting_intent_corrections, [:inserted_at]))
  end
end
