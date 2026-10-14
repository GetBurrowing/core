defmodule Platform.Agents.ActivityDigest do
  @moduledoc """
  Builds a markdown digest of organisational activity within a time window.

  Composed by the Historian's `historian` system event (post-T6 — was the
  legacy `daily_summary` event) so the agent receives a pre-aggregated view
  of chat messages, completed meeting transcripts, and task lifecycle
  changes rather than looping tool calls.

  DMs, archived spaces, deleted messages, and log-only messages are excluded
  by the underlying queries (`Chat.list_messages_since/2`,
  `Meetings.list_transcripts_since/2`, `Tasks.list_tasks_updated_since/2`).

  ## External-user scope partition (stack member 12, rbac-external-users)

  The message + transcript corpora partition on the M1 `external` marker in
  BOTH directions, threaded via the `:scope` opt on the underlying queries:

    * `:internal` (the default for `build/2`, `build/3` and `build_windowed/1`)
      — OMITS any external-user space/DM (and mixed internal+external spaces) from
      the internal digest. With zero external users this is a no-op, so
      an all-internal org's output is byte-for-byte unchanged.
    * `build_external/3` — the mirror direction: builds a summary restricted to
      one external user's allowlisted spaces (`{:external_spaces, ids}`), which
      intrinsically OMITS internal content.

  Pages, journal, and task corpora have no space dimension, so scope does not
  apply to them; `build_external/3` therefore covers only chat + meetings.
  """

  import Ecto.Query

  alias Platform.Agents.CredentialShape
  alias Platform.Agents.HistorianAudit
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks

  @per_space_message_cap 40
  @message_content_preview 280
  @task_event_cap 50

  # The corpora `HistorianDispatcher.slice_windows/2` emits and
  # `Historian` keeps cursors for. Anything else is a code bug in the
  # plan-caller; `build_windowed_result/1` surfaces it as a visible digest
  # artefact rather than a scheduler crash.
  #
  # A corpus missing from THIS list does not crash and does not warn: the
  # `windowed_body/4` guard below falls through to `_(unknown corpus)_`
  # and `corpus_items/4` falls through to `[]`, so the Historian dutifully
  # digests nothing. See `Platform.Agents.HistorianCorpusRegistrationTest`.
  @corpora [:messages, :transcripts, :pages, :journal, :files]

  # ── The three strings (task 019fa1cc stage 4) ────────────────────────────
  #
  # "we could not digest this" and "there was nothing to digest" must never
  # render as the same output. Conflating them is what made a window with
  # zero digest-eligible rows read as catastrophic data loss for a full day,
  # and it is the same collapse forbidden by
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`,
  # which rules that `not_applicable` and `failed` must never be conflated:
  # the first is the progressive-enhancement path, the second is a gate that
  # did not run.
  #
  #   * `@empty_line`         — nothing to digest. The window was quiet.
  #   * `@oversize_empty_*`   — could not digest: the byte signal said this
  #     window held content, the digest predicate found none of it eligible.
  #     NOT a quiet window; the raw row count names how much was out of scope.
  #   * `partial_line/2` — could not digest ALL of it. The cursor is held at
  #     the watermark, so the remainder re-dispatches.
  #   * `skipped_line/3` — one row (or timestamp-tied group) exceeds the
  #     budget on its own. The cursor steps PAST it and it does NOT
  #     re-dispatch until the row changes again; the caller emits an
  #     `:item_skipped` audit row so the step is never silent. See
  #     `HistorianDispatcher.cursor_target/2`, case 3 (ticket 01a0978c).
  #     A page-corpus skip (`:pages`, `:files`) names the page and where
  #     its content is (task 01a0ee1d); a chat or meeting skip names
  #     nothing (01a0a12e clause 10).
  #
  # Consumers act on the difference rather than merely observing it:
  # `HistorianDispatcher.cursor_target/2` reads `truncated?` to decide
  # whether the cursor may reach `window_end`, and `HistorianAudit.classify/1`
  # reads the `oversize_empty` / `truncated` flags off the audit row to
  # classify a window without re-deriving eligibility at read time.
  @empty_line "_No activity in this window._"

  # ── The FOURTH state: `withheld` (task 01a09c9b) ─────────────────────────
  #
  # Distinct from all three above, and never to be collapsed into any of
  # them. `@empty_line` says the window was quiet; the `@oversize_empty_*`
  # lines say we could not digest it; `partial_line/2` / `skipped_line/3`
  # say we could not digest ALL of it. `@withheld_marker` says something
  # different again: content EXISTED, was eligible, was within budget, and
  # was deliberately removed because it is shaped like a credential.
  #
  # It occupies the message's POSITION in the stream rather than deleting
  # the row, so author, space and timestamp survive and the reader can see
  # that a thing was said and go read it at the source. A blank or a silent
  # drop would be worse than a false claim: a hole invites the recipient to
  # invent what filled it, which is the defect task 01a0a74d closed.
  #
  # Renders ALONGSIDE `partial_line/2` when both apply, never instead of it.
  @withheld_marker "[WITHHELD: credential-shaped span]"

  # ── The incompleteness notice (task 01a09c9b stage 3) ────────────────────
  #
  # The marker above changes what the Historian SEES. This changes what it
  # PRODUCES. Without it a careful reader does the wrong thing correctly:
  # sees a marker, respects it, curates everything around it, and publishes
  # an org-wide page that silently omits what the withheld span was about.
  # `@empty_line` and the `RETURN SILENTLY` instruction downstream are both
  # scoped to "nothing to curate", never to "something was withheld".
  #
  # Three properties, each of which is the one an implementer drops:
  #
  #   1. ONCE per dispatch, NOT per marker. Per-marker repetition trains the
  #      reader past it by the third occurrence.
  #   2. At the TOP, immediately under the header — never a footer. At the
  #      end it arrives after the reader has already formed the summary; at
  #      the top it is a precondition on the whole task, and the reader
  #      cannot reach the messages without passing it.
  #   3. It carries the COUNT. The count is the part cut as "redundant with
  #      the markers". It is not: the markers are scattered through the
  #      stream and nobody totals them, and 1 versus 14 licenses completely
  #      different curation decisions.
  #
  # Rendered ALONGSIDE `partial_line/2` when both apply, never instead of.
  @spec incompleteness_notice(non_neg_integer()) :: String.t()
  defp incompleteness_notice(0), do: ""

  defp incompleteness_notice(count) when is_integer(count) and count > 0 do
    "> **This window is INCOMPLETE: #{count} message(s) withheld — " <>
      "credential-shaped content removed before delivery.**\n" <>
      "> **Do not publish a summary that implies full coverage of this window.**\n\n"
  end

  # Header, then the notice (when anything was withheld), then the body.
  # The notice is prepended exactly once here, which is the only place any
  # of the three entry points assembles a header onto a body.
  @spec with_header(String.t(), non_neg_integer(), String.t()) :: String.t()
  defp with_header(header, withheld_count, body) do
    header <> "\n\n" <> incompleteness_notice(withheld_count) <> body
  end

  @doc """
  Returns a markdown string summarising activity in the half-open
  window `[window_start, window_end)`.

  Empty windows yield an italicised `_No activity in this window._` line
  under the header so the agent can detect and handle the quiet case.
  """
  @spec build(DateTime.t(), DateTime.t(), keyword()) :: String.t()
  def build(%DateTime{} = window_start, %DateTime{} = window_end, opts \\ []) do
    scope = Keyword.get(opts, :scope, :internal)

    messages = Chat.list_messages_since(window_start, window_end: window_end, scope: scope)

    transcripts =
      Meetings.list_transcripts_since(window_start, window_end: window_end, scope: scope)

    tasks = Tasks.list_tasks_updated_since(window_start, window_end: window_end)

    {messages, messages_withheld} = withhold_credentialed(messages, :content)
    {transcripts, transcripts_withheld} = withhold_credentialed(transcripts, :summary)
    withheld_count = messages_withheld + transcripts_withheld

    space_names = fetch_space_names(messages, transcripts)

    sections =
      [
        digest_messages(messages, space_names),
        digest_transcripts(transcripts, space_names),
        digest_task_events(tasks)
      ]
      |> Enum.reject(&(&1 == nil))

    body =
      case sections do
        [] -> @empty_line
        sections -> Enum.join(sections, "\n\n")
      end

    header = "## Activity since #{format_datetime(window_start)} (UTC)"
    with_header(header, withheld_count, body)
  end

  @doc """
  Builds an external-user-facing digest for `user_id` over the half-open
  window `[window_start, window_end)`.

  Resolves the external user's allowlisted spaces via
  `Chat.participant_space_ids_for_user/1` and scopes the chat + meeting
  corpora to exactly those spaces (`scope: {:external_spaces, ids}`). Because
  an external user only ever participates in their allowlisted spaces, this
  intrinsically OMITS all internal content. Pages, journal and task
  events are org-scoped (not space-scoped) and are therefore left out of the
  external summary entirely.

  Ships inert on the external side — no dispatcher wires this yet (M13
  notifications is the likely first consumer); the scoped builder is exposed
  now so that caller inherits a correct-by-construction exclusion.
  """
  @spec build_external(binary(), DateTime.t(), DateTime.t()) :: String.t()
  def build_external(user_id, %DateTime{} = window_start, %DateTime{} = window_end)
      when is_binary(user_id) do
    space_ids = Chat.participant_space_ids_for_user(user_id)
    scope = {:external_spaces, space_ids}

    messages = Chat.list_messages_since(window_start, window_end: window_end, scope: scope)

    transcripts =
      Meetings.list_transcripts_since(window_start, window_end: window_end, scope: scope)

    # An external-user digest reaches a WIDER audience than the internal
    # one, not a narrower one. This call site is the one that gets skipped.
    {messages, messages_withheld} = withhold_credentialed(messages, :content)
    {transcripts, transcripts_withheld} = withhold_credentialed(transcripts, :summary)
    withheld_count = messages_withheld + transcripts_withheld

    space_names = fetch_space_names(messages, transcripts)

    sections =
      [
        digest_messages(messages, space_names),
        digest_transcripts(transcripts, space_names)
      ]
      |> Enum.reject(&(&1 == nil))

    body =
      case sections do
        [] -> @empty_line
        sections -> Enum.join(sections, "\n\n")
      end

    header = "## Activity since #{format_datetime(window_start)} (UTC)"
    with_header(header, withheld_count, body)
  end

  @doc """
  Corpus-scoped windowed digest, sized to a single window emitted by
  `Platform.Agents.HistorianDispatcher.slice_windows/2` (task 019f4f55).

  Unlike `build/2` — which fans out to every corpus over a 24-hour anchor
  window — `build_windowed/1` scopes queries to a single corpus in the
  half-open range `[window_start, window_end)`. Callers dispatch one
  message per window; the slicer keeps each range's estimated tokens
  under `historian_window_token_budget` so the resulting body fits the
  small-model context Higgins runs against.

  Recognised corpus keys mirror the atoms `slice_windows/2` returns and
  the atoms `Historian.pending_windows_input/1` uses: `:messages`,
  `:transcripts`, `:pages`, `:journal`, `:files`. Unknown corpus keys fall back to
  a `_(unknown corpus)_` marker rather than raising — the plan-caller is
  the sole producer so garbage keys can only come from a code bug we'd
  rather surface as a visible digest artefact than a scheduler crash.

  Empty corpus queries render the same italicised `_No activity in this
  window._` fallback `build/2` uses so the agent's downstream handling
  stays uniform across the two paths — EXCEPT when the window arrived
  flagged `oversize: true`, in which case a distinct could-not-digest line
  is rendered instead. See `build_windowed_result/1`.
  """
  @spec build_windowed(map()) :: String.t()
  def build_windowed(input) when is_map(input) do
    {:ok, body, _meta} = build_windowed_result(input)
    body
  end

  @doc """
  `build_windowed/1` plus the accounting the cursor needs.

  Returns `{:ok, body, meta}` where `meta` is:

    * `:item_count` — corpus rows the digest predicate returned for the span.
    * `:included_count` — how many of them the rendered body actually carries.
    * `:last_included_at` — the corpus-clock timestamp of the last included
      row, or `nil` when nothing was included. **This is the watermark.**
    * `:truncated?` — `included_count < item_count`. When true the caller
      MUST NOT advance its cursor to `window_end`.
    * `:oversize_empty?` — the window arrived `oversize: true` and the digest
      predicate returned zero rows. "We could not digest this", not "there
      was nothing to digest".
    * `:skipped` — `nil`, or `%{id:, at:, bytes:, count:}` naming the single
      row (or timestamp-tied group) that exceeds the whole window budget on
      its own. Forward progress requires stepping past it; the caller emits
      an `:item_skipped` audit row so the step is never silent.
    * `:credential_withheld_count` — how many INCLUDED rows had their
      rendered field replaced by `[WITHHELD: credential-shaped span]`. A
      fourth state, distinct from every count above: the row was eligible,
      within budget and rendered — only its body was removed. It is still
      counted in `:included_count` and it does not set `:truncated?`,
      because the cursor HAS passed it and must not re-dispatch it.

  ## Item-wise truncation

  Rows are admitted in corpus-clock order until the next one would push the
  running byte total past `budget_tokens * 4`, and the body is rendered from
  the admitted prefix only. This replaces the previous
  `binary_part(body, 0, cap)` cut in `HistorianDispatcher`, which

    1. advanced the cursor past whatever it chopped, and
    2. cut at a byte offset, so it could split a multi-byte grapheme and
       hand Postgres invalid UTF-8 for a `text` column.

  Rows are admitted in whole timestamp groups, so no withheld row ever
  shares `last_included_at`. That is what lets the caller advance to
  `last_included_at + 1µs` — strictly forward, and provably not past
  anything undigested.

  What admission charges a row depends on the corpus.

    * `:messages` and `:transcripts` are charged their RAW bytes, the same
      figure `Platform.Agents.Historian.sum_corpus_bytes/3` sums in SQL. The
      window budget is what keeps an oversized chat or meeting out of the
      digest (task 01a0a12e, ticket clause 10), so it must keep weighing
      what it withholds.
    * The page-previewed corpora (`:pages`, `:files`, `:journal`) are charged
      the bytes of the line the digest actually renders for the row: its
      path, version and a #{@message_content_preview}-character
      `page_preview/1`. That is the page-size policy (task 01a0ee1d): an
      oversized page is admitted as a preview and never skipped, so it cannot
      block the rows behind it in its corpus.

  Either way, bounding the admitted weight bounds the rendered body. Slicing,
  `meta.skipped.bytes` and `Platform.Agents.HistorianAudit` still use the raw
  `:bytes` from `corpus_items/4`, so the audit row and the notice state a
  row's true size.

  ## Options carried on `input`

    * `:budget_tokens` — defaults to the dispatcher's configured window
      budget. Read through `HistorianDispatcher.window_budget_tokens/0` so
      the config key is not read from a second place.
    * `:oversize` — the slicer's flag, used only to tell the two empty
      strings apart.
    * `:scope` — defaults to `:internal`.
  """
  @spec build_windowed_result(map()) :: {:ok, String.t(), map()}
  def build_windowed_result(
        %{
          corpus: corpus,
          window_start: %DateTime{} = ws,
          window_end: %DateTime{} = we
        } = input
      ) do
    header =
      "## #{corpus_heading(corpus)} since #{format_datetime(ws)} (UTC)" <>
        " — window ends #{format_datetime(we)}"

    {body, meta} = windowed_body(corpus, ws, we, input)

    {:ok, with_header(header, meta.credential_withheld_count, body), meta}
  end

  @doc """
  The digest-eligible rows for one corpus in `[window_start, window_end)`,
  each carried with the corpus clock it is ordered by and the byte weight
  the Historian's byte signal charges for it.

  Returns `[%{id:, at:, bytes:, row:}]` in ascending corpus-clock order, or
  `[]` for an unrecognised corpus key. `corpus` accepts the atom the slicer
  emits or the string the cursor/audit rows carry.

  This is the single seam for "what does the digest consider to be in this
  window, and how big is each piece". `build_windowed_result/1` budgets and
  renders from it, and `Platform.Agents.HistorianAudit` measures eligibility
  with it rather than re-deriving either the predicate or the byte weights —
  a diagnostic that re-implements them drifts exactly the way the byte
  signal drifted from the renderer in the first place (task 019fa1cc).
  """
  @spec corpus_items(atom() | String.t(), DateTime.t(), DateTime.t(), keyword()) :: [map()]
  def corpus_items(corpus, window_start, window_end, opts \\ [])

  def corpus_items(corpus, %DateTime{} = ws, %DateTime{} = we, opts) when is_binary(corpus) do
    case Enum.find(@corpora, &(Atom.to_string(&1) == corpus)) do
      nil -> []
      atom -> corpus_items(atom, ws, we, opts)
    end
  end

  def corpus_items(:messages, %DateTime{} = ws, %DateTime{} = we, opts) do
    scope = Keyword.get(opts, :scope, :internal)

    ws
    |> Chat.list_messages_since(window_end: we, scope: scope)
    |> Enum.map(&%{id: &1.id, at: &1.inserted_at, bytes: byte_size(&1.content || ""), row: &1})
  end

  def corpus_items(:transcripts, %DateTime{} = ws, %DateTime{} = we, opts) do
    scope = Keyword.get(opts, :scope, :internal)

    ws
    |> Meetings.list_transcripts_since(window_end: we, scope: scope)
    |> Enum.map(&%{id: &1.id, at: &1.completed_at, bytes: transcript_bytes(&1), row: &1})
  end

  def corpus_items(:pages, %DateTime{} = ws, %DateTime{} = we, _opts) do
    # V1 org-scope only for the Historian sweep (workspace_id is nil in
    # the caller). The Wiki accessor filters by workspace as an option;
    # matching Historian's byte-sum which walks `is_nil(workspace_id)`.
    # Pages are org-wiki, not space-scoped — `scope` does not apply.
    #
    # Catalog cards are excluded INSIDE `list_pages_updated_since/2`, not
    # here: the exclusion is a property of the pages corpus, and a
    # post-filter at this call site would be a second predicate that can
    # drift from the one the byte signal composes (task 019fa1cc).
    ws
    |> Wiki.list_pages_updated_since(window_end: we, workspace_id: nil)
    |> Enum.map(&%{id: &1.id, at: &1.updated_at, bytes: byte_size(&1.content || ""), row: &1})
  end

  # Files corpus → the catalog cards, i.e. exactly the wiki pages
  # `:pages` above excludes. Weighted by the CARD's bytes, matching
  # `Historian.sum_corpus_bytes("files", …)` — the document text these
  # cards summarise never enters the Historian's context, which is the
  # point of the catalog. Same `updated_at` clock as `:pages`, because it
  # is the same table.
  def corpus_items(:files, %DateTime{} = ws, %DateTime{} = we, _opts) do
    ws
    |> Wiki.list_card_pages_updated_since(window_end: we, workspace_id: nil)
    |> Enum.map(&%{id: &1.id, at: &1.updated_at, bytes: byte_size(&1.content || ""), row: &1})
  end

  def corpus_items(:journal, %DateTime{} = ws, %DateTime{} = we, _opts) do
    # Journal is org-wiki, not space-scoped — `scope` does not apply.
    ws
    |> Wiki.list_journal_entries_since(window_end: we, workspace_id: nil)
    |> Enum.map(&%{id: &1.id, at: &1.inserted_at, bytes: byte_size(&1.content || ""), row: &1})
  end

  def corpus_items(_other, %DateTime{}, %DateTime{}, _opts), do: []

  # Mirrors `Historian.sum_corpus_bytes("transcripts", …)`: summary text plus
  # the JSON-serialised segments.
  defp transcript_bytes(transcript) do
    segment_bytes =
      case transcript.segments do
        nil -> 0
        segments -> segments |> Jason.encode!() |> byte_size()
      end

    byte_size(transcript.summary || "") + segment_bytes
  end

  # ── Windowed body assembly ───────────────────────────────────────────────

  defp windowed_body(corpus, ws, we, input) when corpus in @corpora do
    scope = Map.get(input, :scope, :internal)
    oversize? = Map.get(input, :oversize) == true
    cap_bytes = budget_bytes(input)

    items = corpus_items(corpus, ws, we, scope: scope)
    {included, withheld, skipped} = take_within_budget(items, cap_bytes, corpus)

    # AFTER the budget, BEFORE the render: the count then reflects what is
    # actually RENDERED rather than what was queried. Note `withheld` above
    # is the BUDGET-withheld set and is a different quantity entirely — the
    # collision is in the existing name, not in this one.
    {included, credential_withheld_count} =
      withhold_credentialed_items(included, withheld_content_key(corpus))

    item_count = length(items)
    included_count = length(included)

    meta = %{
      item_count: item_count,
      included_count: included_count,
      last_included_at: watermark(included),
      truncated?: included_count < item_count,
      oversize_empty?: oversize? and item_count == 0,
      skipped: skipped,
      credential_withheld_count: credential_withheld_count
    }

    {render_windowed(corpus, ws, we, included, withheld, meta, cap_bytes), meta}
  end

  defp windowed_body(_unknown_corpus, _ws, _we, _input) do
    {"_(unknown corpus)_",
     %{
       item_count: 0,
       included_count: 0,
       last_included_at: nil,
       truncated?: false,
       oversize_empty?: false,
       skipped: nil,
       credential_withheld_count: 0
     }}
  end

  defp render_windowed(corpus, ws, we, included, withheld, meta, cap_bytes) do
    cond do
      # "We could not digest this." The byte signal charged this window for
      # content the digest predicate rejects wholesale. Rendering the quiet
      # line here is the original defect.
      meta.oversize_empty? ->
        raw = HistorianAudit.raw_row_count(Atom.to_string(corpus), ws, we)

        "_Window exceeded the digest budget; no digestible activity in scope " <>
          "(#{raw} raw rows out of scope)._"

      # "There was nothing to digest."
      meta.item_count == 0 ->
        @empty_line

      included == [] ->
        skipped_line(meta.skipped, meta.item_count, cap_bytes)

      withheld == [] ->
        render_corpus(corpus, included, cap_bytes)

      true ->
        partial_line(meta.included_count, meta.item_count) <>
          "\n\n" <> render_corpus(corpus, included, cap_bytes)
    end
  end

  defp partial_line(included_count, item_count) do
    "_(partial — #{included_count} of #{item_count} items included; " <>
      "the remainder re-dispatches next pass.)_"
  end

  # Says why the item was skipped and that the skip is audited, and stops
  # there (task 01a0a12e, ticket clause 10). It must not point the handler at
  # another route to the skipped content: the window budget is what kept the
  # 2026-09-14 one-to-one out of the digest, and a notice that suggests
  # going around it defeats it.
  #
  # A page-corpus skip is the exception, and it is not the route-around
  # clause 10 forbids: pages and file cards are org wiki the Historian
  # curates, and naming the page is the only way it can act on one. With
  # preview-weighted admission (task 01a0ee1d) a page skips only when its
  # annotated preview line alone exceeds the budget.
  defp skipped_line(%{path: path, bytes: bytes}, item_count, cap_bytes)
       when is_binary(path) do
    "_(skipped — page `#{path}` weighs #{bytes} bytes and exceeds the " <>
      "#{cap_bytes}-byte window budget alone; 0 of #{item_count} items included. " <>
      "Its content is on that page. Recorded as an `item_skipped` audit row.)_"
  end

  defp skipped_line(%{bytes: bytes, count: count}, item_count, cap_bytes) do
    "_(skipped — the next #{count} item(s) weigh #{bytes} bytes and exceed the " <>
      "#{cap_bytes}-byte window budget alone; 0 of #{item_count} items included. " <>
      "Recorded as an `item_skipped` audit row.)_"
  end

  defp render_corpus(:messages, included, _cap_bytes) do
    rows = Enum.map(included, & &1.row)
    # `:infinity` rather than `@per_space_message_cap`: the windowed path is
    # budgeted item-wise above, and a second silent count cap would drop rows
    # the cursor has already been told were included. `build/2` keeps the 40
    # cap — it has no budget and no cursor.
    digest_messages(rows, fetch_space_names(rows, []), :infinity)
  end

  defp render_corpus(:transcripts, included, _cap_bytes) do
    rows = Enum.map(included, & &1.row)
    digest_transcripts(rows, fetch_space_names([], rows))
  end

  defp render_corpus(:pages, included, cap_bytes), do: digest_pages(included, cap_bytes)
  defp render_corpus(:journal, included, _cap_bytes), do: digest_journal(included)
  defp render_corpus(:files, included, cap_bytes), do: digest_file_cards(included, cap_bytes)

  # ── Credential withholding (task 01a09c9b) ───────────────────────────────

  # Replace the `content_key` field of every credential-shaped row with
  # `@withheld_marker`, returning the rewritten rows and how many were
  # rewritten. The row itself survives — author, space and timestamp are
  # untouched — so the marker takes the message's POSITION in the stream.
  #
  # The count is the figure a top-of-dispatch notice is assembled from. It
  # is returned rather than discarded even where no caller reads it yet.
  #
  # Assembly is the seam on purpose: it is the one point every push shape
  # passes through, and it needs no decision from any reader.
  @spec withhold_credentialed([map()], atom()) :: {[map()], non_neg_integer()}
  defp withhold_credentialed(rows, content_key) do
    Enum.map_reduce(rows, 0, fn row, count ->
      if CredentialShape.credential_shaped?(Map.get(row, content_key)) do
        {Map.put(row, content_key, @withheld_marker), count + 1}
      else
        {row, count}
      end
    end)
  end

  # `withhold_credentialed/2` lifted over the `%{id:, at:, bytes:, row:}`
  # wrappers `corpus_items/4` emits. `:bytes` is deliberately NOT recomputed:
  # it is the currency the oversize decision and the byte signal were made
  # in, and rewriting it here would make the renderer disagree with
  # `Historian.sum_corpus_bytes/3` — the exact drift task 019fa1cc closed.
  @spec withhold_credentialed_items([map()], atom()) :: {[map()], non_neg_integer()}
  defp withhold_credentialed_items(items, nil), do: {items, 0}

  defp withhold_credentialed_items(items, content_key) do
    Enum.map_reduce(items, 0, fn item, count ->
      {[row], n} = withhold_credentialed([item.row], content_key)
      {%{item | row: row}, count + n}
    end)
  end

  # Which field of a row actually REACHES the rendered body, per corpus.
  # `:transcripts` is `:summary`, not `:segments` — `digest_transcripts/2`
  # renders only the summary, though `transcript_bytes/1` weighs both.
  # `:files` returns `nil`: file cards carry cards, not bodies.
  defp withheld_content_key(:messages), do: :content
  defp withheld_content_key(:transcripts), do: :summary
  defp withheld_content_key(:pages), do: :content
  defp withheld_content_key(:journal), do: :content
  defp withheld_content_key(_other), do: nil

  defp watermark([]), do: nil
  defp watermark(included), do: included |> List.last() |> Map.fetch!(:at)

  defp budget_bytes(input) do
    tokens =
      Map.get(input, :budget_tokens) ||
        Platform.Agents.HistorianDispatcher.window_budget_tokens()

    tokens * 4
  end

  # Admit whole timestamp groups, in corpus-clock order, while the running
  # byte total stays within `cap_bytes`. Grouping matters: if two rows shared
  # `at` and only the first were admitted, advancing the cursor past that
  # instant would skip the second silently — the exact class of bug this
  # stage exists to remove. Groups are size 1 for every real corpus row
  # (microsecond timestamps), so this costs nothing in practice.
  defp take_within_budget([], _cap_bytes, _corpus), do: {[], [], nil}

  defp take_within_budget(items, cap_bytes, corpus) do
    {included_groups, withheld_groups} =
      items
      |> Enum.chunk_by(& &1.at)
      |> admit_groups(cap_bytes, corpus, 0, [])

    included = Enum.concat(included_groups)
    withheld = Enum.concat(withheld_groups)

    skipped =
      case {included, withheld_groups} do
        {[], [first_group | _]} ->
          first = hd(first_group)

          # RAW bytes, not the admission weight: the notice and the
          # `item_skipped` audit row state the row's true size.
          %{
            id: first.id,
            at: first.at,
            bytes: group_bytes(first_group),
            count: length(first_group),
            path: skipped_path(corpus, first)
          }

        _ ->
          nil
      end

    {included, withheld, skipped}
  end

  defp admit_groups([], _cap_bytes, _corpus, _used, acc), do: {Enum.reverse(acc), []}

  defp admit_groups([group | rest], cap_bytes, corpus, used, acc) do
    weight = Enum.reduce(group, 0, &(admission_bytes(corpus, &1, cap_bytes) + &2))

    if used + weight <= cap_bytes do
      admit_groups(rest, cap_bytes, corpus, used + weight, [group | acc])
    else
      {Enum.reverse(acc), [group | rest]}
    end
  end

  defp group_bytes(group), do: Enum.reduce(group, 0, &(&1.bytes + &2))

  # What admission charges one item (task 01a0ee1d, the page-size policy).
  #
  # The page-previewed corpora render one line per row carrying a
  # #{@message_content_preview}-char preview, so they are weighed by THAT
  # line, computed with the same function that renders it: the weight cannot
  # drift from the body. A 330 KB page then costs a few hundred bytes and is
  # admitted as a preview instead of being skipped.
  #
  # `:messages` and `:transcripts` keep their raw `:bytes` on purpose. Task
  # 01a0a12e ticket clause 10 records that the window budget is what kept
  # the 2026-09-14 one-to-one out of the digest; charging chat or meetings
  # their rendered preview would reopen that.
  #
  # The line is weighed exactly as it will render: with the over-budget
  # annotation (hence `cap_bytes`) and AFTER credential withholding, which
  # runs on the admitted rows between admission and render. Weighing the
  # un-withheld line would let the body differ from what was charged.
  #
  # `item.bytes` itself is never rewritten: `HistorianAudit` sums it and it
  # must mirror `Historian.sum_corpus_bytes/3` in SQL.
  defp admission_bytes(corpus, item, cap_bytes) when corpus in [:pages, :files, :journal] do
    {[rendered], _count} = withhold_credentialed_items([item], withheld_content_key(corpus))
    byte_size(rendered_line(corpus, rendered, cap_bytes))
  end

  defp admission_bytes(_messages_or_transcripts, item, _cap_bytes), do: item.bytes

  defp rendered_line(:pages, item, cap_bytes), do: page_line(item, cap_bytes)
  defp rendered_line(:files, item, cap_bytes), do: card_line(item, cap_bytes)
  defp rendered_line(:journal, item, _cap_bytes), do: journal_line(item)

  # The page a skip names: the row's `file_key` for the wiki corpora, `nil`
  # for chat and meetings, whose skip notice must name nothing.
  defp skipped_path(corpus, item) when corpus in [:pages, :files], do: item.row.file_key
  defp skipped_path(_corpus, _item), do: nil

  defp corpus_heading(:messages), do: "Chat"
  defp corpus_heading(:transcripts), do: "Meetings"
  defp corpus_heading(:pages), do: "Wiki pages"
  defp corpus_heading(:journal), do: "Journal"
  defp corpus_heading(:files), do: "File cards"
  defp corpus_heading(other), do: "#{other}"

  # ── Messages ─────────────────────────────────────────────────────────────

  defp digest_messages(messages, space_names, per_space_cap \\ @per_space_message_cap)

  defp digest_messages([], _space_names, _per_space_cap), do: nil

  defp digest_messages(messages, space_names, per_space_cap) do
    grouped =
      messages
      |> Enum.group_by(& &1.space_id)
      |> Enum.sort_by(fn {space_id, _} -> Map.get(space_names, space_id, "") end)

    body =
      grouped
      |> Enum.map(fn {space_id, msgs} ->
        space_label = Map.get(space_names, space_id, "(unknown space)")
        format_space_messages(space_label, msgs, per_space_cap)
      end)
      |> Enum.join("\n\n")

    "### Chat\n\n" <> body
  end

  defp format_space_messages(space_label, msgs, per_space_cap) do
    total = length(msgs)

    {shown, overflow} =
      case per_space_cap do
        :infinity -> {msgs, []}
        cap when is_integer(cap) -> Enum.split(msgs, cap)
      end

    lines =
      shown
      |> Enum.map(&message_line/1)
      |> Enum.join("\n")

    overflow_note =
      if overflow == [] do
        ""
      else
        "\n- _(#{total - length(shown)} more messages — truncated)_"
      end

    "#### ##{space_label}\n" <> lines <> overflow_note
  end

  defp message_line(m) do
    time = format_time(m.inserted_at)
    author = m.author_display_name || "(unknown)"
    content = preview(m.content)
    "- #{time} @#{author}: #{content}"
  end

  # ── Transcripts ──────────────────────────────────────────────────────────

  defp digest_transcripts([], _space_names), do: nil

  defp digest_transcripts(transcripts, space_names) do
    body =
      transcripts
      |> Enum.map(fn t ->
        time = format_time(t.completed_at)
        space_label = Map.get(space_names, t.space_id, "(meeting)")
        duration = format_duration(t.started_at, t.completed_at)
        summary = blank_fallback(t.summary, "_no summary available_")
        "- #{time} [meeting] \"#{space_label}\"#{duration}. Summary: #{summary}"
      end)
      |> Enum.join("\n")

    "### Meetings\n\n" <> body
  end

  # ── Task events ──────────────────────────────────────────────────────────

  defp digest_task_events([]), do: nil

  defp digest_task_events(tasks) do
    total = length(tasks)
    {shown, overflow} = Enum.split(tasks, @task_event_cap)

    lines =
      shown
      |> Enum.map(fn t ->
        time = format_time(t.updated_at)
        title = blank_fallback(t.title, "(untitled)")
        "- #{time} [task] \"#{title}\" → #{t.status}"
      end)
      |> Enum.join("\n")

    overflow_note =
      if overflow == [] do
        ""
      else
        "\n- _(#{total - @task_event_cap} more tasks — truncated)_"
      end

    "### Tasks\n\n" <> lines <> overflow_note
  end

  # ── Wiki pages (windowed only) ───────────────────────────────────────────

  defp digest_pages([], _cap_bytes), do: nil

  defp digest_pages(items, cap_bytes) do
    "### Wiki\n\n" <> (items |> Enum.map(&page_line(&1, cap_bytes)) |> Enum.join("\n"))
  end

  # One rendered row. Also the admission weight for `:pages`
  # (`admission_bytes/3`), so the two cannot drift. Takes the corpus item,
  # not the bare row: the annotation needs the RAW `:bytes`, which survive
  # credential withholding where the row's content does not.
  defp page_line(%{row: p, bytes: raw_bytes}, cap_bytes) do
    "- #{format_datetime(p.updated_at)} [page] `#{p.file_key}` (v#{p.version}): " <>
      page_preview(p.content) <> preview_only_note(p.file_key, raw_bytes, cap_bytes)
  end

  # Appended to a page or card line whose raw content exceeds the whole
  # window budget: the line carries only a preview, so it says so and says
  # where the content is (task 01a0ee1d). Naming an org-wiki path is not the
  # route-around 01a0a12e clause 10 forbids; that clause concerns chat and
  # transcripts, which never render this note.
  defp preview_only_note(file_key, raw_bytes, cap_bytes) when raw_bytes > cap_bytes do
    " _(preview only — page `#{file_key}` is #{raw_bytes} bytes, over the " <>
      "#{cap_bytes}-byte window budget; its content is on that page)_"
  end

  defp preview_only_note(_file_key, _raw_bytes, _cap_bytes), do: ""

  # ── File cards (windowed only) ───────────────────────────────────────────
  #
  # Cards are wiki pages, so this renders the same shape as
  # `digest_pages/2` under a heading that says which corpus it came from.
  # `[card]` rather than `[page]` matters to the reader: a card is a
  # summary of a document the Historian will never be shown, so "go read
  # the source" is a different action than it is for a wiki page.

  defp digest_file_cards([], _cap_bytes), do: nil

  defp digest_file_cards(items, cap_bytes) do
    "### File cards\n\n" <>
      (items |> Enum.map(&card_line(&1, cap_bytes)) |> Enum.join("\n"))
  end

  # One rendered row, and the `:files` admission weight.
  defp card_line(%{row: c, bytes: raw_bytes}, cap_bytes) do
    "- #{format_datetime(c.updated_at)} [card] `#{c.file_key}` (v#{c.version}): " <>
      page_preview(c.content) <> preview_only_note(c.file_key, raw_bytes, cap_bytes)
  end

  defp page_preview(nil), do: ""

  defp page_preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@message_content_preview)
  end

  # ── Journal (windowed only) ──────────────────────────────────────────────

  defp digest_journal([]), do: nil

  defp digest_journal(items) do
    "### Journal\n\n" <> (items |> Enum.map(&journal_line/1) |> Enum.join("\n"))
  end

  # One rendered row, and the `:journal` admission weight. A journal entry
  # has no page path, so it carries no preview-only note.
  defp journal_line(%{row: e}) do
    "- #{format_datetime(e.inserted_at)} [journal] #{Date.to_iso8601(e.date)}: " <>
      page_preview(e.content)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp fetch_space_names(messages, transcripts) do
    ids =
      (Enum.map(messages, & &1.space_id) ++ Enum.map(transcripts, & &1.space_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        from(s in Space, where: s.id in ^ids, select: {s.id, s.name})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp preview(nil), do: ""

  defp preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@message_content_preview)
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp format_time(%DateTime{} = dt) do
    dt
    |> Calendar.strftime("%H:%M")
  end

  defp format_time(_), do: "--:--"

  defp format_duration(%DateTime{} = started, %DateTime{} = completed) do
    minutes = DateTime.diff(completed, started, :second) |> div(60)

    cond do
      minutes < 1 -> ""
      minutes < 60 -> " — #{minutes} min"
      true -> " — #{div(minutes, 60)}h #{rem(minutes, 60)}m"
    end
  end

  defp format_duration(_, _), do: ""

  defp blank_fallback(nil, fallback), do: fallback
  defp blank_fallback("", fallback), do: fallback
  defp blank_fallback(value, _fallback), do: value
end
