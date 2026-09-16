defmodule Platform.Org.Wiki.SearchTest do
  @moduledoc """
  Tests for `Platform.Org.Wiki.Search` (ADR-0041, T5 stage 4).

  Covers the public `search/2` contract: source-tagged hits across
  pages / journal / messages, RRF fusion math (k=60), tie-break,
  filters (source, namespace, since), orphan-id hydration drops,
  message ACL filter (both lexical AND semantic paths), truncation
  flag, and the Noop-provider lexical-only fall-through.

  Lexical channels rely on the `search_vector` generated column added
  by `priv/repo/migrations/20260520020000_add_search_vector_to_org_wiki.exs`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures

  alias Ecto.Adapters.SQL
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Journal, Search}
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo

  ## ─────────────────────────────────────────────────────────────────────
  ## Stub provider — captures `Memory.search/3` calls and lets each test
  ## install a deterministic result list keyed by query.
  ## ─────────────────────────────────────────────────────────────────────

  defmodule StubProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    # `:search_behaviour` models a DEAD semantic channel without any
    # network: `:sleep` never returns (the stream kills the task on its
    # timeout), `:crash` exits the task abnormally, `:error` ANSWERS with
    # `{:error, reason}` (the connection-refused / 5xx shape). Anything
    # else answers with `:search_results`. The live service is never
    # asserted on.
    @impl true
    def search(query, _opts, config) do
      case Keyword.get(config, :search_behaviour) do
        :sleep ->
          Process.sleep(:infinity)

        :crash ->
          exit(:boom)

        :error ->
          {:error, :econnrefused}

        _ ->
          results =
            case Keyword.get(config, :search_results) do
              fun when is_function(fun, 1) -> fun.(query)
              list when is_list(list) -> list
              _ -> []
            end

          {:ok, results}
      end
    end

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_c), do: :ok
  end

  defp install_provider(results) do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: StubProvider,
      search_results: results
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    :ok
  end

  defp count_unknown_tag_warnings(log) do
    log
    |> String.split("unrecognised memory_type tag(s)")
    |> length()
    |> Kernel.-(1)
  end

  defp install_dead_provider(behaviour) when behaviour in [:sleep, :crash, :error] do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: StubProvider,
      search_behaviour: behaviour
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    :ok
  end

  defp noop_provider do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Fixture helpers
  ## ─────────────────────────────────────────────────────────────────────

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  defp create_agent(slug_prefix \\ "agent") do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  defp seed_page(file_key, content, opts \\ []) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: content}, opts)
    page
  end

  defp seed_journal(date, content, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, "org")

    {:ok, entry} =
      Journal.append(
        %{content: content, date: date, workspace_id: Keyword.get(opts, :workspace_id)},
        namespace: namespace
      )

    entry
  end

  defp seed_space(slug \\ nil) do
    slug = slug || "search-test-#{System.unique_integer([:positive])}"
    {:ok, space} = Chat.create_space(%{name: "Search Space", slug: slug, kind: "channel"})
    space
  end

  defp seed_agent_participant(space, %Agent{} = agent) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name || "Agent",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp seed_message(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Empty query / smoke
  ## ─────────────────────────────────────────────────────────────────────

  describe "search/2 — smoke" do
    test "empty query returns empty results with k=60" do
      assert {:ok,
              %{
                results: [],
                fusion_constant_k: 60,
                truncated: false,
                dead_channels: [],
                dropped: %{page: 0, journal: 0, message: 0, task: 0}
              }} =
               Search.search("", [])
    end

    test "fusion_constant_k is always 60" do
      noop_provider()
      assert {:ok, %{fusion_constant_k: 60}} = Search.search("anything")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 1. Source tagging across all three corpora (lexical-only path)
  ## ─────────────────────────────────────────────────────────────────────

  describe "source tagging across corpora (Noop provider, lexical only)" do
    test "tags hits with the correct source for page / journal / message" do
      noop_provider()

      agent = create_agent("alpha")
      space = seed_space()
      participant = seed_agent_participant(space, agent)

      seed_page("org/page/elixir.md", "elixir phoenix runtime guide")
      seed_journal(Date.utc_today(), "phoenix release notes")
      seed_message(space, participant, "have we used phoenix here lately?")

      {:ok, %{results: results}} = Search.search("phoenix", agent: agent, limit: 10)

      sources = results |> Enum.map(& &1.source) |> MapSet.new()

      assert "page" in sources
      assert "journal" in sources
      assert "message" in sources
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 2. RRF math — score = sum(1/(60 + rank_c)) over channels
  ## ─────────────────────────────────────────────────────────────────────

  describe "RRF fusion math" do
    test "score equals 1/(60 + sem_rank) + 1/(60 + lex_rank) for hits in both channels" do
      page_alpha = seed_page("org/page/alpha.md", "fabrikam platform alpha story")
      page_bravo = seed_page("org/page/bravo.md", "fabrikam platform bravo story")
      page_charlie = seed_page("org/page/charlie.md", "fabrikam platform charlie story")

      # Semantic ranks: alpha=1, charlie=2 (bravo is lexical-only).
      install_provider([
        %{entry_id: page_alpha.id, score: 0.9, memory_type: "page"},
        %{entry_id: page_charlie.id, score: 0.8, memory_type: "page"}
      ])

      {:ok, %{results: results}} = Search.search("fabrikam platform", limit: 5)

      by_id = Map.new(results, fn r -> {r.id, r} end)

      alpha = Map.fetch!(by_id, page_alpha.id)
      bravo = Map.fetch!(by_id, page_bravo.id)
      charlie = Map.fetch!(by_id, page_charlie.id)

      # alpha: semantic rank 1 + lexical rank ∈ {1,2,3}
      assert alpha.semantic_rank == 1
      assert alpha.lexical_rank in [1, 2, 3]

      # bravo: lexical-only (no semantic hit)
      assert is_nil(bravo.semantic_rank)
      assert bravo.lexical_rank in [1, 2, 3]

      # charlie: semantic rank 2 + lexical rank ∈ {1,2,3}
      assert charlie.semantic_rank == 2

      # Hand-compute expected scores from the actual ranks we observed.
      expected_alpha = 1.0 / (60 + alpha.semantic_rank) + 1.0 / (60 + alpha.lexical_rank)
      expected_bravo = 1.0 / (60 + bravo.lexical_rank)
      expected_charlie = 1.0 / (60 + charlie.semantic_rank) + 1.0 / (60 + charlie.lexical_rank)

      assert_in_delta alpha.score, expected_alpha, 1.0e-9
      assert_in_delta bravo.score, expected_bravo, 1.0e-9
      assert_in_delta charlie.score, expected_charlie, 1.0e-9

      # alpha and charlie outrank bravo (both have two channels).
      [first, _second, third] = results
      assert third.id == bravo.id
      assert first.id in [page_alpha.id, page_charlie.id]
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 3. Tie-break: identical RRF score → lower lexical_rank wins
  ## ─────────────────────────────────────────────────────────────────────

  describe "tie-break on lexical rank" do
    test "two hits with identical RRF score sort by lexical_rank asc" do
      noop_provider()

      # Two pages with identical content (so the tsvector rank is
      # equal), distinct file_keys (so their order in the lexical
      # channel is determined by inserted_at desc). The second-inserted
      # page gets lexical_rank=1, the first-inserted gets lexical_rank=2.
      _earlier = seed_page("org/page/a.md", "delta echo foxtrot")
      _later = seed_page("org/page/b.md", "delta echo foxtrot")

      {:ok, %{results: results}} = Search.search("delta echo", limit: 5)

      assert length(results) == 2

      # Both hits have the same score (each has only the lexical
      # channel) — but the one with lexical_rank=1 must sort first.
      [first, second] = results
      assert first.lexical_rank < second.lexical_rank
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 4. source: "page" filter — only page hits
  ## ─────────────────────────────────────────────────────────────────────

  describe "source filter" do
    test "source: \"page\" excludes journal and message hits" do
      noop_provider()
      agent = create_agent()
      space = seed_space()
      participant = seed_agent_participant(space, agent)

      seed_page("org/page/x.md", "kelp seaweed kelp")
      seed_journal(Date.utc_today(), "kelp harvest journal")
      seed_message(space, participant, "kelp pricing in Q3")

      {:ok, %{results: results}} = Search.search("kelp", agent: agent, source: "page", limit: 10)

      assert Enum.all?(results, &(&1.source == "page"))
      assert length(results) >= 1
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 5. namespace filter (project/<id>)
  ## ─────────────────────────────────────────────────────────────────────

  describe "namespace filter" do
    test "namespace: \"project/<id>\" restricts page hits to that namespace" do
      noop_provider()

      project_id = Ecto.UUID.generate()

      seed_page("org/page/global.md", "mango harvest notes")
      seed_page("project/#{project_id}/page/local.md", "mango harvest notes")

      {:ok, %{results: results}} =
        Search.search("mango", namespace: "project/#{project_id}", limit: 5)

      assert length(results) == 1
      [hit] = results
      assert hit.source == "page"
      assert String.starts_with?(hit.path, "project/#{project_id}/")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 6. since: date filter — older entries dropped
  ## ─────────────────────────────────────────────────────────────────────

  describe "since filter" do
    test "since date drops older journal entries" do
      noop_provider()

      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      old = Date.add(today, -30)

      seed_journal(today, "raspberry sorbet recipe today")
      seed_journal(yesterday, "raspberry sorbet recipe yesterday")
      seed_journal(old, "raspberry sorbet recipe ancient")

      {:ok, %{results: results}} =
        Search.search("raspberry sorbet", source: "journal", since: yesterday, limit: 10)

      dates = Enum.map(results, & &1.date_or_inserted_at)
      refute Date.to_iso8601(old) in dates
      assert Date.to_iso8601(today) in dates
      assert Date.to_iso8601(yesterday) in dates
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 7. Orphan hydration drop — id from semantic channel with no row.
  ##    The drop is no longer silent: it is counted in `dropped`.
  ## ─────────────────────────────────────────────────────────────────────

  describe "hydration drops orphans and counts them" do
    test "page id returned by semantic but absent from DB is dropped and counted" do
      page = seed_page("org/page/yam.md", "yams roasted recipe")

      ghost_id = Ecto.UUID.generate()

      install_provider([
        %{entry_id: ghost_id, score: 0.99, memory_type: "page"},
        %{entry_id: page.id, score: 0.50, memory_type: "page"}
      ])

      {:ok, %{results: results, dropped: dropped, dead_channels: []}} =
        Search.search("yams", source: "page", limit: 10)

      ids = Enum.map(results, & &1.id)
      refute ghost_id in ids
      assert page.id in ids
      assert dropped == %{page: 1, journal: 0, message: 0, task: 0}
    end

    test "deleted (raw-SQL nuked) page id is dropped and counted" do
      page = seed_page("org/page/papaya.md", "papaya is delicious in shakes")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "page"}
      ])

      # Bypass `Wiki.delete_page/2` so the indexer events don't fire and
      # the semantic provider keeps returning the ghost id.
      SQL.query!(Repo, "DELETE FROM org_wiki_pages WHERE id = $1", [Ecto.UUID.dump!(page.id)])

      {:ok, %{results: results, dropped: dropped}} =
        Search.search("papaya", source: "page", limit: 10)

      assert Enum.all?(results, &(&1.id != page.id))
      assert dropped.page == 1
    end

    test "an ACL-refused private page is counted, indistinguishably from an orphan" do
      noop_provider()

      owner = create_agent("owner")
      caller = create_agent("caller")
      space = seed_space("private-#{System.unique_integer([:positive])}")
      # Ownership of a private path also requires space participation.
      _owner_part = seed_agent_participant(space, owner)

      # The lexical page channel does not filter private paths; the
      # refusal happens at hydration via `Routing.gate_read/2`.
      seed_page("space/#{space.id}/private/#{owner.id}/notes.md", "tamarillo glaze secret ratio")
      seed_page("org/page/tamarillo.md", "tamarillo glaze public ratio")

      {:ok, %{results: results, dropped: dropped}} =
        Search.search("tamarillo glaze", agent: caller, source: "page", limit: 10)

      assert Enum.map(results, & &1.path) == ["org/page/tamarillo.md"]

      # Counted so the caller can see a hit went missing, but not
      # distinguished from an orphan: the payload must not reveal that a
      # row exists which someone else may read.
      assert dropped == %{page: 1, journal: 0, message: 0, task: 0}
      assert Map.keys(dropped) |> Enum.sort() == [:journal, :message, :page, :task]

      # The owner sees it, and nothing is dropped.
      {:ok, %{results: owner_results, dropped: owner_dropped}} =
        Search.search("tamarillo glaze", agent: owner, source: "page", limit: 10)

      assert length(owner_results) == 2
      assert owner_dropped == %{page: 0, journal: 0, message: 0, task: 0}
    end

    test "ghost ids across corpora are counted under their own corpus (StubProvider)" do
      page = seed_page("org/page/durian.md", "durian custard experiment")

      install_provider([
        %{entry_id: Ecto.UUID.generate(), score: 0.99, memory_type: "page"},
        %{entry_id: Ecto.UUID.generate(), score: 0.98, memory_type: "journal"},
        %{entry_id: Ecto.UUID.generate(), score: 0.97, memory_type: "task"},
        %{entry_id: page.id, score: 0.50, memory_type: "page"}
      ])

      {:ok, %{results: results, dropped: dropped}} = Search.search("durian custard", limit: 10)

      assert Enum.map(results, & &1.id) == [page.id]
      assert dropped == %{page: 1, journal: 1, message: 0, task: 1}
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 7a. Dead channels — a channel that times out or crashes is NAMED in
  ##     the response and forces `truncated: true`. StubProvider models
  ##     the death (sleep / exit); no network is involved.
  ## ─────────────────────────────────────────────────────────────────────

  describe "dead channels (StubProvider sleep / crash / error, never the network)" do
    # The stream budget is @channel_timeout_ms (2_000) + 500; the test
    # must finish inside that plus slack, or the kill is not working.
    @channel_timeout_ms 2_000

    @tag timeout: 10_000
    test "a semantic provider that never returns is killed, named, and forces truncated" do
      install_dead_provider(:sleep)

      seed_page("org/page/loquat.md", "loquat jam batch notes")

      started = System.monotonic_time(:millisecond)

      {{:ok, response}, log} =
        with_log(fn -> Search.search("loquat jam", source: "page", limit: 10) end)

      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed <= @channel_timeout_ms + 500 + 1_500,
             "search took #{elapsed}ms — the sleeping channel was not killed on its budget"

      assert response.dead_channels == [{:semantic, :all}]
      assert response.truncated == true
      assert [%{source: "page", content: "loquat jam batch notes"}] = response.results
      assert log =~ "channel {:semantic, :all} timed out"
    end

    test "a semantic provider that crashes is named, logged as crashed, and forces truncated" do
      install_dead_provider(:crash)

      seed_page("org/page/medlar.md", "medlar bletting schedule")

      {{:ok, response}, log} =
        with_log(fn -> Search.search("medlar bletting", source: "page", limit: 10) end)

      assert response.dead_channels == [{:semantic, :all}]
      assert response.truncated == true
      assert [%{source: "page", content: "medlar bletting schedule"}] = response.results
      assert log =~ "channel {:semantic, :all} crashed"
      assert log =~ ":boom"
    end

    test "a semantic provider that ANSWERS with an error marks the channel dead, not empty" do
      install_dead_provider(:error)

      seed_page("org/page/feijoa.md", "feijoa chutney fermentation notes")

      {{:ok, response}, log} =
        with_log(fn -> Search.search("feijoa chutney", source: "page", limit: 10) end)

      assert response.dead_channels == [{:semantic, :all}]
      assert response.truncated == true
      assert [%{source: "page", content: "feijoa chutney fermentation notes"}] = response.results
      assert log =~ "channel {:semantic, :all} returned an error"
      assert log =~ ":econnrefused"
    end

    test "a HEALTHY semantic provider answering {:ok, results} leaves the channel live" do
      # The negative control for the error arm above: the fix must not
      # ship as "every search now warns". A provider that answers
      # normally yields no dead channel and no truncation.
      install_provider([])

      seed_page("org/page/jabuticaba.md", "jabuticaba liqueur steeping notes")

      {{:ok, response}, log} =
        with_log(fn -> Search.search("jabuticaba liqueur", source: "page", limit: 10) end)

      assert response.dead_channels == []
      assert response.truncated == false
      assert [%{source: "page", content: "jabuticaba liqueur steeping notes"}] = response.results
      refute log =~ "channel {:semantic, :all}"
    end

    test "a dead channel does not push truncated toward false when a live channel is capped" do
      install_dead_provider(:crash)

      for n <- 1..50 do
        seed_page("org/page/dead-cap-#{n}.md", "quandong harvest quandong yield")
      end

      {:ok, %{truncated: true, dead_channels: [{:semantic, :all}], results: results}} =
        Search.search("quandong", source: "page", limit: 20)

      assert length(results) == 20
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 7b. Corpus classification of the semantic tag
  ##
  ## Every case here points the stub hit at a REAL row id, so the
  ## hydration lookup resolves. That disarms the accidental barrier (an
  ## unresolvable id is dropped by hydration regardless of corpus) and
  ## makes the assertions attributable to classification. The queries are
  ## chosen not to match the fixture text, so the lexical channels
  ## contribute nothing and the semantic channel is the only source.
  ## ─────────────────────────────────────────────────────────────────────

  describe "semantic corpus classification" do
    test "document-tagged semantic hits are dropped at classification even when the id resolves to a real page" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "document"}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "page", limit: 10)

      assert Enum.all?(results, &(&1.id != page.id))
    end

    test "positive control: the same resolving id tagged page IS returned" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "page"}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "page", limit: 10)

      assert page.id in Enum.map(results, & &1.id)
    end

    test "an unrecognised tag is refused even when the id resolves to a real page" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "sometag"}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "page", limit: 10)

      assert Enum.all?(results, &(&1.id != page.id))
    end

    test "an untagged hit whose id is a page resolves as a page via lookup" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: nil}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "page", limit: 10)

      hit = Enum.find(results, &(&1.id == page.id))
      refute is_nil(hit)
      assert hit.source == "page"
      assert hit.semantic_rank == 1
    end

    # `Platform.Memory.normalize/1` defaults untyped entries to "daily", and
    # journal entries ingested through the direct write path carry no
    # memory_type field — so this is the tag real journal entries arrive with.
    test "a daily-tagged hit resolves against the journal corpus" do
      entry = seed_journal(~D[2026-05-20], "quince harvest notes")

      install_provider([
        %{entry_id: entry.id, score: 0.99, memory_type: "daily"}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "journal", limit: 10)

      assert entry.id in Enum.map(results, & &1.id)
      assert Enum.find(results, &(&1.id == entry.id)).source == "journal"
    end

    # Stage 2 of 01a08a6e: once the provider forwards the service's tag,
    # both spellings of the journal corpus arrive on the same response.
    # StubProvider models that; the live service is never asserted on.
    test "daily- and journal-tagged hits in one response both resolve as journal (StubProvider)" do
      daily = seed_journal(~D[2026-05-21], "medlar bletting log")
      journal = seed_journal(~D[2026-05-22], "sorb apple pressing")

      install_provider([
        %{entry_id: daily.id, score: 0.95, memory_type: "daily"},
        %{entry_id: journal.id, score: 0.90, memory_type: "journal"}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "journal", limit: 10)

      ids = Enum.map(results, & &1.id)
      assert daily.id in ids
      assert journal.id in ids

      for hit <- results, hit.id in [daily.id, journal.id] do
        assert hit.source == "journal"
        assert is_integer(hit.semantic_rank)
      end
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 7c. Untagged semantic hits — classified by id lookup
  ##
  ## memory-service `/search` returns only `entry_id` + `score`, so on prod
  ## every semantic hit reaches classification with a nil tag. The stub
  ## omits `memory_type` (or sets it nil) to model that. Queries are
  ## nonsense so the lexical channels contribute nothing.
  ## ─────────────────────────────────────────────────────────────────────

  describe "untagged semantic hits are classified by id lookup (StubProvider)" do
    test "task-scoped search returns an untagged task hit with semantic_rank only" do
      {:ok, project} = Platform.Tasks.create_project(%{name: "UntaggedCo"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Ossifrage lantern calibration",
          description: "untagged semantic target"
        })

      install_provider([%{entry_id: task.id, score: 0.9}])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "task", limit: 10)

      hit = Enum.find(results, &(&1.id == task.id))
      refute is_nil(hit)
      assert hit.source == "task"
      assert hit.lexical_rank == nil
      assert hit.semantic_rank == 1
    end

    test "unscoped search returns an untagged page AND an untagged journal entry, each with its own source" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")
      entry = seed_journal(~D[2026-05-20], "quince harvest notes")

      install_provider([
        %{entry_id: page.id, score: 0.9},
        %{entry_id: entry.id, score: 0.8, memory_type: nil}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", limit: 10)

      by_id = Map.new(results, &{&1.id, &1})
      assert Map.fetch!(by_id, page.id).source == "page"
      assert Map.fetch!(by_id, entry.id).source == "journal"
      assert Map.fetch!(by_id, page.id).semantic_rank == 1
      assert Map.fetch!(by_id, entry.id).semantic_rank == 2
    end

    test "journal-scoped search returns an untagged journal entry with semantic_rank set" do
      entry = seed_journal(~D[2026-05-20], "quince harvest notes")

      install_provider([%{entry_id: entry.id, score: 0.9}])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "journal", limit: 10)

      hit = Enum.find(results, &(&1.id == entry.id))
      refute is_nil(hit)
      assert hit.source == "journal"
      assert hit.semantic_rank == 1
    end

    test "page-scoped search does NOT return an untagged journal entry as a page" do
      entry = seed_journal(~D[2026-05-20], "quince harvest notes")

      install_provider([%{entry_id: entry.id, score: 0.9}])

      {:ok, %{results: results}} = Search.search("zzyzx", source: "page", limit: 10)

      assert Enum.all?(results, &(&1.id != entry.id))
    end

    test "a present tag wins over the lookup: a page id tagged task is not returned as a page" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([%{entry_id: page.id, score: 0.9, memory_type: "task"}])

      # Unscoped: had the lookup run, the id would resolve as a page. The
      # tag routes it to :task, where hydration finds no row.
      {:ok, %{results: results}} = Search.search("zzyzx", limit: 10)

      assert Enum.all?(results, &(&1.id != page.id))
    end

    test "untagged hits with an unknown UUID or a non-UUID id are dropped without crashing" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: Ecto.UUID.generate(), score: 0.99},
        %{entry_id: "not-a-uuid", score: 0.98},
        %{entry_id: page.id, score: 0.5}
      ])

      {:ok, %{results: results}} = Search.search("zzyzx", limit: 10)

      assert Enum.map(results, & &1.id) == [page.id]
    end

    test "an untagged page in another org is not returned under org_id / project_id scoping" do
      other_org = tenant_org_id("soylent")
      mine = tenant_org_id("sxi")

      foreign =
        %WikiPage{}
        |> WikiPage.changeset(%{
          file_key: "org/page/foreign.md",
          content: "quince paste pairs with cheese",
          org_id: other_org
        })
        |> Repo.insert!()

      install_provider([%{entry_id: foreign.id, score: 0.99}])

      # Anti-vacuity: unscoped, the lookup resolves it.
      {:ok, %{results: unscoped}} = Search.search("zzyzx", limit: 10)
      assert foreign.id in Enum.map(unscoped, & &1.id)

      {:ok, %{results: by_org}} = Search.search("zzyzx", org_id: mine, limit: 10)
      refute foreign.id in Enum.map(by_org, & &1.id)

      {:ok, %{results: by_project}} =
        Search.search("zzyzx", project_id: Ecto.UUID.generate(), limit: 10)

      refute foreign.id in Enum.map(by_project, & &1.id)
    end
  end

  describe "unknown corpus tag logging" do
    test "an unrecognised tag emits exactly one warning naming the tag" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "sometag"}
      ])

      log = capture_log(fn -> Search.search("zzyzx", source: "page", limit: 10) end)

      assert log =~ "sometag"
      assert count_unknown_tag_warnings(log) == 1
    end

    test "a document tag emits no warning" do
      page = seed_page("org/page/quince.md", "quince paste pairs with cheese")

      install_provider([
        %{entry_id: page.id, score: 0.99, memory_type: "document"}
      ])

      log = capture_log(fn -> Search.search("zzyzx", source: "page", limit: 10) end)

      assert count_unknown_tag_warnings(log) == 0
    end

    test "two hits sharing one unknown tag emit a single warning" do
      page_a = seed_page("org/page/quince.md", "quince paste pairs with cheese")
      page_b = seed_page("org/page/medlar.md", "medlar is bletted before eating")

      install_provider([
        %{entry_id: page_a.id, score: 0.99, memory_type: "sometag"},
        %{entry_id: page_b.id, score: 0.98, memory_type: "sometag"}
      ])

      log = capture_log(fn -> Search.search("zzyzx", source: "page", limit: 10) end)

      assert count_unknown_tag_warnings(log) == 1
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 8. ACL filter on messages (lexical AND semantic paths)
  ## ─────────────────────────────────────────────────────────────────────

  describe "message ACL filter" do
    test "lexical message hit in a non-participant space is dropped" do
      noop_provider()

      caller = create_agent("caller")
      other = create_agent("other")

      participating = seed_space("acl-yes-#{System.unique_integer([:positive])}")
      restricted = seed_space("acl-no-#{System.unique_integer([:positive])}")

      caller_part = seed_agent_participant(participating, caller)
      other_part = seed_agent_participant(restricted, other)

      _allowed = seed_message(participating, caller_part, "watermelon harvest report shared")
      _denied = seed_message(restricted, other_part, "watermelon harvest report private")

      {:ok, %{results: results}} =
        Search.search("watermelon harvest", agent: caller, source: "message", limit: 10)

      assert length(results) == 1
      [hit] = results
      assert hit.space_id == participating.id
    end

    test "semantic message hit in a non-participant space is dropped post-fusion" do
      caller = create_agent("caller")
      other = create_agent("other")

      participating = seed_space("acl-sem-yes-#{System.unique_integer([:positive])}")
      restricted = seed_space("acl-sem-no-#{System.unique_integer([:positive])}")

      caller_part = seed_agent_participant(participating, caller)
      other_part = seed_agent_participant(restricted, other)

      allowed_msg = seed_message(participating, caller_part, "kiwi nectar pricing data")
      denied_msg = seed_message(restricted, other_part, "kiwi nectar pricing secret")

      # Semantic stub returns BOTH ids tagged as messages. The ACL
      # filter must drop the restricted hit even though semantic
      # routed it through.
      install_provider([
        %{entry_id: denied_msg.id, score: 0.99, memory_type: "message"},
        %{entry_id: allowed_msg.id, score: 0.90, memory_type: "message"}
      ])

      # Memory.search by default doesn't carry messages — the semantic
      # corpus tagging falls back to :page. We assert here that the
      # *lexical* message channel still respects ACL (the
      # primary contract). The semantic-message path is exercised via
      # the bulk_load_messages drop in the next assertion.
      {:ok, %{results: results, dropped: dropped}} =
        Search.search("kiwi nectar", agent: caller, source: "message", limit: 10)

      ids = Enum.map(results, & &1.id)
      refute denied_msg.id in ids
      assert allowed_msg.id in ids

      # Neither refusal happens at hydration: the "message"-tagged
      # semantic hits are refused at classification (no message corpus in
      # `semantic_corpus/1`) and the lexical message channel only ever
      # queries the caller's own spaces. So nothing reaches `hydrate_one/2`
      # to be counted — `dropped` stays zero. The hydration-time ACL count
      # is pinned by the private-page test in "hydration drops orphans and
      # counts them".
      assert dropped == %{page: 0, journal: 0, message: 0, task: 0}
    end

    test "anonymous caller (no agent) gets zero message hits" do
      noop_provider()

      caller = create_agent("solo")
      space = seed_space("anon-#{System.unique_integer([:positive])}")
      part = seed_agent_participant(space, caller)

      seed_message(space, part, "guava chutney production line")

      {:ok, %{results: results}} = Search.search("guava chutney", source: "message", limit: 10)

      assert results == []
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 9. Truncation flag — channel cap hit
  ## ─────────────────────────────────────────────────────────────────────

  describe "truncation flag" do
    test "truncated: true when a lexical channel hits 2*limit cap" do
      noop_provider()

      for n <- 1..50 do
        seed_page("org/page/cap-#{n}.md", "passionfruit harvest passionfruit yield")
      end

      {:ok, %{truncated: truncated, results: results, dead_channels: dead}} =
        Search.search("passionfruit", source: "page", limit: 20)

      # cap is 2 * limit = 40; we seeded 50 → cap hit → truncated true
      assert truncated == true
      assert length(results) == 20
      # ...and the flag comes from the cap, not from a dead channel.
      assert dead == []
    end

    test "truncated: false when channels return well under cap" do
      noop_provider()

      seed_page("org/page/lone.md", "rambutan smoothie recipe")

      {:ok, %{truncated: false, results: results, dead_channels: []}} =
        Search.search("rambutan", source: "page", limit: 20)

      assert length(results) == 1
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 10. Noop provider — lexical-only path still works
  ## ─────────────────────────────────────────────────────────────────────

  describe "Noop provider fall-through" do
    test "search still returns lexical hits when memory service is unavailable" do
      noop_provider()

      seed_page("org/page/n.md", "blueberry muffin recipe deluxe")

      assert {:ok,
              %{
                results: [%{source: "page", content: "blueberry muffin recipe deluxe"}],
                fusion_constant_k: 60
              }} = Search.search("blueberry muffin", limit: 5)
    end

    test "Noop semantic channel is empty, NOT dead: no dead_channels, zero drops, not truncated" do
      noop_provider()

      seed_page("org/page/n2.md", "cloudberry compote recipe")

      assert {:ok,
              %{
                truncated: false,
                dead_channels: [],
                dropped: %{page: 0, journal: 0, message: 0, task: 0},
                results: [%{source: "page"}]
              }} = Search.search("cloudberry compote", limit: 5)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## 11. Task corpus (stage 3 of task 019f3dbb)
  ## ─────────────────────────────────────────────────────────────────────

  describe "task corpus" do
    test "source: \"task\" returns task hits and excludes pages / journal / messages" do
      noop_provider()

      agent = create_agent("t")
      space = seed_space("task-source-#{System.unique_integer([:positive])}")
      participant = seed_agent_participant(space, agent)

      seed_page("org/page/orange.md", "orange fanta recipe canonical")
      seed_journal(Date.utc_today(), "orange fanta harvest journal")
      seed_message(space, participant, "any word on orange fanta rollout?")
      {:ok, project} = Platform.Tasks.create_project(%{name: "OrangeCo"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Ship orange fanta migration",
          description: "the rollout plan"
        })

      {:ok, %{results: results}} =
        Search.search("orange fanta", agent: agent, source: "task", limit: 10)

      assert Enum.all?(results, &(&1.source == "task"))
      assert Enum.find(results, &(&1.id == task.id))
    end

    test "unset source returns fused hits across all four corpora" do
      noop_provider()

      agent = create_agent("f")
      space = seed_space("fuse-#{System.unique_integer([:positive])}")
      participant = seed_agent_participant(space, agent)

      seed_page("org/page/apricot.md", "apricot syrup deluxe recipe")
      seed_journal(Date.utc_today(), "apricot syrup harvest journal")
      seed_message(space, participant, "have we tried apricot syrup?")
      {:ok, project} = Platform.Tasks.create_project(%{name: "ApricotCo"})

      {:ok, _task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Investigate apricot syrup vendor",
          description: "supplier research"
        })

      {:ok, %{results: results}} =
        Search.search("apricot syrup", agent: agent, limit: 20)

      sources = results |> Enum.map(& &1.source) |> MapSet.new()
      assert "page" in sources
      assert "journal" in sources
      assert "message" in sources
      assert "task" in sources
    end

    test "task hit carries advisory status/priority/updated_at/merged_pr_url/follow_up_task_ids/cancellation_note" do
      noop_provider()

      {:ok, project} = Platform.Tasks.create_project(%{name: "AdvisoryCo"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Task with advisory fields",
          description: "carries stage-3 payload",
          priority: "high"
        })

      {:ok, %{results: [hit]}} =
        Search.search("advisory fields", source: "task", limit: 5)

      assert hit.source == "task"
      assert hit.id == task.id
      # All six advisory keys must be present (nil is fine for URL /
      # cancellation_note when unstamped — but the keys must exist so
      # agent code can Map.get without a defensive Map.has_key? guard).
      assert Map.has_key?(hit, :status)
      assert Map.has_key?(hit, :priority)
      assert Map.has_key?(hit, :updated_at)
      assert Map.has_key?(hit, :merged_pr_url)
      assert Map.has_key?(hit, :follow_up_task_ids)
      assert Map.has_key?(hit, :cancellation_note)
      assert hit.status == "backlog"
      assert hit.priority == "high"
      assert hit.merged_pr_url == nil
      assert hit.follow_up_task_ids == []
      assert hit.cancellation_note == nil
    end

    test "cancellation_note is populated for cancelled tasks with metadata[\"cancellation_note\"]" do
      noop_provider()

      {:ok, project} = Platform.Tasks.create_project(%{name: "CancelledCo"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Task that got cancelled",
          description: "was in flight",
          metadata: %{"cancellation_note" => "rework as a stack member"}
        })

      {:ok, _} = Platform.Tasks.transition_task_status(task, "cancelled")

      {:ok, %{results: results}} =
        Search.search("got cancelled", source: "task", limit: 5)

      hit = Enum.find(results, &(&1.id == task.id))
      refute is_nil(hit)
      assert hit.status == "cancelled"
      assert hit.cancellation_note == "rework as a stack member"
    end

    test "project_id filter excludes tasks from other projects" do
      noop_provider()

      {:ok, project_a} = Platform.Tasks.create_project(%{name: "ProjA"})
      {:ok, project_b} = Platform.Tasks.create_project(%{name: "ProjB"})

      {:ok, task_a} =
        Platform.Tasks.create_task(%{
          project_id: project_a.id,
          title: "Alpha bravo charlie fizzbuzz",
          description: "in project A"
        })

      {:ok, task_b} =
        Platform.Tasks.create_task(%{
          project_id: project_b.id,
          title: "Alpha bravo charlie fizzbuzz",
          description: "in project B"
        })

      {:ok, %{results: results_a}} =
        Search.search("alpha bravo charlie fizzbuzz",
          source: "task",
          project_id: project_a.id,
          limit: 10
        )

      ids_a = Enum.map(results_a, & &1.id)
      assert task_a.id in ids_a
      refute task_b.id in ids_a

      {:ok, %{results: results_b}} =
        Search.search("alpha bravo charlie fizzbuzz",
          source: "task",
          project_id: project_b.id,
          limit: 10
        )

      ids_b = Enum.map(results_b, & &1.id)
      assert task_b.id in ids_b
      refute task_a.id in ids_b
    end

    test "soft-deleted tasks are dropped from hits" do
      noop_provider()

      {:ok, project} = Platform.Tasks.create_project(%{name: "SoftDelCo"})

      {:ok, live} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Live task raspberry gizmo",
          description: "still around"
        })

      {:ok, doomed} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Doomed task raspberry gizmo",
          description: "will be soft-deleted"
        })

      {:ok, _} = Platform.Tasks.soft_delete_task(doomed)

      {:ok, %{results: results}} =
        Search.search("raspberry gizmo", source: "task", limit: 10)

      ids = Enum.map(results, & &1.id)
      assert live.id in ids
      refute doomed.id in ids
    end

    test "semantic-tagged task hits are routed to the task corpus" do
      # Semantic channel returns a task-tagged hit — it must fuse under
      # the :task corpus and hydrate through bulk_load_tasks, not fall
      # back to the :page default.
      {:ok, project} = Platform.Tasks.create_project(%{name: "SemCo"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Semantic-hit target durian shake",
          description: "flavor investigation"
        })

      install_provider([
        %{entry_id: task.id, score: 0.9, memory_type: "task"}
      ])

      {:ok, %{results: results}} =
        Search.search("durian shake", source: "task", limit: 5)

      hit = Enum.find(results, &(&1.id == task.id))
      refute is_nil(hit)
      assert hit.source == "task"
      # Semantic + lexical → both ranks populated.
      assert hit.semantic_rank == 1
      assert is_integer(hit.lexical_rank)
    end
  end
end
