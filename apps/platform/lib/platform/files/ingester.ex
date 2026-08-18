defmodule Platform.Files.Ingester do
  @moduledoc """
  Async ingest pipeline for `Platform.Files.File` rows.

  Stage 3 of ADR 0042. Mirrors `Platform.Memory.ingest_async/1`:
  fire-and-forget, spawned under `Platform.TaskSupervisor`, never blocks
  the caller (the upload LV / backfill loop / MCP tool).

  ## Pipeline

      ingest_async(file)
        ├─ ingest_intent == "human_only"
        │     └─ ingest_status := :not_attempted, no telemetry, no task
        │        spawned, no Extractor call. TERMINAL until
        │        `Platform.Files.request_ingest/1` flips the intent back.
        └─ ingest_intent == "attempt"
           └─ TaskSupervisor.start_child
              ├─ dedup check: same content_hash already :ingested in this project?
              │     ├─ yes → copy chunk_external_id rows from prior file, mark
              │     │       :ingested, skip extract + embed. Saves the API $.
              │     └─ no  → Platform.Files.Extractor.extract/1
              │                  ├─ ok    → Memory.ingest → insert chunks → :ingested
              │                  └─ error → mark :failed + telemetry :exception

  Returns `:ok` synchronously. The actual work happens in the spawned
  task; observers track progress via the telemetry events documented
  below or by polling `file.ingest_status`.

  ## Project / org tagging

  The extracted text is handed directly to `Platform.Memory.ingest/2`
  with the file's `:project_id` and `:org_id` after Stage 4 extended the
  provider behaviour to accept them (ADR 0042). The chunks land in the
  vector store tagged with the project so search can scope by project.

  Stage 4 also persists the extracted text to `platform_file_texts` so
  the `file_get_text` MCP tool can serve whole-file / per-page reads
  without re-shelling out to pdftotext / pandoc on every call.

  ## Telemetry

    * `[:platform, :files, :ingested, :start]` —
      measurements: `%{system_time: integer()}`
      metadata: `%{file_id, project_id, byte_size}`
    * `[:platform, :files, :ingested, :stop]` —
      measurements: `%{duration: integer(), extracted_chars: integer()}`
      metadata: `%{file_id, project_id, byte_size, dedup: boolean(), chunk_count: integer()}`
    * `[:platform, :files, :ingested, :exception]` —
      measurements: `%{duration: integer()}`
      metadata: `%{file_id, project_id, kind, reason, stacktrace}`
  """

  require Logger

  alias Platform.Files
  alias Platform.Files.Extractor
  alias Platform.Memory

  @event_prefix [:platform, :files, :ingested]

  @doc """
  Spawn an async ingest task for `file`. Always returns `:ok`.

  The caller is intentionally not told whether the task started, only
  that the request was accepted — mirrors `Platform.Memory.ingest_async/1`.
  When `Platform.TaskSupervisor` isn't running (rare; only some narrow
  test paths) the task runs inline so unit tests don't have to plumb a
  supervisor stub.

  ## The human_only gate

  This function is the system's **single enqueue choke point** — both
  production callers (the upload LiveView and the MCP file-upload tool)
  route through it — so the intent gate lives here and is not duplicated
  per caller.

  A `ingest_intent: "human_only"` file short-circuits *before* the
  supervisor branch: its `ingest_status` is set to `"not_attempted"`, no
  `:start` telemetry is emitted, no task is spawned and
  `Platform.Files.Extractor.extract/1` is never called. `"not_attempted"`
  is **terminal**: nothing re-enqueues the row until
  `Platform.Files.request_ingest/1` flips the intent back to `"attempt"`.

  The two intents are matched explicitly with no catch-all clause. A row
  carrying an unrecognised intent raises `FunctionClauseError` rather
  than defaulting into extraction — feeding a file to a third-party
  extractor because of an unrecognised enum value is exactly the failure
  this split exists to prevent.
  """
  @spec ingest_async(Platform.Files.File.t()) :: :ok
  def ingest_async(%Platform.Files.File{ingest_intent: "human_only"} = file) do
    {:ok, _file} = Files.update_ingest_status(file, "not_attempted")
    :ok
  end

  def ingest_async(%Platform.Files.File{ingest_intent: "attempt"} = file) do
    fun = fn -> run(file) end

    case Process.whereis(Platform.TaskSupervisor) do
      nil ->
        fun.()

      _pid ->
        Task.Supervisor.start_child(Platform.TaskSupervisor, fun)
    end

    :ok
  end

  @doc """
  Runs the ingest pipeline synchronously. Exposed for tests that want
  to observe the side-effects without the supervisor hop. Production
  callers should use `ingest_async/1`.
  """
  @spec run(Platform.Files.File.t()) :: :ok | {:error, term()}
  def run(%Platform.Files.File{} = file) do
    start_meta = %{
      file_id: file.id,
      project_id: file.project_id,
      byte_size: file.byte_size
    }

    start_time = System.system_time()
    monotonic_start = System.monotonic_time()

    :telemetry.execute(@event_prefix ++ [:start], %{system_time: start_time}, start_meta)

    try do
      do_run(file, monotonic_start, start_meta)
    catch
      kind, reason ->
        duration = System.monotonic_time() - monotonic_start
        stacktrace = __STACKTRACE__

        # Deliberate lossy default: a crash inside the pipeline is not
        # attributable to a named stage — we do not know whether it blew up
        # fetching bytes, reading them, or embedding them. We record
        # `:extract` with the formatted exception rather than inventing a
        # category or leaving the column nil, because a nil reason on a
        # failed row is exactly the defect this column exists to remove.
        _ = mark_failed(file, {:extract, Exception.format(kind, reason, stacktrace)})

        :telemetry.execute(
          @event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(start_meta, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

        broadcast_ingest_failed(file, {kind, reason})

        Logger.warning(
          "Platform.Files.Ingester crashed for file=#{file.id}: " <>
            Exception.format(kind, reason, stacktrace)
        )

        {:error, {kind, reason}}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_run(file, monotonic_start, start_meta) do
    case Files.find_ingested_sibling(file.project_id, file.content_hash) do
      nil ->
        do_extract_and_embed(file, monotonic_start, start_meta)

      %Platform.Files.File{id: prior_id} when prior_id == file.id ->
        # Already ingested under this exact row (e.g. re-running the
        # task after a successful run). No-op + emit a stop event with
        # dedup=true so observers still see the resolution.
        emit_stop(monotonic_start, start_meta, %{
          extracted_chars: 0,
          dedup: true,
          chunk_count: 0
        })

        broadcast_ingested(file)
        :ok

      %Platform.Files.File{} = prior ->
        :ok = copy_chunks_from(prior, file)
        {:ok, _} = Files.update_ingest_status(file, "ingested")

        chunk_count = file.id |> Files.list_chunks_for_file() |> length()

        emit_stop(monotonic_start, start_meta, %{
          extracted_chars: 0,
          dedup: true,
          chunk_count: chunk_count
        })

        broadcast_ingested(file)
        :ok
    end
  end

  defp do_extract_and_embed(file, monotonic_start, start_meta) do
    case Extractor.extract(file) do
      {:ok, %{text: text, pages: pages}} ->
        # Cache the extracted text + per-page split so the Stage 4
        # `file_get_text` MCP tool can serve reads without re-extracting.
        # Best-effort — a failure here doesn't sink the ingest run; it
        # just means the MCP tool will return :not_found until the file
        # is re-ingested. We log so the gap is visible.
        case Files.upsert_extracted_text(file.id, text, pages) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "Platform.Files.Ingester upsert_extracted_text failed for file=#{file.id}: " <>
                inspect(changeset.errors)
            )
        end

        entry = memory_entry(file, text, pages)

        case Memory.ingest([entry]) do
          {:ok, _count} ->
            chunk_ids = [synthetic_chunk_id(file)]
            :ok = insert_chunks(file, chunk_ids, pages)
            {:ok, _} = Files.update_ingest_status(file, "ingested")

            emit_stop(monotonic_start, start_meta, %{
              extracted_chars: byte_size(text),
              dedup: false,
              chunk_count: length(chunk_ids)
            })

            broadcast_ingested(file)
            :ok

          {:error, reason} ->
            _ = mark_failed(file, classify_failure({:memory_ingest_failed, reason}))
            emit_exception(monotonic_start, start_meta, :error, {:memory_ingest_failed, reason})
            broadcast_ingest_failed(file, reason)
            {:error, reason}
        end

      {:error, reason} ->
        _ = mark_failed(file, classify_failure({:extract_failed, reason}))
        emit_exception(monotonic_start, start_meta, :error, {:extract_failed, reason})
        broadcast_ingest_failed(file, reason)
        {:error, reason}
    end
  end

  # PubSub fan-out for the Stage 5 FilesLive. The LV subscribes to
  # `files:project:<project_id>` in mount/3 and re-fetches the row when
  # `{:file_ingested, file_id}` arrives so the "Ingesting…" pill flips
  # to "Ready" without a manual refresh.
  defp broadcast_ingested(%Platform.Files.File{id: id, project_id: project_id})
       when is_binary(project_id) do
    Files.broadcast_project(project_id, {:file_ingested, id})
  end

  defp broadcast_ingest_failed(%Platform.Files.File{id: id, project_id: project_id}, reason)
       when is_binary(project_id) do
    Files.broadcast_project(project_id, {:file_ingest_failed, id, reason})
  end

  # Synthetic chunk-id for the single-chunk pipeline. Mirrors the prior
  # `Platform.Files.MemoryClient` shape ("file:<file_id>") so dedup-copy
  # rows already written under the Stage 3 shim still resolve after the
  # Stage 4 cutover. When the provider behaviour starts returning a
  # per-chunk list we'll trade this for the real ids.
  defp synthetic_chunk_id(%Platform.Files.File{id: id}), do: "file:" <> to_string(id)

  @doc """
  Builds the `Platform.Memory` entry for a file's extracted text — the
  exact shape the ingest pipeline indexes (entry id == file id, so
  `Platform.Memory.delete([file.id])` is the matching scrub key).

  Public so `Platform.Files.restore_file/2` (task 019f7cb0 stage 2) can
  re-index a restored file from the cached extracted text without
  duplicating this shape or re-running extraction.
  """
  @spec memory_entry(Platform.Files.File.t(), String.t(), [String.t()] | nil) :: map()
  def memory_entry(file, text, pages) do
    %{
      id: file.id,
      content: text,
      memory_type: "document",
      # memory-service's MemoryEntry pydantic model requires `date`
      # (see `memory-service/src/memory_service/models.py`). Missing it
      # → 422 Unprocessable Entity and ingest_status="failed". Documents
      # aren't date-keyed for retrieval the way journal entries are, so
      # we stamp today's ISO date for accounting only — same convention
      # as `Platform.Org.Wiki.Indexer.Payload` uses for wiki pages.
      date: Date.utc_today() |> Date.to_iso8601(),
      project_id: file.project_id,
      org_id: file.org_id,
      metadata: %{
        "file_id" => file.id,
        "content_type" => file.content_type,
        "original_filename" => file.original_filename,
        "pages" => pages_metadata(pages)
      }
    }
  end

  # We only stamp the page count + total page text length here, not the
  # text itself (the bodies are already in the embedded chunks). Keeps
  # `metadata` cheap to ship around and easy to introspect.
  defp pages_metadata(nil), do: nil

  defp pages_metadata(pages) when is_list(pages) do
    %{
      "count" => length(pages),
      "sizes" => Enum.map(pages, &byte_size/1)
    }
  end

  defp insert_chunks(file, chunk_ids, pages) when is_list(chunk_ids) do
    chunk_ids
    |> Enum.with_index()
    |> Enum.each(fn {chunk_id, idx} ->
      attrs = %{
        file_id: file.id,
        chunk_external_id: chunk_id,
        page: page_for_index(pages, idx)
      }

      case Files.insert_chunk(attrs) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          # A unique-constraint clash here means we re-ran ingest for the
          # same file; that's fine — the existing row stays put.
          Logger.debug(fn ->
            "Platform.Files.Ingester chunk insert skipped: #{inspect(changeset.errors)}"
          end)
      end
    end)

    :ok
  end

  # Single-chunk pipeline: today's provider returns a count, not a
  # per-chunk id list, so we synthesize a single "file:<id>" chunk id
  # (see `synthetic_chunk_id/1`). When the provider behaviour starts
  # returning real per-chunk ids we'll bind page numbers properly; for
  # now we leave `:page` nil for the single-chunk case even when
  # `pages` is a list.
  defp page_for_index(_pages, _idx), do: nil

  defp copy_chunks_from(%Platform.Files.File{id: prior_id}, %Platform.Files.File{id: file_id}) do
    prior_id
    |> Files.list_chunks_for_file()
    |> Enum.each(fn chunk ->
      attrs = %{
        file_id: file_id,
        chunk_external_id: chunk.chunk_external_id,
        page: chunk.page
      }

      case Files.insert_chunk(attrs) do
        {:ok, _} -> :ok
        {:error, _changeset} -> :ok
      end
    end)

    :ok
  end

  # Classifies a raw failure term into the `{stage, detail_term}` pair the
  # `Files.update_ingest_status/3` seam persists.
  #
  # THE STAGE PREFIX IS THE FEATURE. Most production failures record the
  # same transient embed error; the value of the column is that the odd one
  # out is visibly a DIFFERENT KIND of problem. Raw machine tails do not
  # sort themselves into kinds for a reader, so if anything has to give,
  # detail fidelity gives and the category stays.
  #
  # The two categories demand OPPOSITE responses, which is the whole reason
  # `:storage` is not folded into `:extract`:
  #
  #   * `:extract` — we HAVE the bytes and could not read them. The store is
  #     fine; the document is the problem. Re-export it.
  #   * `:storage` — we never GOT the bytes. The file is fine; the store is
  #     the problem. Fixing the document changes nothing.
  #
  # `Extractor.extract/1` returns both kinds through one `{:error, reason}`
  # channel, so the byte-fetch failures arrive wearing an extract error's
  # clothes and have to be re-homed here by reason.
  @spec classify_failure(term()) :: {:extract | :embed | :storage, term()}
  defp classify_failure({:memory_ingest_failed, reason}), do: {:embed, reason}

  # `Extractor.local_path/1` — no storage key on the row at all.
  defp classify_failure({:extract_failed, :missing_storage_key}),
    do: {:storage, :missing_storage_key}

  # `Extractor.local_path/1` — the configured adapter cannot hand us a path.
  defp classify_failure({:extract_failed, :unsupported_adapter}),
    do: {:storage, :unsupported_adapter}

  # `Extractor.fetch_bytes/2`'s `File.read/1` leg, both the tagged shape and
  # the bare posix atom the stdlib actually returns.
  defp classify_failure({:extract_failed, {:file_read_failed, detail}}),
    do: {:storage, {:file_read_failed, detail}}

  defp classify_failure({:extract_failed, reason})
       when reason in [:enoent, :eacces, :eisdir, :enotdir, :enospc, :eperm, :eio],
       do: {:storage, reason}

  # Everything else out of the extractor — including
  # `{:unsupported_content_type, _}` — is a genuine read-the-bytes failure.
  defp classify_failure({:extract_failed, reason}), do: {:extract, reason}

  defp mark_failed(file, {stage, detail}) do
    # Reload to avoid stomping a concurrent update. Best-effort.
    #
    # This runs inside the outer `try/catch` in `run/1` — but the
    # `catch kind, reason ->` clause only wraps `do_run/3`. When
    # `Files.get_file/1` (a `Repo.get`) is invoked from a
    # `Task.Supervisor`-spawned child whose `$callers` chain is empty
    # (production: Cowboy handler / PubSub broadcast; test: the
    # cascade repro), the `Repo.get` raises `DBConnection.OwnershipError`
    # and the raise escapes `mark_failed/2` entirely — reproducing the
    # 2026-07-03 cascade shape from the *ingest* seam rather than the
    # summarizer seam. Guard it explicitly so the sandbox-unowned Task
    # exits `:normal` and the escape can no longer ride this path.
    #
    # See apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md.
    try do
      case Files.get_file(file.id) do
        nil ->
          :ok

        %Platform.Files.File{} = current ->
          # ONE call site for the log, so the three failure paths cannot
          # drift apart. This does not replace the column — the column is
          # the durable, user-visible record — it closes the hole where
          # grepping a running container's logs for a returned-error
          # failure produced zero lines.
          Logger.warning(
            "[Files.Ingester] ingest failed file=#{current.id} stage=#{stage} " <>
              "detail=#{inspect(detail, limit: 20, printable_limit: 200)}"
          )

          Files.update_ingest_status(current, "failed",
            failure_stage: stage,
            failure_detail: detail
          )
      end
    rescue
      DBConnection.OwnershipError ->
        Logger.debug(
          "[Files.Ingester] sandbox-owned DB call from Task.Supervised — treating mark_failed as no-op"
        )

        :ok
    end
  end

  defp emit_stop(monotonic_start, start_meta, extra_meta) do
    duration = System.monotonic_time() - monotonic_start
    chunk_count = Map.get(extra_meta, :chunk_count, 0)
    extracted_chars = Map.get(extra_meta, :extracted_chars, 0)

    measurements = %{duration: duration, extracted_chars: extracted_chars}

    meta =
      start_meta
      |> Map.put(:dedup, Map.get(extra_meta, :dedup, false))
      |> Map.put(:chunk_count, chunk_count)

    :telemetry.execute(@event_prefix ++ [:stop], measurements, meta)
  end

  defp emit_exception(monotonic_start, start_meta, kind, reason) do
    duration = System.monotonic_time() - monotonic_start

    :telemetry.execute(
      @event_prefix ++ [:exception],
      %{duration: duration},
      Map.merge(start_meta, %{kind: kind, reason: reason, stacktrace: []})
    )
  end
end
