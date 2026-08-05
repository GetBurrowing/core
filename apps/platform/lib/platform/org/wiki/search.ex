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
  rows are dropped silently.

  ## Robustness

  Each channel runs in its own `Task.async_stream/3` with a 2s timeout.
  A failed channel logs a warning, contributes zero hits, and the
  fusion proceeds with the surviving channels — a memory-service
  outage degrades to lexical-only rather than failing the call.
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

  @fusion_constant_k 60
  @default_limit 20
  @max_limit 100
  @channel_timeout_ms 2_000
  @lexical_fallback_meta_key :lexical_fallback

  @type corpus :: :page | :journal | :message | :task | :excluded | :unknown

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
  Hybrid (semantic + lexical) search across pages, journal entries, and
  chat messages. Returns `{:ok, %{results, fusion_constant_k, truncated}}`.

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
  @spec search(String.t(), search_opts()) ::
          {:ok, %{results: [hit()], fusion_constant_k: 60, truncated: boolean()}}
  def search(query, opts \\ []) when is_binary(query) and is_list(opts) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:ok, %{results: [], fusion_constant_k: @fusion_constant_k, truncated: false}}
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

    # All channels run concurrently with a 2s budget each. The
    # `:on_timeout :kill_task` + `nil`-result handling means a slow
    # channel never blocks the fusion — it just contributes no hits.
    channel_results =
      [:semantic | Enum.map(corpora, &{:lexical, &1})]
      |> Task.async_stream(
        fn channel -> run_channel(channel, query, opts, channel_cap, corpora) end,
        max_concurrency: max(length(corpora) + 1, 2),
        timeout: @channel_timeout_ms + 500,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {channel, hits}} -> {channel, hits}
        {:exit, reason} -> handle_channel_exit(reason)
      end)

    hits = Enum.flat_map(channel_results, fn {_channel, hits} -> hits end)

    truncated? =
      Enum.any?(channel_results, fn {_channel, hits} -> length(hits) >= channel_cap end)

    fused = fuse(hits, opts.limit)

    hydrated =
      fused
      |> hydrate(opts)
      |> Enum.take(opts.limit)

    {:ok,
     %{
       results: hydrated,
       fusion_constant_k: @fusion_constant_k,
       truncated: truncated?
     }}
  end

  defp handle_channel_exit(:timeout) do
    Logger.warning("Platform.Org.Wiki.Search: channel timed out")
    {:exited, []}
  end

  defp handle_channel_exit(reason) do
    Logger.warning("Platform.Org.Wiki.Search: channel crashed: #{inspect(reason)}")
    {:exited, []}
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Channels — each returns {channel_label, [channel_hit]}
  ## ─────────────────────────────────────────────────────────────────────

  # Semantic — single call covering every enabled corpus. The provider
  # tags each hit via `memory_type` on the indexed payload, and every tag
  # is classified by a named clause of `semantic_corpus/1`:
  #
  #   * nil / "" — legacy entries indexed before the tag existed; these
  #     are wiki pages and map to `:page`. The only unnamed value that does.
  #   * "document" — refused. File text is ingested for the Files surface,
  #     not for wiki memory search.
  #   * anything else — unknown, and refused rather than reinterpreted.
  #     A refusal is a no-result we can see; a silent remap to `:page` is
  #     a wrong result we cannot.
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
          hits =
            results
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {hit, rank} -> semantic_hit_to_channel(hit, rank, corpora) end)

          warn_unknown_tags(results)

          {{:semantic, :all}, hits}

        {:error, reason} ->
          Logger.warning("Platform.Org.Wiki.Search: semantic channel error: #{inspect(reason)}")
          {{:semantic, :all}, []}
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
  # org id or project id. `:excluded` and the legacy nil/"" cases are
  # expected refusals, not surprises, so they are not logged.
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

  defp semantic_hit_to_channel(hit, rank, corpora) do
    id = Map.get(hit, :entry_id) || Map.get(hit, "entry_id")
    score = Map.get(hit, :score) || Map.get(hit, "score")

    corpus = hit |> raw_memory_type() |> semantic_corpus()

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
  # Legacy entries indexed before the corpus tag existed carry no type.
  # They are wiki pages; this is the only unnamed value that may map to :page.
  defp semantic_corpus(nil), do: :page
  defp semantic_corpus(""), do: :page
  # Any other tag is a value this module has never been taught. Refuse it
  # rather than silently reinterpreting it as a page.
  defp semantic_corpus(_other), do: :unknown

  ## ─────────────────────────────────────────────────────────────────────
  ## Lexical channels — tsvector first, ilike fallback when empty
  ## ─────────────────────────────────────────────────────────────────────

  defp lexical_pages(query, opts, cap) do
    tsvector_hits =
      WikiPage
      |> filter_workspace(opts.workspace_id)
      |> filter_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_namespace(opts.namespace)
      |> maybe_filter_since_inserted(opts.since)
      |> where(
        [p],
        fragment("? @@ websearch_to_tsquery('english', ?)", p.search_vector, ^query)
      )
      |> order_by(
        [p],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            p.search_vector,
            ^query
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
      |> filter_org(opts.org_id)
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
    tsvector_hits =
      WikiJournalEntry
      |> filter_workspace(opts.workspace_id)
      |> filter_org(opts.org_id)
      |> filter_project(opts.project_id)
      |> maybe_filter_journal_namespace(opts.namespace)
      |> maybe_filter_since_date(opts.since)
      |> where(
        [e],
        fragment("? @@ websearch_to_tsquery('english', ?)", e.search_vector, ^query)
      )
      |> order_by(
        [e],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            e.search_vector,
            ^query
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
      |> filter_org(opts.org_id)
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
    tsvector_hits =
      TaskRecord
      |> filter_task_deleted()
      |> filter_task_project(opts.project_id)
      |> filter_task_org(opts.org_id)
      |> maybe_filter_since_inserted(opts.since)
      |> where(
        [t],
        fragment("? @@ websearch_to_tsquery('english', ?)", t.search_vector, ^query)
      )
      |> order_by(
        [t],
        desc:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            t.search_vector,
            ^query
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

  defp ilike_tasks_fallback(query, opts, cap) do
    pattern = "%" <> escape_like(query) <> "%"

    rows =
      TaskRecord
      |> filter_task_deleted()
      |> filter_task_project(opts.project_id)
      |> filter_task_org(opts.org_id)
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

    fused
    |> Enum.flat_map(fn fused_hit -> hydrate_one(fused_hit, ctx) end)
    # Stable post-hydration sort: score desc → lexical_rank asc →
    # date_or_inserted_at desc.
    |> Enum.sort_by(fn hit ->
      {-hit.score, hit.lexical_rank || 999_999, neg_iso(hit.date_or_inserted_at)}
    end)
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
      |> filter_org(opts.org_id)
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
      |> filter_org(opts.org_id)
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
      |> filter_task_org(opts.org_id)
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

  # ADR-0042 additive filters. Both default to no-op (nil) so the legacy
  # workspace-only call path is unchanged. A list value (added by the
  # federation surface's tenant-default scoping) is treated as an `IN`
  # clause so tenant agents see their own + inherited-root content
  # without leaking sibling tenants.
  defp filter_org(queryable, nil), do: queryable

  defp filter_org(queryable, org_id) when is_binary(org_id) do
    where(queryable, [r], r.org_id == ^org_id)
  end

  defp filter_org(queryable, org_ids) when is_list(org_ids) do
    ids = Enum.filter(org_ids, &is_binary/1)

    case ids do
      [] -> queryable
      [one] -> where(queryable, [r], r.org_id == ^one)
      many -> where(queryable, [r], r.org_id in ^many)
    end
  end

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

  defp filter_task_org(queryable, nil), do: queryable

  defp filter_task_org(queryable, org_id) when is_binary(org_id) do
    from(t in queryable,
      join: p in Project,
      on: p.id == t.project_id,
      where: p.org_id == ^org_id
    )
  end

  defp filter_task_org(queryable, org_ids) when is_list(org_ids) do
    ids = Enum.filter(org_ids, &is_binary/1)

    case ids do
      [] ->
        queryable

      [one] ->
        filter_task_org(queryable, one)

      many ->
        from(t in queryable,
          join: p in Project,
          on: p.id == t.project_id,
          where: p.org_id in ^many
        )
    end
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
