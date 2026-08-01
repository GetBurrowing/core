defmodule Platform.Repo.Migrations.AddRouterDispatchedAtToMeetingTranscripts do
  use Ecto.Migration

  @moduledoc """
  Task 019f2566 stage 1 — foundation for the responsibility-router
  heartbeat + fallback path (ADR 0041 M5/M6). Stamps the moment the
  Summarizer hands a completed transcript off to the responsibility
  router so the SummarizerSweeper (stage 2) can detect dispatches that
  stalled without their agent ever picking the job up.

  Only rows in `status = 'processing'` are candidates for stall
  detection (recording is still accumulating segments, complete/failed
  are already terminal), so the observability index is partial on
  that predicate to keep it lean. Non-processing rows carry the
  timestamp harmlessly but are never scanned via this index.
  """

  def up do
    alter table(:meeting_transcripts) do
      add(:router_dispatched_at, :utc_datetime_usec, null: true)
    end

    create(
      index(:meeting_transcripts, [:router_dispatched_at],
        where: "status = 'processing'",
        name: :meeting_transcripts_router_dispatched_at_processing_index
      )
    )
  end

  def down do
    drop(
      index(:meeting_transcripts, [:router_dispatched_at],
        name: :meeting_transcripts_router_dispatched_at_processing_index
      )
    )

    alter table(:meeting_transcripts) do
      remove(:router_dispatched_at)
    end
  end
end
