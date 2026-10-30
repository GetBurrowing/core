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

  ## Default ingestion intent

  This function is the single choke point for file creation, so the
  content-type-derived default lives here rather than at each caller.
  When the attrs carry no `:ingest_intent` (atom or string key), the
  intent is derived by `default_ingest_intent/1`: `"attempt"` for a
  content type the extractor's dispatch table can actually handle,
  `"human_only"` for everything else (including a nil content type).

  An explicit caller-supplied `ingest_intent` always wins — that is what
  lets the upload UI hold back a PDF it knows is human reading material,
  or push a format the extractor would otherwise skip.

  A resolved `"human_only"` intent also seeds `ingest_status` with
  `"not_attempted"`. Nothing enqueues a human_only file, so leaving the
  schema's `"pending"` default in place would strand the row rendering
  as "Ingesting…" forever.
  """
  @spec create_file(map()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t() | :project_archived}
  def create_file(attrs) when is_map(attrs) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- Lifecycle.ensure_project_writable(project_id) do
      %File{}
      |> File.changeset(put_default_ingest_intent(attrs))
      |> Repo.insert()
    end
  end

  @doc """
  Store in-memory `bytes` as a file of `project` — the one ingest path for
  bytes a caller already holds.

  Extracted from the `file_add` MCP tool's inline branch (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4) so the Email module's "Add
  to files" writes through the same code instead of a second store. In order:

    1. `Platform.Files.Storage.put/3` persists the bytes under a fresh key;
    2. `find_ingested_sibling/2` dedupes on the content hash within the
       project — on a hit the just-written bytes are deleted (best effort)
       and the existing row is returned;
    3. otherwise `create_file/1` inserts the `platform_files` row and
       `Platform.Files.Ingester.ingest_async/1` is fired.

  Options:

    * `:uploaded_by_user_id` — recorded on a new row (default `nil`);
    * `:ingest` — `false` skips step 3's `ingest_async/1`, for a caller that
      runs this inside its own transaction and must enqueue after commit
      (the ingester reads the row from another process). Default `true`.

  Returns `{:ok, file, deduplicated?}`, `{:error, {:persist_failed,
  reason}}`, or `create_file/1`'s error (the bytes are deleted first).
  """
  @spec add_bytes(map(), binary(), String.t(), String.t(), keyword()) ::
          {:ok, File.t(), boolean()}
          | {:error, {:persist_failed, term()} | Ecto.Changeset.t() | :project_archived}
  def add_bytes(%{id: project_id} = project, bytes, filename, content_type, opts \\ [])
      when is_binary(project_id) and is_binary(bytes) and is_binary(filename) do
    case Platform.Files.Storage.put({:binary, bytes}, project_id, filename: filename) do
      {:ok, %{storage_key: storage_key, content_hash: hash, byte_size: size}} ->
        case find_ingested_sibling(project_id, hash) do
          %File{} = sibling ->
            # Storage.put landed under a fresh key; the canonical row points
            # at its own, so the new key is orphaned.
            _ = Platform.Files.Storage.delete(storage_key)
            {:ok, sibling, true}

          nil ->
            insert_added_bytes(project, filename, content_type, size, storage_key, hash, opts)
        end

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  @doc """
  Persist bytes and a caller's database registration atomically. The callback runs
  before the finalized row is visible and returns `{:ok, value}` or `{:error, reason}`.
  On rollback, remove only a newly allocated object, never a deduplicated sibling.
  This keeps compensating storage cleanup inside the Files boundary.
  """
  def add_bytes_registered(project, bytes, filename, content_type, opts, register) do
    result =
      Repo.transaction(fn ->
        case add_bytes(project, bytes, filename, content_type, Keyword.put(opts, :ingest, false)) do
          {:ok, file, dedup?} ->
            registration =
              try do
                register.(file)
              rescue
                _ -> {:error, :registration_failed}
              catch
                _, _ -> {:error, :registration_failed}
              end

            case registration do
              {:ok, value} -> value
              {:error, reason} -> Repo.rollback({:registration_failed, reason, file, dedup?})
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:error, {:registration_failed, reason, file, dedup?}} ->
        unless dedup? or Repo.get(File, file.id),
          do: Platform.Files.Storage.delete(file.storage_key)

        {:error, reason}

      other ->
        other
    end
  end

  defp insert_added_bytes(project, filename, content_type, size, storage_key, hash, opts) do
    attrs = %{
      project_id: project.id,
      org_id: Map.get(project, :org_id),
      uploaded_by_user_id: Keyword.get(opts, :uploaded_by_user_id),
      name: filename,
      original_filename: filename,
      content_type: content_type,
      byte_size: size,
      storage_key: storage_key,
      content_hash: hash,
      ingest_status: "pending"
    }

    case create_file(attrs) do
      {:ok, file} ->
        if Keyword.get(opts, :ingest, true),
          do: :ok = Platform.Files.Ingester.ingest_async(file)

        {:ok, file, false}

      {:error, reason} ->
        _ = Platform.Files.Storage.delete(storage_key)
        {:error, reason}
    end
  end

  @doc """
  The ingestion intent a file of this content type gets when the caller
  does not specify one.

  Derived from `Platform.Files.Extractor.supported_content_type?/1` — the
  extractor's dispatch table is the single source of truth for "can this
  be turned into text?", so there is no second format list here to drift
  from it. A nil content type is unsupported and therefore `"human_only"`.
  """
  @spec default_ingest_intent(String.t() | nil) :: String.t()
  def default_ingest_intent(content_type) do
    if Platform.Files.Extractor.supported_content_type?(content_type) do
      "attempt"
    else
      "human_only"
    end
  end

  defp put_default_ingest_intent(attrs) do
    case {Map.fetch(attrs, :ingest_intent), Map.fetch(attrs, "ingest_intent")} do
      {:error, :error} ->
        attrs
        |> put_attr(
          :ingest_intent,
          default_ingest_intent(attrs[:content_type] || attrs["content_type"])
        )
        |> seed_status_for_human_only()

      _ ->
        seed_status_for_human_only(attrs)
    end
  end

  # A human_only row is never enqueued, so its status starts (and stays)
  # at "not_attempted" until `request_ingest/1` flips the intent. Applies
  # to an explicitly-supplied human_only just as much as a derived one —
  # the upload UI holding back a PDF hits the same stranding otherwise.
  # An explicit ingest_status still wins (backfill replays real outcomes).
  defp seed_status_for_human_only(attrs) do
    explicit_status? =
      Map.has_key?(attrs, :ingest_status) or Map.has_key?(attrs, "ingest_status")

    if not explicit_status? and (attrs[:ingest_intent] || attrs["ingest_intent"]) == "human_only" do
      put_attr(attrs, :ingest_status, "not_attempted")
    else
      attrs
    end
  end

  # Keeps the key style of the map the caller handed us: a string-key
  # attrs map stays entirely string-keyed (Ecto rejects mixed maps).
  defp put_attr(attrs, key, value) do
    if Enum.any?(attrs, fn {k, _} -> is_binary(k) end) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
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
    # `file_id` is a raw MCP argument (file_get_metadata / file_get_text /
    # file_delete). Platform.UUID.valid?/1, not a bare Ecto.UUID.cast/1 — a
    # bare cast accepts any 16-byte binary and the raise lands inside Repo.
    if Platform.UUID.valid?(id) do
      File
      |> maybe_exclude_deleted(opts)
      |> Repo.get(id)
    else
      nil
    end
  end

  @doc """
  Fetches a file by id and raises `Ecto.NoResultsError` when absent.
  Soft-deleted rows raise too (same visibility contract as `get_file/2`);
  pass `include_deleted: true` to fetch a deleted row.
  """
  @spec get_file!(binary(), keyword()) :: File.t()
  def get_file!(id, opts \\ []) when is_binary(id) do
    # Documented contract is `Ecto.NoResultsError` when absent, so a malformed
    # id raises THAT rather than `Ecto.Query.CastError` — malformed and absent
    # are the same outcome to every caller.
    if Platform.UUID.valid?(id) do
      File
      |> maybe_exclude_deleted(opts)
      |> Repo.get!(id)
    else
      raise Ecto.NoResultsError, queryable: File
    end
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
  The wiki `file_key`s that are catalog cards — one row per live file
  that has one (task 01a0008c stage 4).

  **This is the single definition of "is this wiki page a catalog
  card?"**, and it exists because the answer partitions the Historian's
  corpora: a card page is charged to the `files` corpus and must NOT
  also be charged to `pages`. Both sides of that partition compose this
  query (`Platform.Org.Wiki.only_card_pages/1` and
  `exclude_card_pages/1`), so they cannot disagree about which rows they
  are talking about. Two hand-written predicates would eventually
  double-charge a card or drop one entirely, which is the same defect
  class task `019fa1cc` spent five stages removing from the messages
  corpus.

  Returns an `Ecto.Query` selecting `card_file_key`, intended for
  `subquery/1` — never `Repo.all/1` into an `IN ^list`, which would
  materialise the whole card set into the app.

  Soft-deleted files are excluded via `not_deleted/1`: their card page
  is no longer backed by a live file, so it falls back to being an
  ordinary wiki page rather than becoming invisible to both corpora.
  """
  @spec card_page_keys_query() :: Ecto.Query.t()
  def card_page_keys_query do
    File
    |> not_deleted()
    |> where([f], not is_nil(f.card_file_key))
    |> select([f], f.card_file_key)
  end

  @doc """
  Lists files for a project, newest first.

  ## Options

    * `:limit` — caps the result count (default 50; nil disables the cap).
    * `:content_type` — exact-match filter on `content_type`. Useful for
      "only images" / "only PDFs" admin views (Stage 5).
    * `:ingest_intent` — exact-match filter on `ingest_intent`
      (`"attempt"` / `"human_only"`). `nil` means no filter.
    * `:ingest_status` — exact-match filter on `ingest_status`
      (`"pending"` / `"ingested"` / `"failed"` / `"not_attempted"`).
      `nil` means no filter.
    * `:preload` — Ecto preload spec applied after the query (e.g. `:project`).
  """
  @spec list_files_for_project(binary(), keyword()) :: [File.t()]
  def list_files_for_project(project_id, opts \\ []) when is_binary(project_id) do
    limit = Keyword.get(opts, :limit, 50)
    preload = Keyword.get(opts, :preload, [])

    project_id
    |> project_files_query(opts)
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc "True for a finalized, non-deleted upload with storage identity; reservations are false."
  def finalized_upload?(%File{} = file) do
    is_nil(file.deleted_at) and is_binary(file.content_hash) and file.content_hash != "" and
      is_binary(file.storage_key) and file.storage_key != "" and is_integer(file.byte_size) and
      file.byte_size > 0
  end

  def finalized_upload?(_), do: false

  @doc """
  Lists live files across `project_ids`, most recently changed first
  (`updated_at` desc), with `:uploaded_by_user` preloaded for its display
  name. The Recents and type views of `Platform.Files.Browser`
  (task 01a1557a-b5f9 stage 1).

  `project_ids` must be DB-derived (the viewer's readable projects); this
  function does no viewer scoping of its own. An empty list returns `[]`
  without a query.

  ## Options

    * `:since` — only files with `updated_at` at or after this instant.
    * `:limit` — caps the result count (default 50; nil disables the cap).
    * `:type` — `:image` (an `image/*` content type) or `:doc` (anything
      else); absent means both.
  """
  @spec list_recent_files_for_projects([binary()], keyword()) :: [File.t()]
  def list_recent_files_for_projects(project_ids, opts \\ [])

  def list_recent_files_for_projects([], _opts), do: []

  def list_recent_files_for_projects(project_ids, opts) when is_list(project_ids) do
    File
    |> not_deleted()
    |> where([f], f.project_id in ^project_ids)
    |> maybe_updated_since(Keyword.get(opts, :since))
    |> maybe_filter_file_type(Keyword.get(opts, :type))
    |> order_by([f], desc: f.updated_at, desc: f.id)
    |> maybe_limit(Keyword.get(opts, :limit, 50))
    |> Repo.all()
    |> Repo.preload(:uploaded_by_user)
  end

  @doc """
  Searches live files across `project_ids` by a case-insensitive substring
  of `name` or `original_filename`, newest `updated_at` first, with
  `:uploaded_by_user` preloaded. `%`, `_` and `\\` in `query` match
  literally (they are escaped before the `ILIKE`).

  `project_ids` must be DB-derived. An empty id list, or a blank query,
  returns `[]` without a query.

  ## Options

    * `:limit` — caps the result count (default 25).
  """
  @spec search_files_by_name([binary()], String.t(), keyword()) :: [File.t()]
  def search_files_by_name(project_ids, query, opts \\ [])

  def search_files_by_name([], _query, _opts), do: []

  def search_files_by_name(project_ids, query, opts)
      when is_list(project_ids) and is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      trimmed ->
        pattern = "%" <> escape_like(trimmed) <> "%"

        File
        |> not_deleted()
        |> where([f], f.project_id in ^project_ids)
        |> where([f], ilike(f.name, ^pattern) or ilike(f.original_filename, ^pattern))
        |> order_by([f], desc: f.updated_at, desc: f.id)
        |> maybe_limit(Keyword.get(opts, :limit, 25))
        |> Repo.all()
        |> Repo.preload(:uploaded_by_user)
    end
  end

  def search_files_by_name(_project_ids, _query, _opts), do: []

  defp maybe_updated_since(query, nil), do: query
  defp maybe_updated_since(query, since), do: where(query, [f], f.updated_at >= ^since)

  defp maybe_filter_file_type(query, nil), do: query

  defp maybe_filter_file_type(query, :image),
    do: where(query, [f], ilike(f.content_type, "image/%"))

  defp maybe_filter_file_type(query, :doc),
    do: where(query, [f], is_nil(f.content_type) or not ilike(f.content_type, "image/%"))

  # Backslash first, so the escapes added for `%` and `_` are not doubled.
  defp escape_like(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Counts the files `list_files_for_project/2` would return with no limit
  (task 01a04a7a stage 2), in the database.

  Takes the same filter options (`:content_type`, `:ingest_intent`,
  `:ingest_status`); `:limit` and `:preload` are ignored. The count and the
  list share one private query builder (`project_files_query/2`), so they
  cannot be taken over different sets — which is what lets `file_list`
  report `total` / `has_more` truthfully.
  """
  @spec count_files_for_project(binary(), keyword()) :: non_neg_integer()
  def count_files_for_project(project_id, opts \\ []) when is_binary(project_id) do
    project_id
    |> project_files_query(opts)
    |> Repo.aggregate(:count)
  end

  defp project_files_query(project_id, opts) do
    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> maybe_filter_content_type(Keyword.get(opts, :content_type))
    |> maybe_filter_ingest_intent(Keyword.get(opts, :ingest_intent))
    |> maybe_filter_ingest_status(Keyword.get(opts, :ingest_status))
  end

  @doc """
  Counts the files in `project_id` whose extraction was ATTEMPTED and BROKE
  (task 01a0008b stage 2).

  A `Repo.aggregate(:count)` computed entirely in the database. It is
  deliberately NOT `length(list_failed_ingests(project_id))`, and
  deliberately not an option on `list_files_for_project/2`: that function
  caps at 50 by default and the Files page calls it with `limit: 200`, so a
  count taken from a loaded list starts under-reporting the moment a
  project outgrows the cap. A wrong number on a surface whose entire job is
  to be trusted is worse than no number.

  See `list_failed_ingests/2` for the predicate, which is shared.
  """
  @spec count_failed_ingests(binary()) :: non_neg_integer()
  def count_failed_ingests(project_id) when is_binary(project_id) do
    project_id
    |> failed_ingests_query()
    |> Repo.aggregate(:count)
  end

  @doc """
  Lists the files in `project_id` whose extraction was ATTEMPTED and BROKE,
  newest first (task 01a0008b stage 2).

  Each row carries `:ingest_failure_count`, so a caller can tell a file
  that broke once from one that has broken three times on the same
  unchanged bytes.

  ## The predicate, and the one distinction it exists to preserve

  A row is swept when ALL of the following hold:

    * `ingest_status == "failed"` — extraction ran and broke. A defect.
    * `ingest_intent == "attempt"` — we still mean to read this file.
    * not soft-deleted.

  `"not_attempted"` is EXCLUDED, and that exclusion is the point of this
  function. A `"not_attempted"` row carries `ingest_intent: "human_only"`,
  so `Platform.Files.Ingester.ingest_async/1` short-circuits before
  spawning anything: nothing was tried, nothing broke, and the state is
  terminal by design until someone calls `request_ingest/2`. It is a
  deliberate exclusion, not a breakage. Sweeping the two together would
  report every file a human intentionally withheld as something to repair,
  and that noise would bury the handful of real defects this sweep exists
  to surface.

  `Platform.Files.HtmlBackfill` matches `~w(failed not_attempted)` and is
  correct to — its job is re-attempting everything that lacks text. It is
  NOT a template for this predicate.

  `"human_only"` + `"failed"` is excluded too. The pair is legal (the
  `platform_files_not_attempted_requires_human_only_check` constraint
  forbids only `attempt` + `not_attempted`) and reachable by calling
  `set_ingest_intent/2` on a row that already failed. Someone deciding a
  broken file should stay human-only is an answer, not an open defect.

  ## Options

    * `:limit` — caps the result count. Defaults to `nil`, i.e. UNCAPPED,
      unlike `list_files_for_project/2`. A truncated repair list silently
      hides work.
    * `:preload` — Ecto preload spec applied after the query.
  """
  @spec list_failed_ingests(binary(), keyword()) :: [File.t()]
  def list_failed_ingests(project_id, opts \\ []) when is_binary(project_id) do
    project_id
    |> failed_ingests_query()
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
    |> Repo.preload(Keyword.get(opts, :preload, []))
  end

  # Single source of truth for the sweep predicate, so the count and the
  # list can never disagree about what "failed" means.
  defp failed_ingests_query(project_id) do
    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> where([f], f.ingest_status == "failed" and f.ingest_intent == "attempt")
  end

  @doc """
  Lists the files in a project that are eligible for catalog-card
  generation, oldest first (task 01a0008c).

  **This is the single eligibility seam for cataloging.** Every consumer
  — the card writer, the ingest telemetry emitter, the backfill mix task
  — enumerates through here. Nothing in the catalog path may hand-roll a
  `Repo.all(File)`: the exclusions below are not display filters, and a
  query that re-derives them will eventually re-derive them wrong.

  ## Exclusions

    * **`ingest_intent == "human_only"` — a disclosure boundary, not a
      filter nicety.** `Platform.Files.Ingester.ingest_async/1`
      short-circuits such a file to `"not_attempted"` *before* any
      telemetry, task spawn or `Extractor.extract/1` call, precisely so
      its bytes never reach a third-party extractor. An LLM card pass is
      the same class of disclosure. The telemetry path inherits that
      protection for free (no `:stop` event ever fires for these rows);
      a backfill running its own query inherits nothing, which is the
      whole reason this function exists.
    * **`ingest_status != "ingested"`.** A `pending` file has no text
      yet, a `failed` one never will, and `not_attempted` is the
      human_only marker again. Only `"ingested"` has something to
      summarize.
    * **`deleted_at` not nil** — soft-deleted rows are invisible on
      every other path in this module and must be here too.

  ## Options

    * `:limit` — **defaults to nil, meaning no cap.** Deliberately unlike
      `list_files_for_project/2`, which defaults to 50: a catalog that
      silently stops at 50 rows and reports success is the failure mode
      this default exists to prevent. A caller that wants a page must ask
      for one.
    * `:preload` — Ecto preload spec applied after the query.

  Ordered ascending by `inserted_at` with an id tiebreak, so a backfill
  run and a sibling list see the same sequence twice in a row.
  """
  @spec list_catalogable_files(binary(), keyword()) :: [File.t()]
  def list_catalogable_files(project_id, opts \\ []) when is_binary(project_id) do
    limit = Keyword.get(opts, :limit)
    preload = Keyword.get(opts, :preload, [])

    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> where([f], f.ingest_intent != "human_only")
    |> where([f], f.ingest_status == "ingested")
    |> order_by([f], asc: f.inserted_at, asc: f.id)
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
  Marks a file's own code as runnable, on behalf of `actor` (task
  01a06a20 stage 1) — the gate that decides whether a file may execute.

  Sets `interactive_at` (when) and `interactive_by_user_id` (who). NOT a
  boolean: after an incident the only question that matters is who
  turned scripts on and when, which a boolean can't answer. Mirrors the
  soft-delete shape of `delete_file/2` on this same struct: both fields
  sit OUTSIDE `File.changeset/2`'s `@cast_fields`, moved only by this
  function and `unmark_interactive/2` via a dedicated
  `Ecto.Changeset.change/2` — never through `cast/2` — so bulk attrs
  (an upload form, an MCP tool) can never flip a file's execute
  permission. There is deliberately no generic `update_file/2` on this
  module, and nothing here (or anywhere else in `Platform.Files`) casts
  `storage_key` after insert: that is what stops the gate being set on
  innocent bytes which are then swapped for hostile ones.

  Emits the `[:platform, :files, :file_interactive_marked]` audit event
  (same telemetry→audit bridge as the soft-delete pair) with the actor
  attributed. No search-index or PubSub side effect: the gate governs
  code execution, not visibility, and this stage is backend/DB only —
  there is no UI yet to react to a broadcast.

  Actor-first: `actor` must be a map with a binary `:id` (the platform
  convention — every gate flip is attributable), and `:id` must be a
  real user id — `interactive_by_user_id` is a genuine FK to `users`
  (unlike `deleted_at`'s bare timestamp), so a bogus id surfaces as
  `{:error, changeset}` rather than crashing. Errors:
  `{:error, :unauthorized}` (missing/anonymous actor),
  `{:error, :project_archived}`, `{:error, :already_interactive}`,
  `{:error, changeset}` (actor id references no user).
  """
  @spec mark_interactive(map() | nil, File.t()) ::
          {:ok, File.t()}
          | {:error,
             Ecto.Changeset.t() | :unauthorized | :project_archived | :already_interactive}
  def mark_interactive(actor, %File{} = file) do
    with :ok <- ensure_actor(actor),
         :ok <- Lifecycle.ensure_project_writable(file.project_id),
         :ok <- ensure_not_yet_interactive(file),
         {:ok, marked} <-
           file
           |> Ecto.Changeset.change(
             interactive_at: DateTime.utc_now(),
             interactive_by_user_id: actor.id
           )
           # Unlike `deleted_at`, `interactive_by_user_id` is a genuine FK
           # to `users` — a bogus actor id must surface as a changeset
           # error, not an unhandled `Ecto.ConstraintError` crash.
           |> Ecto.Changeset.foreign_key_constraint(:interactive_by_user_id)
           |> Repo.update() do
      emit([:platform, :files, :file_interactive_marked], actor, file_meta(marked, %{}))
      {:ok, marked}
    end
  end

  @doc """
  Clears the interactive-code gate on behalf of `actor` (task 01a06a20
  stage 1) — the inverse of `mark_interactive/2`.

  Clears both `interactive_at` and `interactive_by_user_id` together —
  the pair moves as one, so there is never a stale actor id sitting on a
  nil timestamp. Same dedicated-change / not-in-`@cast_fields` contract
  as `mark_interactive/2`.

  Emits the `[:platform, :files, :file_interactive_unmarked]` audit
  event with the actor attributed. Errors: `{:error, :unauthorized}`,
  `{:error, :project_archived}`, `{:error, :not_interactive}` when the
  gate is already closed.
  """
  @spec unmark_interactive(map() | nil, File.t()) ::
          {:ok, File.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :project_archived | :not_interactive}
  def unmark_interactive(actor, %File{} = file) do
    with :ok <- ensure_actor(actor),
         :ok <- Lifecycle.ensure_project_writable(file.project_id),
         :ok <- ensure_interactive(file),
         {:ok, unmarked} <-
           file
           |> Ecto.Changeset.change(interactive_at: nil, interactive_by_user_id: nil)
           |> Repo.update() do
      emit([:platform, :files, :file_interactive_unmarked], actor, file_meta(unmarked, %{}))
      {:ok, unmarked}
    end
  end

  @doc """
  Updates the `:ingest_status` field on a `Platform.Files.File`.

  Used by `Platform.Files.Ingester` to mark `:ingested` / `:failed`
  after the memory-service round-trip. Returns the updated file row.

  ## Contract: this is the only place `:ingest_failure_count` moves

  `:ingest_status` records the LATEST outcome, which cannot distinguish a
  file that broke once from one that has broken three times on the same
  unchanged bytes. `:ingest_failure_count` carries that history, and it is
  maintained here — at the single seam every `"failed"` and `"ingested"`
  write already passes through — rather than at the call sites:

    * `"failed"` — increments the count by one.
    * `"ingested"` — resets it to zero. The count is CONSECUTIVE failures;
      a success is what makes the streak end.
    * `"pending"` / `"not_attempted"` — leaves it byte-identical. A
      re-queue is not an outcome, so `request_ingest/2` (which writes
      `"pending"` on its own) must not clear the history either: three
      retries that all fail have to reach three, which is the entire point
      of the field.

  Maintaining it at the call sites instead would mean the ingester's
  `mark_failed/1`, its two dedup/success branches, and every future writer
  each remembering to do it — the same drift the enqueue choke point
  documented on `set_ingest_intent/2` exists to prevent.

  ## Contract: the failure REASON moves here too, and clears on success

  `:ingest_failure_stage` / `:ingest_failure_detail` (task 01a0166d) say
  WHAT broke, and follow the same rules as the count, at the same seam:

    * `"failed"` — writes both from `opts` (`:failure_stage`,
      `:failure_detail`). The stage must be one of `:extract` / `:embed` /
      `:storage`; anything else is a programmer error and is not silently
      stored.
    * `"ingested"` — clears BOTH to nil. Mandatory, not tidiness: a stale
      reason surviving a success makes the next reader diagnose a fixed
      file from a dead string, which is the same defect class this ticket
      exists to remove.
    * `"pending"` / `"not_attempted"` — leaves both byte-identical, matching
      the count contract. A re-queue is not an outcome, and the reason has
      to stay readable while a retry is in flight.

  `update_ingest_status/2` delegates here with no opts, so a caller with
  nothing to record writes nil-nothing rather than being forced to invent a
  reason.

  ## Interaction with task 019ff49f (ingest status is last-writer-wins)

  NOT fixed here. Both reason columns ride the SAME `Repo.update` as
  `:ingest_status`, so they can never disagree with the status they
  explain. A diverging concurrent ingest can still make that whole tuple
  the loser — that is 019ff49f's problem, unchanged and not made worse by
  these columns.
  """
  @spec update_ingest_status(File.t(), String.t()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def update_ingest_status(%File{} = file, status), do: update_ingest_status(file, status, [])

  @doc """
  As `update_ingest_status/2`, additionally recording WHY a `"failed"`
  ingest failed. See that function's docs for the full contract.

  ## Options

    * `:failure_stage` — `:extract` / `:embed` / `:storage` (or the
      equivalent string). Only read on a `"failed"` write.
    * `:failure_detail` — any term. Binaries are stored verbatim, other
      terms are inspected; `nil` stores SQL NULL rather than the string
      `"nil"`. Truncated to 500 graphemes.
  """
  @spec update_ingest_status(File.t(), String.t(), keyword()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def update_ingest_status(%File{} = file, status, opts)
      when status in ~w(pending ingested failed not_attempted) and is_list(opts) do
    file
    |> File.changeset(%{ingest_status: status})
    |> put_failure_count(file, status)
    |> put_failure_reason(status, opts)
    |> Repo.update()
  end

  # `:ingest_failure_count` is outside `@cast_fields` on purpose, so it
  # moves only through this explicit change and never through bulk attrs.
  #
  # Read-then-write off the struct the caller handed us, rather than a
  # DB-side `inc:`, for two reasons. First, `Repo.update_all` would bypass
  # `File.changeset/2` and turn the
  # `platform_files_not_attempted_requires_human_only_check` violation into
  # a raised `Postgrex.Error` instead of the `{:error, changeset}` this
  # function's callers rely on. Second, the write is not contended: ingest
  # is spawned per file from one choke point, and the ingester's
  # `mark_failed/1` reloads the row immediately before calling here. A lost
  # update under a hypothetical concurrent double-ingest would undercount,
  # delaying a retry-withhold by one attempt — not corrupt anything — so it
  # does not justify a lock.
  defp put_failure_count(changeset, %File{} = file, "failed") do
    Ecto.Changeset.put_change(
      changeset,
      :ingest_failure_count,
      (file.ingest_failure_count || 0) + 1
    )
  end

  defp put_failure_count(changeset, _file, "ingested") do
    Ecto.Changeset.put_change(changeset, :ingest_failure_count, 0)
  end

  defp put_failure_count(changeset, _file, status)
       when status in ~w(pending not_attempted),
       do: changeset

  @failure_stages ~w(extract embed storage)

  # Same treatment and the same reason as `put_failure_count/3` above: both
  # reason columns sit outside `@cast_fields`, so they move only through
  # this explicit change and never through bulk attrs. A reason string any
  # bulk update could set is not evidence anybody can trust, which would
  # defeat the point of persisting it.
  defp put_failure_reason(changeset, "failed", opts) do
    stage = opts |> Keyword.get(:failure_stage) |> normalize_failure_stage()

    changeset
    |> Ecto.Changeset.put_change(:ingest_failure_stage, stage)
    |> Ecto.Changeset.put_change(
      :ingest_failure_detail,
      sanitize_failure_detail(Keyword.get(opts, :failure_detail))
    )
  end

  # Clearing on success is load-bearing, not housekeeping — see the
  # contract on `update_ingest_status/2`.
  defp put_failure_reason(changeset, "ingested", _opts) do
    changeset
    |> Ecto.Changeset.put_change(:ingest_failure_stage, nil)
    |> Ecto.Changeset.put_change(:ingest_failure_detail, nil)
  end

  defp put_failure_reason(changeset, status, _opts)
       when status in ~w(pending not_attempted),
       do: changeset

  defp normalize_failure_stage(nil), do: nil

  defp normalize_failure_stage(stage) when is_atom(stage),
    do: normalize_failure_stage(Atom.to_string(stage))

  defp normalize_failure_stage(stage) when stage in @failure_stages, do: stage

  defp normalize_failure_stage(other) do
    raise ArgumentError,
          "invalid :failure_stage #{inspect(other)}; expected one of #{inspect(@failure_stages)}"
  end

  # Total over arbitrary terms, and deliberately never produces a
  # MISLEADING string.
  #
  # The `nil` clause is explicit and comes first because `nil` is an atom:
  # a naive `to_string/1` or JSON-safing pass turns "no reason recorded"
  # into the literal `"nil"`, which reads exactly like a real reason. That
  # is the specific bug this function was written to avoid.
  #
  # Truncation is on GRAPHEMES (`String.slice/3`), not bytes, so we never
  # cut a codepoint in half and hand Postgres invalid UTF-8.
  defp sanitize_failure_detail(nil), do: nil

  defp sanitize_failure_detail(detail) when is_binary(detail),
    do: String.slice(detail, 0, 500)

  defp sanitize_failure_detail(detail),
    do: detail |> inspect(limit: 20, printable_limit: 200) |> String.slice(0, 500)

  @doc """
  Records that `file` now has a catalog card at `card_file_key`
  (task 01a0008c stage 2).

  Stamps `card_generated_at` to now in the same write. The two columns
  move together on purpose: `card_file_key` without a timestamp gives
  the backfill no way to tell a fresh card from a stale one, and a
  timestamp without a key points at nothing.

  Deliberately has no "unset" counterpart. A card that fails to
  generate leaves both columns nil, which is indistinguishable from
  never-attempted — that is the whole retry strategy (retry *is* the
  backfill), so there is nothing to clear.
  """
  @spec mark_card_generated(File.t(), String.t()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def mark_card_generated(%File{} = file, card_file_key) when is_binary(card_file_key) do
    file
    |> File.changeset(%{
      card_file_key: card_file_key,
      card_generated_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Sets the `:ingest_intent` field on a `Platform.Files.File`.

  Intent is the operator's *decision* about whether a file should ever be
  fed to the ingest pipeline (`"attempt"`) or held back as human-only
  reading material (`"human_only"`). It is deliberately a separate field
  from `:ingest_status`, which records the *outcome* of that decision.

  ## Contract: this function ONLY writes the intent

  It does **not** enqueue ingest work, and it does **not** touch
  `:ingest_status`. Flipping `"human_only"` → `"attempt"` here leaves the
  status byte-identical; the decision to enqueue on that flip lives at a
  single seam in the ingester gate, so the system has exactly **one**
  enqueue choke point. Adding an enqueue call here — however convenient
  it looks — creates the second choke point this split exists to avoid,
  and the two will drift.

  An unrecognised intent raises `FunctionClauseError` rather than
  degrading to a default: a typo'd intent is a bug, and a silent fallback
  would file no report.

  ## Flipping a withdrawn row back is now refused, by the database

  Because this function writes intent alone, calling it with `"attempt"`
  on an already-withdrawn row (`"human_only"` + `"not_attempted"`) would
  produce the incoherent pair `"attempt"` + `"not_attempted"` — a row
  claiming we meant to ingest it while recording that ingestion was never
  attempted. The check constraint
  `platform_files_not_attempted_requires_human_only_check` refuses that
  pair outright, so the call returns `{:error, changeset}` with the error
  on `:ingest_status` and the row on disk is left untouched.

  `request_ingest/1` is the correct call for that transition: it resets
  the status to `"pending"` in the same write and re-enqueues, so the row
  never passes through the forbidden pair.
  """
  @spec set_ingest_intent(File.t(), String.t()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def set_ingest_intent(%File{} = file, intent)
      when intent in ~w(attempt human_only) do
    file
    |> File.changeset(%{ingest_intent: intent})
    |> Repo.update()
  end

  @doc """
  Post-hoc override: asks for a file to be ingested after all.

  This is the **single** retry / override entry point. It does three
  things, in order: sets `:ingest_intent` to `"attempt"`, resets
  `:ingest_status` to `"pending"`, and hands the refreshed row to
  `Platform.Files.Ingester.ingest_async/1`.

  Callers — a "Send to search" button, an MCP tool, an operator script —
  must call this rather than reimplementing the sequence. Setting the
  intent without resetting the status leaves a `"human_only"` row stuck
  in its terminal `"not_attempted"` state, which is precisely the bug
  this helper exists to make unrepresentable.

  Works from any prior state: a `"human_only"` + `"not_attempted"` row
  (terminal, never tried) and an `"attempt"` + `"failed"` row (tried,
  broke) both become `"attempt"` + `"pending"` and get re-enqueued.

  ## `:mode` — who is allowed to outlive the ingest

  `mode: :async` (the default) is the request/response contract: the row
  is flipped, a supervised task is spawned, and the caller returns
  immediately. That is correct for a LiveView or an MCP tool, because
  the BEAM those callers run on stays up long enough for the task to
  finish.

  `mode: :sync` runs `Platform.Files.Ingester.run/1` in the CALLING
  process and reports its outcome — `{:error, reason}` when the ingest
  itself failed, as distinct from `{:error, %Ecto.Changeset{}}` when the
  flip failed. A batch caller that exits when its loop ends (a mix task
  halts the VM, and the supervisor dies with it) MUST use this: with
  `:async` such a caller leaves the row parked at `"attempt"` +
  `"pending"` with no text and no running task, and — because `pending`
  is not a retry candidate — no later run will pick it up. Same pipeline
  either way; the only difference is whether the caller waits.
  """
  @spec request_ingest(File.t(), keyword()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t() | term()}
  def request_ingest(%File{} = file, opts \\ []) do
    mode = Keyword.get(opts, :mode, :async)

    with {:ok, updated} <-
           file
           |> File.changeset(%{ingest_intent: "attempt", ingest_status: "pending"})
           |> Repo.update() do
      case mode do
        :async ->
          :ok = Platform.Files.Ingester.ingest_async(updated)
          {:ok, updated}

        :sync ->
          case Platform.Files.Ingester.run(updated) do
            :ok -> {:ok, get_file(updated.id)}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  # Consecutive failures after which the BULK SWEEP stops re-enqueueing a
  # file. It is a rate limit on one fan-out button, not a judgement about
  # the file, and it has exactly ONE enforcement point: `retryable_failure?/1`
  # below. The per-file manual retry is UNBOUNDED by design — see
  # `retry_failed_ingests/2`'s "Eligibility" section for the argument.
  #
  # THIS BOUND IS ONLY HONEST BECAUSE THE MANUAL RETRY IS ALWAYS PRESENT
  # FOR A FAILED FILE. That dependency lives in another file: the DETAIL
  # PANE's `data-role="files-detail-retry"` button, gated by
  # `PlatformWeb.FilesLive.can_retry_file?/1`, which is status-only. The
  # list row deliberately carries no button of its own — it is already a
  # whole-row click target — so the pane's button is the ONLY escape
  # hatch and there is no second one to fall back on.
  # If someone re-introduces a condition on that button — a count, a
  # threshold, any withhold — this number silently stops being a rate
  # limit and becomes a LOCKOUT, with no way for a human to retry their
  # own file. Delete the bound in that same change, or do not re-condition
  # the button.
  #
  # A second literal `3` anywhere is the drift `repeat_failure_threshold/0`
  # exists to prevent; the LiveView READS it (for copy), never re-gates on it.
  @repeat_failure_threshold 3

  @doc """
  The number of consecutive failed ingests after which the AUTOMATIC bulk
  sweep stops re-enqueueing a file (task 01a0008b stage 3, rescoped by
  task 01a0166d stage 3).

  ONE enforcement point: `retry_failed_ingests/2`. Public only so the
  Files page can READ it for copy — naming the number in the sentence
  that explains why a row was skipped, and in the per-row clause that
  says the row was not retried *automatically*. That is a read, never a
  second gate: the per-file manual retry is unbounded, so a UI that
  compared a count against this value would be re-introducing a rule the
  product deliberately removed.
  """
  @spec repeat_failure_threshold() :: pos_integer()
  def repeat_failure_threshold, do: @repeat_failure_threshold

  @doc """
  Retries every failed ingest in `project_id` that is still worth
  retrying (task 01a0008b stage 3).

  Reads the sweep from `list_failed_ingests/2` and calls
  `request_ingest/2` — the single retry entry point — on each eligible
  row. Returns `{:ok, %{requested: n, withheld: m, threshold: t}}`.

  ## Routed, not reimplemented

  Every row goes through `request_ingest/2`, which performs the
  `"attempt"` + `"pending"` flip in ONE write and then hands the
  refreshed row to `Platform.Files.Ingester.ingest_async/1`. This
  function calls neither `Repo.update` nor `ingest_async/1` itself.
  Doing the flip inline would re-create the half-transition
  (`request_ingest/2`'s docstring describes it) that leaves a row
  stranded; calling the ingester directly would add a fourth production
  caller to the system's single enqueue choke point, which is exactly
  the drift the ingester/context split exists to prevent.

  `opts` is passed straight through to `request_ingest/2`, so `:mode`
  behaves identically here (`:async` by default, correct for a LiveView).

  ## Eligibility: a rate limit on the sweep, not a verdict on the file

  A row whose `:ingest_failure_count` has reached
  `repeat_failure_threshold/0` is WITHHELD **by this function only** —
  counted, not retried. The per-file manual retry has no such bound and
  never refuses.

  The two callers differ in blast radius and in information. A human
  clicking Retry on one row has looked at that row, spends one request,
  and is the only party who can know something changed outside the
  system — the backend came back, the file was re-exported. Bounding
  them makes the product argue with a person about their own file. This
  sweep is one click that fans out across EVERY failed row in a project,
  at a backend that is very often the thing already failing; against a
  downed embedder that is a burst proportional to the failure count.
  Its bound is a rate limit, not paternalism, and not a claim that a
  fourth attempt would be pointless.

  KEEPING IT COSTS THE USER NOTHING ONLY BECAUSE THE UNBOUNDED PER-ROW
  BUTTON IS ALWAYS PRESENT ON A FAILED ROW — see the comment on
  `@repeat_failure_threshold`. If that escape hatch is ever conditioned
  again, this bound becomes a lockout and must be deleted in the same
  change.

  Withholding deliberately does NOT escalate. Nothing pages, no
  notification is sent, no digest line is written, no severity or colour
  changes. The row says so where the row is: the Files page renders the
  skip as its own state, naming the AUTOMATIC path, beside the Retry the
  reader can still press.

  ## The summary carries the threshold that produced the withholds

  So a caller can explain the skip in words without re-spelling the
  number: the map includes `:threshold`. `requested + withheld` still
  equals the size of the sweep — `:threshold` is not a third arm.

  ## What is NOT swept

  Everything `list_failed_ingests/2` excludes, and for its reasons —
  most importantly a `"human_only"` / `"not_attempted"` row, which was
  never attempted and is withheld ON PURPOSE. Re-enqueueing one here
  would silently overturn a human decision, which on the write side is a
  mutation rather than a mis-count.

  Retry is human-initiated only: there is no schedule, no cron, no job
  queue and no automatic re-attempt behind this function. It runs when
  somebody presses the button.

  ## The two arms of the summary always add up

  `requested + withheld` equals the size of the sweep, so a caller can
  trust the numbers to describe every file it swept:

    * `{:ok, _}` from `request_ingest/2` — requested.
    * `{:error, reason}` under `mode: :sync` — requested. The flip landed
      and the pipeline ran; that the extraction then failed is the
      retry's outcome, not a sign the retry was never asked for.
    * `{:error, %Ecto.Changeset{}}` — the flip itself was refused, so
      nothing was asked of the pipeline. Counted as withheld and logged.
      Practically unreachable (the sweep only yields rows for which
      `"attempt"` + `"pending"` is a valid write), but silently dropping
      it would make the totals lie on the one surface whose whole job is
      to be trusted.
  """
  @spec retry_failed_ingests(binary(), keyword()) ::
          {:ok,
           %{
             requested: non_neg_integer(),
             withheld: non_neg_integer(),
             threshold: pos_integer()
           }}
  def retry_failed_ingests(project_id, opts \\ []) when is_binary(project_id) do
    summary =
      project_id
      |> list_failed_ingests()
      |> Enum.reduce(%{requested: 0, withheld: 0, threshold: @repeat_failure_threshold}, fn file,
                                                                                            acc ->
        if retryable_failure?(file) do
          retry_one(file, opts, acc)
        else
          %{acc | withheld: acc.withheld + 1}
        end
      end)

    {:ok, summary}
  end

  # The sweep's ONLY gate. Not called from the LiveView, and nothing in
  # the manual retry path consults it.
  defp retryable_failure?(%File{} = file) do
    (file.ingest_failure_count || 0) < @repeat_failure_threshold
  end

  defp retry_one(%File{} = file, opts, acc) do
    case request_ingest(file, opts) do
      {:ok, _requested} ->
        %{acc | requested: acc.requested + 1}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "retry_failed_ingests: refused the attempt/pending flip for file " <>
            "#{file.id}: #{inspect(changeset.errors)}"
        )

        %{acc | withheld: acc.withheld + 1}

      {:error, _ingest_failure} ->
        %{acc | requested: acc.requested + 1}
    end
  end

  @doc """
  Withdraws an ALREADY-EXTRACTED file from every agent-visible reader.

  Flipping intent alone is cosmetic: the extraction already happened, so
  the text is sitting in two independent places an agent can read.
  Scrubbing only one of them leaves the body fully legible, which is
  worse than shipping no control at all — the operator believes the file
  is withdrawn and it is not. So this function removes both:

    1. `platform_file_texts` — the cached extracted body. Read DIRECTLY
       (bypassing the vector index entirely) by the `file_get_text` MCP
       tool and by `file_search` snippet rendering. This is the reader
       that makes an index-only scrub cosmetic.
    2. the vector index entry, keyed on the file id
       (`scrub_search_index/1`, shared with `delete_file/2`).

  `platform_file_chunks` rows go too. They hold no text — only opaque
  external ids for dedup linkage — but a later byte-identical upload
  would otherwise dedup-copy that linkage and resurrect a pointer to a
  withdrawn body.

  Ordering: intent → status → text row → chunk rows all commit in ONE
  transaction, so there is no window where the row reads as withdrawn
  while its text is still queryable (or vice versa). The index scrub and
  the broadcast run AFTER commit, best-effort — a memory-service outage
  must not make the control unusable. A stale index entry surviving an
  outage is covered by the `file_get_text` / `file_search` refusals in
  `Platform.Federation.ToolSurface`, which read the DB intent, not the
  index.

  Raw bytes are deliberately untouched: `file_get_text` with
  `binary: true` still serves this file. Withdrawing EXTRACTED TEXT from
  agent context is the contract; withholding the document from its
  human audience is not.
  """
  @spec withdraw_from_agent_context(File.t()) :: {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def withdraw_from_agent_context(%File{} = file) do
    txn =
      Repo.transaction(fn ->
        with {:ok, intended} <- set_ingest_intent(file, "human_only"),
             {:ok, updated} <- update_ingest_status(intended, "not_attempted") do
          {_, _} = Repo.delete_all(from(t in Text, where: t.file_id == ^file.id))
          {_, _} = Repo.delete_all(from(c in Chunk, where: c.file_id == ^file.id))
          updated
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        end
      end)

    case txn do
      {:ok, %File{} = withdrawn} ->
        scrub_search_index(withdrawn)

        _ =
          broadcast_project(
            withdrawn.project_id,
            {:file_withdrawn_from_agent_context, withdrawn.id}
          )

        {:ok, withdrawn}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  The inverse of `withdraw_from_agent_context/1`: puts a withdrawn file
  back in front of agents. Delegates to `request_ingest/1`.

  ## Why this is NOT symmetric with `restore_file/2`

  `restore_file/2` (the soft-delete inverse) re-indexes from the cached
  extracted text via `reindex_from_cached_text/1` — cheap, no
  re-extraction, because soft-delete never touched
  `platform_file_texts`. Withdrawal DID: it deleted that row, on purpose.
  There is no cache left to re-index from, so the flip back must
  RE-EXTRACT, which is exactly what `request_ingest/1` enqueues.

  Do not "optimise" this into a `reindex_from_cached_text/1` call. It
  would find nothing, log a skip, and quietly leave the file
  unsearchable while reporting success.
  """
  @spec restore_to_agent_context(File.t()) :: {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def restore_to_agent_context(%File{} = file), do: request_ingest(file)

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
  Subscribes the calling process to a project's file events.

  CAUTION: this is NOT idempotent per pid. `Phoenix.PubSub` does NOT dedup
  within a single pid — its registry is started with `keys: :duplicate`
  (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex) and `subscribe/3` is
  a bare `Registry.register/3` (deps/phoenix_pubsub/lib/phoenix/pubsub.ex), so
  a second call from the same process for the same project adds a SECOND
  registration and every later broadcast on the topic is delivered twice.

  The caller's obligation is therefore to track what it has subscribed and
  guard the subscribe. `PlatformWeb.Files.BrowserHooks` tracks the complete
  readable topic set in `:browser_topics` and applies its MapSet differences.
  It is the browser's sole project-topic owner: entering or leaving a project
  node changes detail state, not the global Recents/Starred subscriptions.

  ASYMMETRY — do NOT reflexively pair every subscribe with an unsubscribe.
  One `Registry.unregister/2` takes that pid's count for the key to 0, not to
  n-1: it drops ALL of that pid's entries for the topic. So an unsubscribe on
  a teardown path silently kills a registration another feature still holds —
  that is how the unread badge died, when a teardown unsubscribed the space it
  was leaving and took the mount-time badge registration with it. Guard the
  subscribe; unsubscribe only with the full overlap of that pid's
  registrations understood.
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
  Fetches the live (not soft-deleted) `platform_files` row whose
  `storage_key` is `key`, whatever its `ingest_status`. Returns nil when
  no live row holds the key. The presigned-upload controller uses this
  to tell "no such reservation" (404) from "reservation already
  finalized" (409) — see `get_pending_by_storage_key/1` for the
  pending-only lookup.
  """
  @spec get_by_storage_key(String.t()) :: File.t() | nil
  def get_by_storage_key(key) when is_binary(key) do
    File
    |> not_deleted()
    |> where([f], f.storage_key == ^key)
    |> Repo.one()
  end

  @doc """
  Fetches the live `platform_files` reservation (ingest_status
  "pending") for `key`, or nil. Soft-deleted reservations read as absent
  via `not_deleted/1`, mirroring `get_file/2`: a deleted reservation must
  not accept a late byte POST.
  """
  @spec get_pending_by_storage_key(String.t()) :: File.t() | nil
  def get_pending_by_storage_key(key) when is_binary(key) do
    File
    |> not_deleted()
    |> where([f], f.storage_key == ^key and f.ingest_status == "pending")
    |> Repo.one()
  end

  @doc """
  Finalizes a presigned-upload reservation once the bytes have landed at
  `file.storage_key`. Mirrors the inline `file_add` branch
  (`Platform.Federation.ToolSurface` `file_add_inline/4`) and the
  LiveView upload path, but starts from an already-reserved row:

    * `file` must still be `ingest_status: "pending"` with a nil
      `content_hash`, else `{:error, :not_pending}`. The hash is the
      reservation marker: after an `:async` finalize the row stays
      `"pending"` until the Ingester runs, and a second finalize on it
      must be refused (task 01a091b7 stage 2, controller test (5)).
    * If an ingested sibling in the same project already holds
      `content_hash`, the reservation is redundant: the just-uploaded
      bytes are deleted (best-effort) and the reservation row is hard
      deleted (same as the presign-failure cleanup — it never held
      finalized content). Returns the sibling with `deduplicated: true`.
    * Otherwise `byte_size` and `content_hash` are written onto the row
      and ingest is fired: `mode: :async` (default) via
      `Platform.Files.Ingester.ingest_async/1`; `mode: :sync` runs the
      ingester inline and re-reads the row, same shape as
      `request_ingest/2`.

  A `(content_hash, project_id)` unique-index clash with a non-ingested
  twin is surfaced as the changeset error, not swallowed.
  """
  @spec finalize_presigned_upload(
          File.t(),
          %{byte_size: non_neg_integer(), content_hash: String.t()},
          keyword()
        ) ::
          {:ok, %{file: File.t(), deduplicated: boolean()}}
          | {:error, :not_pending | Ecto.Changeset.t() | term()}
  def finalize_presigned_upload(file, stat, opts \\ [])

  def finalize_presigned_upload(
        %File{ingest_status: "pending", content_hash: nil} = file,
        %{byte_size: size, content_hash: hash},
        opts
      )
      when is_integer(size) and size >= 0 and is_binary(hash) do
    mode = Keyword.get(opts, :mode, :async)

    case find_ingested_sibling(file.project_id, hash) do
      %File{} = sibling ->
        _ = Platform.Files.Storage.delete(file.storage_key)
        _ = Repo.delete(file)
        {:ok, %{file: sibling, deduplicated: true}}

      nil ->
        with {:ok, updated} <-
               file
               |> File.changeset(%{byte_size: size, content_hash: hash})
               |> Repo.update(),
             {:ok, ingested} <- run_ingest(updated, mode) do
          {:ok, %{file: ingested, deduplicated: false}}
        end
    end
  end

  def finalize_presigned_upload(%File{}, _stat, _opts), do: {:error, :not_pending}

  defp run_ingest(%File{} = file, :async) do
    :ok = Platform.Files.Ingester.ingest_async(file)
    {:ok, file}
  end

  defp run_ingest(%File{} = file, :sync) do
    case Platform.Files.Ingester.run(file) do
      :ok -> {:ok, get_file(file.id)}
      {:error, reason} -> {:error, reason}
    end
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
    # NOTE the schema difference from get_file/2 above: `Platform.Files.Text`
    # keys on a BARE :binary_id, not `Platform.Types.UUIDv7`. A raw 16-byte
    # binary therefore returns nil SILENTLY here while "higgins" raises — two
    # symptoms from one guard-less lookup. The guard makes both return nil.
    if not Platform.UUID.valid?(file_id) do
      nil
    else
      Repo.get(Text, file_id)
    end
  end

  defp maybe_filter_content_type(query, nil), do: query

  defp maybe_filter_content_type(query, content_type) when is_binary(content_type) do
    where(query, [f], f.content_type == ^content_type)
  end

  defp maybe_filter_ingest_intent(query, nil), do: query

  defp maybe_filter_ingest_intent(query, intent) when is_binary(intent) do
    where(query, [f], f.ingest_intent == ^intent)
  end

  defp maybe_filter_ingest_status(query, nil), do: query

  defp maybe_filter_ingest_status(query, status) when is_binary(status) do
    where(query, [f], f.ingest_status == ^status)
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

  # Interactive-code gate guards (task 01a06a20 stage 1) — same
  # toggle-pair shape as the soft-delete guards above.
  defp ensure_not_yet_interactive(%File{interactive_at: nil}), do: :ok
  defp ensure_not_yet_interactive(%File{}), do: {:error, :already_interactive}

  defp ensure_interactive(%File{interactive_at: %DateTime{}}), do: :ok
  defp ensure_interactive(%File{}), do: {:error, :not_interactive}

  # Remove the file's entry from the vector index. The ingest pipeline
  # indexes each file under its own row id (`Platform.Files.Ingester`
  # builds the memory entry with `id: file.id`), so that id is the scrub
  # key. Best-effort after commit — see `delete_file/2` doc.
  #
  # Shared by TWO callers with the same semantics: `delete_file/2` (the
  # whole row goes away) and `withdraw_from_agent_context/1` (the row
  # stays, its extracted text does not). Deliberately one copy — a second
  # scrub implementation is a second place for the "which id do we scrub
  # by?" reasoning below to drift out of date.
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
