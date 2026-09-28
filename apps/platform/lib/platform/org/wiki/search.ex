defmodule Platform.Org.Wiki.Search do
  @moduledoc """
  Cross-corpus search for the `memory_search` tool (ADR-0041, T5; task
  corpus added stage 3 of task 019f3dbb).

  Fuses four lexical channels (`org_wiki_pages`, `org_wiki_journal_entries`,
  `chat_messages`, `tasks`) with a single semantic channel
  (`Platform.Memory.search/3` fed by the T3 indexer + the Tasks stage 2
  write-path hook) using Reciprocal Rank Fusion at k=60.

  ## Algorithm (see `docs/stack/0041-org-memory-impl/t5-design-lock.md` §6)

      score(d) = Σ over channels c where d appears of  1 / (k + rank_c(d))
      k = 60

  Each unique `(corpus, id)` accumulates a score across:
  - the global semantic channel (corpus-tagged via `memory_type`),
  - the per-corpus lexical channel (`page`, `journal`, `message`, `task`).

  ## Semantic hit classification

  Every core ingest path stamps `memory_type` on the indexed payload and
  memory-service stores it `NOT NULL`. The tag arrives on a hit when the
  service includes it in its `/search` response (the StartupSuite
  provider passes a non-empty `memory_type` through and omits the key
  otherwise); older service builds return only `entry_id` + `score`, so
  those hits reach this module UNTAGGED. A tag, when present, is
  authoritative and never triggers a lookup: `"page"` -> `:page`,
  `"task"` -> `:task`, and both `"journal"` (stamped by the Indexer) and
  `"daily"` (the `normalize/1` default on the direct
  `Context.append_memory_entry/2` path) -> `:journal`. An absent tag is
  resolved by a bulk id lookup across `org_wiki_pages`,
  `org_wiki_journal_entries` and `tasks` (one query per table, same
  tenancy filters as hydration). Ids that match no table are dropped
  before fusion. The lookup can be retired once the provider returns
  the tag for every hit (`classify_untagged_ids/2` then never runs).

  Tie-break: `score desc → lexical_rank asc → date_or_inserted_at desc`.

  ## Task hits (stage 3, 019f3dbb)

  Task-corpus hits carry the standard hit shape plus four advisory fields
  the agent uses to distinguish "in-flight / shipped-clean / was-supposed-
  to-work" without a follow-up query:

    * `status` — task lifecycle status
    * `priority` — for advisory ranking / display
    * `updated_at` — recency signal beyond `date_or_inserted_at`
    * `merged_pr_url` — populated via `Platform.Tasks.merged_pr_url/1`
      (walks the plan → stages → validations → `pr_merged` evidence, or
      falls back to the stack rollup URL for stack members)
    * `follow_up_task_ids` — populated via `Platform.Tasks.follow_up_task_ids/1`
      (open, temporally-after tasks whose descriptions reference this
      task's UUID — the "was supposed to work but didn't" signal)
    * `cancellation_note` — surfaces `metadata["cancellation_note"]` for
      cancelled tasks (the rework directive), `nil` otherwise

  ## ACL

  Message hits are post-filtered against
  `Platform.Chat.list_spaces_for_agent/2` — anonymous callers get zero
  message hits. Pages/journal entries flow through `Routing.gate_read/2`
  (private rows are dropped if the caller isn't the owner).

  Orphan ids (deleted between embed and query) and `deleted_at`-set
  rows are dropped — untagged ones at classification, tagged ones at
  hydration, where each drop is counted in `dropped` (see below).

  ## Robustness

  Each channel runs in its own `Task.async_stream/3` with a 2s timeout.
  A channel that does not answer the query is DEAD — it timed out, it
  crashed, or its provider returned an error (`{:error, reason}`, e.g. a
  refused connection or a 5xx from memory-service). A dead channel is
  logged by name,
  contributes zero hits, and the fusion proceeds with the surviving
  channels — a memory-service outage degrades to lexical-only rather
  than failing the call. A dead channel is never silent in the
  response: its label is listed under `dead_channels` and `truncated`
  is forced to `true`, so a caller can tell "the semantic half died"
  from "the semantic half found nothing".

  `truncated` therefore means "incomplete for ANY reason": a live
  channel hit its `2*limit` cap, or a channel died.

  The semantic channel being CONFIGURED OFF (`Platform.Memory.enabled?/0`
  false — the Noop provider) is NOT an outage: it contributes zero hits
  and is not dead. Only a timeout, a crash, or an error return is dead.

  ## Match count

  `match_count` is `length(hydrated)` — the number of hits that survived
  fusion AND hydration, counted BEFORE `results` is truncated to
  `opts.limit`. It exists so a caller can tell "there were more matches
  than fit in this page" apart from "this is everything there was".

  `match_count` is a LOWER BOUND, not an exact count, whenever
  `truncated: true`: a channel hitting its `2*limit` cap, or a channel
  dying outright, means `hits`/`fused`/`hydrated` were already missing
  matches before `match_count` was ever computed from them — the same
  caveat `truncated` itself carries (see above), inherited here rather
  than re-derived.

  It is ALSO a lower bound in one case where `truncated` stays `false`:
  `fuse/2` caps fusion candidates at `max(limit * 4, limit)` before
  hydration ever runs. Five channels (one semantic + up to four lexical)
  can each return just UNDER their own `2*limit` cap — so none trips
  `capped?` and `truncated` stays `false` — while still summing to more
  than `4*limit` distinct `(corpus, id)` pairs once channel hits are
  merged. `fuse/2`'s `Enum.take(max(limit * 4, limit))` silently drops
  the excess before `hydrate/2` and `match_count` ever see it. There is
  no signal for this case today; `match_count` can undercount even when
  every other field says the response is complete.

  ## Hydration drops

  Every fused hit that hydration cannot turn into a result — the row is
  gone (orphan / tombstone) or the caller is refused by ACL — is counted
  per corpus in `dropped: %{page, journal, message, task}`. All four
  keys are always present (zero when nothing was dropped). Orphans and
  ACL refusals are counted together on purpose: distinguishing them
  would leak the existence of rows the caller may not read.
  """

  require Logger

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Memory
  alias Platform.Org.Wiki.{Journal, Routing}
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy

  @fusion_constant_k 60
  @default_limit 20
  @max_limit 100
  @channel_timeout_ms 2_000
  @zero_dropped %{page: 0, journal: 0, message: 0, task: 0}
  @lexical_fallback_meta_key :lexical_fallback

  # Queries at or under this many distinct tokens keep the implicit conjunction
  # `websearch_to_tsquery` applies — they are precise today and the AND is doing
  # useful work. See `prepare_lexical_query/1`.
  @lexical_short_query_tokens 6

  # Upper bound on the number of alternation terms. An OR over a full ticket
  # body would be a GIN scan over nearly the whole table.
  @lexical_query_token_cap 32

  @type corpus :: :page | :journal | :message | :task | :excluded | :unknown

  # Only `semantic_corpus/1` produces `:untagged`, and only
  # `classify_untagged_ids/2` consumes it; it never reaches fusion.
  @type raw_corpus :: corpus() | :untagged

  @type hit :: %{
          source: String.t(),
          id: String.t(),
          path: String.t() | nil,
          space_id: String.t() | nil,
          content: String.t(),
          score: float(),
          semantic_rank: pos_integer() | nil,
          lexical_rank: pos_integer() | nil,
          authored_by: String.t() | nil,
          date_or_inserted_at: String.t()
        }

  # Label of one fused channel: the single semantic channel, or one
  # lexical channel per enabled corpus.
  @type channel_label :: {:semantic, :all} | {:lexical, :page | :journal | :message | :task}

  # Per-corpus count of fused hits that hydration refused (orphan,
  # tombstone, or ACL) — always all four keys.
  @type dropped :: %{
          page: non_neg_integer(),
          journal: non_neg_integer(),
          message: non_neg_integer(),
          task: non_neg_integer()
        }

  @type response :: %{
          results: [hit()],
          fusion_constant_k: 60,
          truncated: boolean(),
          dead_channels: [channel_label()],
          dropped: dropped(),
          # Pre-limit hydrated count — a LOWER BOUND (not exact) when
          # `truncated: true`, and in one case even when it's `false`.
          # See moduledoc `## Match count`.
          match_count: non_neg_integer()
        }

  @type search_opts :: [
          source: String.t() | nil,
          namespace: String.t() | nil,
          since: Date.t() | String.t() | nil,
          limit: pos_integer(),
          agent: Agent.t() | nil,
          workspace_id: String.t() | nil,
          org_id: String.t() | nil,
          project_id: String.t() | nil,
          memory_type: String.t() | nil
        ]

  # Internal channel-hit shape. Stays inside this module — the public
  # contract is `t:hit/0` after hydration + fusion. The `:metadata`
  # field carries telemetry-only flags like `lexical_fallback: true`
  # that intentionally never reach the caller envelope.
  @type channel_hit :: %{
          corpus: corpus(),
          id: String.t(),
          score: float() | nil,
          rank: pos_integer(),
          channel: :semantic | :lexical,
          metadata: map()
        }

  ## ─────────────────────────────────────────────────────────────────────
  ## Public API
  ## ─────────────────────────────────────────────────────────────────────

  @doc """
  Hybrid (semantic + lexical) search across pages, journal entries,
  chat messages and tasks. Returns
  `{:ok, %{results, fusion_constant_k, truncated, dead_channels, dropped, match_count}}`
  (see `t:response/0`): `dead_channels` names every channel that did not
  answer — it timed out, crashed, or its provider returned an error —
  and forces `truncated: true`; `dropped` counts the
  fused hits hydration refused per corpus; `match_count` is the
  pre-limit hydrated match count (see moduledoc `## Match count` for why
  it is a lower bound, not exact, in more than one case).

  ## Options

    * `:source` — restrict to `"page"`, `"journal"`, `"message"`, or
      `"task"`. Omit for all four.
    * `:namespace` — prefix filter for page/journal `file_key`
      (e.g. `"org"`, `"project/<uuid>"`).
    * `:since` — `Date.t()` or ISO-8601 string. Lower bound for
      `inserted_at` (pages, messages) or `date` (journal).
    * `:limit` — max results (default `#{20}`, max `#{100}`).
    * `:agent` — caller agent; used for message ACL filtering. Omit /
      `nil` → no message hits.
    * `:workspace_id` — legacy workspace scope (back-compat).
    * `:org_id` — ADR-0042 tenant filter (scopes page/journal lookups
      to a single org). Ignored for the `:message` corpus.
    * `:project_id` — ADR-0042 project filter (scopes page/journal
      lookups to a single project). Ignored for the `:message` corpus.
    * `:memory_type` — restrict the semantic channel to a single tag
      (e.g. `"document"`, `"page"`, `"journal"`, `"daily"`). Ignored
      by the lexical channels (they already partition by corpus).
  """
  @spec search(String.t(), search_opts()) :: {:ok, response()}
  def search(query, opts \\ []) when is_binary(query) and is_list(opts) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:ok,
       %{
         results: [],
         fusion_constant_k: @fusion_constant_k,
         truncated: false,
         dead_channels: [],
         dropped: @zero_dropped,
         match_count: 0
       }}
    else
      do_search(trimmed, normalize_opts(opts))
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Search orchestration
  ## ─────────────────────────────────────────────────────────────────────

  defp do_search(query, opts) do
    corpora = enabled_corpora(opts.source)
    channel_cap = 2 * opts.limit

    # All channels run concurrently with a 2s budget each. A slow
    # channel never blocks the fusion (`:on_timeout :kill_task`), and a
    # crashing one never takes the caller down (the `catch` inside the
    # task — a linked task's abnormal exit would otherwise propagate
    # to this process). Either way the channel is reported DEAD under
    # its own label, not silently folded into "no hits".
    #
    # The stream yields a bare `{:exit, :timeout}` with no channel
    # label, so the labels are carried alongside: `ordered: true` keeps
    # results in input order and `Enum.zip/2` re-attaches the label.
    labels = [{:semantic, :all} | Enum.map(corpora, &{:lexical, &1})]

    channel_results =
      labels
      |> Task.async_stream(
        fn label -> run_channel_guarded(label, query, opts, channel_cap, corpora) end,
        max_concurrency: max(length(corpora) + 1, 2),
        timeout: @channel_timeout_ms + 500,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(labels)
      |> Enum.map(fn
        {{:ok, {:ok, hits}}, label} -> {label, hits}
        {{:ok, {:errored, reason}}, label} -> handle_channel_error(label, reason)
        {{:ok, {:crashed, reason}}, label} -> handle_channel_exit(label, reason)
        {{:exit, reason}, label} -> handle_channel_exit(label, reason)
      end)

    dead_channels = for {label, :dead} <- channel_results, do: label
    live_results = for {label, hits} when is_list(hits) <- channel_results, do: {label, hits}

    hits = Enum.flat_map(live_results, fn {_channel, hits} -> hits end)

    # `truncated` means "incomplete for any reason": a live channel at
    # its cap, or a channel that died (its share of the corpus is
    # unknown, so the result set is known-incomplete). A dead channel
    # contributes no hits and so could never trip the cap test — it
    # must be OR-ed in explicitly.
    capped? = Enum.any?(live_results, fn {_channel, hits} -> length(hits) >= channel_cap end)
    truncated? = capped? or dead_channels != []

    fused = fuse(hits, opts.limit)

    {hydrated, dropped} = hydrate(fused, opts)
    match_count = length(hydrated)

    {:ok,
     %{
       results: Enum.take(hydrated, opts.limit),
       fusion_constant_k: @fusion_constant_k,
       truncated: truncated?,
       dead_channels: dead_channels,
       dropped: dropped,
       match_count: match_count
     }}
  end

  # Runs one channel inside its task and converts a crash (raise /
  # throw / exit) into a value, so the stream never sees an abnormal
  # exit. Timeouts cannot be caught here — the task is killed from the
  # outside — and surface as `{:exit, :timeout}` from the stream.
  defp run_channel_guarded(label, query, opts, channel_cap, corpora) do
    channel =
      case label do
        {:semantic, :all} -> :semantic
        {:lexical, corpus} -> {:lexical, corpus}
      end

    case run_channel(channel, query, opts, channel_cap, corpora) do
      {^label, {:errored, reason}} -> {:errored, reason}
      {^label, hits} when is_list(hits) -> {:ok, hits}
    end
  catch
    kind, reason -> {:crashed, {kind, reason}}
  end

  # A channel whose provider ANSWERED with an error did not answer the
  # query: it is dead for the same reason a crashed or timed-out channel
  # is, and appears in `dead_channels` in exactly the same shape.
  @spec handle_channel_error(channel_label(), term()) :: {channel_label(), :dead}
  defp handle_channel_error(label, reason) do
    Logger.warning(
      "Platform.Org.Wiki.Search: channel #{inspect(label)} returned an error: #{inspect(reason)}"
    )

    {label, :dead}
  end

  @spec handle_channel_exit(channel_label(), term()) :: {channel_label(), :dead}
  defp handle_channel_exit(label, :timeout) do
    Logger.warning("Platform.Org.Wiki.Search: channel #{inspect(label)} timed out")
    {label, :dead}
  end

  defp handle_channel_exit(label, reason) do
    Logger.warning(
      "Platform.Org.Wiki.Search: channel #{inspect(label)} crashed: #{inspect(reason)}"
    )

    {label, :dead}
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Channels — each returns {channel_label, [channel_hit]}
  ## ─────────────────────────────────────────────────────────────────────

  # Semantic — single call covering every enabled corpus. Every ingest
  # path stamps `memory_type` on the indexed payload, but memory-service's
  # `/search` response drops it (only `entry_id` + `score` come back), so
  # in practice every hit arrives untagged. Hits are partitioned:
  #
  #   * tagged — the tag is authoritative and classified by a named clause
  #     of `semantic_corpus/1`. No DB lookup runs for a tagged hit.
  #       - "document" — refused. File text is ingested for the Files
  #         surface, not for wiki memory search.
  #       - anything unrecognised — refused rather than reinterpreted. A
  #         refusal is a no-result we can see; a silent remap to `:page`
  #         is a wrong result we cannot.
  #   * untagged (nil / "") — the tag was dropped at the read boundary,
  #     not missing at ingest. The corpus is recovered by
  #     `classify_untagged_ids/2` (bulk id lookup under the hydration
  #     tenancy filters). Ids matching no table are dropped.
  #
  # Hits whose corpus doesn't match an enabled corpus are dropped before
  # fusion.
  defp run_channel(:semantic, query, opts, cap, corpora) do
    if Memory.enabled?() do
      semantic_opts =
        [
          workspace_id: opts.workspace_id,
          project_id: opts.project_id,
          org_id: opts.org_id,
          memory_type: opts.memory_type,
          limit: cap
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      case Memory.search(query, semantic_opts) do
        {:ok, results} ->
          # Partition on the tag once; only the untagged side reaches the
          # DB. A fully tagged result set costs zero extra queries.
          classified =
            Enum.map(results, fn hit -> {hit, hit |> raw_memory_type() |> semantic_corpus()} end)

          resolved =
            classified
            |> Enum.filter(fn {_hit, corpus} -> corpus == :untagged end)
            |> Enum.map(fn {hit, _} -> semantic_hit_id(hit) end)
            |> classify_untagged_ids(opts)

          hits =
            classified
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {{hit, corpus}, rank} ->
              corpus =
                case corpus do
                  :untagged -> Map.get(resolved, semantic_hit_id(hit), :unknown)
                  other -> other
                end

              semantic_hit_to_channel(hit, rank, corpus, corpora)
            end)

          warn_unknown_tags(results)

          {{:semantic, :all}, hits}

        {:error, reason} ->
          Logger.warning("Platform.Org.Wiki.Search: semantic channel error: #{inspect(reason)}")
          # The error is carried out of this branch rather than collapsing
          # to `[]`: an empty hit list is what the CONFIGURED-OFF (Noop)
          # branch below returns, and configured-off is not an outage.
          {{:semantic, :all}, {:errored, reason}}
      end
    else
      {{:semantic, :all}, []}
    end
  end

  defp run_channel({:lexical, :page}, query, opts, cap, _corpora) do
    hits = lexical_pages(query, opts, cap)
    {{:lexical, :page}, hits}
  end

  defp run_channel({:lexical, :journal}, query, opts, cap, _corpora) do
    hits = lexical_journal(query, opts, cap)
    {{:lexical, :journal}, hits}
  end

  defp run_channel({:lexical, :message}, query, opts, cap, _corpora) do
    hits = lexical_messages(query, opts, cap)
    {{:lexical, :message}, hits}
  end

  defp run_channel({:lexical, :task}, query, opts, cap, _corpora) do
    hits = lexical_tasks(query, opts, cap)
    {{:lexical, :task}, hits}
  end

  # One warning per search call, listing the distinct unrecognised tags.
  # A provider returning many unknown-tagged hits would otherwise emit a
  # line per hit. Logs the TAG VALUE ONLY — never an entry id, content,
  # org id or project id. `:excluded` and the untagged nil/"" cases are
  # expected (refusal / lookup), not surprises, so they are not logged.
  defp warn_unknown_tags(results) do
    unknown_tags =
      results
      |> Enum.map(&raw_memory_type/1)
      |> Enum.filter(&(semantic_corpus(&1) == :unknown))
      |> Enum.uniq()

    if unknown_tags != [] do
      Logger.warning(fn ->
        "Platform.Org.Wiki.Search: unrecognised memory_type tag(s) " <>
          "#{inspect(unknown_tags)} — hits were refused. Add a clause to " <>
          "semantic_corpus/1 to classify them."
      end)
    end

    :ok
  end

  defp raw_memory_type(hit) do
    Map.get(hit, :memory_type) || Map.get(hit, "memory_type") ||
      get_in(Map.get(hit, :metadata, %{}), ["memory_type"]) ||
      get_in(Map.get(hit, "metadata", %{}), ["memory_type"])
  end

  defp semantic_hit_id(hit) do
    case Map.get(hit, :entry_id) || Map.get(hit, "entry_id") do
      nil -> nil
      id -> to_string(id)
    end
  end

  # Resolve untagged ids to a corpus by asking each table which of them
  # it holds. Three bulk queries, never one per hit. Tenancy filters are
  # the ones the hydration bulk loaders apply, so classification cannot
  # admit a row hydration would then refuse. Non-UUID ids are dropped
  # before the query (`Platform.UUID.valid?/1`, which also enforces the
  # canonical length) so a garbage `entry_id` cannot raise a CastError.
  # Ids in no table are absent from the map and are dropped by the
  # caller (the orphan drop, now before fusion instead of at hydration).
  #
  # Precedence: a page id also present as a task id (impossible for
  # UUIDv7 rows, but cheap to pin) resolves in `:page` order, matching
  # the merge order below.
  @spec classify_untagged_ids([String.t() | nil], map()) ::
          %{String.t() => :page | :journal | :task}
  defp classify_untagged_ids(ids, opts) do
    ids =
      ids
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&Platform.UUID.valid?/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      page_ids =
        WikiPage
        |> filter_workspace(opts.workspace_id)
        |> scope_org(opts.org_id)
        |> filter_project(opts.project_id)
        |> where([r], r.id in ^ids)
        |> select([r], r.id)
        |> Repo.all()

      journal_ids =
        WikiJournalEntry
        |> filter_workspace(opts.workspace_id)
        |> scope_org(opts.org_id)
        |> filter_project(opts.project_id)
        |> where([r], r.id in ^ids)
        |> select([r], r.id)
        |> Repo.all()

      task_ids =
        TaskRecord
        |> filter_task_deleted()
        |> filter_task_project(opts.project_id)
        |> scope_task_org(opts.org_id)
        |> where([r], r.id in ^ids)
        |> select([r], r.id)
        |> Repo.all()

      %{}
      |> put_corpus(task_ids, :task)
      |> put_corpus(journal_ids, :journal)
      |> put_corpus(page_ids, :page)
    end
  end

  defp put_corpus(acc, ids, corpus) do
    Enum.reduce(ids, acc, fn id, acc -> Map.put(acc, id, corpus) end)
  end

  # `corpus` is already resolved: tag-derived for tagged hits,
  # lookup-derived for untagged ones (`:unknown` when the lookup found
  # nothing, so the id falls into the explicit refusal below).
  defp semantic_hit_to_channel(hit, rank, corpus, corpora) do
    id = semantic_hit_id(hit)
    score = Map.get(hit, :score) || Map.get(hit, "score")

    cond do
      is_nil(id) ->
        []

      # Explicit refusal. Both atoms would also fail the corpora-membership
      # check below, but an exclusion that holds only as a side effect of a
      # membership miss is not a decision — it evaporates the moment someone
      # widens the corpora list. This branch is what makes it survive.
      corpus in [:excluded, :unknown] ->
        []

      corpus not in corpora ->
        []

      true ->
        [
          %{
            corpus: corpus,
            id: to_string(id),
            score: score,
            rank: rank,
            channel: :semantic,
            metadata: %{}
          }
        ]
    end
  end

  defp semantic_corpus("journal"), do: :journal
  defp semantic_corpus(:journal), do: :journal
  # `Platform.Memory.normalize/1` defaults untyped entries to "daily", and the
  # only structs ingested untyped are journal entries.
  defp semantic_corpus("daily"), do: :journal
  defp semantic_corpus(:daily), do: :journal
  defp semantic_corpus("page"), do: :page
  defp semantic_corpus(:page), do: :page
  defp semantic_corpus("task"), do: :task
  defp semantic_corpus(:task), do: :task
  # File text is ingested for the Files surface, not for wiki memory search.
  # Refuse it at classification rather than letting it into fusion and losing
  # it later by accident at the wiki-page hydration lookup.
  defp semantic_corpus("document"), do: :excluded
  defp semantic_corpus(:document), do: :excluded
  # No tag on the hit. This is NOT a legacy-row signal: every ingest path
  # stamps the tag and memory-service stores it NOT NULL; it is dropped
  # at the `/search` read boundary. The corpus is recovered by id lookup
  # in `classify_untagged_ids/2`; nothing else may consume `:untagged`.
  defp semantic_corpus(nil), do: :untagged
  defp semantic_corpus(""), do: :untagged
  # Any other tag is a value this module has never been taught. Refuse it
  # rather than silently reinterpreting it as a page.
  defp semantic_corpus(_other), do: :unknown

  ## ─────────────────────────────────────────────────────────────────────
  ## Lexical channels — tsvector first, ilike fallback when empty
  ## ─────────────────────────────────────────────────────────────────────

  # Rewrite a long natural-language query so `websearch_to_tsquery/2` parses it
  # as an ALTERNATION instead of a conjunction.
  #
  # `websearch_to_tsquery('english', "a b c")` yields `'a' & 'b' & 'c'` — every
  # stem must be present. For a ticket-length query that is unsatisfiable
  # against any real row, so the lexical channel returns `[]` and the caller
  # cannot tell a false negative from a true absence. Measured on the seeded
  # corpus for this ticket the conjunction empties at 8 stems.
  #
  # A bare lowercase `or` is parsed by `websearch_to_tsquery` as the `|`
  # operator, so joining tokens with `" or "` yields `'a' | 'b' | ...` with no
  # new SQL function, no migration, and no change to the generated
  # `search_vector` columns or their GIN indexes. Verified on PostgreSQL 16.14:
  #
  #     websearch_to_tsquery('english', 'alpha or beta or gamma')
  #       => 'alpha' | 'beta' | 'gamma'
  #
  # The cost, stated plainly: an OR matches far more rows than an AND, so
  # `ts_rank_cd` now carries the whole burden of precision and the channel cap
  # bites on broad queries. That is the right trade against a confident false
  # empty.
  #
  # Exposed as `@doc false` public rather than `defp` so the anti-AND guard in
  # `search_lexical_query_test.exs` can assert on the OPERATOR this produces —
  # `SELECT websearch_to_tsquery('english', $1)::text` must contain `|` and no
  # `&`. Asserting on a downstream result set instead would let a future
  # refactor back to conjunction pass silently. Not part of the public API.
  @doc false
  def prepare_lexical_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      # A deliberate operator query is user intent — a phrase search, a
      # negation, or an explicit uppercase OR. Never rewrite it into
      # alternation; doing so would silently disarm a caller who was already
      # being precise.
      deliberate_operator_query?(trimmed) ->
        trimmed

      true ->
        tokens = lexical_tokens(trimmed)

        # Short queries are precise today and the conjunction is doing useful
        # work there, so leave them byte-identical to the previous behaviour.
        # Only long queries — exactly the ones that currently empty — are
        # rewritten.
        if length(tokens) <= @lexical_short_query_tokens do
          trimmed
        else
          Enum.join(tokens, " or ")
        end
    end
  end

  defp deliberate_operator_query?(trimmed) do
    String.contains?(trimmed, "\"") or
      Regex.match?(~r/(?:^|\s)-\S/u, trimmed) or
      Regex.match?(~r/(?:^|\s)OR(?:\s|$)/, trimmed)
  end

  # Split on anything that is not a letter or a digit, downcase, drop empties,
  # dedupe preserving first-seen order, then cap. The cap exists because an OR
  # over a two-hundred-token ticket body is a GIN scan over nearly the whole
  # table; taking the FIRST 32 of a title-then-description query text keeps the
  # subject terms, which are the discriminating ones.
  defp lexical_tokens(trimmed) do
    trimmed
    |> String.split(~r/[^\p{L}\p{N}]+/u)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@lexical_query_token_cap)
  end

  defp lexical_pages(query, opts, cap) do
    prepared = prepare_lexical_query(query)

    tsvector_hits =
      WikiPage
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_namespace(opts.namespace)
      |> maybe_filter_since_inserted(opts.since)
      |> where(
        [p],
        fragment("? @@ websearch_to_tsquery('english', ?)", p.search_vector, ^prepared)
      )
      |> order_by(
        [p],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            p.search_vector,
            ^prepared
          ),
        desc: p.inserted_at
      )
      |> limit(^cap)
      |> Repo.all()

    if tsvector_hits == [] do
      ilike_pages_fallback(query, opts, cap)
    else
      to_lexical_hits(:page, tsvector_hits, false)
    end
  end

  defp ilike_pages_fallback(query, opts, cap) do
    pattern = "%" <> escape_like(query) <> "%"

    rows =
      WikiPage
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_namespace(opts.namespace)
      |> maybe_filter_since_inserted(opts.since)
      |> where([p], ilike(p.content, ^pattern))
      |> order_by([p], desc: p.inserted_at)
      |> limit(^cap)
      |> Repo.all()

    to_lexical_hits(:page, rows, true)
  end

  defp lexical_journal(query, opts, cap) do
    prepared = prepare_lexical_query(query)

    tsvector_hits =
      WikiJournalEntry
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_journal_namespace(opts.namespace)
      |> maybe_filter_since_date(opts.since)
      |> where(
        [e],
        fragment("? @@ websearch_to_tsquery('english', ?)", e.search_vector, ^prepared)
      )
      |> order_by(
        [e],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            e.search_vector,
            ^prepared
          ),
        desc: e.inserted_at
      )
      |> limit(^cap)
      |> Repo.all()

    if tsvector_hits == [] do
      ilike_journal_fallback(query, opts, cap)
    else
      to_lexical_hits(:journal, tsvector_hits, false)
    end
  end

  defp ilike_journal_fallback(query, opts, cap) do
    pattern = "%" <> escape_like(query) <> "%"

    rows =
      WikiJournalEntry
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_journal_namespace(opts.namespace)
      |> maybe_filter_since_date(opts.since)
      |> where([e], ilike(e.content, ^pattern))
      |> order_by([e], desc: e.inserted_at)
      |> limit(^cap)
      |> Repo.all()

    to_lexical_hits(:journal, rows, true)
  end

  # Message lexical channel: skip entirely for anonymous callers (ACL
  # would drop every hit anyway). For agents, fan out across accessible
  # spaces via `Chat.search_messages/3`, then re-rank by the virtual
  # `search_rank` field that the tsvector query populates.
  defp lexical_messages(_query, %{agent: nil}, _cap), do: []

  defp lexical_messages(query, opts, cap) do
    agent_id = opts.agent.id

    spaces =
      agent_id
      |> Chat.list_spaces_for_agent()
      |> Enum.map(& &1.id)

    if spaces == [] do
      []
    else
      since_dt = parse_since_datetime(opts.since)

      messages =
        spaces
        |> Enum.flat_map(fn space_id ->
          Chat.search_messages(space_id, query, limit: cap)
        end)
        |> Enum.filter(fn msg ->
          is_nil(msg.deleted_at) and message_after_since?(msg, since_dt)
        end)
        |> Enum.sort_by(fn m ->
          {-(m.search_rank || 0.0), -DateTime.to_unix(m.inserted_at, :microsecond)}
        end)
        |> Enum.take(cap)

      to_lexical_message_hits(messages)
    end
  end

  # Task lexical channel (stage 3, 019f3dbb): mirrors the pages/journal
  # tsvector-then-ilike pattern against `tasks.search_vector` (generated
  # column added in stage 1). Filters:
  #
  #   * `project_id` — tenancy scope. Tasks don't have `workspace_id`;
  #     skip that filter entirely.
  #   * `org_id` — resolved by joining `projects` on `tasks.project_id`,
  #     since `tasks` inherit tenancy through their project (ADR 0042).
  #   * `since` — filter by `tasks.inserted_at`.
  #
  # Soft-deleted tasks (`deleted_at != nil`) are dropped in both channels.
  defp lexical_tasks(query, opts, cap) do
    prepared = prepare_lexical_query(query)

    tsvector_hits =
      TaskRecord
      |> filter_task_deleted()
      |> filter_task_project(opts.project_id)
      |> scope_task_org(opts.org_id)
      |> maybe_filter_since_inserted(opts.since)
      |> where(
        [t],
        fragment("? @@ websearch_to_tsquery('english', ?)", t.search_vector, ^prepared)
      )
      |> order_by(
        [t],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            t.search_vector,
            ^prepared
          ),
        desc: t.updated_at
      )
      |> limit(^cap)
      |> Repo.all()

    if tsvector_hits == [] do
      ilike_tasks_fallback(query, opts, cap)
    else
      to_lexical_hits(:task, tsvector_hits, false)
    end
  end

  # NOTE: the fallback deliberately receives the ORIGINAL query, never the
  # prepared one — a `%a or b or c%` LIKE pattern matches nothing. Since
  # `prepare_lexical_query/1` landed this fallback is near-dead for long
  # queries: the OR-tsquery will almost always return something, so the
  # `tsvector_hits == []` branch that reaches here is now rare. It is kept
  # because deleting it is a separate decision.
  defp ilike_tasks_fallback(query, opts, cap) do
    pattern = "%" <> escape_like(query) <> "%"

    rows =
      TaskRecord
      |> filter_task_deleted()
      |> filter_task_project(opts.project_id)
      |> scope_task_org(opts.org_id)
      |> maybe_filter_since_inserted(opts.since)
      |> where([t], ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
      |> order_by([t], desc: t.updated_at)
      |> limit(^cap)
      |> Repo.all()

    to_lexical_hits(:task, rows, true)
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Lexical hit normalisation
  ## ─────────────────────────────────────────────────────────────────────

  defp to_lexical_hits(corpus, rows, fallback?) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      %{
        corpus: corpus,
        id: row.id,
        score: nil,
        rank: rank,
        channel: :lexical,
        metadata: maybe_fallback_meta(fallback?)
      }
    end)
  end

  defp to_lexical_message_hits(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {msg, rank} ->
      %{
        corpus: :message,
        id: msg.id,
        score: nil,
        rank: rank,
        channel: :lexical,
        metadata: %{}
      }
    end)
  end

  defp maybe_fallback_meta(true), do: %{@lexical_fallback_meta_key => true}
  defp maybe_fallback_meta(false), do: %{}

  ## ─────────────────────────────────────────────────────────────────────
  ## RRF fusion
  ## ─────────────────────────────────────────────────────────────────────

  # Group hits by `(corpus, id)` and sum 1/(k + rank) across the
  # channels each appears in. Preserve the per-channel ranks so the
  # hit envelope can report them later for debugging.
  defp fuse(channel_hits, limit) do
    channel_hits
    |> Enum.group_by(fn h -> {h.corpus, h.id} end)
    |> Enum.map(fn {{corpus, id}, hits} ->
      score =
        Enum.reduce(hits, 0.0, fn h, acc ->
          acc + 1.0 / (@fusion_constant_k + h.rank)
        end)

      semantic_rank =
        hits
        |> Enum.find(fn h -> h.channel == :semantic end)
        |> case do
          nil -> nil
          h -> h.rank
        end

      lexical_rank =
        hits
        |> Enum.find(fn h -> h.channel == :lexical end)
        |> case do
          nil -> nil
          h -> h.rank
        end

      %{
        corpus: corpus,
        id: id,
        score: score,
        semantic_rank: semantic_rank,
        lexical_rank: lexical_rank,
        # Used only for tie-breaking before hydration; the public hit
        # carries `:date_or_inserted_at` from the hydrated row.
        tie_break_lexical: lexical_rank || 999_999
      }
    end)
    # Cap candidates at 4× limit before hydration so absurd corpora can't
    # cause a runaway hydration step. Final `Enum.take(limit)` happens
    # post-hydration in `do_search/2`.
    |> Enum.sort_by(fn h -> {-h.score, h.tie_break_lexical} end)
    |> Enum.take(max(limit * 4, limit))
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Hydration — bulk load + ACL + orphan drop
  ## ─────────────────────────────────────────────────────────────────────

  defp hydrate(fused, opts) do
    pages_by_id = bulk_load_pages(fused, opts)
    journal_by_id = bulk_load_journal(fused, opts)
    messages_by_id = bulk_load_messages(fused, opts)
    tasks_by_id = bulk_load_tasks(fused, opts)

    agent_space_ids = agent_space_ids(opts.agent)

    ctx = %{
      pages: pages_by_id,
      journal: journal_by_id,
      messages: messages_by_id,
      tasks: tasks_by_id,
      spaces: agent_space_ids,
      opts: opts
    }

    # Every `hydrate_one/2` miss (orphan, tombstone, ACL refusal) is
    # counted under the fused hit's corpus. The kinds are deliberately
    # not distinguished: a separate ACL count would tell the caller a
    # row exists that they may not read.
    {hits, dropped} =
      Enum.reduce(fused, {[], @zero_dropped}, fn fused_hit, {acc, dropped} ->
        case hydrate_one(fused_hit, ctx) do
          [] -> {acc, Map.update!(dropped, fused_hit.corpus, &(&1 + 1))}
          [hit] -> {[hit | acc], dropped}
        end
      end)

    # Stable post-hydration sort: score desc → lexical_rank asc →
    # date_or_inserted_at desc.
    sorted =
      Enum.sort_by(hits, fn hit ->
        {-hit.score, hit.lexical_rank || 999_999, neg_iso(hit.date_or_inserted_at)}
      end)

    {sorted, dropped}
  end

  defp hydrate_one(%{corpus: :page} = h, %{pages: pages, opts: opts}) do
    case Map.get(pages, h.id) do
      %WikiPage{} = page ->
        case Routing.gate_read(opts.agent, page.file_key) do
          :ok ->
            [
              %{
                source: "page",
                id: page.id,
                path: page.file_key,
                space_id: nil,
                content: page.content,
                score: h.score,
                semantic_rank: h.semantic_rank,
                lexical_rank: h.lexical_rank,
                authored_by: page.updated_by,
                date_or_inserted_at: DateTime.to_iso8601(page.inserted_at)
              }
            ]

          {:error, _} ->
            []
        end

      _ ->
        []
    end
  end

  defp hydrate_one(%{corpus: :journal} = h, %{journal: journal, opts: opts}) do
    case Map.get(journal, h.id) do
      %WikiJournalEntry{} = entry ->
        file_key = Journal.virtual_file_key(journal_namespace(entry), entry.date)

        case Routing.gate_read(opts.agent, file_key) do
          :ok ->
            [
              %{
                source: "journal",
                id: entry.id,
                path: file_key,
                space_id: nil,
                content: entry.content,
                score: h.score,
                semantic_rank: h.semantic_rank,
                lexical_rank: h.lexical_rank,
                authored_by: entry.authored_by,
                date_or_inserted_at: Date.to_iso8601(entry.date)
              }
            ]

          {:error, _} ->
            []
        end

      _ ->
        []
    end
  end

  defp hydrate_one(%{corpus: :message} = h, %{messages: msgs, spaces: spaces}) do
    case Map.get(msgs, h.id) do
      nil ->
        []

      msg ->
        cond do
          not is_nil(msg.deleted_at) -> []
          msg.space_id not in spaces -> []
          true -> [message_to_hit(msg, h)]
        end
    end
  end

  # Stage 3 (019f3dbb): task-corpus hits. Task ACL was already enforced by
  # the `project_id` / `org_id` filter at query time; hydration just drops
  # orphans (id not in the bulk-loaded map — e.g. deleted between embed
  # and search) and soft-deleted rows (defense in depth against
  # tombstoned rows the memory-service semantic channel might still
  # remember). Task-specific advisory fields flow through
  # `Platform.Tasks.merged_pr_url/1` + `Platform.Tasks.follow_up_task_ids/1`.
  defp hydrate_one(%{corpus: :task} = h, %{tasks: tasks}) do
    case Map.get(tasks, h.id) do
      %TaskRecord{deleted_at: %DateTime{}} ->
        []

      %TaskRecord{} = task ->
        [task_to_hit(task, h)]

      _ ->
        []
    end
  end

  defp task_to_hit(%TaskRecord{} = task, h) do
    updated_at_iso = DateTime.to_iso8601(task.updated_at)

    %{
      source: "task",
      id: task.id,
      path: nil,
      space_id: nil,
      content: task_content(task),
      score: h.score,
      semantic_rank: h.semantic_rank,
      lexical_rank: h.lexical_rank,
      authored_by: task.reported_by,
      date_or_inserted_at: updated_at_iso,
      # ── Task-specific advisory fields (flat on the hit) ────────────────
      status: task.status,
      priority: task.priority,
      updated_at: updated_at_iso,
      merged_pr_url: Tasks.merged_pr_url(task),
      follow_up_task_ids: Tasks.follow_up_task_ids(task),
      cancellation_note: task_cancellation_note(task)
    }
  end

  defp task_content(%TaskRecord{title: title, description: nil}), do: title || ""

  defp task_content(%TaskRecord{title: title, description: description}) do
    (title || "") <> " — " <> description
  end

  defp task_cancellation_note(%TaskRecord{status: "cancelled", metadata: %{} = metadata}) do
    case Map.get(metadata, "cancellation_note") do
      note when is_binary(note) and note != "" -> note
      _ -> nil
    end
  end

  defp task_cancellation_note(_), do: nil

  defp message_to_hit(msg, h) do
    %{
      source: "message",
      id: msg.id,
      path: nil,
      space_id: msg.space_id,
      content: message_content(msg),
      score: h.score,
      semantic_rank: h.semantic_rank,
      lexical_rank: h.lexical_rank,
      authored_by: msg.author_agent_id || msg.author_user_id || msg.participant_id,
      date_or_inserted_at: DateTime.to_iso8601(msg.inserted_at)
    }
  end

  # Prefer the highlighted excerpt when present so the caller sees the
  # matched span; fall back to the raw body.
  defp message_content(%{search_headline: headline}) when is_binary(headline) and headline != "",
    do: headline

  defp message_content(%{content: content}), do: content || ""

  defp journal_namespace(%WikiJournalEntry{metadata: %{"namespace" => ns}}) when is_binary(ns),
    do: ns

  defp journal_namespace(_), do: Journal.default_namespace()

  ## ─────────────────────────────────────────────────────────────────────
  ## Bulk loaders
  ## ─────────────────────────────────────────────────────────────────────

  defp bulk_load_pages(fused, opts) do
    ids = corpus_ids(fused, :page)

    if ids == [] do
      %{}
    else
      WikiPage
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> where([p], p.id in ^ids)
      |> Repo.all()
      |> Map.new(fn p -> {p.id, p} end)
    end
  end

  defp bulk_load_journal(fused, opts) do
    ids = corpus_ids(fused, :journal)

    if ids == [] do
      %{}
    else
      WikiJournalEntry
      |> filter_workspace(opts.workspace_id)
      |> scope_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> where([e], e.id in ^ids)
      |> Repo.all()
      |> Map.new(fn e -> {e.id, e} end)
    end
  end

  defp bulk_load_messages(fused, _opts) do
    ids = corpus_ids(fused, :message)

    if ids == [] do
      %{}
    else
      Platform.Chat.Message
      |> where([m], m.id in ^ids and is_nil(m.deleted_at))
      |> Repo.all()
      |> Map.new(fn m -> {m.id, m} end)
    end
  end

  # Stage 3 (019f3dbb): bulk-load task rows for hydration. Preloads
  # `:project` (required by `Tasks.merged_pr_url/1`'s repo_url resolution)
  # and `:stack` (rollup URL fallback). Plans → stages → validations are
  # NOT preloaded here — `Tasks.merged_pr_url/1` handles the lazy preload
  # itself on the small set of hits that survive the fusion + hydration
  # cutoff, keeping the bulk query narrow. Project/org tenancy is
  # re-applied here so soft-deleted rows and rows that slipped past the
  # semantic filter get dropped defensively.
  defp bulk_load_tasks(fused, opts) do
    ids = corpus_ids(fused, :task)

    if ids == [] do
      %{}
    else
      TaskRecord
      |> filter_task_deleted()
      |> filter_task_project(opts.project_id)
      |> scope_task_org(opts.org_id)
      |> where([t], t.id in ^ids)
      |> preload([:project, :stack])
      |> Repo.all()
      |> Map.new(fn t -> {t.id, t} end)
    end
  end

  defp corpus_ids(fused, corpus) do
    fused
    |> Enum.filter(fn h -> h.corpus == corpus end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp agent_space_ids(nil), do: []

  defp agent_space_ids(%Agent{id: id}) do
    id
    |> Chat.list_spaces_for_agent()
    |> Enum.map(& &1.id)
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Query helpers
  ## ─────────────────────────────────────────────────────────────────────

  defp filter_workspace(queryable, nil) do
    where(queryable, [r], is_nil(r.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [r], r.workspace_id == ^workspace_id)
  end

  # ADR-0042 additive org filter, mapped onto the shared choke point
  # `Tenancy.scope/3`. A list value (from the federation surface's
  # tenant-default scoping) is an `IN` clause so tenant agents see their
  # own + inherited-root content without leaking sibling tenants.
  #
  # `nil` and `[]` are NOT the same question:
  #
  #   * `nil` is the ABSENCE of a question — the legacy workspace-only
  #     call path did not ask to filter by org, so we do not filter.
  #   * `[]` is a RESOLVED answer meaning "no orgs", so it maps to
  #     `:none` and matches nothing. It used to return the queryable
  #     untouched. A fail-open default is wrong regardless of how wide
  #     the intended audience is, because a deliberate wide audience and
  #     an accidental one are different things and only the first is a
  #     decision.
  defp org_visibility(org_id) when is_binary(org_id), do: {:orgs, [org_id]}

  defp org_visibility(org_ids) when is_list(org_ids),
    do: {:orgs, Enum.filter(org_ids, &is_binary/1)}

  defp scope_org(queryable, nil), do: queryable

  defp scope_org(queryable, org_opt),
    do: Tenancy.scope(queryable, org_visibility(org_opt))

  defp filter_project(queryable, nil), do: queryable

  defp filter_project(queryable, project_id) when is_binary(project_id) do
    where(queryable, [r], r.project_id == ^project_id)
  end

  ## Task-specific filter helpers (stage 3, 019f3dbb) —────────────────────
  ##
  ## Tasks don't share the `workspace_id` column that pages/journal use,
  ## so they get their own project/org filters. `org_id` requires a join
  ## against `projects` because tasks inherit tenancy through their
  ## project (ADR 0042).

  defp filter_task_deleted(queryable) do
    where(queryable, [t], is_nil(t.deleted_at))
  end

  defp filter_task_project(queryable, nil), do: queryable

  defp filter_task_project(queryable, project_id) when is_binary(project_id) do
    where(queryable, [t], t.project_id == ^project_id)
  end

  # Same nil-vs-`[]` reasoning as `scope_org/2` above; the only difference
  # is the join, because tasks inherit tenancy through their project. The
  # joined `projects` row is the last binding, so `Tenancy.scope/3` is
  # pointed at it with `binding: :last`.
  defp scope_task_org(queryable, nil), do: queryable

  defp scope_task_org(queryable, org_opt) do
    from(t in queryable, join: p in Project, on: p.id == t.project_id)
    |> Tenancy.scope(org_visibility(org_opt), binding: :last)
  end

  # Namespace filter for page queries: `file_key LIKE 'namespace/%'`.
  defp maybe_filter_namespace(queryable, nil), do: queryable

  defp maybe_filter_namespace(queryable, namespace) when is_binary(namespace) do
    prefix = namespace <> "/%"
    where(queryable, [p], like(p.file_key, ^prefix))
  end

  # Namespace filter for journal queries: `metadata ->> 'namespace' = ?`.
  defp maybe_filter_journal_namespace(queryable, nil), do: queryable

  defp maybe_filter_journal_namespace(queryable, namespace) when is_binary(namespace) do
    where(queryable, [e], fragment("? ->> 'namespace'", e.metadata) == ^namespace)
  end

  defp maybe_filter_since_inserted(queryable, nil), do: queryable

  defp maybe_filter_since_inserted(queryable, %Date{} = date) do
    {:ok, dt} = DateTime.new(date, ~T[00:00:00.000000], "Etc/UTC")
    where(queryable, [r], r.inserted_at >= ^dt)
  end

  defp maybe_filter_since_date(queryable, nil), do: queryable

  defp maybe_filter_since_date(queryable, %Date{} = date) do
    where(queryable, [e], e.date >= ^date)
  end

  defp parse_since_datetime(nil), do: nil

  defp parse_since_datetime(%Date{} = d) do
    {:ok, dt} = DateTime.new(d, ~T[00:00:00.000000], "Etc/UTC")
    dt
  end

  defp message_after_since?(_msg, nil), do: true

  defp message_after_since?(msg, %DateTime{} = dt) do
    DateTime.compare(msg.inserted_at, dt) != :lt
  end

  defp escape_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp neg_iso(iso) when is_binary(iso), do: {:neg, iso}
  defp neg_iso(_), do: {:neg, ""}

  ## ─────────────────────────────────────────────────────────────────────
  ## Opt normalisation
  ## ─────────────────────────────────────────────────────────────────────

  defp normalize_opts(opts) do
    %{
      source: parse_source(Keyword.get(opts, :source)),
      namespace: Keyword.get(opts, :namespace),
      since: parse_since(Keyword.get(opts, :since)),
      limit: parse_limit(Keyword.get(opts, :limit, @default_limit)),
      agent: Keyword.get(opts, :agent),
      workspace_id: Keyword.get(opts, :workspace_id),
      org_id: Keyword.get(opts, :org_id),
      project_id: Keyword.get(opts, :project_id),
      memory_type: Keyword.get(opts, :memory_type)
    }
  end

  defp parse_source(nil), do: nil

  defp parse_source(value) when value in [:page, :journal, :message, :task],
    do: Atom.to_string(value)

  defp parse_source(value) when value in ["page", "journal", "message", "task"], do: value
  defp parse_source(_), do: nil

  defp parse_since(nil), do: nil
  defp parse_since(%Date{} = d), do: d

  defp parse_since(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_since(_), do: nil

  defp parse_limit(value) when is_integer(value) and value > 0,
    do: min(value, @max_limit)

  defp parse_limit(_), do: @default_limit

  defp enabled_corpora(nil), do: [:page, :journal, :message, :task]
  defp enabled_corpora("page"), do: [:page]
  defp enabled_corpora("journal"), do: [:journal]
  defp enabled_corpora("message"), do: [:message]
  defp enabled_corpora("task"), do: [:task]
  defp enabled_corpora(_), do: [:page, :journal, :message, :task]
end
