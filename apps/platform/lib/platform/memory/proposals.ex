defmodule Platform.Memory.Proposals do
  @moduledoc """
  Context for `MemoryProposal` rows — the persistence of parsed
  `<synthesis-proposal>` blocks emitted by the Historian's dreaming
  runs.

  ## Lifecycle

      Journal write ─► ingest_from_journal/3 ─► pending row
                                                  │
                        Rowan clicks Approve  ─────┼─► approved row
                                                  │
                       Rowan clicks Reject   ─────┼─► rejected row + feedback
                                                  │
                            +7 days elapsed  ────►│─► expired row (silent)

  Rejected + expired rows persist for post-hoc analysis (acceptance
  criterion 8) and — for rejected rows — feed few-shot exemplars into
  the next dreaming prompt via `rejected_exemplars/1`.

  ## Block grammar

  The parser accepts blocks matching:

      <synthesis-proposal category="…" confidence="…" evidence="…">
        …body text…
      </synthesis-proposal>

  Attributes may appear in any order. `category` and `confidence` are
  strictly enum-validated (unknown values → skip + log). `evidence` is
  optional (missing → stored as `nil`). The tag body is trimmed of
  surrounding whitespace but internal newlines are preserved so
  multi-line proposal bodies (the common case) survive re-rendering.

  Deliberately forgiving: LLM-emitted HTML-style tags occasionally arrive
  with stray whitespace, missing attrs, or truncated close tags. We warn
  and skip malformed blocks rather than raise so a single bad block
  doesn't poison the whole dreaming run.

  ## Idempotency

  `ingest_from_journal/3` uses `on_conflict: :nothing` against the
  `(workspace_id, block_hash)` unique index so a journal that gets
  written twice (e.g. dreaming retry) inserts each block exactly once.
  `block_hash` is `sha256(inner_body_trimmed)` — attribute reordering
  won't dedup, but body-preserving format tweaks in the LLM's output
  will.
  """

  import Ecto.Query

  require Logger

  alias Platform.Audit
  alias Platform.Memory.MemoryProposal
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki
  alias Platform.Repo

  @default_pending_limit 50
  @default_exemplars_limit 3

  # Regex matches the outer `<synthesis-proposal …>…</synthesis-proposal>`
  # envelope; attributes are pulled out with a second pass so ordering
  # doesn't matter. `[\s\S]` (rather than `.`) is intentional so the
  # DOTALL flag isn't required and the body may span newlines.
  @block_regex ~r/<synthesis-proposal([^>]*)>([\s\S]*?)<\/synthesis-proposal>/
  @attr_regex ~r/(\w+)\s*=\s*"([^"]*)"/

  # Category → base path for the target wiki page. Approved proposals
  # promote into `<base><slug>.md` where the slug is derived from the
  # proposal's evidence or body (see `derive_target_page_key/3`).
  # Categories not in this map fall through to `org/page/misc/`.
  @category_bases %{
    "recurring-theme" => "org/page/topics/",
    "cross-project-pattern" => "org/page/patterns/",
    "emerging-risk" => "org/page/risks/",
    "stale-fact-candidate-retirement" => "org/page/retirement/",
    "strategic-insight" => "org/page/strategy/",
    "unresolved-question" => "org/page/questions/"
  }

  @default_category_base "org/page/misc/"

  # Stopwords for `derive_slug/2` — filtered before we pick the first
  # "content" word. Deliberately narrow: articles, pronouns, auxiliaries,
  # common prepositions, quantifiers, and a couple of names/verbs that
  # dominate Rowan's journal voice ("rowan", "mentioned", "noted"). If a
  # future category needs finer control we can add per-category stopword
  # lists; today's mix of proposal bodies all resolve cleanly to a
  # single-word slug with this base set.
  @stopwords MapSet.new(~w(a an the and or but is was are were be been being have has had
                  do does did will would should could might may can shall must to
                  for of on in at by with about from into onto upon this that these
                  those i me my you your he him his she her we us our they them
                  their it its rowan mentioned mentions mentioning noted said says
                  talked talks talking discussed brought raised recent recently
                  across several three multiple many few various different both
                  either neither yes no not only just simply some any all as
                  when where why how which who whose than then so if while
                  during over under before after between within during without
                  more most less least each every own same such other another
                  here there now today tomorrow yesterday week weeks day days
                  month months year years hour hours minute minutes always never
                  often rarely sometimes usually))

  @doc """
  List pending proposals, newest first.

  ## Options

    * `:workspace_id` — filter to a specific workspace. `nil` (default)
      returns rows across all workspaces — matches how `/memory/proposals`
      renders in the org-scoped view. Callers who want strict org-only
      rows should pass `nil` and understand it's "no filter", not
      "workspace IS NULL".
    * `:limit` — max rows to return (default 50).

  Expired rows are excluded — the LiveView never surfaces them, even
  though they persist in the DB.
  """
  @spec list_pending(keyword()) :: [MemoryProposal.t()]
  def list_pending(opts \\ []) when is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit_n = Keyword.get(opts, :limit, @default_pending_limit)
    now = DateTime.utc_now()

    MemoryProposal
    |> where([p], p.status == "pending")
    |> where([p], p.expires_at > ^now)
    |> maybe_filter_workspace(workspace_id)
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit_n)
    |> Repo.all()
  end

  @doc """
  Parse `content` for `<synthesis-proposal>` blocks and insert one
  `MemoryProposal` row per well-formed block. Idempotent via the
  `(workspace_id, block_hash)` unique index.

  Returns `{:ok, count}` where `count` is the number of NEW rows
  inserted (skipped-as-duplicate rows do not count). Malformed blocks
  are logged at `warning` and dropped.

  Called from `Platform.Org.Context.upsert_context_file/3` on any
  successful write whose `file_key` matches
  `~r|^(org|project/[^/]+|space/[^/]+)/journal/\\d{4}-\\d{2}-\\d{2}\\.md$|`.
  Page writes are NOT swept — the sweep-hook regex is enforced at the
  call site so this function stays a pure ingester and can be exercised
  directly from tests.
  """
  @spec ingest_from_journal(binary() | nil, String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()}
  def ingest_from_journal(workspace_id, journal_path, content)
      when is_binary(journal_path) do
    content = content || ""

    blocks = parse_blocks(content)

    inserted =
      blocks
      |> Enum.map(&insert_block(&1, workspace_id, journal_path))
      |> Enum.count(&match?({:ok, _}, &1))

    {:ok, inserted}
  end

  @doc """
  Fetch a proposal by id. Returns `nil` when the row doesn't exist —
  callers that need to distinguish "already expired" from "never
  existed" should compare status against `MemoryProposal.statuses/0`.
  """
  @spec get(binary()) :: MemoryProposal.t() | nil
  def get(id) when is_binary(id) do
    # `id` is a `phx-value-id` LiveView param (org_memory_live/view.ex:358,393).
    # Platform.UUID.valid?/1, not a bare Ecto.UUID.cast/1 — a bare cast accepts
    # any 16-byte binary and the raise lands inside Repo regardless.
    if Platform.UUID.valid?(id), do: Repo.get(MemoryProposal, id), else: nil
  end

  def get(_), do: nil

  @doc """
  Mark a proposal `:approved`.

  Returns `{:ok, proposal}` on success. The caller (`OrgMemoryLive`'s
  `handle_event("approve_proposal", …)`) is responsible for the
  follow-through — promoting the proposal body into a page and stripping
  the block from the source journal. This function only flips the
  status.
  """
  @spec approve(MemoryProposal.t(), keyword()) :: {:ok, MemoryProposal.t()} | {:error, term()}
  def approve(%MemoryProposal{} = proposal, _opts \\ []) do
    proposal
    |> MemoryProposal.status_changeset(%{status: "approved"})
    |> Repo.update()
  end

  @doc """
  Promote an approved `MemoryProposal` into its target wiki page.

  Executes the four-step pipeline synchronously (caller is
  `PlatformWeb.OrgMemoryLive.handle_event("approve_proposal", …)` after
  `approve/2` succeeds):

    1. **Resolve the target page key** — from `proposal.target_page_key`
       (filled at ingest time) or, for pre-migration rows, derived on
       the fly via `derive_target_page_key/3`.

    2. **Append the proposal body** to that page via `Wiki.upsert_page/3`.
       New pages are created; existing pages get a dated section
       appended so successive promotions accumulate rather than
       overwrite. This is deliberately additive: Rowan approved this
       body, so it becomes canon on the page.

    3. **Strip the `<synthesis-proposal>` block from the source
       journal** via `OrgContext.upsert_context_file/3`. Located by
       `block_hash`, so if multiple blocks share the journal only the
       promoted one is removed. The stripped upsert re-runs the journal
       sweep hook — which finds no proposal blocks (this one is gone,
       the others were already ingested + deduped by unique index),
       so it's a safe no-op.

    4. **Record an audit event** via `Platform.Audit.record/1` with
       `event_type: "platform.memory.proposal_promoted"`,
       `actor_type: "agent"`, and metadata carrying `proposal_id`,
       `target_page_key`, `source_journal_path`, `block_hash`, plus
       `actor_slug: "historian.dreaming"`. Called directly (not via
       telemetry) so the audit row is durable regardless of whether
       `Platform.Audit.TelemetryHandler` is attached in the caller's
       runtime (matches how `Platform.Memory.MaintenanceSubagent`
       records its per-op audit rows).

  Returns `:ok` on success (all four steps landed). Returns
  `{:error, reason}` if the page write, journal write, or audit persist
  fails — the caller surfaces the error via `put_flash(:error, …)`.
  Step 3 failing to *find* the block is not an error: the block may
  already have been stripped by a prior approve, or the journal may
  have been edited independently.

  Lives on the `Proposals` context (not `HistorianDispatcher`) so the
  promotion lifecycle stays inside the T7 module boundary — the T6
  scope-creep guards forbid LiveView references into
  `HistorianDispatcher` and the dispatcher itself referencing
  `Platform.Memory.*`.
  """
  @spec queue_promotion(MemoryProposal.t()) :: :ok | {:error, term()}
  def queue_promotion(%MemoryProposal{} = proposal) do
    target_key =
      proposal.target_page_key ||
        derive_target_page_key(proposal.category, proposal.evidence, proposal.body)

    workspace_opts =
      case proposal.workspace_id do
        nil -> []
        ws_id when is_binary(ws_id) -> [workspace_id: ws_id]
      end

    with {:ok, _page} <- append_to_target_page(target_key, proposal, workspace_opts),
         :ok <- strip_journal_block(proposal, workspace_opts),
         :ok <- emit_promoted_event(proposal, target_key) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[memory.proposals] queue_promotion failed proposal_id=#{proposal.id} " <>
            "target_key=#{target_key} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ── Target-page derivation ───────────────────────────────────────────

  @doc """
  Derive the target wiki page `file_key` for a proposal from its
  category, evidence, and body.

  Public so the ingest path AND the promote fallback path share one
  implementation — and so tests can pin the mapping directly.
  """
  @spec derive_target_page_key(String.t(), String.t() | nil, String.t()) :: String.t()
  def derive_target_page_key(category, evidence, body)
      when is_binary(category) and is_binary(body) do
    base = Map.get(@category_bases, category, @default_category_base)
    slug = derive_slug(evidence, body)
    base <> slug <> ".md"
  end

  # First "content" word from the evidence, or from the first line of
  # the body when evidence is absent/empty. Falls back to a hash-derived
  # slug so we never return the empty string.
  defp derive_slug(evidence, body) do
    source =
      case String.trim(evidence || "") do
        "" -> first_line(body)
        text -> text
      end

    candidate =
      source
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.reject(fn word ->
        MapSet.member?(@stopwords, word) or String.length(word) < 3
      end)
      |> List.first()

    case candidate do
      nil -> "untitled-" <> String.slice(hash_body(body), 0, 8)
      word -> word
    end
  end

  defp first_line(body) when is_binary(body) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp first_line(_), do: ""

  # ── Promotion pipeline steps ─────────────────────────────────────────

  defp append_to_target_page(target_key, %MemoryProposal{} = proposal, workspace_opts) do
    existing = Wiki.get_page(target_key, workspace_opts)
    existing_content = if existing, do: existing.content || "", else: ""

    dated_section =
      "\n\n## Dreaming synthesis " <>
        Date.to_iso8601(Date.utc_today()) <>
        " (approved proposal #{short_id(proposal.id)})\n\n" <>
        proposal.body <>
        "\n"

    new_content =
      case existing_content do
        "" -> String.trim_leading(dated_section)
        content -> content <> dated_section
      end

    Wiki.upsert_page(target_key, %{content: new_content}, workspace_opts)
  end

  defp strip_journal_block(%MemoryProposal{} = proposal, workspace_opts) do
    case OrgContext.get_file(proposal.journal_path, workspace_opts) do
      nil ->
        # Journal missing — nothing to strip. Not an error: the block
        # may have been removed by a prior approve, or the journal
        # may have been manually deleted. Log and move on.
        Logger.debug(
          "[memory.proposals] strip_journal_block: journal not found " <>
            "journal_path=#{proposal.journal_path} proposal_id=#{proposal.id}"
        )

        :ok

      %{content: content} = _file ->
        stripped = strip_block_by_hash(content || "", proposal.block_hash)

        if stripped == content do
          # No matching block found — either already stripped or the
          # block was rewritten. Not an error; audit row still fires.
          :ok
        else
          case OrgContext.upsert_context_file(
                 proposal.journal_path,
                 %{content: stripped, updated_by: nil},
                 workspace_opts
               ) do
            {:ok, _file} -> :ok
            {:error, reason} -> {:error, {:journal_upsert_failed, reason}}
          end
        end
    end
  end

  # Walk every `<synthesis-proposal>` block and rewrite it as empty
  # ONLY when its trimmed-body hash matches `target_hash`. Non-matching
  # blocks pass through untouched so multi-proposal journals stay
  # intact after a single approve.
  defp strip_block_by_hash(content, target_hash) when is_binary(content) do
    Regex.replace(@block_regex, content, fn full, _attr_string, body ->
      if hash_body(String.trim(body)) == target_hash, do: "", else: full
    end)
  end

  defp emit_promoted_event(%MemoryProposal{} = proposal, target_key) do
    attrs = %{
      event_type: "platform.memory.proposal_promoted",
      actor_type: "agent",
      actor_id: nil,
      action: "proposal_promoted",
      resource_type: "wiki_page",
      resource_id: target_key,
      metadata: %{
        "actor_slug" => "historian.dreaming",
        "proposal_id" => proposal.id,
        "target_page_key" => target_key,
        "source_journal_path" => proposal.journal_path,
        "block_hash" => proposal.block_hash,
        "workspace_id" => proposal.workspace_id,
        "category" => proposal.category
      }
    }

    case Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[memory.proposals] proposal_promoted audit failed proposal_id=#{proposal.id} " <>
            "errors=#{inspect(changeset.errors)}"
        )

        {:error, {:audit_failed, changeset.errors}}
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "unknown"

  @doc """
  Mark a proposal `:rejected` and capture Rowan's feedback text.

  The feedback is load-bearing — `rejected_exemplars/1` reads it back
  as `{body, feedback}` pairs to inject into the next dreaming prompt's
  few-shot exemplars (acceptance criterion 7).
  """
  @spec reject(MemoryProposal.t(), String.t() | nil, keyword()) ::
          {:ok, MemoryProposal.t()} | {:error, term()}
  def reject(%MemoryProposal{} = proposal, feedback, _opts \\ [])
      when is_binary(feedback) or is_nil(feedback) do
    proposal
    |> MemoryProposal.status_changeset(%{status: "rejected", feedback: feedback})
    |> Repo.update()
  end

  @doc """
  Flip all `pending` rows whose `expires_at` is in the past to
  `expired`. Bulk UPDATE — no per-row loading, no PubSub broadcast (the
  transition is silent per Rowan's spec).

  Returns `{updated_count, nil}` per Ecto's `update_all` contract.

  This is called from a cron responsibility (wired in a follow-up
  stage) so pending queues auto-clean themselves. The e2e test in
  stage 8 exercises the function directly via IEx.
  """
  @spec expire_stale() :: {non_neg_integer(), nil}
  def expire_stale do
    now = DateTime.utc_now()

    from(p in MemoryProposal,
      where: p.status == "pending" and p.expires_at < ^now
    )
    |> Repo.update_all(set: [status: "expired", updated_at: now])
  end

  @doc """
  Return the N most recent rejected proposals as few-shot exemplars for
  the next dreaming run's prompt.

  ## Options

    * `:workspace_id` — scope to a workspace. `nil` (default) = no filter.
    * `:limit` — max exemplars (default 3).

  Each exemplar is `%{body: string, feedback: string | nil, category:
  string, rejected_at: DateTime.t()}`. The dreaming prompt renderer at
  `HeartbeatScheduler.dispatch_prompt/4` (stage 5) formats these as a
  bulleted list for the `{{rejected_exemplars}}` mustache placeholder.
  """
  @spec rejected_exemplars(keyword()) :: [
          %{
            body: String.t(),
            feedback: String.t() | nil,
            category: String.t(),
            rejected_at: DateTime.t()
          }
        ]
  def rejected_exemplars(opts \\ []) when is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit_n = Keyword.get(opts, :limit, @default_exemplars_limit)

    MemoryProposal
    |> where([p], p.status == "rejected")
    |> maybe_filter_workspace(workspace_id)
    |> order_by([p], desc: p.updated_at)
    |> limit(^limit_n)
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        body: p.body,
        feedback: p.feedback,
        category: p.category,
        rejected_at: p.updated_at
      }
    end)
  end

  # ── Sweep-hook trigger predicate ─────────────────────────────────────

  @journal_path_regex ~r/^(org|project\/[^\/]+|space\/[^\/]+)\/journal\/\d{4}-\d{2}-\d{2}\.md$/

  @doc """
  True when `file_key` is a journal path the sweep hook should ingest.

  Exposed so `Platform.Org.Context.upsert_context_file/3` (the sweep
  call site) can gate the ingestion call — the predicate lives here
  because the ingestion rules are a Proposals concern, not an OrgContext
  concern.
  """
  @spec journal_path?(String.t()) :: boolean()
  def journal_path?(file_key) when is_binary(file_key) do
    Regex.match?(@journal_path_regex, file_key)
  end

  def journal_path?(_), do: false

  # ── Parsing ──────────────────────────────────────────────────────────

  defp parse_blocks(content) do
    @block_regex
    |> Regex.scan(content)
    |> Enum.flat_map(fn
      [_full, attr_string, body] ->
        case parse_block(attr_string, body) do
          {:ok, parsed} -> [parsed]
          {:error, reason} -> log_skip(reason, attr_string, body)
        end

      _ ->
        []
    end)
  end

  defp parse_block(attr_string, body) do
    attrs = extract_attrs(attr_string)
    trimmed_body = String.trim(body)

    with {:ok, category} <- fetch_enum(attrs, "category", MemoryProposal.categories()),
         {:ok, confidence} <- fetch_enum(attrs, "confidence", MemoryProposal.confidences()),
         :ok <- validate_body(trimmed_body) do
      {:ok,
       %{
         category: category,
         confidence: confidence,
         evidence: Map.get(attrs, "evidence"),
         body: trimmed_body,
         block_hash: hash_body(trimmed_body)
       }}
    end
  end

  defp extract_attrs(attr_string) do
    @attr_regex
    |> Regex.scan(attr_string)
    |> Map.new(fn [_full, k, v] -> {k, v} end)
  end

  defp fetch_enum(attrs, key, allowed) do
    case Map.get(attrs, key) do
      nil -> {:error, "missing #{key}"}
      val -> if val in allowed, do: {:ok, val}, else: {:error, "invalid #{key}=#{inspect(val)}"}
    end
  end

  defp validate_body(""), do: {:error, "empty body"}
  defp validate_body(_), do: :ok

  defp hash_body(body) do
    :sha256
    |> :crypto.hash(body)
    |> Base.encode16(case: :lower)
  end

  defp log_skip(reason, attr_string, body) do
    Logger.warning(
      "[memory.proposals] skipped malformed synthesis-proposal block: #{reason} " <>
        "attrs=#{inspect(String.slice(attr_string, 0, 80))} " <>
        "body_preview=#{inspect(String.slice(body, 0, 80))}"
    )

    []
  end

  # ── Insert ───────────────────────────────────────────────────────────

  defp insert_block(parsed, workspace_id, journal_path) do
    # Compute target_page_key at ingest time so it's stable + auditable.
    # The promotion pipeline (queue_promotion/1) falls back to the same
    # derivation function for rows inserted before the column landed.
    target_key =
      derive_target_page_key(
        parsed.category,
        Map.get(parsed, :evidence),
        parsed.body
      )

    attrs =
      parsed
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:journal_path, journal_path)
      |> Map.put(:target_page_key, target_key)

    # Pre-check for dedup rather than parsing Ecto's `on_conflict:
    # :nothing` response — our PK is client-side-generated (UUIDv7 auto),
    # so the returned struct always has an id whether or not the DB
    # actually inserted. `Repo.exists?/1` here is a cheap uniqueness
    # probe; the DB unique index still catches the race window between
    # this check and the insert (returned as `{:error, changeset}`
    # which we normalize to `{:conflict, :duplicate}`).
    if duplicate?(workspace_id, attrs.block_hash) do
      {:conflict, :duplicate}
    else
      %MemoryProposal{}
      |> MemoryProposal.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :block_hash]
      )
      |> case do
        {:ok, %MemoryProposal{} = row} ->
          # Detect the race-lost case: Ecto returns `{:ok, struct}` for
          # both a real insert AND a `:nothing` conflict; verify the row
          # actually persisted by a follow-up lookup. In the happy path
          # this is a no-op — we just requery a row we know is there.
          if row_persisted?(row.id) do
            {:ok, row}
          else
            {:conflict, :duplicate}
          end

        {:error, _changeset} = err ->
          err
      end
    end
  end

  defp duplicate?(workspace_id, block_hash) do
    MemoryProposal
    |> where([p], p.block_hash == ^block_hash)
    |> maybe_filter_workspace_strict(workspace_id)
    |> Repo.exists?()
  end

  # Strict workspace filter for the dedup probe — nil means "match
  # workspace_id IS NULL" (as opposed to `list_pending/1`'s "nil = no
  # filter"). The unique index treats workspace_id NULL as a distinct
  # value for uniqueness purposes (Postgres treats NULLs as distinct in
  # unique indexes by default), so the probe must match that semantics.
  defp maybe_filter_workspace_strict(queryable, nil) do
    where(queryable, [p], is_nil(p.workspace_id))
  end

  defp maybe_filter_workspace_strict(queryable, workspace_id) when is_binary(workspace_id) do
    where(queryable, [p], p.workspace_id == ^workspace_id)
  end

  defp row_persisted?(id), do: Repo.exists?(from(p in MemoryProposal, where: p.id == ^id))

  # ── Query helpers ────────────────────────────────────────────────────

  defp maybe_filter_workspace(queryable, nil), do: queryable

  defp maybe_filter_workspace(queryable, workspace_id) when is_binary(workspace_id) do
    where(queryable, [p], p.workspace_id == ^workspace_id)
  end
end
