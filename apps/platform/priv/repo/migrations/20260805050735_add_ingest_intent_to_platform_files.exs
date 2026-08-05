defmodule Platform.Repo.Migrations.AddIngestIntentToPlatformFiles do
  @moduledoc """
  Task 019fd02d — dual-audience files, stage 1 (schema only).

  Separates *what we meant to do with a file* from *what happened to it*.

    * `platform_files.ingest_intent` — `attempt | human_only`. NOT NULL with
      default `'attempt'`. A nullable intent recreates exactly the ambiguity
      this column exists to remove and forces every insert site to remember,
      so the column is deliberately non-nullable.

    * `platform_files.ingest_status` gains `not_attempted` — the terminal
      status for a `human_only` file. The existing values
      (`pending`/`ingested`/`failed`) are unchanged; the check constraint is
      dropped and re-created because Postgres has no ALTER CONSTRAINT for a
      CHECK expression.

  ## Backfill mapping

  The backfill IS the column default. Every pre-existing row was attempted,
  so `attempt` is correct for all of them — including rows sitting in
  `ingest_status = 'failed'`, which were attempted and failed rather than
  never attempted. `ingest_status` is left untouched for every existing row,
  and no row is retro-assigned `human_only`: nobody expressed that intent.
  """

  use Ecto.Migration

  # Explicit up/down rather than `change/0`: dropping a CHECK constraint is
  # not auto-reversible (Ecto cannot know the expression to restore).
  def up do
    alter table(:platform_files) do
      add(:ingest_intent, :string, null: false, default: "attempt")
    end

    create(
      constraint(
        :platform_files,
        :platform_files_ingest_intent_check,
        check: "ingest_intent IN ('attempt', 'human_only')"
      )
    )

    create(index(:platform_files, [:ingest_intent]))

    drop(constraint(:platform_files, :platform_files_ingest_status_check))

    create(
      constraint(
        :platform_files,
        :platform_files_ingest_status_check,
        check: "ingest_status IN ('pending', 'ingested', 'failed', 'not_attempted')"
      )
    )
  end

  def down do
    drop(constraint(:platform_files, :platform_files_ingest_status_check))

    create(
      constraint(
        :platform_files,
        :platform_files_ingest_status_check,
        check: "ingest_status IN ('pending', 'ingested', 'failed')"
      )
    )

    drop(index(:platform_files, [:ingest_intent]))
    drop(constraint(:platform_files, :platform_files_ingest_intent_check))

    alter table(:platform_files) do
      remove(:ingest_intent)
    end
  end
end
