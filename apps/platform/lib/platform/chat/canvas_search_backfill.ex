defmodule Platform.Chat.CanvasSearchBackfill do
  @moduledoc """
  Indexes the canvases that were saved before the write path existed
  (task `01a07402` stage 3).

  Stage 2 wired `Platform.Chat.CanvasSearchIndex` into every writer of
  `chat_canvases.document`, which covers **the future exclusively**. A canvas
  saved yesterday emits nothing, will emit nothing, and is therefore
  unfindable by body until somebody happens to edit it. At the time this was
  written that was 409 rows — the entire existing corpus.

  ## Not a data migration

  This calls application code (`Platform.Chat.Canvas.SearchText`, which
  delegates to `MarkdownExporter`, which dispatches off the kind registry).
  A migration that calls application code breaks the next time the schema
  moves under it — the migration is pinned to a moment in history and the
  module is not. It also has to run in batches rather than as one long
  transaction, which a `change/0` body is a poor place to do.

  So: logic here, a thin `mix platform.backfill_canvas_search` wrapper over
  it, and a boot-time one-shot in `Platform.Application` so production
  converges without anyone remembering to run a command. That is the house
  pattern — see `Platform.Files.CardBackfill` and
  `Mix.Tasks.Platform.Tasks.Embed`.

  ## Keyset pagination on `id`, and why the loop cannot spin

  `chat_canvases.id` is a `Platform.Types.UUIDv7` — time-ordered, so
  `where: c.id > ^cursor, order_by: c.id, limit: ^batch` is a monotonic
  cursor with no composite key and no `OFFSET` (which would re-scan the
  prefix on every batch and, worse, *skip* rows here: the candidate set
  shrinks as the loop indexes it, so a fixed offset walks past unprocessed
  rows).

  Termination, spelled out, because a boot-time `Task` that spins hangs the
  supervision tree:

    1. Every row a batch returns satisfies `id > cursor`.
    2. The batch is ordered ascending, so `List.last(rows).id` is the maximum
       of the batch and is therefore **strictly greater** than `cursor`.
    3. The next cursor is that maximum, so the cursor strictly increases on
       every iteration that returns at least one row, and an iteration that
       returns none stops immediately.
    4. Critically, (1)-(3) hold **regardless of whether the batch wrote any
       index rows**. The cursor is driven by the ids seen, not by the work
       done, so a batch in which every single row fails still advances past
       them and cannot be re-fetched. A cursor derived from "rows that are
       still unindexed" instead would re-fetch a failing row forever.
    5. The candidate set is finite and does not grow during a run: a canvas
       created while the backfill is running goes through stage 2's write
       path and arrives already indexed, so it is never a candidate.

  ## A row that fails is skipped, logged, and left visible in `remaining`

  `SearchText.extract/1` is total — it returns `""` rather than raising, for
  any input, including a structurally invalid `document`. The write is not:
  `CanvasSearchIndex.upsert!/2` can raise on real production data. The
  reachable case is a canvas whose extracted body exceeds Postgres's
  1,048,575-byte `tsvector` limit, which the STORED GENERATED
  `body_search_vector` column computes on insert (`54000
  program_limit_exceeded`); an FK violation from a canvas hard-deleted
  mid-run is another.

  Between crashing the whole run and skipping the row, this skips — one
  oversized canvas must not cost the other 408 their index, and see
  `run_at_boot/0` for why raising out of the boot child is worse still.

  But skipping has its own trap, and it is the exact failure this stage
  exists to prevent: skip a row, advance the cursor past it, report success,
  and that canvas is silently unfindable forever. So the skip is not silent
  at any layer:

    * `index_one/1` returns `{:error, reason}` rather than raising, so the
      decision is one testable function and not a `rescue` buried in a loop;
    * the row is logged at `:error` with its id;
    * it is counted in `:failed` and named in `:failed_ids`;
    * and `:remaining` is **re-counted from the database after the loop**,
      not derived from the loop's own arithmetic, so a skipped row keeps
      `remaining > 0`. A run that skipped something cannot report a clean
      sweep, because the number it reports is measured rather than assumed.

  Re-running is the retry: a failed row still has no index row, so it is a
  candidate again on the next run. There is no retry queue.

  ## Soft-deleted canvases are indexed too

  There is deliberately no `deleted_at` filter here. Excluding soft-deleted
  rows would mean a canvas restored later is silently unfindable by body
  until somebody edits it — reintroducing this stage's bug for exactly the
  rows least likely to be noticed. Keeping deleted canvases out of *results*
  is the query's job, not the backfill's; the index table's moduledoc makes
  the same commitment from the other side.

  `CanvasSearchIndex.unindexed_count/1` is the counterpart and *does* filter
  on `deleted_at`, because it answers a different question — "is this space's
  index still partial" — and counting rows the user can never see would keep
  that line lit forever.

  ## Idempotent

  Candidates are canvases with **no** `chat_canvas_search` row. A second full
  run therefore finds nothing and writes nothing.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasSearchIndex
  alias Platform.Repo

  @default_batch 200

  @type report :: %{
          processed: non_neg_integer(),
          failed: non_neg_integer(),
          failed_ids: [binary()],
          remaining: non_neg_integer(),
          batches: non_neg_integer()
        }

  @doc """
  Index every canvas that has no `chat_canvas_search` row.

  Options:

    * `:batch` — rows per query (default `#{@default_batch}`).
    * `:limit` — stop after considering this many rows. Absent means run to
      completion, which is what the boot-time child and a bare mix run do.

  Returns `{:ok, report}`. `:processed` counts rows successfully indexed,
  `:failed` counts rows skipped after an error, and `:remaining` is counted
  fresh from the database once the loop is done — so `remaining > 0` after a
  full run means real work is outstanding, not a stale accumulator.
  """
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) do
    batch = opts |> Keyword.get(:batch, @default_batch) |> validate_batch!()
    limit = opts |> Keyword.get(:limit) |> validate_limit!()

    acc = do_run(nil, batch, limit, %{processed: 0, failed: 0, failed_ids: [], batches: 0})

    report = %{
      processed: acc.processed,
      failed: acc.failed,
      failed_ids: Enum.reverse(acc.failed_ids),
      batches: acc.batches,
      remaining: remaining_count()
    }

    log_summary(report)

    {:ok, report}
  end

  @doc """
  Boot-time entry point. Runs the backfill and **always returns `:ok`**.

  The supervised child that calls this is a `Task` with `restart: :transient`,
  which restarts on abnormal exit. If this raised on production data the
  supervisor would restart it, it would raise again, and it would trip the
  supervisor's max-restart intensity — taking the **whole application** down
  over an unindexed canvas. That trade is never worth making, so every error
  is caught here and logged, and the process exits `:normal` so `:transient`
  does not restart it.

  The cost is that a backfill which fails wholesale at boot (Repo not
  reachable, say) does not retry until the next boot. That is recoverable by
  hand — `mix platform.backfill_canvas_search`, or the same call from a
  release — and a crash loop is not.

  Per-row failures never reach here; `run/1` already skips those.

  `run_fun` defaults to the real run and exists so the never-raises
  guarantee can be tested against *these* rescue and catch clauses rather
  than a copy of them in a test file. A wrapper whose whole job is to
  swallow failure is worth very little if nothing ever drives it with a
  failure.
  """
  @spec run_at_boot((-> {:ok, report()})) :: :ok
  def run_at_boot(run_fun \\ fn -> run([]) end) do
    case run_fun.() do
      {:ok, %{remaining: 0}} ->
        :ok

      {:ok, report} ->
        Logger.warning(
          "CanvasSearchBackfill: boot run left #{report.remaining} canvas(es) unindexed " <>
            "(failed=#{report.failed}); re-run `mix platform.backfill_canvas_search`"
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "CanvasSearchBackfill: boot run failed, skipping rather than crash-looping the " <>
          "supervisor: " <> Exception.message(error)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "CanvasSearchBackfill: boot run exited (#{inspect(kind)}), skipping rather than " <>
          "crash-looping the supervisor: #{inspect(reason)}"
      )

      :ok
  end

  @doc """
  Index one canvas. Returns `:ok`, or `{:error, reason}` if the write failed.

  Exposed so a test can drive a single row without the batching loop, and so
  the skip-versus-crash decision is one function with one return type rather
  than a `rescue` tangled into the loop. Never raises.
  """
  @spec index_one(Canvas.t()) :: :ok | {:error, term()}
  def index_one(%Canvas{} = canvas) do
    CanvasSearchIndex.upsert!(Repo, canvas)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # ── Batch loop ─────────────────────────────────────────────────────────

  defp do_run(cursor, batch, budget, acc) do
    fetch = fetch_size(batch, budget)

    if fetch <= 0 do
      acc
    else
      case fetch_batch(cursor, fetch) do
        [] ->
          acc

        rows ->
          acc = Enum.reduce(rows, %{acc | batches: acc.batches + 1}, &apply_row/2)

          # Strictly greater than `cursor`: every row matched `id > cursor`
          # and the batch is ordered ascending. See the moduledoc.
          next_cursor = List.last(rows).id

          do_run(next_cursor, batch, decrement(budget, length(rows)), acc)
      end
    end
  end

  defp apply_row(%Canvas{} = canvas, acc) do
    case index_one(canvas) do
      :ok ->
        %{acc | processed: acc.processed + 1}

      {:error, reason} ->
        Logger.error(
          "CanvasSearchBackfill: canvas #{canvas.id} left unindexed: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + 1, failed_ids: [canvas.id | acc.failed_ids]}
    end
  end

  defp fetch_size(batch, nil), do: batch
  defp fetch_size(batch, budget), do: min(batch, budget)

  defp decrement(nil, _n), do: nil
  defp decrement(budget, n), do: budget - n

  # ── Queries ────────────────────────────────────────────────────────────

  # No `deleted_at` filter — see the moduledoc.
  defp candidates do
    from(c in Canvas,
      left_join: s in CanvasSearchIndex,
      on: s.canvas_id == c.id,
      where: is_nil(s.canvas_id)
    )
  end

  defp fetch_batch(cursor, fetch) do
    candidates()
    |> apply_cursor(cursor)
    |> order_by([c], asc: c.id)
    |> limit(^fetch)
    |> Repo.all()
  end

  defp apply_cursor(query, nil), do: query
  defp apply_cursor(query, cursor), do: from(c in query, where: c.id > ^cursor)

  defp remaining_count do
    Repo.aggregate(candidates(), :count, :id)
  end

  # ── Options ────────────────────────────────────────────────────────────

  defp validate_batch!(batch) when is_integer(batch) and batch > 0, do: batch

  defp validate_batch!(other) do
    raise ArgumentError,
          "CanvasSearchBackfill: :batch must be a positive integer, got #{inspect(other)}. " <>
            "A batch of 0 would fetch nothing and report a clean sweep it never made."
  end

  defp validate_limit!(nil), do: nil
  defp validate_limit!(limit) when is_integer(limit) and limit >= 0, do: limit

  defp validate_limit!(other) do
    raise ArgumentError,
          "CanvasSearchBackfill: :limit must be a non-negative integer or nil, " <>
            "got #{inspect(other)}"
  end

  # ── Logging ────────────────────────────────────────────────────────────

  defp log_summary(%{failed: 0} = report) do
    Logger.info(
      "CanvasSearchBackfill: processed=#{report.processed} batches=#{report.batches} " <>
        "remaining=#{report.remaining}"
    )
  end

  defp log_summary(report) do
    Logger.warning(
      "CanvasSearchBackfill: processed=#{report.processed} failed=#{report.failed} " <>
        "batches=#{report.batches} remaining=#{report.remaining} " <>
        "failed_ids=#{inspect(report.failed_ids)}"
    )
  end
end
