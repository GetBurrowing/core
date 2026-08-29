defmodule Platform.Repo.Migrations.AddThreadingColumnsToMeetingCandidates do
  use Ecto.Migration

  @moduledoc """
  Somewhere to record a threading decision (task 01a03fb9 stage 1).

  Threading asks a question of an incoming utterance — "is this the same
  person continuing the thing they just said?" — and `meeting_candidates`
  today cannot answer either half of it. Verified on 2026-08-28 that
  `Platform.Meetings.MeetingCandidate.__schema__(:fields)` carries no
  `speaker` and no `last_utterance_at` (positive control on the same
  call: `:evidence_quote` and `:transcript_chunk_ids` ARE present). The
  accretion slot `transcript_chunk_ids` exists and is written by nothing
  in production. So this migration is the precondition for every later
  stage, and it is deliberately schema-only: no threading happens yet.

  ## `speaker` is a plain string, and nil means unknown

  `Platform.Meetings.IntentClassifier.segment_speaker/2` answers `""`
  when a transcript segment carries no attribution. That empty string is
  normalised to nil on the way in (see `IntentQueue.Server.mirror_enqueue/3`)
  precisely BECAUSE of what stage 3 will do with this column: a
  same-speaker test on two unattributed utterances would read `"" == ""`
  as "the same person" and thread two strangers together. nil is the
  value that cannot accidentally match itself.

  No foreign key to a participant, matching every other pointer on this
  table (see `20260827094944_create_meeting_candidates.exs`): a speaker
  label is what the transcript said, denormalised at write time, not a
  live reference.

  ## `last_utterance_at` is distinct from `heard_at`

  `heard_at` stamps when the candidate FIRST appeared and never moves —
  it is what the board sorts by. `last_utterance_at` moves every time an
  utterance attaches, and it is what a time-window threading rule reads.
  Collapsing the two would make the window measure the wrong thing the
  moment threading starts working: a candidate that has been accreting
  for a minute would look a minute stale. They start equal at enqueue and
  diverge from the first attachment onward.

  ## `threading_events` is a jsonb ARRAY, not a jsonb object

  Column type `:map` (jsonb) with `{:array, :map}` in the schema, exactly
  the pairing `tasks.dependencies` and `stages.expected_artifacts` use
  (`20260320120000_create_tasks_tables.exs`). It is an append-only log of
  why each attachment happened, one entry per threading decision, because
  the failure mode this ticket calls invisible — attaching an utterance
  to the WRONG candidate — is only diagnosable after the fact if the
  reason that fired was recorded alongside the result. A single "threaded:
  true" boolean would record that a decision happened and lose which rule
  made it.

  `null: false` with a `'[]'::jsonb` default so a reader never has to
  distinguish "no threading events" from "unknown", which is the same
  call `transcript_chunk_ids` made.

  Reversible: `add/3` inverts to `remove/1` under `change/0`. No backfill
  — existing rows get nil `speaker`/`last_utterance_at` and an empty
  event log, which is the truthful reading of a candidate created before
  anything recorded these.
  """

  def change do
    alter table(:meeting_candidates) do
      # The transcript's attribution for the utterance that created this
      # candidate. nil = unattributed; see moduledoc.
      add(:speaker, :string)

      # Moves as utterances attach; `heard_at` does not. See moduledoc.
      add(:last_utterance_at, :utc_datetime_usec)

      # Append-only log of threading decisions. jsonb array — see moduledoc.
      add(:threading_events, :map, null: false, default: fragment("'[]'::jsonb"))
    end
  end
end
