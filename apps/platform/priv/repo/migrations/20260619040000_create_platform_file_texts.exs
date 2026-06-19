defmodule Platform.Repo.Migrations.CreatePlatformFileTexts do
  @moduledoc """
  ADR 0042 — Stage 4 of the files pipeline.

  Caches the extracted text + per-page bodies produced by
  `Platform.Files.Extractor` so the `file_get_text` MCP tool can serve
  whole-file or per-page reads without re-shelling-out to pdftotext /
  pandoc / tesseract on every call.

  One row per file (PK == `file_id`). Cascade-deletes with the parent
  `platform_files` row so retired files don't leak text bodies.
  """

  use Ecto.Migration

  def change do
    create table(:platform_file_texts, primary_key: false) do
      add(
        :file_id,
        references(:platform_files, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:text, :text, null: false)
      # `pages` is the page-by-page split when the extractor produced one
      # (PDF, gdoc). For flow formats (CSV, plain text, OCR'd image) it
      # stays nil and `file_get_text` falls back to the whole `text`
      # blob regardless of any `page:` arg.
      add(:pages, {:array, :text})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
