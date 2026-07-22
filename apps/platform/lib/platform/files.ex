defmodule Platform.Files do
  @moduledoc """
  Context module for the project-scoped document/file store (ADR 0042).

  Stage 1 ships the schema + storage wrapper only — extraction (Stage 2),
  ingestion (Stage 3), the MCP surface (Stage 4), and the LiveView UI
  (Stage 5) build on top of this layer.

  ## Scoping

  Every `Platform.Files.File` carries a required `project_id`. Org-level
  spans (`org_id`) are supported but optional; see ADR 0042 for the
  topology rationale. The deprecated `workspace_id` concept is NOT used
  here — files were never on the old workspace plane.

  ## Storage

  Bytes live behind `Platform.Files.Storage`, a thin wrapper over the
  existing chat-attachments adapter so dev/test (local disk) and prod
  (R2/S3) work identically. The `storage_key` on each row is the opaque
  handle into that adapter.
  """

  import Ecto.Query

  require Logger

  alias Platform.Files.Chunk
  alias Platform.Files.File
  alias Platform.Files.Text
  alias Platform.Repo
  alias Platform.Tenancy.Lifecycle

  @doc """
  Inserts a new file row.

  Wraps `File.changeset/2` so callers (the eventual upload pipeline and
  Stage 6 backfill) hit the same validation surface. Returns
  `{:ok, file}` or `{:error, changeset}`.
  """
  @spec create_file(map()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t() | :project_archived}
  def create_file(attrs) when is_map(attrs) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- Lifecycle.ensure_project_writable(project_id) do
      %File{}
      |> File.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Fetches a file by id. Returns nil when absent (mirrors `Platform.Tasks`).

  Soft-deleted rows read as absent by default — a deleted file must be
  invisible on every get path (task 019f7cb0 stage 2). Pass
  `include_deleted: true` to fetch a deleted row anyway; that escape
  hatch exists for the restore path (`restore_file/2` callers need to
  load the row they are about to bring back).
  """
  @spec get_file(binary(), keyword()) :: File.t() | nil
  def get_file(id, opts \\ []) when is_binary(id) do
    File
    |> maybe_exclude_deleted(opts)
    |> Repo.get(id)
  end

  @doc """
  Fetches a file by id and raises `Ecto.NoResultsError` when absent.
  Soft-deleted rows raise too (same visibility contract as `get_file/2`);
  pass `include_deleted: true` to fetch a deleted row.
  """
  @spec get_file!(binary(), keyword()) :: File.t()
  def get_file!(id, opts \\ []) when is_binary(id) do
    File
    |> maybe_exclude_deleted(opts)
    |> Repo.get!(id)
  end

  @doc """
  Composable soft-delete exclusion: narrows a `Platform.Files.File` query
  to rows that are not marked deleted. Applied at the query root by every
  get/list/search path in this module; exposed so later stages (the MCP
  surface, the purge sweeper's inverse) compose against the same
  predicate instead of re-spelling `is_nil(deleted_at)`.
  """
  @spec not_deleted(Ecto.Queryable.t()) :: Ecto.Query.t()
  def not_deleted(query) do
    where(query, [f], is_nil(f.deleted_at))
  end

  @doc """
  Lists files for a project, newest first.

  ## Options

    * `:limit` — caps the result count (default 50; nil disables the cap).
    * `:content_type` — exact-match filter on `content_type`. Useful for
      "only images" / "only PDFs" admin views (Stage 5).
    * `:preload` — Ecto preload spec applied after the query (e.g. `:project`).
  """
  @spec list_files_for_project(binary(), keyword()) :: [File.t()]
  def list_files_for_project(project_id, opts \\ []) when is_binary(project_id) do
    limit = Keyword.get(opts, :limit, 50)
    content_type = Keyword.get(opts, :content_type)
    preload = Keyword.get(opts, :preload, [])

    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> maybe_filter_content_type(content_type)
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Soft-deletes a file on behalf of `actor` (task 019f7cb0 stage 2).

  Marks the row `deleted_at` — from that moment the file is invisible on
  every get/list/search path in this module — then, in order:

    1. scrubs the file's entry from the AI search index
       (`Platform.Memory.delete/1` under the file's id, the same id the
       ingest pipeline indexed it under), so deleted files stop occupying
       ranking slots instead of merely being filtered at query time;
    2. emits the `[:platform, :files, :file_deleted]` audit event (same
       telemetry→audit bridge `Platform.Tenancy.Lifecycle` uses), with
       the actor attributed;
    3. broadcasts `{:file_deleted, file_id}` on the project topic so open
       Files pages drop the row instantly.

  The index scrub is best-effort AFTER the DB commit: the row's hidden
  state is the source of truth (query-time exclusion covers a stale
  embedding until re-scrub), and a memory-service outage must not make
  files undeletable. Failures are logged.

  Actor-first: `actor` must be a map with a binary `:id` (the platform
  convention — every delete is attributable). It may also carry an
  optional `:type` string for the audit row's `actor_type` — the MCP
  `file_delete` tool passes `"agent"`; absent, an actor map audits as
  `"user"`. There is deliberately no role gate beyond that: the ratified
  scope is attribution + the project-writable freeze, and the stage-5 UI
  exposes delete to regular users. Errors: `{:error, :unauthorized}`
  (missing/anonymous actor), `{:error, :project_archived}`,
  `{:error, :already_deleted}`.

  The row is retained for the 30-day restore window; the stage-3 sweeper
  owns permanent purge.
  """
  @spec delete_file(map() | nil, File.t()) ::
          {:ok, File.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :project_archived | :already_deleted}
  def delete_file(actor, %File{} = file) do
    with :ok <- ensure_actor(actor),
         :ok <- Lifecycle.ensure_project_writable(file.project_id),
         :ok <- ensure_not_yet_deleted(file),
         {:ok, deleted} <-
           file
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
           |> Repo.update() do
      scrub_search_index(deleted)
      emit([:platform, :files, :file_deleted], actor, file_meta(deleted, %{}))
      _ = broadcast_deleted(deleted.project_id, deleted.id)
      {:ok, deleted}
    end
  end

  @doc """
  Restores a soft-deleted file on behalf of `actor` (task 019f7cb0
  stage 2) — the path the stage-5 Undo toast will call.

  Clears `deleted_at`, then:

    1. re-indexes the file into the AI search index from the cached
       extracted text (`platform_file_texts`) — no re-extraction. A file
       with no cached text (never ingested, or extract failed) had no
       index entry to restore, so the re-index is skipped with a log;
    2. emits the `[:platform, :files, :file_restored]` audit event;
    3. broadcasts `{:file_restored, file_id}` on the project topic (no
       subscriber yet — a Phoenix PubSub no-op until the stage-5 UI
       arrives; producer ships first).

  Returns the RE-FETCHED file row so the UI can reinsert it directly.
  The re-index runs async (mirrors the ingest pipeline's fire-and-forget
  contract). Errors: `{:error, :unauthorized}`, `{:error,
  :project_archived}`, `{:error, :not_deleted}` when the file isn't
  soft-deleted.
  """
  @spec restore_file(map() | nil, File.t()) ::
          {:ok, File.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :project_archived | :not_deleted}
  def restore_file(actor, %File{} = file) do
    with :ok <- ensure_actor(actor),
         :ok <- Lifecycle.ensure_project_writable(file.project_id),
         :ok <- ensure_deleted(file),
         {:ok, _} <-
           file
           |> Ecto.Changeset.change(deleted_at: nil)
           |> Repo.update() do
      restored = get_file!(file.id)
      reindex_from_cached_text(restored)
      emit([:platform, :files, :file_restored], actor, file_meta(restored, %{}))
      _ = broadcast_restored(restored.project_id, restored.id)
      {:ok, restored}
    end
  end

  @doc """
  Updates the `:ingest_status` field on a `Platform.Files.File`.

  Used by `Platform.Files.Ingester` to mark `:ingested` / `:failed`
  after the memory-service round-trip. Returns the updated file row.
  """
  @spec update_ingest_status(File.t(), String.t()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def update_ingest_status(%File{} = file, status)
      when status in ~w(pending ingested failed) do
    file
    |> File.changeset(%{ingest_status: status})
    |> Repo.update()
  end

  # ── PubSub helpers ─────────────────────────────────────────────────────

  @doc """
  PubSub topic for a project's file events. Subscribers receive messages
  in the shape `{:file_ingested, file_id}` and `{:file_ingest_failed, file_id}`
  when `Platform.Files.Ingester` finishes a run.

  Used by `PlatformWeb.FilesLive` so the per-row "Ingesting…" pill flips
  to "Ready" without a manual refresh.
  """
  @spec project_topic(String.t()) :: String.t()
  def project_topic(project_id) when is_binary(project_id),
    do: "files:project:" <> project_id

  @doc """
  Subscribes the calling process to a project's file events. Safe to call
  more than once per process (Phoenix.PubSub.subscribe is idempotent).
  """
  @spec subscribe_project(String.t()) :: :ok | {:error, term()}
  def subscribe_project(project_id) when is_binary(project_id) do
    Phoenix.PubSub.subscribe(Platform.PubSub, project_topic(project_id))
  end

  @doc """
  Broadcasts a file event onto the project topic. Currently used by
  `Platform.Files.Ingester` after a run resolves so subscribed
  LiveViews can refresh the corresponding row in their stream.
  """
  @spec broadcast_project(String.t(), term()) :: :ok | {:error, term()}
  def broadcast_project(project_id, message) when is_binary(project_id) do
    Phoenix.PubSub.broadcast(Platform.PubSub, project_topic(project_id), message)
  end

  @doc """
  Convenience: broadcasts `{:file_deleted, file_id}` on the project
  topic. Emitted by `delete_file/2` (the single delete path for both the
  `file_delete` MCP tool and the stage-5 UI) so live UIs drop the row
  without a manual refresh — mirrors the `{:file_ingested, file_id}`
  shape `Platform.Files.Ingester` emits.
  """
  @spec broadcast_deleted(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_deleted(project_id, file_id)
      when is_binary(project_id) and is_binary(file_id) do
    broadcast_project(project_id, {:file_deleted, file_id})
  end

  @doc """
  Convenience: broadcasts `{:file_restored, file_id}` on the project
  topic. Emitted by `restore_file/2`; no subscriber consumes it yet —
  the stage-5 Files UI will reinsert the row on receipt. A broadcast
  with no subscriber is a safe no-op in Phoenix PubSub.
  """
  @spec broadcast_restored(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_restored(project_id, file_id)
      when is_binary(project_id) and is_binary(file_id) do
    broadcast_project(project_id, {:file_restored, file_id})
  end

  @doc """
  Returns the most recent successfully-ingested file row in `project_id`
  whose `content_hash` matches `hash`, or nil. Used by the Stage 3
  ingester to short-circuit extract + embed when the same bytes have
  already been processed for this project.

  Project-scoped on purpose — cross-project dedup is intentionally NOT
  done (project isolation is the boundary; the same bytes uploaded into
  two projects produce two independent rows + two embed runs).
  """
  @spec find_ingested_sibling(String.t(), String.t()) :: File.t() | nil
  def find_ingested_sibling(project_id, hash)
      when is_binary(project_id) and is_binary(hash) do
    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> where([f], f.content_hash == ^hash)
    |> where([f], f.ingest_status == "ingested")
    |> order_by([f], desc: f.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Inserts a chunk back-reference row. Returns the chunk struct or a
  changeset error (e.g. duplicate `chunk_external_id` for the file).
  """
  @spec insert_chunk(map()) :: {:ok, Chunk.t()} | {:error, Ecto.Changeset.t()}
  def insert_chunk(attrs) when is_map(attrs) do
    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the `Platform.Files.Chunk` rows linked to a file, oldest first.
  """
  @spec list_chunks_for_file(binary()) :: [Chunk.t()]
  def list_chunks_for_file(file_id) when is_binary(file_id) do
    Chunk
    |> where([c], c.file_id == ^file_id)
    |> order_by([c], asc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Upserts the cached extracted text for a file.

  One row per file (PK is `file_id`); re-running ingest overwrites the
  prior body and page split so consumers always see the freshest
  extraction. Stage 4 of ADR 0042 — backs `file_get_text` MCP reads so
  we don't re-shell-out to pdftotext / pandoc on every read.
  """
  @spec upsert_extracted_text(binary(), String.t(), [String.t()] | nil) ::
          {:ok, Text.t()} | {:error, Ecto.Changeset.t()}
  def upsert_extracted_text(file_id, text, pages \\ nil)
      when is_binary(file_id) and is_binary(text) do
    attrs = %{file_id: file_id, text: text, pages: pages}

    %Text{}
    |> Text.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:text, :pages]},
      conflict_target: [:file_id]
    )
  end

  @doc """
  Fetches the cached extracted-text row for a file. Returns nil when no
  row exists yet (file is still ingesting / ingest failed / not text-
  bearing). Returns `%Platform.Files.Text{}` on hit so callers can read
  the full `text` or the per-page split.
  """
  @spec fetch_extracted_text(binary()) :: Text.t() | nil
  def fetch_extracted_text(file_id) when is_binary(file_id) do
    Repo.get(Text, file_id)
  end

  defp maybe_filter_content_type(query, nil), do: query

  defp maybe_filter_content_type(query, content_type) when is_binary(content_type) do
    where(query, [f], f.content_type == ^content_type)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)

  defp maybe_exclude_deleted(query, opts) do
    if Keyword.get(opts, :include_deleted, false),
      do: query,
      else: not_deleted(query)
  end

  # ── Soft-delete internals (task 019f7cb0 stage 2) ─────────────────────

  # Actor-first guard: delete/restore must always know WHO acts (platform
  # convention). Anonymous/malformed actors are rejected before any write.
  defp ensure_actor(%{id: id}) when is_binary(id), do: :ok
  defp ensure_actor(_), do: {:error, :unauthorized}

  defp ensure_not_yet_deleted(%File{deleted_at: nil}), do: :ok
  defp ensure_not_yet_deleted(%File{}), do: {:error, :already_deleted}

  defp ensure_deleted(%File{deleted_at: %DateTime{}}), do: :ok
  defp ensure_deleted(%File{}), do: {:error, :not_deleted}

  # Remove the file's entry from the vector index. The ingest pipeline
  # indexes each file under its own row id (`Platform.Files.Ingester`
  # builds the memory entry with `id: file.id`), so that id is the scrub
  # key. Best-effort after commit — see `delete_file/2` doc.
  #
  # Scrubbing by this file's id ALONE is safe only because the strict
  # UNIQUE (content_hash, project_id) index guarantees no byte-identical
  # sibling row can coexist in the project (soft-deleted rows still
  # occupy the slot) — so no surviving file can be relying on this
  # index entry for its searchability. Task 019f7cb0 stage 4 verified
  # this before closing the ratified "identical twins" concern; the
  # invariant is pinned by "content-hash unique slot" tests in
  # `Platform.FilesTest` / `Platform.Files.SoftDeleteTest`. If the
  # deferred re-upload collision work ever relaxes that index (e.g. to
  # a partial index over live rows), REVISIT this scrub: deleting one
  # twin must not orphan the surviving twin's search entry — re-ingest
  # the survivor from its cached text (`reindex_from_cached_text/1`
  # shape) or key the scrub on sole ownership.
  defp scrub_search_index(%File{} = file) do
    case Platform.Memory.delete([file.id]) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Platform.Files search-index scrub failed for file=#{file.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Re-index a restored file from the cached extracted text — the inverse
  # of `scrub_search_index/1`, without re-running extraction. Async via
  # `Memory.ingest_async/1` (same fire-and-forget contract as ingest).
  defp reindex_from_cached_text(%File{} = file) do
    case fetch_extracted_text(file.id) do
      %Text{text: text, pages: pages} ->
        entry = Platform.Files.Ingester.memory_entry(file, text, pages)
        Platform.Memory.ingest_async([entry])

      nil ->
        Logger.info(
          "Platform.Files restore skipped re-index for file=#{file.id}: " <>
            "no cached extracted text (file was never indexed)"
        )

        :ok
    end
  end

  # Same telemetry→audit bridge pattern as `Platform.Tenancy.Lifecycle.emit/3`:
  # events registered in `Platform.Audit.TelemetryHandler` @events, metadata
  # restricted to JSON-safe scalars, emitted AFTER the DB write commits.
  defp emit([_ | _] = event_name, actor, meta) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      Map.merge(
        %{
          actor_id: actor && Map.get(actor, :id),
          actor_type: actor_audit_type(actor),
          action: event_name |> List.last() |> Atom.to_string()
        },
        meta
      )
    )

    :ok
  end

  # Audit `actor_type` for an actor map. Callers may tag the actor with an
  # explicit `:type` (the MCP tool surface passes "agent" — task 019f7cb0
  # stage 4); an untagged actor map is a human ("user"); no actor at all is
  # a system action. Values must be in Platform.Audit.Event's actor_type
  # enum (system|user|agent|anonymous|federated_user) or the bridged audit
  # insert is rejected.
  defp actor_audit_type(nil), do: "system"
  defp actor_audit_type(%{type: type}) when is_binary(type), do: type
  defp actor_audit_type(actor) when is_map(actor), do: "user"

  defp file_meta(%File{} = file, extra) do
    Map.merge(
      %{
        resource_type: "file",
        resource_id: file.id,
        project_id: file.project_id,
        org_id: file.org_id,
        file_name: file.name || file.original_filename
      },
      extra
    )
  end
end
