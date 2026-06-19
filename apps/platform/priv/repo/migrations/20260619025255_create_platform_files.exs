defmodule Platform.Repo.Migrations.CreatePlatformFiles do
  @moduledoc """
  ADR 0042 — Centralized, vectorized document/file store (Stage 1).

  Creates the project-scoped `platform_files` table that backs the new
  /files surface and the upcoming Platform.Files.* extractor + ingester
  pipeline.

  ## Scoping

  Files are first-class at the project layer. Per ADR 0042:

    * `project_id` is REQUIRED and FK-cascades on project delete (a project
      owns its files; nuking the project nukes the files).
    * `org_id` is NULLABLE and FK-restricts on org delete. It is populated
      only for files that span multiple projects within a tenant (rare;
      Stage 1 just makes the column available). Default null keeps the
      column out of the way for the common per-project case.
    * `uploaded_by_user_id` nilifies on user delete — we keep the file
      historically even if the uploader leaves.

  ## Indexes

    * `(project_id, inserted_at DESC)` — primary list-view ordering.
    * UNIQUE `(content_hash, project_id)` — dedup within a project; the
      same bytes uploaded twice to one project collapse to one row.
      Different projects keep independent rows (no cross-project dedup;
      project isolation is the boundary).
    * UNIQUE `storage_key` — backfill (Stage 6) reuses chat_attachments'
      storage_key directly. Uniqueness lets the data migration use
      `on_conflict: :nothing` for idempotency.
    * `org_id` — supports tenant-scoped admin queries (uncommon path, but
      cheap to maintain).
  """

  use Ecto.Migration

  def change do
    create table(:platform_files, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :project_id,
        references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :org_id,
        references(:orgs, type: :binary_id, on_delete: :restrict),
        null: true
      )

      add(:name, :string)
      add(:original_filename, :string)
      add(:content_type, :string, null: false)
      add(:byte_size, :bigint, null: false)
      add(:storage_key, :string, null: false)
      add(:content_hash, :string, null: false)

      add(
        :uploaded_by_user_id,
        references(:users, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:platform_files, [:project_id, :inserted_at]))
    create(unique_index(:platform_files, [:content_hash, :project_id]))
    create(unique_index(:platform_files, [:storage_key]))
    create(index(:platform_files, [:org_id]))
  end
end
