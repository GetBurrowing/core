defmodule Platform.Repo.Migrations.CreateChatCanvasSearch do
  use Ecto.Migration

  @moduledoc """
  Task `01a07402` stage 2: an indexed plain-text projection of every canvas
  BODY, so search can find a canvas by what is written inside it rather than
  only by its title.

  Schema only. There is deliberately **no data pass here** — the backfill is
  its own stage, for the reasons in "absence of a row" below.

  ## Why a separate table rather than a column on `chat_canvases`

    1. **Absence of a row IS the "not yet indexed" signal.** A canvas with no
       `chat_canvas_search` row has provably never been indexed. That is
       unmistakable in a way a nullable column is not: a `NULL body_text`
       column cannot be told apart from a canvas whose body genuinely
       extracts to nothing, and a `''` default cannot be told apart from
       either. The backfill stage has to report honestly on partial
       progress, and this is the only shape that lets it.
    2. **The backfill INSERTs into an empty table** instead of UPDATEing
       every row of `chat_canvases`, which is hot and wide. No row-version
       churn on the table every canvas read touches.
    3. **It stops colliding with the last-editor work.** That task migrates
       `chat_canvases`; this one does not touch it at all, so the two can
       land in either order.

  ## Why the vector is still a STORED GENERATED column

  The 20260804014331 migration ruled canvas bodies out of full-text search
  on the grounds that the only reliable extractor
  (`Platform.Chat.Canvas.MarkdownExporter`) is application code and cannot
  appear inside an IMMUTABLE generated expression. That reasoning is intact
  and this migration does not contradict it — it splits the job in two:

    * the application does the part that must be application code, writing
      the extracted text into `body_text` in the same transaction as the
      canvas write (`Platform.Chat.CanvasSearchIndex`);
    * Postgres does the vectorising, because
      `to_tsvector('english', body_text)` — two-arg, with a *literal*
      config — IS IMMUTABLE, so it is legal in a generated expression.

  So the same guarantee the 20260804 moduledoc bought still holds for this
  column: no trigger to keep in step with a column list, and no refresh path
  to forget. `body_text` changing is the only way the vector can change, and
  Postgres maintains it from there.

  ## Why weight `D`

  `chat_canvases.title_search_vector` is weight `B`. `ts_rank_cd/2`'s default
  weights are `{D, C, B, A} = {0.1, 0.2, 0.4, 1.0}`, so a title hit (0.4)
  outranks a body hit (0.1) with **no hand-rolled scoring at any call site**.
  Bodies are also the largest and noisiest surface here, which is the same
  reason raw transcript speech got `D` in 20260804014331.

  ## FK and lifecycle

  `canvas_id` is both the primary key and the FK, `ON DELETE CASCADE`: one
  index row per canvas, and a hard-deleted canvas cannot leave a dangling
  index row behind. Soft deletes (`chat_canvases.deleted_at`) leave the row
  in place on purpose — a restore must not have to re-index — so every
  reader of this table filters on `chat_canvases.deleted_at IS NULL` the way
  the existing canvas queries already do.
  """

  def change do
    create table(:chat_canvas_search, primary_key: false) do
      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:body_text, :text, null: false, default: "")
      add(:indexed_at, :utc_datetime_usec, null: false)
    end

    alter table(:chat_canvas_search) do
      add(:body_search_vector, :tsvector,
        generated: """
        ALWAYS AS (
          setweight(to_tsvector('english', coalesce(body_text, '')), 'D')
        ) STORED\
        """
      )
    end

    create(index(:chat_canvas_search, [:body_search_vector], using: :gin))
  end
end
