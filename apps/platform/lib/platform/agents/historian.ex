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
  Returns the max `last_run_at` across the four corpus cursor rows for
  `workspace_id`, or `nil` if no cursor has ever been stamped.

  V1 fan-out passes `nil` for org-scope; the `is_nil/1` guard keeps Ecto from
  rejecting the `column == nil` literal comparison.
  """
  @spec last_run_at(binary() | nil) :: DateTime.t() | nil
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

  Returns `:ok`.
  """
  @spec mark_run_started(binary()) :: :ok
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

  Returns `{:ok, %HistorianCursor{}}` or `{:error, changeset}`.
  """
  @spec advance_cursor(binary(), String.t(), String.t() | nil, DateTime.t() | nil) ::
          {:ok, HistorianCursor.t()} | {:error, Ecto.Changeset.t()}
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
