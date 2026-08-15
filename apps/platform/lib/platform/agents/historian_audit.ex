defmodule Platform.Agents.HistorianAudit do
  @moduledoc """
  Digest-eligibility audit for Historian oversize windows (task 019fa1cc).

  ## Why this exists

  The Historian's window slicer decides `oversize` from a **byte signal**
  (`Historian.pending_bytes_per_day/4`) while the digest renderer builds
  its body from a **different predicate** (`ActivityDigest.corpus_body/4`,
  which delegates to `Chat.list_messages_since/2` and friends). When those
  two drift, a window can be flagged oversize on hundreds of kilobytes of
  bytes that the renderer will never render — and dispatch
  `_No activity in this window._` while the telemetry claims a 60K-token
  day.

  Diagnosing that by hand produces exactly the failure that motivated this
  module: a one-off SQL query, hand-written to approximate the digest
  predicate, reported "87 messages silently lost" for a window in which the
  digest-eligible count was **zero**. A diagnostic that re-implements the
  predicate can drift from the renderer the same way the byte signal did,
  and will confidently report the same false positive.

  **So this module never writes the eligibility predicate.** `eligible_*`
  is computed by calling the digest's own accessor for the corpus and
  summing the bytes of what comes back. If the digest changes what it
  considers eligible, this audit changes with it, by construction.

  ## What it reads

  `audit_oversize_windows/1` walks `audit_events` rows with
  `action = "window_dispatched"` and `metadata->>'oversize' = 'true'`
  (emitted by `HistorianDispatcher.dispatch_one_window/12`), parses
  `metadata->>'day_span'` into `{window_start, window_end}`, and rejoins
  the dispatched `chat_messages` row by matching
  `metadata->'cursor'->>'window_start'` / `'window_end'` / `'namespace'`.

  ## Classification

    * `:spurious` — oversize fired but nothing in the span was
      digest-eligible. The byte signal over-counted; no content was lost
      because there was no content to lose. This is the fingerprint of the
      predicate drift above.
    * `:silent_loss` — the body is the empty stub yet eligible rows exist
      in the span. Real loss.
    * `:truncated_loss` — the truncation marker is present AND
      `body_bytes >= truncation_cap_bytes`. See below for why the cap, and
      not a body/eligible comparison, is the right test. **Pre-019fa1cc-
      stage-4 rows only** — the `binary_part/3` cut that made this class
      possible no longer exists.
    * `:partial_deferred` — the row carries `truncated: true`, i.e. the
      dispatcher held the cursor at the digested watermark and the withheld
      rows re-dispatch on the next pass. Deferral, NOT loss; excluded from
      `summarize/1`'s loss fold.
    * `:legitimate` — oversize fired and eligible content was rendered.

  `:spurious` is checked before `:truncated_loss`: a window with zero
  eligible rows has nothing to have truncated. Both `oversize_empty` and
  `truncated` are read straight off the audit row and are checked before
  everything else — see `classify/1`.

  ### Why `:truncated_loss` keys on the byte cap and NOT on
  ### `eligible_bytes > body_bytes`

  Two traps, both of which this module fell into on its first prod run
  (16 windows wrongly classified `:truncated_loss`, corrected here):

  1. **The marker is unconditional.**
     `HistorianDispatcher.maybe_truncate_digest/3` prepends
     `@truncation_marker` to *every* oversize body whether or not
     `binary_part/3` cut a single byte. Keying on the marker alone labels
     100% of oversize windows as truncated.

  2. **The digest is lossy by design.**
     `ActivityDigest.format_space_messages/2` renders each message through
     `preview/1` (280-char cap) and shows at most `@per_space_message_cap`
     (40) messages per space. So `eligible_bytes > body_bytes` is the
     *normal* state of every healthy digest — it means the digest
     summarised, not that the window lost content. Exposed as the
     informational `digest_compressed?` field, which is deliberately NOT a
     classification input.

  What *is* diagnostic: `maybe_truncate_digest/3` cuts at
  `budget_tokens * 4` bytes, so a genuinely cut body is at least that
  large. The dispatched chat message strictly contains the digest, so
  `body_bytes >= cap` is a **necessary** condition for a real cut. The cap
  is taken per-row from the audit event's own `token_count` (the slicer
  clamps `token_estimate` to the budget on oversize windows), so historical
  rows are judged against the budget in force when they were dispatched,
  not today's config.

  ## Caveat: eligibility is evaluated at read time

  `eligible_*` re-runs the digest accessor *now*. If a space became
  external, was archived, or a message was soft-deleted after the window
  was dispatched, this reports today's eligibility rather than the
  eligibility at dispatch time. That is the correct trade for the tool's
  purpose (it must not re-implement the predicate to freeze it), but it
  means a `:silent_loss` verdict should always be confirmed against the
  space's archive/deletion history before it is believed.

  ## Usage

      iex> Platform.Agents.HistorianAudit.audit_oversize_windows()
      [%{window_start: ~U[...], classification: :spurious, ...}, ...]

      iex> Platform.Agents.HistorianAudit.audit_oversize_windows()
      ...> |> Platform.Agents.HistorianAudit.summarize()
      %{total: 84, spurious: 84, silent_loss: 0, ...}

  See `Mix.Tasks.Platform.HistorianAuditOversize` for the CLI wrapper. In a
  release (prod) there is no Mix, so call the functions directly:

      podman exec core-platform /app/bin/platform rpc \\
        "Platform.Agents.HistorianAudit.audit_oversize_windows() |>
         Platform.Agents.HistorianAudit.summarize() |> inspect() |> IO.puts()"
  """

  import Ecto.Query

  alias Platform.Agents.ActivityDigest
  alias Platform.Audit.Event
  alias Platform.Chat.Message
  alias Platform.Org.Wiki
  alias Platform.Repo

  # Kept in sync with `ActivityDigest`'s empty-window line (activity_digest.ex
  # :176/:186/:199/:210) and `HistorianDispatcher.@truncation_marker` (:105).
  # Deliberately duplicated rather than imported: this is an *observer* of
  # those strings, and it must keep classifying historical rows correctly
  # even after the emitters change them.
  @empty_stub "_No activity in this window._"
  @truncation_marker "_(truncated — deep-summary rather than deep-curate)_"

  @default_limit 1_000

  @type classification ::
          :spurious | :silent_loss | :truncated_loss | :partial_deferred | :legitimate

  @type window_audit :: %{
          window_start: DateTime.t(),
          window_end: DateTime.t(),
          corpus: String.t(),
          day_bytes: non_neg_integer(),
          token_count: non_neg_integer(),
          body_bytes: non_neg_integer(),
          empty_stub?: boolean(),
          truncation_marker?: boolean(),
          truncation_cap_bytes: non_neg_integer(),
          oversize_empty?: boolean(),
          truncated?: boolean(),
          digest_compressed?: boolean(),
          raw_row_count: non_neg_integer(),
          eligible_row_count: non_neg_integer(),
          eligible_bytes: non_neg_integer(),
          classification: classification(),
          audit_event_id: integer(),
          dispatched_message_id: binary() | nil
        }

  @doc """
  Audits every `oversize: true` window the dispatcher has recorded.

  Returns one map per window, oldest first.

  ## Options

    * `:limit` — max audit rows to walk (default #{@default_limit}).
    * `:since` — `DateTime` lower bound on `audit_events.inserted_at`.
    * `:corpus` — restrict to a single corpus string (e.g. `"messages"`).
  """
  @spec audit_oversize_windows(keyword()) :: [window_audit()]
  def audit_oversize_windows(opts \\ []) do
    opts
    |> oversize_events()
    |> Enum.flat_map(fn event ->
      case parse_day_span(event.metadata["day_span"]) do
        {:ok, window_start, window_end} -> [audit_window(event, window_start, window_end)]
        :error -> []
      end
    end)
  end

  @doc """
  Folds a list from `audit_oversize_windows/1` into class totals plus the
  rows/bytes attributable to genuine loss.

  `lost_rows` / `lost_bytes` count only `:silent_loss` and
  `:truncated_loss` windows — `:spurious` windows lost nothing by
  definition, and folding them in is how the original false positive was
  manufactured.
  """
  @spec summarize([window_audit()]) :: map()
  def summarize(results) when is_list(results) do
    lossy = Enum.filter(results, &(&1.classification in [:silent_loss, :truncated_loss]))

    %{
      total: length(results),
      spurious: count_class(results, :spurious),
      silent_loss: count_class(results, :silent_loss),
      truncated_loss: count_class(results, :truncated_loss),
      partial_deferred: count_class(results, :partial_deferred),
      legitimate: count_class(results, :legitimate),
      lost_rows: Enum.reduce(lossy, 0, &(&1.eligible_row_count + &2)),
      lost_bytes: Enum.reduce(lossy, 0, &(&1.eligible_bytes + &2)),
      corpora: results |> Enum.map(& &1.corpus) |> Enum.frequencies()
    }
  end

  @doc """
  One-line human summary of `summarize/1`'s map. Used by the mix task and
  safe to `IO.puts` from an `rpc` call against a release.
  """
  @spec summary_line(map()) :: String.t()
  def summary_line(%{} = summary) do
    "#{summary.total} oversize windows: " <>
      "#{summary.spurious} spurious, " <>
      "#{summary.silent_loss} silent_loss, " <>
      "#{summary.truncated_loss} truncated_loss, " <>
      "#{summary.partial_deferred} partial_deferred, " <>
      "#{summary.legitimate} legitimate — " <>
      "lost #{summary.lost_rows} rows / #{summary.lost_bytes} bytes"
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp count_class(results, class),
    do: Enum.count(results, &(&1.classification == class))

  defp oversize_events(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    query =
      from(e in Event,
        where:
          e.action == "window_dispatched" and
            fragment("?->>'oversize' = 'true'", e.metadata),
        order_by: [asc: e.id],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :since) do
        %DateTime{} = since -> where(query, [e], e.inserted_at >= ^since)
        nil -> query
      end

    query =
      case Keyword.get(opts, :corpus) do
        corpus when is_binary(corpus) ->
          where(query, [e], fragment("?->>'corpus' = ?", e.metadata, ^corpus))

        nil ->
          query
      end

    Repo.all(query)
  end

  # `day_span` is stamped as `"<iso8601>/<iso8601>"`. ISO-8601 instants
  # contain no `/`, so a two-part split is unambiguous.
  defp parse_day_span(span) when is_binary(span) do
    with [raw_start, raw_end] <- String.split(span, "/", parts: 2),
         {:ok, window_start, _} <- DateTime.from_iso8601(raw_start),
         {:ok, window_end, _} <- DateTime.from_iso8601(raw_end) do
      {:ok, window_start, window_end}
    else
      _ -> :error
    end
  end

  defp parse_day_span(_), do: :error

  defp audit_window(%Event{} = event, window_start, window_end) do
    corpus = to_string(event.metadata["corpus"] || "messages")
    message = dispatched_message(corpus, window_start, window_end)
    body = (message && message.content) || ""

    {eligible_row_count, eligible_bytes} = eligible(corpus, window_start, window_end)

    empty_stub? = String.contains?(body, @empty_stub)
    truncation_marker? = String.contains?(body, @truncation_marker)
    body_bytes = byte_size(body)
    token_count = to_int(event.metadata["token_count"])
    cap_bytes = token_count * 4

    # Post-019fa1cc-stage-4 rows state their own outcome. `to_bool/1` because
    # the telemetry handler's `ensure_json_safe/1` stringifies atoms, and
    # `true` IS an atom — prod rows carry the string `"true"`.
    oversize_empty? = to_bool(event.metadata["oversize_empty"])
    truncated? = to_bool(event.metadata["truncated"])

    %{
      window_start: window_start,
      window_end: window_end,
      corpus: corpus,
      day_bytes: to_int(event.metadata["day_bytes"]),
      token_count: token_count,
      body_bytes: body_bytes,
      empty_stub?: empty_stub?,
      truncation_marker?: truncation_marker?,
      truncation_cap_bytes: cap_bytes,
      oversize_empty?: oversize_empty?,
      truncated?: truncated?,
      # Informational only. True for essentially every healthy digest —
      # `preview/1` and `@per_space_message_cap` compress by design. Never
      # a classification input; see the moduledoc.
      digest_compressed?: eligible_bytes > body_bytes,
      raw_row_count: raw_row_count(corpus, window_start, window_end),
      eligible_row_count: eligible_row_count,
      eligible_bytes: eligible_bytes,
      classification:
        classify(%{
          oversize_empty?: oversize_empty?,
          truncated?: truncated?,
          empty_stub?: empty_stub?,
          truncation_marker?: truncation_marker?,
          eligible_rows: eligible_row_count,
          body_bytes: body_bytes,
          cap_bytes: cap_bytes
        }),
      audit_event_id: event.id,
      dispatched_message_id: message && message.id
    }
  end

  # The first two clauses read the dispatcher's own statement of what it did
  # (task 019fa1cc stage 4) off the audit row. They come first deliberately:
  # every clause below them re-derives eligibility *at read time*, which the
  # moduledoc caveat explains can disagree with eligibility at dispatch time
  # after an archive / soft-delete / external-scope change. A row that states
  # its own outcome does not need to be re-derived, and is the reason the
  # flags exist rather than merely being present.
  #
  # `:partial_deferred` is NOT loss and is deliberately excluded from
  # `summarize/1`'s loss fold: post-fix the cursor is held at the digested
  # watermark, so the withheld rows re-dispatch on the next pass. Counting a
  # deferral as loss would manufacture the same false positive the original
  # investigation did, in the opposite direction.
  defp classify(%{oversize_empty?: true}), do: :spurious
  defp classify(%{truncated?: true}), do: :partial_deferred

  defp classify(%{
         empty_stub?: empty_stub?,
         truncation_marker?: truncation_marker?,
         eligible_rows: eligible_rows,
         body_bytes: body_bytes,
         cap_bytes: cap_bytes
       }) do
    cond do
      empty_stub? and eligible_rows > 0 -> :silent_loss
      eligible_rows == 0 -> :spurious
      truncation_marker? and cap_bytes > 0 and body_bytes >= cap_bytes -> :truncated_loss
      true -> :legitimate
    end
  end

  # The dispatcher stamps `cursor: %{namespace:, window_start:, window_end:}`
  # plus a top-level `oversize` onto the instruction message it posts into
  # the Historian's system space (`post_instruction/6`). That triple is the
  # join key back from the audit row to the body actually dispatched.
  defp dispatched_message(corpus, window_start, window_end) do
    start_iso = DateTime.to_iso8601(window_start)
    end_iso = DateTime.to_iso8601(window_end)

    from(m in Message,
      where:
        fragment("?->>'oversize' = 'true'", m.metadata) and
          fragment("?->'cursor'->>'namespace' = ?", m.metadata, ^corpus) and
          fragment("?->'cursor'->>'window_start' = ?", m.metadata, ^start_iso) and
          fragment("?->'cursor'->>'window_end' = ?", m.metadata, ^end_iso),
      order_by: [asc: m.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  # ── Eligibility: the digest's own accessor, never a hand-written copy ──
  #
  # Task 019fa1cc stage 4 collapsed the four per-corpus clauses that used to
  # live here into a single call to `ActivityDigest.corpus_items/4`. That
  # function is now the one place that knows both which rows the digest
  # considers in-window AND what byte weight it charges each of them — the
  # same weight the item-wise truncation budgets against. Before, this module
  # held a second copy of the per-row byte arithmetic (notably
  # `transcript_bytes/1`), which is exactly the kind of near-duplicate that
  # drifts.
  defp eligible(corpus, window_start, window_end) do
    items = ActivityDigest.corpus_items(corpus, window_start, window_end, scope: :internal)

    {length(items), Enum.reduce(items, 0, &(&1.bytes + &2))}
  end

  # ── Raw counts: deliberately predicate-free ────────────────────────────
  #
  # `raw_row_count` is the *unfiltered* row count in the span — the number
  # a naive "did we lose anything?" query would produce. The gap between it
  # and `eligible_row_count` IS the finding. Each clause bounds on the same
  # timestamp column the corresponding `Historian` byte-sum uses, so the two
  # describe the same population.

  @doc """
  Unfiltered row count for `corpus` in `[window_start, window_end)`.

  Public because `ActivityDigest` renders it into the could-not-digest line:
  a window that fired oversize and rendered nothing needs to say how much
  raw traffic was in scope of the byte signal but out of scope of the digest
  predicate, and re-deriving that count in a second place is how the two
  sides drifted in the first place.
  """
  @spec raw_row_count(String.t(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def raw_row_count(corpus, window_start, window_end)

  def raw_row_count("messages", window_start, window_end),
    do: count_between("chat_messages", :inserted_at, window_start, window_end)

  def raw_row_count("transcripts", window_start, window_end),
    do: count_between("meeting_transcripts", :updated_at, window_start, window_end)

  # `pages` and `files` are two halves of one table (task 01a0008c stage
  # 4). The card partition is applied here for the same reason the corpus
  # clock is: this count must describe the population the corresponding
  # byte-sum charged for. Without it, every `pages` window would report
  # the whole org wiki as "raw rows in scope" including cards that were
  # never charged to `pages`, and every `files` window would report the
  # entire wiki as raw — inflating the raw-vs-eligible gap that IS the
  # finding this module exists to produce.
  def raw_row_count("pages", window_start, window_end),
    do:
      "org_wiki_pages"
      |> count_between_query(:updated_at, window_start, window_end)
      |> Wiki.exclude_card_pages()
      |> Repo.one()
      |> Kernel.||(0)

  def raw_row_count("files", window_start, window_end),
    do:
      "org_wiki_pages"
      |> count_between_query(:updated_at, window_start, window_end)
      |> Wiki.only_card_pages()
      |> Repo.one()
      |> Kernel.||(0)

  def raw_row_count("journal", window_start, window_end),
    do: count_between("org_wiki_journal_entries", :inserted_at, window_start, window_end)

  def raw_row_count(_unknown_corpus, _window_start, _window_end), do: 0

  defp count_between_query(table, column, window_start, window_end) do
    from(r in table,
      where:
        field(r, ^column) >= ^window_start and
          field(r, ^column) < ^window_end,
      select: count()
    )
  end

  defp count_between(table, column, window_start, window_end) do
    table
    |> count_between_query(column, window_start, window_end)
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  # `ensure_json_safe/1` in the audit telemetry bridge stringifies atoms, so a
  # `true` in telemetry metadata lands in `audit_events` as the STRING
  # `"true"`. Accept both so the classifier works against a live telemetry
  # map and against a persisted row.
  defp to_bool(true), do: true
  defp to_bool("true"), do: true
  defp to_bool(_), do: false
end
