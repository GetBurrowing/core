defmodule Platform.Repo.Migrations.AddIngestFailureReasonToPlatformFiles do
  @moduledoc """
  Task `01a0166d` stage 1: give a failed file row a durable, readable REASON.

  `ingest_status` says a file broke and `ingest_failure_count` says how many
  times, but neither says WHAT broke — so a reader looking at a failed row
  has no next action, which is the defect this task exists to remove.

  TWO COLUMNS, NOT ONE BLOB:

    * `ingest_failure_stage` — the machine-readable category, one of
      `"extract"` / `"embed"` / `"storage"`.
    * `ingest_failure_detail` — the verbatim machine tail, e.g.
      `connect timed out after 5000ms`.

  Extraction, embedding and storage failures need OPPOSITE responses from a
  reader (re-export the document vs. wait for the backend vs. fix the
  store), so they have to be distinguishable by a reader AND by a test. A
  single free-text string forces every consumer to parse prose back into a
  category, which is not a thing a query or an assertion can do reliably.

  NULLABLE WITH NO DEFAULT, unlike `ingest_failure_count` (non-null `0`).
  Here nil is a real, meaningful state — "this row has no recorded reason" —
  rather than a value every reader must special-case away.

  NO BACKFILL. The already-failed rows that predate these columns have no
  recoverable reason, and inventing one would be worse than nil: a fabricated
  reason reads exactly like a real one. nil-means-legacy is accepted and is
  load-bearing — a later stage renders nil as the literal copy
  `Reason not recorded` rather than as a blank strip, because a blank strip
  on a failed row recreates the very defect being fixed.

  No index: these columns are read off rows a project-scoped query has
  already loaded, never used as a filter or a sort key.
  """
  use Ecto.Migration

  def change do
    alter table(:platform_files) do
      add(:ingest_failure_stage, :string)
      add(:ingest_failure_detail, :text)
    end
  end
end
