defmodule Platform.Repo.Migrations.ReleaseRouterClaimOnFailedTranscripts do
  use Ecto.Migration

  @moduledoc """
  Task 01a0826f stage 4 — release router claims stranded on transcripts
  that already reached `failed`.

  `Meetings.fail_transcript/3` now clears `router_dispatched_at` when a
  transcript fails (stage 1), but that only helps rows that fail *after*
  this deploys. Every row already sitting at `status = 'failed'` with a
  non-NULL `router_dispatched_at` still carries a claim nobody holds, and
  the retry path refuses to re-dispatch a claimed row — so those rows are
  permanently un-retryable. That includes the production row that
  motivated the ticket: transcript 01a0626d-0fe3-7001-99c1-c2f8b75b932c
  (2026-09-02 SXI client workshop), failed with
  `{:llm_failed, %Req.TransportError{reason: :timeout}}`.

  The UPDATE touches only terminal-failed rows, so it cannot disturb a
  live `processing` dispatch, and it is idempotent: a re-run matches zero
  rows.

  Irreversible by design. The cleared timestamps carry no information a
  rollback needs — they record a dispatch that already ended in failure —
  and re-stamping them would simply re-strand the rows this migration
  exists to free. `down` is therefore a no-op.
  """

  def up do
    execute("""
    UPDATE meeting_transcripts
       SET router_dispatched_at = NULL
     WHERE status = 'failed'
       AND router_dispatched_at IS NOT NULL
    """)
  end

  def down do
    execute("SELECT 1")
  end
end
