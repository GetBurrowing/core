defmodule Platform.Repo.Migrations.AddFailureReasonToMeetingTranscripts do
  @moduledoc """
  Task 019ff6f3 stage 3 — give a failed transcript a reason.

  `Platform.Meetings.fail_transcript/1` set `status: "failed"` and threw
  the reason away; the caller only `Logger.error`ed it. A failed row was
  therefore mute on every surface a human can reach, which is how a
  populated transcript ended at `failed` with a NULL summary and nothing
  anywhere explaining why.

  Nullable on purpose: every historical row predates the column and no
  backfill can invent a reason it never recorded. NULL means "we did not
  capture one", not "there was none".
  """
  use Ecto.Migration

  def change do
    alter table(:meeting_transcripts) do
      # size: 500 matches the byte cap `Meetings.fail_transcript/3`
      # applies. Ecto's bare `:string` is varchar(255), which an
      # `inspect/1`ed exception overruns — and a write that raises on a
      # FAILURE path takes the failure with it, which is the exact
      # silence this column exists to end.
      add(:failure_reason, :string, size: 500, null: true)
    end
  end
end
