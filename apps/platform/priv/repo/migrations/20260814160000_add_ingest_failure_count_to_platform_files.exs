defmodule Platform.Repo.Migrations.AddIngestFailureCountToPlatformFiles do
  @moduledoc """
  Task `01a0008b` stage 1: give a file row a durable count of CONSECUTIVE
  failed ingest attempts.

  `ingest_status` records only the latest outcome, so a row that broke once
  and a row that has broken three times on the same unchanged bytes are
  indistinguishable. A later stage withholds the repeatedly-broken ones from
  bulk retry — a fourth attempt on bytes that failed three times has no new
  information to act on — and that decision needs a number, not a boolean.

  CONSECUTIVE is the point: the counter increments on a write of `"failed"`
  and resets to `0` on a write of `"ingested"`, both inside
  `Platform.Files.update_ingest_status/2`. A re-queue (`"pending"`) does not
  touch it, so three retries that all fail reach `3`.

  Non-null with a `0` default so every existing row — including the failed
  ones this task exists to surface — starts at a known value rather than a
  NULL every reader would have to special-case. Existing failed rows begin
  at `0` rather than `1`: their prior failure predates the column and is not
  recoverable, and starting them at `0` grants one more retry, which is the
  safe direction to be wrong in.

  No index: the column is read off rows a project-scoped query has already
  loaded, never used as a filter or a sort key.
  """
  use Ecto.Migration

  def change do
    alter table(:platform_files) do
      add(:ingest_failure_count, :integer, null: false, default: 0)
    end
  end
end
