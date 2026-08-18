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
    content_type = Keyword.get(opts, :content_type)
    ingest_intent = Keyword.get(opts, :ingest_intent)
    ingest_status = Keyword.get(opts, :ingest_status)
    preload = Keyword.get(opts, :preload, [])

    File
    |> not_deleted()
    |> where([f], f.project_id == ^project_id)
    |> maybe_filter_content_type(content_type)
    |> maybe_filter_ingest_intent(ingest_intent)
    |> maybe_filter_ingest_status(ingest_status)
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Repo.preload(preload)
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
  """
  @spec update_ingest_status(File.t(), String.t()) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def update_ingest_status(%File{} = file, status)
      when status in ~w(pending ingested failed not_attempted) do
    file
    |> File.changeset(%{ingest_status: status})
    |> put_failure_count(file, status)
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

  # Consecutive failures after which a file stops being offered a retry.
  # One number, read by everything that has to agree about it: the bulk
  # sweep below and — through `repeat_failure_threshold/0` — the Files
  # page's per-row control. A second literal `3` in the LiveView is the
  # drift this attribute exists to prevent.
  @repeat_failure_threshold 3

  @doc """
  The number of consecutive failed ingests after which a file is withheld
  from retry (task 01a0008b stage 3).

  Public because the withhold rule has two enforcement points and they
  must not disagree: `retry_failed_ingests/2` applies it to the bulk
  action, and the Files page applies it to the per-file retry control.
  The UI must read this rather than hardcode its own copy of the number.
  """
  @spec repeat_failure_threshold() :: pos_integer()
  def repeat_failure_threshold, do: @repeat_failure_threshold

  @doc """
  Retries every failed ingest in `project_id` that is still worth
  retrying (task 01a0008b stage 3).

  Reads the sweep from `list_failed_ingests/2` and calls
  `request_ingest/2` — the single retry entry point — on each eligible
  row. Returns `{:ok, %{requested: n, withheld: m}}`.

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

  ## Eligibility: three strikes and the machine stops pretending

  A row whose `:ingest_failure_count` has reached
  `repeat_failure_threshold/0` is WITHHELD — counted, not retried. The
  same bytes have already broken the extractor three times; a fourth
  identical attempt has no new information to act on, so it would be the
  system performing work rather than doing it, and it would keep the
  file's real problem (it likely needs re-exporting) hidden behind a
  button that looks like a fix.

  Repeated failure deliberately does NOT escalate. Nothing pages, no
  notification is sent, no digest line is written, no severity or colour
  changes, and no surface outside the Files page is created. The file
  becomes self-diagnosing rather than louder: withheld here, re-worded
  there. An alert firing on a condition nobody can act on from the alert
  is the same noise this task exists to remove, relocated.

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
          {:ok, %{requested: non_neg_integer(), withheld: non_neg_integer()}}
  def retry_failed_ingests(project_id, opts \\ []) when is_binary(project_id) do
    summary =
      project_id
      |> list_failed_ingests()
      |> Enum.reduce(%{requested: 0, withheld: 0}, fn file, acc ->
        if retryable_failure?(file) do
          retry_one(file, opts, acc)
        else
          %{acc | withheld: acc.withheld + 1}
        end
      end)

    {:ok, summary}
  end

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
  guard the subscribe. `PlatformWeb.FilesLive` is the shape to copy: it holds
  the current topic in the `:subscribed_project_id` assign and releases it via
  `maybe_unsubscribe/1` before subscribing to the next project
  (apps/platform/lib/platform_web/live/files_live.ex:805).

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
