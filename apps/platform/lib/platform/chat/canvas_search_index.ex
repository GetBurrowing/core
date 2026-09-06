defmodule Platform.Chat.CanvasSearchIndex do
  @moduledoc """
  The `chat_canvas_search` row for a canvas: its body as plain text, plus the
  Postgres-maintained `tsvector` over that text (task `01a07402` stage 2).

  ## The contract this module exists to keep

  **Every write of `chat_canvases.document` updates this table in the SAME
  transaction as the canvas write.** Not after it, not in a `Task`, not on a
  timer. A canvas whose body changed but whose index row did not is invisible
  to search while looking perfectly healthy in the UI, and nothing would ever
  report it. Composing into the caller's `Ecto.Multi` makes that failure mode
  unrepresentable: if the index write fails, the canvas write rolls back and
  the save fails loudly.

  That is why the primary entry point is `upsert_multi/3` and not an
  `upsert/1` the caller sprinkles after a save — the same reasoning
  `Platform.Chat.Canvas.Versions` gives for having no `insert/5` shortcut.

  ## Extraction is `SearchText.extract/1`, always

  Text sits at a different prop key per node kind. Any second extractor — a
  private traversal here, or a `jsonb_path_query_array(document, '$..content')`
  in SQL — silently drops every kind registered after it was written.
  `Platform.Chat.Canvas.SearchText` is the one projection, and it delegates to
  the one exporter that dispatches off the kind registry.

  ## `body_search_vector` is generated; never write it

  It is a STORED GENERATED column (`setweight(to_tsvector('english',
  coalesce(body_text, '')), 'D')`). Postgres rejects any attempt to supply a
  value, so it appears in no cast list and in no insert here — the field is
  declared `Platform.Types.TSVector, read_after_writes: true` purely so a
  reader can load it and assert it is populated.

  ## Absence of a row means "never indexed"

  There is no row for a canvas until something writes one. That is the
  signal the backfill stage reports partial progress against, so do not
  seed empty rows to make joins tidier.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.SearchText
  alias Platform.Repo

  @primary_key {:canvas_id, Ecto.UUID, autogenerate: false}

  schema "chat_canvas_search" do
    field(:body_text, :string)
    field(:indexed_at, :utc_datetime_usec)

    # STORED GENERATED. Read-only by construction — see moduledoc.
    field(:body_search_vector, Platform.Types.TSVector, read_after_writes: true)
  end

  @type t :: %__MODULE__{}

  # `:replace` names exactly the two application-written columns.
  # `body_search_vector` is absent because Postgres maintains it, and
  # `canvas_id` is absent because it is the conflict target.
  @conflict_opts [
    conflict_target: :canvas_id,
    on_conflict: {:replace, [:body_text, :indexed_at]}
  ]

  @doc """
  Add an index-upsert step to `multi`, to run inside the caller's transaction.

  `canvas_or_fun` is either a `%Canvas{}` already in hand, or a one-arity
  function over the multi's changes so far — use the function form whenever
  the canvas is produced by an earlier step, so the text is extracted from
  the document that was actually persisted rather than from a stale struct:

      multi
      |> Multi.update(:canvas, canvas_changeset)
      |> CanvasSearchIndex.upsert_multi(:canvas_search, & &1.canvas)
  """
  @spec upsert_multi(Multi.t(), atom(), Canvas.t() | (map() -> Canvas.t())) :: Multi.t()
  def upsert_multi(multi, step_name, canvas_or_fun) when is_atom(step_name) do
    Multi.run(multi, step_name, fn repo, changes ->
      canvas =
        case canvas_or_fun do
          fun when is_function(fun, 1) -> fun.(changes)
          %Canvas{} = canvas -> canvas
        end

      do_upsert(repo, canvas)
    end)
  end

  @doc """
  Upsert one canvas's index row outside a multi. Returns `:ok`.

  Prefer `upsert_multi/3`. This exists for the backfill
  (`Platform.Chat.CanvasSearchBackfill`), which is re-indexing rows nobody is
  writing, not as a way to index after a save.

  Deliberately **not** wrapped in a transaction, and the backfill does not
  wrap it in one either: each row is its own statement so that one canvas
  Postgres refuses (an over-1MB `tsvector`, an FK violation from a canvas
  hard-deleted mid-run) fails alone instead of rolling back its whole batch.
  Raises on such a row — `CanvasSearchBackfill.index_one/1` is the caller that
  turns that into a skip.
  """
  @spec upsert!(Ecto.Repo.t(), Canvas.t()) :: :ok
  def upsert!(repo \\ Repo, %Canvas{} = canvas) do
    {:ok, _row} = do_upsert(repo, canvas)
    :ok
  end

  @doc """
  Build the row this module writes for `canvas`. Exposed so the backfill can
  batch rows through one `insert_all` without duplicating the extraction rule.
  """
  @spec row_for(Canvas.t()) :: %{
          canvas_id: binary(),
          body_text: String.t(),
          indexed_at: DateTime.t()
        }
  def row_for(%Canvas{id: canvas_id} = canvas) when is_binary(canvas_id) do
    %{
      canvas_id: canvas_id,
      body_text: SearchText.extract(canvas),
      indexed_at: DateTime.utc_now()
    }
  end

  @doc """
  How many canvases in `space_ids` have never been indexed.

  The single source of truth for "is the body index still partial here" —
  stage 5 renders a partial-index line off this number, and one function
  means that line cannot drift from what the backfill actually left behind.

  **Soft-deleted canvases are excluded**, which is the one place this differs
  from `Platform.Chat.CanvasSearchBackfill`'s own `:remaining`. The backfill
  indexes deleted rows on purpose, so that a restore does not have to
  re-index; but counting them here would keep the partial-index line lit
  forever in any space that has ever had a canvas deleted, over rows nobody
  can search for anyway. Two questions, two counts.

  Returns `0` for an empty list without touching the database.

  Malformed ids are dropped rather than raised on. `where: c.space_id in
  ^space_ids` raises the same `Ecto.Query.CastError` as `Repo.get/2` on a
  value that is not a UUID, and these ids reach here from a caller rather
  than from code — stage 5 renders a partial-index line from whatever spaces
  the current view is showing. A malformed id degrading to "nothing
  unindexed there" is right; taking a page render down over it is not.
  """
  @spec unindexed_count([binary()]) :: non_neg_integer()
  def unindexed_count(space_ids) when is_list(space_ids) do
    case Enum.filter(space_ids, &Platform.UUID.valid?/1) do
      [] ->
        0

      ids ->
        from(c in Canvas,
          left_join: s in __MODULE__,
          on: s.canvas_id == c.id,
          where: c.space_id in ^ids and is_nil(c.deleted_at) and is_nil(s.canvas_id),
          select: count(c.id)
        )
        |> Repo.one()
    end
  end

  # Written through the schema rather than the bare `"chat_canvas_search"`
  # string so Ecto dumps `canvas_id` to a 16-byte uuid and `indexed_at` to a
  # timestamptz. A string source carries no types: Postgrex would be handed a
  # 36-character string for a `uuid` parameter and raise at encode time.
  defp do_upsert(repo, %Canvas{id: canvas_id} = canvas) when is_binary(canvas_id) do
    row = row_for(canvas)

    {1, _} = repo.insert_all(__MODULE__, [row], @conflict_opts)

    {:ok, row}
  end
end
