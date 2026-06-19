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

  alias Platform.Files.Chunk
  alias Platform.Files.File
  alias Platform.Files.Text
  alias Platform.Repo

  @doc """
  Inserts a new file row.

  Wraps `File.changeset/2` so callers (the eventual upload pipeline and
  Stage 6 backfill) hit the same validation surface. Returns
  `{:ok, file}` or `{:error, changeset}`.
  """
  @spec create_file(map()) :: {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def create_file(attrs) when is_map(attrs) do
    %File{}
    |> File.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a file by id. Returns nil when absent (mirrors `Platform.Tasks`).
  """
  @spec get_file(binary()) :: File.t() | nil
  def get_file(id) when is_binary(id), do: Repo.get(File, id)

  @doc """
  Fetches a file by id and raises `Ecto.NoResultsError` when absent.
  """
  @spec get_file!(binary()) :: File.t()
  def get_file!(id) when is_binary(id), do: Repo.get!(File, id)

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
    |> where([f], f.project_id == ^project_id)
    |> maybe_filter_content_type(content_type)
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Deletes a file row (does NOT touch the underlying object store).

  Callers that own the bytes should also call `Platform.Files.Storage.delete/1`
  with the file's `storage_key`. We keep these explicit because the
  Stage 6 backfill points two tables (chat_attachments + platform_files)
  at the same object key — neither table owns deletion of the other's
  bytes.
  """
  @spec delete_file(File.t()) :: {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def delete_file(%File{} = file), do: Repo.delete(file)

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
end
