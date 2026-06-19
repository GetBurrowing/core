defmodule Platform.Repo.Migrations.AddIngestStatusAndChunksToPlatformFiles do
  @moduledoc """
  ADR 0042 — Stage 3 of the files pipeline.

  Adds the bookkeeping needed by `Platform.Files.Ingester`:

    * `platform_files.ingest_status` — `:pending | :ingested | :failed`
      (stored as a string + check constraint, mirroring the convention
      used by `Platform.Tasks.Task.status`). The ingester writes
      `:ingested` after the memory-service round-trip succeeds, or
      `:failed` when extraction errors. Dedup keys on this column —
      we only short-circuit when a prior row for the same content hash
      is in `:ingested`.

    * `platform_file_chunks` — back-reference table linking a file to the
      `chunk_external_id`s it produced in the memory-service. The
      content-hash dedup path copies these rows from the prior file so
      both rows resolve to the same vector chunks without a second
      embed round-trip. `page` is nullable; only paginated formats
      (PDF, GDoc) populate it.
  """

  use Ecto.Migration

  def change do
    alter table(:platform_files) do
      add(:ingest_status, :string, null: false, default: "pending")
    end

    create(
      constraint(
        :platform_files,
        :platform_files_ingest_status_check,
        check: "ingest_status IN ('pending', 'ingested', 'failed')"
      )
    )

    create(index(:platform_files, [:ingest_status]))

    create table(:platform_file_chunks, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :file_id,
        references(:platform_files, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:chunk_external_id, :string, null: false)
      add(:page, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:platform_file_chunks, [:file_id]))
    create(unique_index(:platform_file_chunks, [:file_id, :chunk_external_id]))
  end
end
