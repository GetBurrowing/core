defmodule Platform.Agents.Historian do
  @moduledoc """
  Context module for the Historian agent — the curator of org wiki pages
  and journal entries.

  The Historian walks four corpora per workspace and remembers progress
  via `Platform.Agents.HistorianCursor` rows in `org_historian_cursors`.
  This module owns ALL writes to that table; `SystemEventScheduler` stays
  a pure dispatcher.

  ## Token estimator

  `byte_size(content) |> div(4)` — the same char/4 heuristic
  `Platform.Org.PreambleBuilder` ships with (~4 chars/token for English).
  When a real tokenizer lands, update both sites together.

  ## Corpus sources

  | Corpus          | Table                      | Timestamp column | Byte source                          |
  |-----------------|----------------------------|------------------|--------------------------------------|
  | `"pages"`       | `org_wiki_pages`           | `updated_at`     | `byte_size(content)`                 |
  | `"journal"`     | `org_wiki_journal_entries` | `inserted_at`    | `byte_size(content)`                 |
  | `"messages"`    | `chat_messages`            | `inserted_at`    | `byte_size(content)` (nil → 0)       |
  | `"transcripts"` | `meeting_transcripts`      | `updated_at`     | `byte_size(summary) + segments JSON` |

  T6 was developed against the pre-T1 table names (`org_context_files` /
  `org_memory_entries`); the stack rollup reconciled these queries to the
  V2 `org_wiki_*` names from the T1 rename migration (20260515224500).
  """

  import Ecto.Query

  alias Platform.Agents.HistorianCursor
  alias Platform.Repo

  @corpora ~w(pages journal messages transcripts)

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
  Returns the sum of pending (post-cursor) bytes across all four corpora
  for `workspace_id`. Rows older than or equal to the corpus's
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
  byte-sum state four separate times.

  Consumed by `Platform.Agents.HistorianDispatcher.slice_windows/2` at
  planning time. Keeping this as the sole DB-hitting surface for
  windowed dispatch means the slicer stays a pure function you can
  test against a stubbed input.

  Corpus keys are atoms (`:pages`, `:journal`, `:messages`,
  `:transcripts`) rather than strings — the slicer atoms are the
  public contract for downstream telemetry / message metadata.
  """
  @spec pending_windows_input(binary() | nil) :: %{
          pages: {DateTime.t() | nil, non_neg_integer()},
          journal: {DateTime.t() | nil, non_neg_integer()},
          messages: {DateTime.t() | nil, non_neg_integer()},
          transcripts: {DateTime.t() | nil, non_neg_integer()}
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

  Consumed by `HistorianDispatcher.slice_by_calendar_day/5` (Stage 2 of
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
  Returns the max `last_run_at` across the four corpus cursor rows for
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
  # Guarded to `pages`/`journal` — messages/transcripts ignore workspace_id
  # entirely and the guard prevents a future refactor from silently
  # widening the coercion.
  defp sum_corpus_bytes(corpus, @org_scope_workspace_id, last_at)
       when corpus in ["pages", "journal"],
       do: sum_corpus_bytes(corpus, nil, last_at)

  # Pages corpus → org_wiki_pages. Updated_at because pages mutate.
  # nil workspace_id (V1 org-scope) → sum across rows with null workspace_id.
  defp sum_corpus_bytes("pages", nil, last_at) do
    query = from(f in "org_wiki_pages", where: is_nil(f.workspace_id))
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

  # Messages corpus → chat_messages. Inserted_at; edits are tracked in
  # chat_message_versions and don't affect the pending-bytes signal.
  # workspace_id is unused here in V1 (chat_messages has no workspace_id
  # column; org-scope V1 fan-out sweeps the whole table).
  defp sum_corpus_bytes("messages", _workspace_id, last_at) do
    query = from(m in "chat_messages")
    query = apply_cursor_filter(query, :inserted_at, last_at)

    query
    |> select([m], sum(fragment("coalesce(octet_length(?), 0)", m.content)))
    |> Repo.one()
    |> to_non_neg()
  end

  # Transcripts corpus → meeting_transcripts. Updated_at because segments
  # accumulate during a recording. Byte size = summary + JSON-encoded
  # segments (cheap approximation; the char/4 heuristic absorbs the slack).
  defp sum_corpus_bytes("transcripts", _workspace_id, last_at) do
    query = from(t in "meeting_transcripts")
    query = apply_cursor_filter(query, :updated_at, last_at)

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
       when corpus in ["pages", "journal"],
       do: per_day_bytes_query(corpus, nil, start_at, end_at)

  # Pages corpus → org_wiki_pages. Updated_at because pages mutate.
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
  # variant at `sum_corpus_bytes("messages", ...)`).
  defp per_day_bytes_query("messages", _workspace_id, start_at, end_at) do
    from(m in "chat_messages",
      where: m.inserted_at >= ^start_at and m.inserted_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", m.inserted_at),
      select: %{
        day: fragment("date_trunc('day', ?)", m.inserted_at),
        bytes: sum(fragment("coalesce(octet_length(?), 0)", m.content))
      }
    )
  end

  # Transcripts corpus → meeting_transcripts. Updated_at because
  # segments accumulate during a recording. Byte size = summary +
  # JSON-encoded segments (matches `sum_corpus_bytes("transcripts",
  # ...)`). No workspace filter — meeting_transcripts has no
  # workspace_id column in V1.
  defp per_day_bytes_query("transcripts", _workspace_id, start_at, end_at) do
    from(t in "meeting_transcripts",
      where: t.updated_at >= ^start_at and t.updated_at < ^end_at,
      group_by: fragment("date_trunc('day', ?)", t.updated_at),
      select: %{
        day: fragment("date_trunc('day', ?)", t.updated_at),
        bytes:
          sum(
            fragment(
              "coalesce(octet_length(?), 0) + coalesce(octet_length(?::text), 0)",
              t.summary,
              t.segments
            )
          )
      }
    )
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
