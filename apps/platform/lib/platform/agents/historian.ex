defmodule Platform.Agents.Historian do
  @moduledoc """
  Context module for the Historian agent — the curator of org wiki pages
  and journal entries.

  The Historian walks five corpora per workspace and remembers progress
  via `Platform.Agents.HistorianCursor` rows in `org_historian_cursors`.
  This module owns ALL writes to that table; `SystemEventScheduler` stays
  a pure dispatcher.

  ## Adding a corpus

  `@corpora` is ONE of six places a corpus must be registered, and the
  other five degrade silently when they are missed — most severely
  `HistorianCursor.@valid_corpora`, because `mark_run_started/1` below
  discards the changeset error and the corpus then re-dispatches its
  whole history on every pass with `:ok` returned.
  `Platform.Agents.HistorianCorpusRegistrationTest` enumerates all six.

  ## Token estimator

  `byte_size(content) |> div(4)` — the same char/4 heuristic
  `Platform.Org.PreambleBuilder` ships with (~4 chars/token for English).
  When a real tokenizer lands, update both sites together.

  ## Corpus sources

  | Corpus          | Table                      | Timestamp column | Byte source                          |
  |-----------------|----------------------------|------------------|--------------------------------------|
  | `"pages"`       | `org_wiki_pages` (no cards)| `updated_at`     | `byte_size(content)`                 |
  | `"journal"`     | `org_wiki_journal_entries` | `inserted_at`    | `byte_size(content)`                 |
  | `"messages"`    | `chat_messages`            | `inserted_at`    | `byte_size(content)` (nil → 0)       |
  | `"transcripts"` | `meeting_transcripts`      | `completed_at`   | `byte_size(summary) + segments JSON` |
  | `"files"`       | `org_wiki_pages`, cards    | `updated_at`     | `byte_size(content)` — the CARD      |

  ## The pages / files partition — a deliberate decision, do NOT "fix" it

  A catalog card is a wiki page, so `pages` and `files` read the same
  table and are told apart by `Platform.Files.card_page_keys_query/0`
  through `Wiki.exclude_card_pages/1` / `Wiki.only_card_pages/1`. Every
  wiki page in a span belongs to exactly one of the two corpora.

  The `files` byte weight is the CARD's bytes, never the source
  document's (`platform_file_texts.text`). A `files` window renders
  cards, and the `019fa1cc` invariant is that the byte signal charges
  for exactly what the renderer renders. Weighting by document text
  would read as ~300k tokens against a 100k-token threshold and flood
  the slicer with oversize windows whose bodies are a few KB — the same
  defect class in a new corpus — and it would push document text back
  into the Historian's context, which is the entire thing the file
  catalog exists to remove.

  The cost of that decision is the `pages` exclusion, which must be
  applied at EVERY `pages` site: `sum_corpus_bytes/3` (both workspace
  variants), `per_day_bytes_query/4` (both), the digest accessor
  `Wiki.list_pages_updated_since/2`, and
  `HistorianAudit.raw_row_count/3`. An exclusion applied at some of them
  double-charges the ones that forgot.

  ## Digest eligibility — one seam, not two predicates

  The `messages` and `transcripts` byte signals are built by composing
  `Platform.Chat.digest_eligible_messages_query/1` and
  `Platform.Meetings.digest_eligible_transcripts_query/1` — the same queries
  `Chat.list_messages_since/2` and `Meetings.list_transcripts_since/2`
  compose, and therefore exactly the rows `ActivityDigest` will render.
  Any eligibility filter added to the accessor is inherited here for free;
  adding one to only one side is the defect task `019fa1cc` fixed. See the
  invariant note above `sum_corpus_bytes("messages", ...)`.

  T6 was developed against the pre-T1 table names (`org_context_files` /
  `org_memory_entries`); the stack rollup reconciled these queries to the
  V2 `org_wiki_*` names from the T1 rename migration (20260515224500).
  """

  import Ecto.Query

  alias Platform.Agents.HistorianCursor
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Org.Wiki
  alias Platform.Repo

  @corpora ~w(pages journal messages transcripts files)

  # Sentinel workspace_id string used by `Platform.Tasks.Projects` to represent
  # "the whole org" during V1 fan-out (see `Projects.list_active_workspaces/0`).
  # The pages+journal tables store actual org-scope rows with
  # `workspace_id IS NULL`, so we translate the sentinel to `nil` at the
  # query boundary rather than aliasing `Tasks.Projects` (compile-time dep
  # this context module avoids). If the sentinel ever changes, update both
  # sites together.
  @org_scope_workspace_id "00000000-0000-0000-0000-000000000000"

  @doc "List of corpus keys the Historian walks."
  def corpora, do: @corpora

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns the sum of pending (post-cursor) bytes across every corpus in
  `corpora/0` for `workspace_id`. Rows older than or equal to the corpus's
  `last_processed_at` are excluded. If a corpus has no cursor row yet,
  all rows count.
  """
  @spec pending_bytes(binary() | nil) :: non_neg_integer()
  def pending_bytes(workspace_id) do
    Enum.reduce(@corpora, 0, fn corpus, acc ->
      acc + corpus_pending_bytes(workspace_id, corpus)
    end)
  end

  @doc """
  Returns `div(pending_bytes/1, 4)` — char/4 token heuristic.
  """
  @spec pending_tokens(binary() | nil) :: non_neg_integer()
  def pending_tokens(workspace_id) do
    div(pending_bytes(workspace_id), 4)
  end

  @doc """
  Returns the per-corpus `{last_processed_at, pending_bytes}` pair the
  slicer needs to plan windows without re-querying the same cursor +
  byte-sum state once per corpus.

  Consumed by `Platform.Agents.HistorianDispatcher.slice_windows/2` at
  planning time. Keeping this as the sole DB-hitting surface for
  windowed dispatch means the slicer stays a pure function you can
  test against a stubbed input.

  Corpus keys are atoms (`:pages`, `:journal`, `:messages`,
  `:transcripts`, `:files`) rather than strings — the slicer atoms are
  the public contract for downstream telemetry / message metadata.
  """
  @spec pending_windows_input(binary() | nil) :: %{
          pages: {DateTime.t() | nil, non_neg_integer()},
          journal: {DateTime.t() | nil, non_neg_integer()},
          messages: {DateTime.t() | nil, non_neg_integer()},
          transcripts: {DateTime.t() | nil, non_neg_integer()},
          files: {DateTime.t() | nil, non_neg_integer()}
        }
  def pending_windows_input(workspace_id) do
    Enum.reduce(@corpora, %{}, fn corpus, acc ->
      last_at = cursor_last_processed_at(workspace_id, corpus)
      bytes = sum_corpus_bytes(corpus, workspace_id, last_at)
      Map.put(acc, String.to_atom(corpus), {last_at, bytes})
    end)
  end

  @doc """
  Returns the per-day sum of pending bytes for `corpus` inside the
  half-open range `[start_at, end_at)`. Keys are UTC calendar days
  (`Date.t()`), values are `non_neg_integer()` byte counts. Days with
  zero rows are absent from the map (callers treat missing keys as 0).

  Half-open semantic: `timestamp >= start_at AND timestamp < end_at`.
  Mirrors the slicer's `enumerate_day_ranges/2` shape in
  `HistorianDispatcher`, so the map keys line up 1:1 with the per-day
  windows the slicer enumerates.

  V1 org-fanout: pass `workspace_id: nil` (default) to sweep across the
  whole table (`pages`/`journal` restrict to rows with null
  `workspace_id`; `messages`/`transcripts` do not filter on workspace
  because those tables have no such column — see `sum_corpus_bytes/3`
  for the same shape).

  Consumed by `HistorianDispatcher.slice_by_calendar_day/6` (Stage 2 of
  this task) to feed real per-day density into the window planner
  instead of the uniform-distribute heuristic.
  """
  @spec pending_bytes_per_day(String.t(), DateTime.t(), DateTime.t()) ::
          %{Date.t() => non_neg_integer()}
  def pending_bytes_per_day(corpus, start_at, end_at) do
    pending_bytes_per_day(corpus, start_at, end_at, nil)
  end

  @spec pending_bytes_per_day(
          String.t(),
          DateTime.t(),
          DateTime.t(),
          binary() | nil
        ) :: %{Date.t() => non_neg_integer()}
  def pending_bytes_per_day(corpus, start_at, end_at, workspace_id) do
    corpus
    |> per_day_bytes_query(workspace_id, start_at, end_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn %{day: day, bytes: bytes}, acc ->
      Map.put(acc, truncate_to_date(day), to_non_neg(bytes))
    end)
  end

  @doc """
  Returns the total pending bytes for `corpus` inside the half-open range
  `[start_at, end_at)` as a single `non_neg_integer()` — the ungrouped
  twin of `pending_bytes_per_day/3-4`, for callers that need to measure an
  arbitrary sub-day span.

  Same half-open semantic, same corpus clocks, same workspace scoping.

  ## Why this exists

  `HistorianDispatcher.halve_until_fits/7` used to manufacture each half's
  byte count as `div(total_bytes, 2)` and never re-query, so at recursion
  depth N the oversize decision ran against `day_bytes / 2^N` — a
  uniform-density fiction. A day with all its traffic in one hour charged
  every quiet hour an equal share and drove them to the minimum sub-window
  span, where they were stamped `oversize: true`. This function is what the
  halving loop asks instead of guessing (task `019fa1cc` stage 3).

  ## It is the SAME query, not a second one

  It composes `per_day_bytes_query/4` — the stage-2 unified builder — and
  sums its groups in the database. That is deliberate and load-bearing: the
  defect this task exists to remove is two predicates drifting apart, and a
  hand-rolled `from(m in ...)` here would be a third copy of the digest
  eligibility filter, one level down. Summing over the day groups is
  arithmetically identical to an ungrouped `SUM` over the same rows, so the
  only structural difference from `pending_bytes_per_day/4` is where the
  fold happens. A range inside a single calendar day — which is every range
  the halving loop asks about — produces exactly one group.

  ## Query cost

  Halving depth is bounded by `log2(86_400 / @min_sub_window_seconds) ≈ 5`,
  so one pathological day costs at most ~2^5 = 32 extra aggregate queries
  against an indexed corpus clock, and only on days that already overflowed
  the budget.
  """
  @spec pending_bytes_in_range(String.t(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def pending_bytes_in_range(corpus, start_at, end_at) do
    pending_bytes_in_range(corpus, start_at, end_at, nil)
  end

  @spec pending_bytes_in_range(
          String.t(),
          DateTime.t(),
          DateTime.t(),
          binary() | nil
        ) :: non_neg_integer()
  def pending_bytes_in_range(corpus, start_at, end_at, workspace_id) do
    corpus
    |> per_day_bytes_query(workspace_id, start_at, end_at)
    |> subquery()
    |> select([r], sum(r.bytes))
    |> Repo.one()
    |> to_non_neg()
  end

  @doc """
  Returns the max `last_run_at` across the corpus cursor rows for
  `workspace_id`, or `nil` if no cursor has ever been stamped.

  V1 fan-out passes `nil` for org-scope; the `is_nil/1` guard keeps Ecto from
  rejecting the `column == nil` literal comparison. The org-scope sentinel
  from `Tasks.Projects.list_active_workspaces/0` coerces to `nil` at the
  boundary (mirrors `sum_corpus_bytes/3`) so the debounce read finds the
  same nil-workspace cursor rows the write path stamps.
  """
  @spec last_run_at(binary() | nil) :: DateTime.t() | nil
  def last_run_at(@org_scope_workspace_id), do: last_run_at(nil)

  def last_run_at(nil) do
    from(c in HistorianCursor,
      where: is_nil(c.workspace_id),
      select: max(c.last_run_at)
    )
    |> Repo.one()
  end

  def last_run_at(workspace_id) do
    from(c in HistorianCursor,
      where: c.workspace_id == ^workspace_id,
      select: max(c.last_run_at)
    )
    |> Repo.one()
  end

  @doc """
  Upserts `last_run_at: utc_now()` on every corpus row for `workspace_id`.

  Idempotent — calling twice in quick succession advances `last_run_at`
  on each call without raising a UNIQUE violation. Wrapped in a
  transaction so partial writes can't strand the workspace.

  The org-scope sentinel coerces to `nil` so the persisted rows land on
  the canonical `workspace_id IS NULL` shape that `last_run_at/1` reads
  under the same coercion (mirrors `sum_corpus_bytes/3`). Migration
  `20260714000000_relax_org_historian_cursors_null_workspace` relaxes
  the cursor table's NOT NULL constraint so this write is legal.

  Returns `:ok`.
  """
  @spec mark_run_started(binary() | nil) :: :ok
  def mark_run_started(@org_scope_workspace_id), do: mark_run_started(nil)

  def mark_run_started(workspace_id) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Enum.each(@corpora, fn corpus ->
        upsert_run_marker(workspace_id, corpus, now)
      end)
    end)

    :ok
  end

  @doc """
  Single-corpus cursor advance. Inserts a new row if the
  `(workspace_id, corpus)` cursor is absent; updates `last_processed_id`
  and `last_processed_at` if present. Other corpora's rows are untouched.

  The org-scope sentinel coerces to `nil` so the persisted cursor lands
  on the canonical `workspace_id IS NULL` row that `cursor_last_processed_at/2`
  reads under the same coercion. Without this, sweep-time advance and next-tick
  read would live on separate rows and the slicer would re-dispatch the same
  windows forever.

  Returns `{:ok, %HistorianCursor{}}` or `{:error, changeset}`.
  """
  @spec advance_cursor(binary() | nil, String.t(), String.t() | nil, DateTime.t() | nil) ::
          {:ok, HistorianCursor.t()} | {:error, Ecto.Changeset.t()}
  def advance_cursor(@org_scope_workspace_id, corpus, last_id, last_at),
    do: advance_cursor(nil, corpus, last_id, last_at)

  def advance_cursor(workspace_id, corpus, last_id, last_at) do
    attrs = %{
      workspace_id: workspace_id,
      corpus: corpus,
      last_processed_id: last_id,
      last_processed_at: last_at
    }

    %HistorianCursor{}
    |> HistorianCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_processed_id, :last_processed_at, :updated_at]},
      conflict_target: [:workspace_id, :corpus]
    )
  end

  # ── Internals ───────────────────────────────────────────────────────────

  @spec corpus_pending_bytes(binary(), String.t()) :: non_neg_integer()
  defp corpus_pending_bytes(workspace_id, corpus) do
    last_at = cursor_last_processed_at(workspace_id, corpus)
    sum_corpus_bytes(corpus, workspace_id, last_at)
  end

  @spec cursor_last_processed_at(binary() | nil, String.t()) :: DateTime.t() | nil
  # Org-scope sentinel → coerce to nil so the cursor read hits the same
  # `workspace_id IS NULL` shape the coerced write path stamps. Mirrors
  # `sum_corpus_bytes/3` at L244.
  defp cursor_last_processed_at(@org_scope_workspace_id, corpus),
    do: cursor_last_processed_at(nil, corpus)

  defp cursor_last_processed_at(nil, corpus) do
    from(c in HistorianCursor,
      where: is_nil(c.workspace_id) and c.corpus == ^corpus,
      select: c.last_processed_at
    )
    |> Repo.one()
  end

  defp cursor_last_processed_at(workspace_id, corpus) do
    from(c in HistorianCursor,
      where: c.workspace_id == ^workspace_id and c.corpus == ^corpus,
      select: c.last_processed_at
    )
    |> Repo.one()
  end

  # Org-scope sentinel (from `Tasks.Projects.list_active_workspaces/0` fan-out)
  # → coerce to nil so we hit the `is_nil(workspace_id)` clauses below.
  # Guarded to `pages`/`journal`/`files` — messages/transcripts ignore
  # workspace_id entirely and the guard prevents a future refactor from
  # silently widening the coercion. (`files` is org_wiki_pages under a
  # different half of the card partition, so it scopes exactly like
  # `pages` does.)
  defp sum_corpus_bytes(corpus, @org_scope_workspace_id, last_at)
       when corpus in ["pages", "journal", "files"],
       do: sum_corpus_bytes(corpus, nil, last_at)

  # Pages corpus → org_wiki_pages MINUS catalog cards. Updated_at because
  # pages mutate.
  # nil workspace_id (V1 org-scope) → sum across rows with null workspace_id.
  #
  # `Wiki.exclude_card_pages/1` is the pages half of the card partition —
  # see the moduledoc. It must be composed at BOTH workspace variants and
  # at both `per_day_bytes_query("pages", …)` clauses; a card left in one
  # of them is charged to `pages` and to `files` at once.
  defp sum_corpus_bytes("pages", nil, last_at) do
    query =
      from(f in "org_wiki_pages", where: is_nil(f.workspace_id))
      |> Wiki.exclude_card_pages()

    query = apply_cursor_filter(query, :updated_at, last_at)

    query
    |> select([f], sum(fragment("coalesce(octet_length(?), 0)", f.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  defp sum_corpus_bytes("pages", workspace_id, last_at) do
    query =
      from(f in "org_wiki_pages",
        where: f.workspace_id == type(^workspace_id, :binary_id)
      )
      |> Wiki.exclude_card_pages()

    query = apply_cursor_filter(query, :updated_at, last_at)

    query
    |> select([f], sum(fragment("coalesce(octet_length(?), 0)", f.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  # Files corpus → org_wiki_pages, catalog cards ONLY. The exact
  # complement of the two `pages` clauses above: same table, same
  # `updated_at` clock, same `octet_length(content)` weight.
  #
  # THE WEIGHT IS THE CARD, NOT THE DOCUMENT, and that is deliberate —
  # see the moduledoc. `platform_file_texts.text` must never appear in
  # this query.
  defp sum_corpus_bytes("files", nil, last_at) do
    query =
      from(f in "org_wiki_pages", where: is_nil(f.workspace_id))
      |> Wiki.only_card_pages()

    query = apply_cursor_filter(query, :updated_at, last_at)

    query
    |> select([f], sum(fragment("coalesce(octet_length(?), 0)", f.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  defp sum_corpus_bytes("files", workspace_id, last_at) do
    query =
      from(f in "org_wiki_pages",
        where: f.workspace_id == type(^workspace_id, :binary_id)
      )
      |> Wiki.only_card_pages()

    query = apply_cursor_filter(query, :updated_at, last_at)

    query
    |> select([f], sum(fragment("coalesce(octet_length(?), 0)", f.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  # Journal corpus → org_wiki_journal_entries. Inserted_at because journal
  # is append-only (`updated_at: false` on the schema).
  # nil workspace_id (V1 org-scope) → sum across rows with null workspace_id.
  defp sum_corpus_bytes("journal", nil, last_at) do
    query = from(e in "org_wiki_journal_entries", where: is_nil(e.workspace_id))
    query = apply_cursor_filter(query, :inserted_at, last_at)

    query
    |> select([e], sum(fragment("coalesce(octet_length(?), 0)", e.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  defp sum_corpus_bytes("journal", workspace_id, last_at) do
    query =
      from(e in "org_wiki_journal_entries",
        where: e.workspace_id == type(^workspace_id, :binary_id)
      )

    query = apply_cursor_filter(query, :inserted_at, last_at)

    query
    |> select([e], sum(fragment("coalesce(octet_length(?), 0)", e.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  # ── The digest-eligibility seam (task 019fa1cc stage 2) ────────────────
  #
  # Messages corpus → chat_messages, keyed on inserted_at; edits are tracked
  # in chat_message_versions and don't affect the pending-bytes signal.
  # workspace_id is unused here in V1 (chat_messages has no workspace_id
  # column; org-scope V1 fan-out sweeps the whole table).
  #
  # The byte signal is built by composing `Chat.digest_eligible_messages_query/1`
  # — the SAME query `Chat.list_messages_since/2` composes, and therefore the
  # same rows `ActivityDigest.corpus_body(:messages, …)` will actually render.
  # It is not a re-statement of that predicate: it is that predicate, plus a
  # time bound and an aggregate select.
  #
  # THE INVARIANT: any eligibility filter added to the digest accessor is
  # inherited by this byte signal automatically. Adding a filter to only one
  # side is a bug of a specific, measured class — the previous version of this
  # code hand-wrote `from(m in "chat_messages", where: space_id not in …)` and
  # carried a comment claiming it was "on the same predicate" as the digest.
  # It was not: the accessor additionally required `s.kind in ~w(channel group)`,
  # `m.log_only == false`, `m.content_type in ~w(text agent_action)`,
  # `is_nil(m.deleted_at)` and `is_nil(s.archived_at)`. That five-filter gap let
  # a busy hour of agent execution-space chatter read as a 60K-token day to the
  # window slicer and as an empty window to the renderer. Measured on prod:
  # 86 oversize windows, 56 spurious, 55 of which dispatched the empty stub
  # with an eligible row count of exactly 0. Do not hand-write the filter list
  # here; compose the seam.
  #
  # (External-user space exclusion — stack member 12, rbac-external-users —
  # now rides in via the seam's default `scope: :internal`. Empty external set
  # → `NOT IN ^[]` is a no-op, leaving all-internal orgs unchanged.)

  defp sum_corpus_bytes("messages", _workspace_id, last_at) do
    Chat.digest_eligible_messages_query(scope: :internal)
    |> apply_cursor_filter(:inserted_at, last_at)
    |> select([m], sum(fragment("coalesce(octet_length(?), 0)", m.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  # Transcripts corpus → meeting_transcripts, composed on
  # `Meetings.digest_eligible_transcripts_query/1` for the same reason and
  # under the same invariant. Byte size = summary + JSON-encoded segments
  # (cheap approximation; the char/4 heuristic absorbs the slack).
  #
  # Keyed on `completed_at`, matching `Meetings.list_transcripts_since/2`.
  # This half was never a live bug — zero of the 86 measured oversize windows
  # were transcripts — but it carried the identical divergence (no status
  # filter, bound on `updated_at` while the accessor bounds on `completed_at`),
  # and leaving one half of the seam un-unified reintroduces the drift.
  defp sum_corpus_bytes("transcripts", _workspace_id, last_at) do
    query =
      Meetings.digest_eligible_transcripts_query(scope: :internal)
      |> apply_cursor_filter(:completed_at, last_at)

    query
    |> select(
      [t],
      sum(
        fragment(
          "coalesce(octet_length(?), 0) + coalesce(octet_length(?::text), 0)",
          t.summary,
          t.segments
        )
      )
    )
    |> Repo.one()
    |> to_non_neg()
  end

  # ── Per-day grouped byte-sum queries (pending_bytes_per_day/3-4) ────────
  #
  # Same per-corpus dispatch as `sum_corpus_bytes/3` (nil-workspace vs
  # scoped variants for pages/journal; messages/transcripts ignore
  # workspace_id since those tables have no such column). Each query
  # groups by `date_trunc('day', <ts>)` and sums octet_length of the
  # content column(s). Half-open `[start_at, end_at)` range.

  # Org-scope sentinel → coerce to nil (matches the `sum_corpus_bytes/3`
  # pass-through above). Guarded to `pages`/`journal` for the same reason.
  defp per_day_bytes_query(corpus, @org_scope_workspace_id, start_at, end_at)
       when corpus in ["pages", "journal", "files"],
       do: per_day_bytes_query(corpus, nil, start_at, end_at)

  # Pages corpus → org_wiki_pages MINUS catalog cards. Updated_at because
  # pages mutate. The exclusion mirrors `sum_corpus_bytes("pages", …)`;
  # applying it to one and not the other means the day-grouped signal and
  # the total disagree about the same span.
  defp per_day_bytes_query("pages", nil, start_at, end_at) do
    from(f in "org_wiki_pages",
      where:
        is_nil(f.workspace_id) and f.updated_at >= ^start_at and
          f.updated_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", f.updated_at),
      select: %{
        day: fragment("date_trunc('day', ?)", f.updated_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", f.content))
      }
    )
    |> Wiki.exclude_card_pages()
  end

  defp per_day_bytes_query("pages", workspace_id, start_at, end_at) do
    from(f in "org_wiki_pages",
      where:
        f.workspace_id == type(^workspace_id, :binary_id) and
          f.updated_at >= ^start_at and f.updated_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", f.updated_at),
      select: %{
        day: fragment("date_trunc('day', ?)", f.updated_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", f.content))
      }
    )
    |> Wiki.exclude_card_pages()
  end

  # Files corpus → org_wiki_pages, catalog cards ONLY. Complement of the
  # two `pages` clauses above, on the same clock and the same weight.
  defp per_day_bytes_query("files", nil, start_at, end_at) do
    from(f in "org_wiki_pages",
      where:
        is_nil(f.workspace_id) and f.updated_at >= ^start_at and
          f.updated_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", f.updated_at),
      select: %{
        day: fragment("date_trunc('day', ?)", f.updated_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", f.content))
      }
    )
    |> Wiki.only_card_pages()
  end

  defp per_day_bytes_query("files", workspace_id, start_at, end_at) do
    from(f in "org_wiki_pages",
      where:
        f.workspace_id == type(^workspace_id, :binary_id) and
          f.updated_at >= ^start_at and f.updated_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", f.updated_at),
      select: %{
        day: fragment("date_trunc('day', ?)", f.updated_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", f.content))
      }
    )
    |> Wiki.only_card_pages()
  end

  # Journal corpus → org_wiki_journal_entries. Inserted_at because
  # journal is append-only (`updated_at: false` on the schema).
  defp per_day_bytes_query("journal", nil, start_at, end_at) do
    from(e in "org_wiki_journal_entries",
      where:
        is_nil(e.workspace_id) and e.inserted_at >= ^start_at and
          e.inserted_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", e.inserted_at),
      select: %{
        day: fragment("date_trunc('day', ?)", e.inserted_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", e.content))
      }
    )
  end

  defp per_day_bytes_query("journal", workspace_id, start_at, end_at) do
    from(e in "org_wiki_journal_entries",
      where:
        e.workspace_id == type(^workspace_id, :binary_id) and
          e.inserted_at >= ^start_at and e.inserted_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", e.inserted_at),
      select: %{
        day: fragment("date_trunc('day', ?)", e.inserted_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", e.content))
      }
    )
  end

  # Messages corpus → chat_messages. Inserted_at; no workspace filter
  # (chat_messages has no workspace_id column — mirrors the sum
  # variant at `sum_corpus_bytes("messages", ...)`). Composed on the same
  # `Chat.digest_eligible_messages_query/1` seam; see the invariant note
  # above `sum_corpus_bytes("messages", ...)`.
  defp per_day_bytes_query("messages", _workspace_id, start_at, end_at) do
    Chat.digest_eligible_messages_query(scope: :internal)
    |> where([m], m.inserted_at >= ^start_at and m.inserted_at < ^end_at)
    |> group_by([m], fragment("date_trunc('day', ?)", m.inserted_at))
    |> select([m], %{
      day: fragment("date_trunc('day', ?)", m.inserted_at),
      bytes: sum(fragment("coalesce(octet_length(?), 0)", m.content))
    })
  end

  # Transcripts corpus → meeting_transcripts, grouped on `completed_at`
  # (the corpus clock `Meetings.list_transcripts_since/2` bounds on — see
  # the note above `sum_corpus_bytes("transcripts", ...)`). Byte size =
  # summary + JSON-encoded segments. No workspace filter —
  # meeting_transcripts has no workspace_id column in V1. Composed on the
  # `Meetings.digest_eligible_transcripts_query/1` seam.
  defp per_day_bytes_query("transcripts", _workspace_id, start_at, end_at) do
    Meetings.digest_eligible_transcripts_query(scope: :internal)
    |> where([t], t.completed_at >= ^start_at and t.completed_at < ^end_at)
    |> group_by([t], fragment("date_trunc('day', ?)", t.completed_at))
    |> select([t], %{
      day: fragment("date_trunc('day', ?)", t.completed_at),
      bytes:
        sum(
          fragment(
            "coalesce(octet_length(?), 0) + coalesce(octet_length(?::text), 0)",
            t.summary,
            t.segments
          )
        )
    })
  end

  # `date_trunc('day', timestamptz)` returns a `timestamp with time
  # zone`, which postgrex hands back as `DateTime`. Ecto occasionally
  # decodes it as `NaiveDateTime` when the underlying column is
  # `timestamp` without zone — accept both defensively.
  defp truncate_to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp truncate_to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp truncate_to_date(%Date{} = d), do: d

  defp apply_cursor_filter(query, _field, nil), do: query

  defp apply_cursor_filter(query, :updated_at, last_at) do
    from(q in query, where: q.updated_at > ^last_at)
  end

  defp apply_cursor_filter(query, :completed_at, last_at) do
    from(q in query, where: q.completed_at > ^last_at)
  end

  defp apply_cursor_filter(query, :inserted_at, last_at) do
    from(q in query, where: q.inserted_at > ^last_at)
  end

  defp to_non_neg(nil), do: 0
  defp to_non_neg(n) when is_integer(n) and n >= 0, do: n
  defp to_non_neg(n) when is_integer(n), do: 0
  defp to_non_neg(%Decimal{} = d), do: d |> Decimal.to_integer() |> max(0)

  # Defensive belt-and-suspenders sentinel coerce: `mark_run_started/1`
  # already normalises the entry point, but future callers that reach this
  # private helper directly (or a refactor that reintroduces the sentinel)
  # would otherwise write a `workspace_id = sentinel` row that the coerced
  # reads no longer see.
  defp upsert_run_marker(@org_scope_workspace_id, corpus, now),
    do: upsert_run_marker(nil, corpus, now)

  defp upsert_run_marker(workspace_id, corpus, now) do
    attrs = %{
      workspace_id: workspace_id,
      corpus: corpus,
      last_run_at: now
    }

    %HistorianCursor{}
    |> HistorianCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [last_run_at: now, updated_at: now]],
      conflict_target: [:workspace_id, :corpus]
    )
  end
end
