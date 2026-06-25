defmodule Platform.Repo.Migrations.AllowNullContentHashForPendingFiles do
  @moduledoc """
  ADR 0042 — Stage 3 of the Files MCP surface.

  The `file_add` MCP tool's presigned-upload branch reserves a
  `platform_files` row BEFORE bytes hit the object store, so the row's
  `content_hash` cannot be known at insert time. Today the schema's
  changeset requires `content_hash` (and the column itself is `NOT NULL`
  in `20260619025255_create_platform_files`).

  This migration:

    * Relaxes the column to allow NULL.
    * Adds a check constraint enforcing the contract that ONLY
      `ingest_status = 'pending'` rows may have NULL `content_hash`.
      Once a row flips to `'ingested'` or `'failed'` it must carry a
      non-null hash — preserving the post-upload invariant the rest of
      the pipeline (dedup, embed copy) relies on.

  Existing rows all have ingest_status `'pending'`, `'ingested'`, or
  `'failed'` AND a non-null `content_hash`, so the check constraint is
  forward-compatible — no row data needs updating.
  """

  use Ecto.Migration

  def up do
    alter table(:platform_files) do
      modify(:content_hash, :string, null: true)
    end

    create(
      constraint(
        :platform_files,
        :platform_files_content_hash_required_when_finalized_check,
        check: "content_hash IS NOT NULL OR ingest_status = 'pending'"
      )
    )
  end

  def down do
    drop(
      constraint(
        :platform_files,
        :platform_files_content_hash_required_when_finalized_check
      )
    )

    alter table(:platform_files) do
      modify(:content_hash, :string, null: false)
    end
  end
end
