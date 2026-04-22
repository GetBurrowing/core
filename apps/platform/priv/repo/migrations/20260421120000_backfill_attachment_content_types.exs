defmodule Platform.Repo.Migrations.BackfillAttachmentContentTypes do
  @moduledoc """
  Re-labels existing `chat_attachments` rows that were stored with
  `content_type = 'application/octet-stream'` because the uploading client
  (commonly iOS Safari picking a photo) didn't send a specific MIME type.

  Without this, those rows fail the `image_attachment?/1` check in the
  renderer (`image/*` prefix only) AND get `Content-Disposition: attachment`
  from `ChatAttachmentController`, so they show up in the UI as a grey
  file chip instead of inlining in the image gallery.

  The fix for new uploads lives in `AttachmentStorage.normalize_content_type/2`;
  this migration brings past rows up to par. The relabeled set matches the
  runtime `@safe_override_types` allowlist (no SVG, no text/*, no HTML) so
  this migration cannot reintroduce the stored-XSS vector the allowlist
  closes. Unknown extensions are left as `application/octet-stream`.
  """

  use Ecto.Migration

  def up do
    # Single UPDATE with a CASE expression so the table is scanned and
    # locked once, rather than nine times. The narrow WHERE clause ensures
    # we only rewrite rows that will actually change value (avoiding
    # gratuitous MVCC row-version writes).
    execute("""
    UPDATE chat_attachments
    SET content_type = CASE
      WHEN lower(filename) LIKE '%.png'  THEN 'image/png'
      WHEN lower(filename) LIKE '%.jpg'  THEN 'image/jpeg'
      WHEN lower(filename) LIKE '%.jpeg' THEN 'image/jpeg'
      WHEN lower(filename) LIKE '%.gif'  THEN 'image/gif'
      WHEN lower(filename) LIKE '%.webp' THEN 'image/webp'
      WHEN lower(filename) LIKE '%.heic' THEN 'image/heic'
      WHEN lower(filename) LIKE '%.heif' THEN 'image/heif'
      WHEN lower(filename) LIKE '%.pdf'  THEN 'application/pdf'
      ELSE content_type
    END
    WHERE content_type = 'application/octet-stream'
      AND (
           lower(filename) LIKE '%.png'
        OR lower(filename) LIKE '%.jpg'
        OR lower(filename) LIKE '%.jpeg'
        OR lower(filename) LIKE '%.gif'
        OR lower(filename) LIKE '%.webp'
        OR lower(filename) LIKE '%.heic'
        OR lower(filename) LIKE '%.heif'
        OR lower(filename) LIKE '%.pdf'
      )
    """)
  end

  def down do
    # Reverting would blanket re-label rows back to application/octet-stream
    # and reintroduce the rendering bug. A silent no-op would make a rollback
    # appear successful while leaving data in the post-migration state — so
    # raise loudly instead. Re-run the backfill manually if data was restored
    # from a pre-fix backup.
    raise "Irreversible data backfill — re-run manually after restoring pre-fix data"
  end
end
