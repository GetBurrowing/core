defmodule Platform.Federation.ToolSurfaceMemorySearchBoundTest do
  @moduledoc """
  The `memory_search` MCP head must return a payload an agent can actually
  consume in one tool result.

  `Platform.Org.Wiki.Search.search/2` hydrates each hit with the FULL page
  body. Twenty full org pages serialize to a six-figure JSON string. The
  bound is applied at the MCP dispatch head in
  `Platform.Federation.ToolSurface`, which is what these tests drive —
  the same entry point `PlatformWeb.MCPController` calls.

  Anti-vacuity notes, because a smaller test here would prove nothing:

    * The fixture is sized to the WRONG answer. 25 pages of ~8_000
      characters each means an unbounded 20-hit result is >160_000
      characters and MUST blow the bound. A three-small-page fixture
      passes on the broken code.
    * The load-bearing assertions are STRUCTURE and SIZE, never content
      presence — `payload =~ "something"` is true of the broken payload
      too. Size is asserted against `Jason.encode!/1`, the same
      serialization the controller performs, not against the Elixir term.
    * Every fixture page is synthetic generated filler. `core` is a
      public repo and org-memory content is organizational; no retrieved
      memory content, hostnames, ids, or names appear here.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo

  # Mirrors the module attributes on the tool surface. Restated here on
  # purpose: the test pins the contract, it does not read it back from the
  # implementation (which would make the assertion true by construction).
  @snippet_chars 500
  @max_payload_bytes 20_000

  @page_count 25
  @page_body_chars 8_000

  # A nonsense token that appears in every seeded body and nowhere else in
  # the corpus, so the query cannot accidentally match real fixture rows
  # left behind by another suite.
  @marker "zarquonium"

  setup do
    # Noop memory provider: no vector index in test, so the lexical
    # channels are the only contributors. The bound sits downstream of
    # fusion, so this does not weaken what is being asserted.
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    :ok
  end

  ## ── Fixtures ─────────────────────────────────────────────────────────

  # Synthetic filler only. `word` is repeated until the body clears
  # `@page_body_chars`; nothing here is derived from real memory content.
  defp filler(word, chars) do
    word
    |> Kernel.<>(" ")
    |> String.duplicate(div(chars, String.length(word) + 1) + 1)
    |> String.slice(0, chars)
  end

  defp seed_pages(marker) do
    for i <- 1..@page_count do
      body = marker <> " " <> filler("lorem ipsum dolor sit amet consectetur", @page_body_chars)

      # Guard the guard: if the fixture ever shrinks below the size that
      # makes this test able to fail, say so loudly rather than pass.
      assert String.length(body) >= @page_body_chars,
             "fixture page #{i} is only #{String.length(body)} chars — too small to blow the bound"

      {:ok, page} =
        Wiki.upsert_page("org/page/synthetic-bound-#{i}.md", %{content: body})

      page
    end
  end

  defp create_agent do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "bound-test-#{System.unique_integer([:positive, :monotonic])}",
        name: "BoundTestAgent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  defp search(query, agent) do
    {:ok, envelope} = raw_search(query, agent)
    envelope
  end

  # Unwrapped dispatch: the degraded branches return `{:error, _}`, which
  # `search/2` would match-fail on.
  defp raw_search(query, agent) do
    ToolSurface.execute(
      "memory_search",
      %{"query" => query, "source" => "page"},
      %{agent_id: agent.id}
    )
  end

  ## ── Shared assertions ────────────────────────────────────────────────

  defp assert_bounded(envelope, label) do
    %{results: results} = envelope

    assert is_list(results), "#{label}: results is not a list — got #{inspect(results)}"
    assert results != [], "#{label}: fixture produced no hits, so the bound was never exercised"

    Enum.each(results, fn hit ->
      assert is_map(hit), "#{label}: hit is not a map — got #{inspect(hit)}"

      assert String.length(hit.content) <= @snippet_chars,
             "#{label}: hit #{inspect(hit.path)} content is #{String.length(hit.content)} chars, over the #{@snippet_chars} snippet bound"

      assert is_binary(hit.path) and hit.path != "",
             "#{label}: page hit has no path, so it cannot be fetched with memory_view — #{inspect(hit)}"
    end)

    encoded = Jason.encode!(envelope)

    assert byte_size(encoded) <= @max_payload_bytes,
           "#{label}: encoded payload is #{byte_size(encoded)} bytes over #{length(results)} hits, above the #{@max_payload_bytes} byte bound"

    encoded
  end

  ## ── Cases ────────────────────────────────────────────────────────────

  test "hybrid channel: payload and per-hit snippets stay inside the bound" do
    seed_pages(@marker)
    agent = create_agent()

    envelope = search(@marker, agent)

    assert_bounded(envelope, "hybrid")

    # The bodies WERE oversized — proves the snippet did work rather than
    # the fixture happening to be small.
    assert Enum.all?(envelope.results, & &1.content_truncated),
           "expected every oversized fixture hit to report content_truncated"

    assert Enum.all?(envelope.results, &(&1.content_length >= @page_body_chars)),
           "content_length should report the ORIGINAL body size, got: #{inspect(Enum.map(envelope.results, & &1.content_length))}"
  end

  test "lexical ilike fallback channel is bounded identically" do
    # A marker embedded inside a longer word: `websearch_to_tsquery` will
    # not match the substring, so `ilike_pages_fallback/3` is the channel
    # that produces these hits.
    seed_pages("xxqqz" <> @marker <> "zzqqx")
    agent = create_agent()

    envelope = search(@marker, agent)

    assert_bounded(envelope, "ilike fallback")
  end

  test "both channels produce the same payload shape" do
    agent = create_agent()

    seed_pages(@marker)
    hybrid = search(@marker, agent)

    Repo.delete_all(WikiPage)
    seed_pages("xxqqz" <> @marker <> "zzqqx")
    fallback = search(@marker, agent)

    hybrid_keys = hybrid.results |> hd() |> Map.keys() |> Enum.sort()
    fallback_keys = fallback.results |> hd() |> Map.keys() |> Enum.sort()

    assert hybrid_keys == fallback_keys,
           "channels disagree on hit shape — hybrid #{inspect(hybrid_keys)} vs fallback #{inspect(fallback_keys)}"

    assert Map.keys(hybrid) |> Enum.sort() == Map.keys(fallback) |> Enum.sort(),
           "channels disagree on envelope shape"
  end

  test "a hit's path round-trips through memory_view" do
    seed_pages(@marker)
    agent = create_agent()

    envelope = search(@marker, agent)
    hit = hd(envelope.results)

    {:ok, viewed} =
      ToolSurface.execute("memory_view", %{"path" => hit.path}, %{agent_id: agent.id})

    body = viewed[:content] || viewed["content"]

    assert is_binary(body), "memory_view returned no body for #{hit.path}: #{inspect(viewed)}"

    assert String.length(body) >= @page_body_chars,
           "memory_view returned #{String.length(body)} chars — the full body should be reachable even though search snippets it"
  end

  # A crashing semantic provider: the search must survive it and the
  # MCP envelope must carry the dead channel in a JSON-encodable shape.
  # No network — the stub exits on purpose.
  defmodule CrashingProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, _config), do: exit(:boom)

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_c), do: :ok
  end

  # The ERROR path (task 01a0a730). Distinct from CrashingProvider above:
  # this provider does not exit, it ANSWERS with `{:error, reason}` —
  # a refused connection or a 5xx from memory-service. Before stage 1 that
  # return collapsed to `[]` and was indistinguishable from "found
  # nothing"; it is the configuration that produced the original bug.
  defmodule ErroringProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, _config), do: {:error, :econnrefused}

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_c), do: :ok
  end

  test "a semantic provider answering with an error yields the degraded envelope, not retrieval_status ok" do
    seed_pages(@marker)
    agent = create_agent()

    Application.put_env(:platform, :memory_service, provider: ErroringProvider)

    assert {:ok, payload} = raw_search(@marker, agent)

    # Acceptance line 1 of the ticket, as an executable assertion. The
    # pre-fix measurement was `retrieval_status: "ok"` with a `results`
    # key and `dead_channels: []` — if any of these four flip back, the
    # error return has stopped reaching the degraded branch.
    refute Map.has_key?(payload, :results),
           "an errored semantic channel must not produce a `results` key — the hits are partial"

    assert payload.retrieval_status == "degraded"
    assert payload.partial_results != []
    assert payload.degraded.channels_down == ["semantic"]
    assert payload.degraded.dead_channels == [[:semantic, :all]]
    assert payload.truncated == true

    # Same JSON rendering as the crash path: the pair, not a tuple.
    assert Jason.decode!(Jason.encode!(payload))["dead_channels"] == [["semantic", "all"]]
  end

  test "an errored semantic channel with zero surviving hits is {:error, code: :search_degraded}" do
    seed_pages(@marker)
    agent = create_agent()

    Application.put_env(:platform, :memory_service, provider: ErroringProvider)

    assert {:error, error} = raw_search("qwfpgjluyzxcv", agent)

    assert error.code == :search_degraded
    assert error.dead_channels == [[:semantic, :all]]

    # An empty `results: []` here would read as an established absence,
    # which is precisely what a failed measurement is not.
    refute Map.has_key?(error, :results)
    refute Map.has_key?(error, :partial_results)
  end

  test "dead_channels and dropped ride through alongside truncated, JSON-safe" do
    seed_pages(@marker)
    agent = create_agent()

    envelope = search(@marker, agent)

    assert envelope.dead_channels == []
    assert envelope.dropped == %{page: 0, journal: 0, message: 0, task: 0}
    assert envelope.truncated == false

    Application.put_env(:platform, :memory_service, provider: CrashingProvider)

    dead = search(@marker, agent)

    # Tuples cannot be JSON-encoded; the head renders the label as a pair.
    assert dead.dead_channels == [[:semantic, :all]]
    assert dead.truncated == true

    # A degraded search carries its hits under `partial_results`; the
    # `results` key does not exist. See the degraded tests below.
    assert dead.partial_results != []
    refute Map.has_key?(dead, :results)

    assert Jason.decode!(Jason.encode!(dead))["dead_channels"] == [["semantic", "all"]]
  end

  test "a degraded search with zero hits returns {:error, code: :search_degraded} and carries no results key" do
    seed_pages(@marker)
    agent = create_agent()

    Application.put_env(:platform, :memory_service, provider: CrashingProvider)

    assert {:error, error} = raw_search("qwfpgjluyzxcv", agent)

    assert error.code == :search_degraded
    assert error.recoverable == true
    assert error.dead_channels == [[:semantic, :all]]

    # No `results` key anywhere: an empty list here is exactly the
    # reading — "nothing exists" — this branch exists to make unreachable.
    refute Map.has_key?(error, :results)
    refute Map.has_key?(error, :partial_results)

    assert error.error =~ "FAILED MEASUREMENT"
    assert error.error =~ "semantic"
    assert error.suggestion =~ "limit"
  end

  test "a degraded search with surviving hits returns partial_results and NO results key" do
    seed_pages(@marker)
    agent = create_agent()

    Application.put_env(:platform, :memory_service, provider: CrashingProvider)

    assert {:ok, envelope} = raw_search(@marker, agent)

    assert envelope.retrieval_status == "degraded"
    assert is_list(envelope.partial_results)
    assert envelope.partial_results != []

    refute Map.has_key?(envelope, :results),
           "a degraded envelope must not carry a `results` key — the hits are partial"

    assert envelope.truncated == true
    assert envelope.degraded.dead_channels == [[:semantic, :all]]
    assert envelope.degraded.channels_down == ["semantic"]
    assert envelope.degraded.implication =~ "absence is not established"

    # Still JSON-encodable end to end, like the healthy envelope.
    decoded = Jason.decode!(Jason.encode!(envelope))
    refute Map.has_key?(decoded, "results")
    assert decoded["retrieval_status"] == "degraded"
  end

  test "a healthy search returns retrieval_status ok, a results key, and NO degraded key" do
    seed_pages(@marker)
    agent = create_agent()

    assert {:ok, envelope} = raw_search(@marker, agent)

    assert envelope.retrieval_status == "ok"
    assert is_list(envelope.results)
    assert envelope.results != []
    assert envelope.dead_channels == []

    # The anti-polarity-flip assertion: if the degraded surfacing ever
    # fires unconditionally, the fix becomes "every search now warns",
    # which is the same blindness with the polarity reversed.
    refute Map.has_key?(envelope, :degraded)
    refute Map.has_key?(envelope, :partial_results)

    # A healthy search that matches nothing is an ordinary negative
    # result and must stay just as calm.
    assert {:ok, empty} = raw_search("qwfpgjluyzxcv", agent)
    assert empty.retrieval_status == "ok"
    assert empty.results == []
    refute Map.has_key?(empty, :degraded)
  end

  test "an empty result set caused only by the payload byte bound is NOT reported as search_degraded" do
    seed_pages(@marker)
    agent = create_agent()

    # Shrink the transport budget below one hit so the byte bound empties
    # the kept list. Real fixtures cannot reach this state: a 500-char
    # snippet is ~1 KB against a 20 KB budget.
    Application.put_env(:platform, :memory_search_max_payload_bytes, 120)
    on_exit(fn -> Application.delete_env(:platform, :memory_search_max_payload_bytes) end)

    # Healthy channels: an emptied list is still an ok payload.
    assert {:ok, healthy} = raw_search(@marker, agent)
    assert healthy.retrieval_status == "ok"
    assert healthy.results == []
    assert healthy.payload_truncated == true

    # The ordering guard proper. The search DID return hits; only the
    # transport bound emptied them. Deciding degraded-vs-partial on the
    # kept list instead of the pre-bound list would turn this into a
    # `:search_degraded` error — a false positive with the same signature
    # as a genuinely dead channel.
    Application.put_env(:platform, :memory_service, provider: CrashingProvider)

    assert {:ok, degraded} = raw_search(@marker, agent),
           "a byte-bound artefact must not masquerade as a dead-channel failure"

    assert degraded.retrieval_status == "degraded"
    assert degraded.partial_results == []
    assert degraded.payload_truncated == true
  end

  test "a query matching nothing returns an empty LIST, not an empty string" do
    seed_pages(@marker)
    agent = create_agent()

    envelope = search("qwfpgjluyzxcv", agent)

    assert is_list(envelope.results),
           "no-hit results must be a list — got #{inspect(envelope.results)}"

    assert envelope.results == []
    assert Map.has_key?(envelope, :fusion_constant_k), "envelope lost its normal keys on no hits"
  end
end
