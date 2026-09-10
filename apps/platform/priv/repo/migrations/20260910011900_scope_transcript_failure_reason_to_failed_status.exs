defmodule Platform.Repo.Migrations.ScopeTranscriptFailureReasonToFailedStatus do
  @moduledoc """
  Task 01a089b3-7f84 stage 3 — make "a complete transcript carrying a failure
  reason" unrepresentable in the database rather than merely unlikely.

  `meeting_transcripts.failure_reason` is a one-slot latch describing why a row
  is CURRENTLY failed. Task 01a089b3-7f84 stage 2 fixed the writer
  (`Platform.Meetings.complete_transcript/2` now clears the column on success);
  this migration closes the state off structurally, so that
  `where: not is_nil(t.failure_reason)` can never again report a healthy
  transcript as broken. A rename of the column to `last_failure_reason` was
  considered and REJECTED: it leaves the identical wrong row set behind the
  identical query.

  ## The backfill erases text, deliberately

  The `UPDATE` below nulls `failure_reason` on rows that are already
  `complete`. On production that is exactly one row
  (`room_id = "space-019db5f7-9ff5-70c7-b678-54a4d15d1573"`, 668 segments,
  completed 2026-09-10 00:24:53) carrying
  `{:llm_failed, %Req.TransportError{reason: :timeout}}`.

  Three things a future reader needs, in order:

    1. The erasure is a DELIBERATE DECISION, not a side effect of adding the
       constraint. The value describes a failure the row has since recovered
       from; keeping it is what caused the bug.
    2. The deleted text is preserved in the ticket body for task 01a089b3-7f84
       and, going forward, in `audit_events` with
       `event_type = "platform.meetings.transcription_failed"` (task
       01a089b3-7f84 stage 1), which is multi-valued and therefore a real
       history rather than a latch.
    3. THIS SPECIFIC PRODUCTION ROW PREDATES STAGE 1, so NO audit row exists
       for it. Do not go looking for one. Its only surviving copy is the
       ticket body and this moduledoc.

  ## Scope

  The constraint is scoped to `complete` ONLY. `recording` and `processing`
  carry no such invariant and are deliberately left alone. `down` drops the
  constraint and does not attempt to restore the erased reason — that text is
  not recoverable from the database.
  """

  use Ecto.Migration

  def up do
    # BACKFILL FIRST: the constraint below is validated against existing rows,
    # so any surviving offender would abort the migration.
    execute("""
    UPDATE meeting_transcripts
       SET failure_reason = NULL
     WHERE status = 'complete'
       AND failure_reason IS NOT NULL
    """)

    create(
      constraint(:meeting_transcripts, :meeting_transcripts_no_reason_when_complete,
        check: "status <> 'complete' OR failure_reason IS NULL"
      )
    )
  end

  def down do
    drop(
      constraint(:meeting_transcripts, :meeting_transcripts_no_reason_when_complete)
    )
  end
end
