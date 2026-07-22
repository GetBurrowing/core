defmodule Platform.Files.Purger do
  @moduledoc """
  Permanently erases soft-deleted files once their restore window elapses
  (task 019f7cb0 stage 3).

  `Platform.Files.delete_file/2` (stage 2) marks a file `deleted_at` and
  hides it from every read path, keeping the row + bytes recoverable via
  `restore_file/2`. This GenServer ticks daily — the same send_after
  cadence as `Platform.Chat.SpacePurger` and
  `Platform.Tenancy.ContainerPurger` — and hard-deletes every file whose
  `deleted_at` passed the shared retention window
  (`Platform.Tenancy.Lifecycle.retention_days/0`, default 30 days):

    * **Stored bytes** via `Platform.Files.Storage.delete/1` (idempotent —
      an already-gone object reads as success, which is what makes the
      commit-failure edge below self-healing).
    * **The `platform_files` row.** The candidate query keys off the
      partial index over `deleted_at IS NOT NULL` rows (stage 2 migration).
    * **Dependent rows by FK cascade.** Both `platform_file_chunks.file_id`
      and `platform_file_texts.file_id` are `ON DELETE :delete_all`
      (migrations 20260619030000 / 20260619040000), so chunk back-refs and
      cached extracted text go with the row — no explicit deletes needed.

  Each purge additionally re-scrubs the file's entry from the AI search
  index (belt-and-braces: stage 2 scrubbed at soft-delete time, but that
  scrub is best-effort and purge is the last moment the file id exists to
  scrub by) and emits a `[:platform, :files, :file_purged]` system-actor
  audit event, registered in `Platform.Audit.TelemetryHandler` `@events`.

  ## Safety posture

  Each file purges in its OWN short transaction, ordered:

    1. Delete the row with the full "still deleted + still past window"
       predicate re-asserted IN the delete query (not just the select).
       0 rows affected → the file was restored (or already purged) since
       selection → roll back and skip, storage untouched.
    2. Delete the bytes. Any non-`:ok` → roll back, resurrecting the row
       so next tick retries. A row is never committed away while its
       bytes may remain.

  Row-first-inside-the-transaction (rather than the legacy hard-delete
  path's storage-then-row order) is deliberate: the row delete takes the
  row lock, so a concurrent `restore_file/2` either commits first (our
  re-check then matches 0 rows and the bytes are spared) or blocks until
  our commit and fails loudly on the stale row. Storage-first would leave
  a race where a just-restored, user-visible file loses its bytes. The
  "bytes may remain ⇒ row must remain" invariant holds in both orders —
  this one also closes the restore race. The one edge left is a commit
  failure AFTER the storage delete succeeded: the row survives pointing
  at gone bytes, and the next tick self-heals (idempotent storage delete
  reads `:ok`, row deletes).

  A raise while purging one file is rescued, logged, and counted as a
  skip — one poisoned row must not starve every other file of its purge.

  ## Batching

  Candidates are drained in batches (default 500, oldest `deleted_at`
  first) so a bulk deletion doesn't load an unbounded row set in one
  query. Skipped files are excluded from subsequent batch queries within
  the same sweep, so a persistently failing file cannot loop the drain.

  ## Out of scope

  Files hard-deleted by CASCADE when `ContainerPurger` purges their
  project lose their rows without a storage pass — those bytes are
  currently orphaned. That leak predates this sweeper and needs its own
  fix (flagged as a stage-3 follow-up); this module only purges rows it
  can still see.

  Disabled in `config/test.exs` (`:start_file_purger false`, enrolled in
  the start-flag audit) — tests call `sweep/1` directly inside the
  DataCase sandbox.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Files.File
  alias Platform.Files.Storage
  alias Platform.Repo
  alias Platform.Tenancy.Lifecycle

  @tick_interval_ms 24 * 60 * 60 * 1000
  @default_batch_size 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep synchronously. Returns `{:ok, purged_count}` (skipped
  files are not counted — they retry next sweep).

  ## Options

    * `:batch_size` — rows per candidate query (default
      #{@default_batch_size}). Exposed for tests exercising the drain
      loop; production ticks use the default.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()}
  def sweep(opts \\ []), do: do_sweep(opts)

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, _count} = do_sweep([])
    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp do_sweep(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    cutoff = DateTime.add(DateTime.utc_now(), -Lifecycle.retention_days(), :day)

    {purged, skipped_ids} = drain(cutoff, batch_size, MapSet.new(), [])

    # Index scrub + telemetry fire only AFTER each row's transaction has
    # committed (they run post-drain, and every per-file transaction is
    # already resolved) — a rolled-back purge must not leave phantom
    # audit rows or scrub a still-restorable file's index entry.
    Enum.each(purged, &finalize_purge/1)

    skipped_count = MapSet.size(skipped_ids)

    Logger.info(
      "[file_purger] purged #{length(purged)} file(s) past retention" <>
        if(skipped_count > 0, do: " (#{skipped_count} skipped for retry)", else: "")
    )

    {:ok, length(purged)}
  end

  # Drains candidate batches until a partial batch signals the pool is
  # exhausted. Skipped ids are excluded from every subsequent query, so
  # each iteration strictly shrinks the remaining pool (rows purged or
  # ids excluded) and the loop terminates.
  defp drain(cutoff, batch_size, skipped_ids, purged_acc) do
    batch = Repo.all(candidates_query(cutoff, skipped_ids, batch_size))

    {purged, skipped_ids} =
      Enum.reduce(batch, {[], skipped_ids}, fn file, {purged, skipped} ->
        case purge_one(file, cutoff) do
          :purged -> {[file | purged], skipped}
          :skipped -> {purged, MapSet.put(skipped, file.id)}
        end
      end)

    purged_acc = purged_acc ++ Enum.reverse(purged)

    if length(batch) < batch_size do
      {purged_acc, skipped_ids}
    else
      drain(cutoff, batch_size, skipped_ids, purged_acc)
    end
  end

  # Oldest deletions first, so a backlog (e.g. after downtime) clears in
  # the order files became purgeable. Hits the stage-2 partial index over
  # `deleted_at IS NOT NULL`.
  defp candidates_query(cutoff, skipped_ids, batch_size) do
    from(f in File,
      where: not is_nil(f.deleted_at) and f.deleted_at < ^cutoff,
      where: f.id not in ^MapSet.to_list(skipped_ids),
      order_by: [asc: f.deleted_at],
      limit: ^batch_size
    )
  end

  # Purges one candidate: row delete (with in-query re-check) and storage
  # delete in one transaction — see the moduledoc's safety posture for the
  # ordering rationale. Exposed (`@doc false`) as the test seam proving
  # the re-check lives in the delete query and that a stale candidate
  # never reaches the storage adapter.
  @doc false
  @spec purge_one(File.t(), DateTime.t()) :: :purged | :skipped
  def purge_one(%File{} = candidate, cutoff) do
    Repo.transaction(fn ->
      delete_row_or_rollback(candidate, cutoff)

      case Storage.delete(candidate.storage_key) do
        :ok -> :ok
        other -> Repo.rollback({:storage_delete_failed, other})
      end
    end)
    |> case do
      {:ok, :ok} ->
        :purged

      {:error, :stale} ->
        Logger.warning(
          "[file_purger] file #{candidate.id} no longer matched the delete " <>
            "re-check — skipped"
        )

        :skipped

      {:error, {:storage_delete_failed, reason}} ->
        Logger.warning(
          "[file_purger] storage delete failed for file #{candidate.id} " <>
            "(key #{candidate.storage_key}): #{inspect(reason)} — " <>
            "row kept, retrying next sweep"
        )

        :skipped
    end
  rescue
    error ->
      # One poisoned row (e.g. a raising storage adapter) must not starve
      # the rest of the sweep. The transaction already rolled back.
      Logger.error(
        "[file_purger] purge crashed for file #{candidate.id} — skipped: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :skipped
  end

  # Deletes the row, re-asserting the full "still soft-deleted + still
  # past the window" predicate IN the delete query so a restore landing
  # between candidate selection and this delete is respected (0 rows →
  # rollback → the storage delete never runs). A count above 1 is
  # impossible for a primary-key delete — raise into the rescue above.
  defp delete_row_or_rollback(%File{} = candidate, cutoff) do
    {deleted, _} =
      Repo.delete_all(
        from(f in File,
          where: f.id == ^candidate.id and not is_nil(f.deleted_at) and f.deleted_at < ^cutoff
        )
      )

    case deleted do
      1 ->
        :ok

      0 ->
        Repo.rollback(:stale)

      other ->
        raise "file purge affected #{other} rows for file #{candidate.id} — expected exactly 1"
    end
  end

  # ── Post-commit effects ────────────────────────────────────────────────

  defp finalize_purge(%File{} = file) do
    scrub_search_index(file)
    emit_purged_telemetry(file)
  end

  # Belt-and-braces final scrub: stage 2 already scrubbed at soft-delete
  # time, but that pass is best-effort (a memory-service outage logs and
  # moves on) and purge destroys the row — the last record of the id the
  # index entry lives under. Same best-effort contract as stage 2.
  defp scrub_search_index(%File{} = file) do
    case Platform.Memory.delete([file.id]) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[file_purger] search-index scrub failed for file=#{file.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Bridged into the append-only audit log by
  # `Platform.Audit.TelemetryHandler`. No actor exists for a timer purge —
  # system attribution, matching ContainerPurger/SpacePurger. `deleted_at`
  # is stringified so the bridge's JSON pass doesn't choke on a DateTime.
  defp emit_purged_telemetry(%File{} = file) do
    :telemetry.execute(
      [:platform, :files, :file_purged],
      %{system_time: System.system_time()},
      %{
        actor_id: nil,
        actor_type: "system",
        resource_type: "file",
        resource_id: file.id,
        action: "file_purged",
        project_id: file.project_id,
        org_id: file.org_id,
        file_name: file.name || file.original_filename,
        storage_key: file.storage_key,
        byte_size: file.byte_size,
        deleted_at: DateTime.to_iso8601(file.deleted_at)
      }
    )
  end
end
