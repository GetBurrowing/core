defmodule Platform.Org.Wiki.IndexerTest do
  @moduledoc """
  Stage-3 unit tests for `Platform.Org.Wiki.Indexer`.

  These tests start an Indexer process explicitly per case (the test-mode
  gate added in stage 4 keeps the supervisor from starting one). Each
  test wires a stub provider that captures calls so we can assert ingest
  / delete shape and verify dedupe + retry semantics without the
  memory-service HTTP path.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Indexer
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  # A controllable provider — each case spawns its own owner pid and
  # routes captures to it. The mailbox is the test process.
  defmodule StubProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, config) do
      target = Keyword.fetch!(config, :test_pid)
      send(target, {:ingest, entries})

      case Keyword.get(config, :ingest_response, {:ok, length(entries)}) do
        fun when is_function(fun, 0) -> fun.()
        other -> other
      end
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, config) do
      target = Keyword.fetch!(config, :test_pid)
      send(target, {:delete, ids})

      case Keyword.get(config, :delete_response, {:ok, length(ids)}) do
        fun when is_function(fun, 0) -> fun.()
        other -> other
      end
    end

    @impl true
    def health(_c), do: :ok
  end

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: StubProvider,
      test_pid: self()
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  defp start_indexer!(opts \\ []) do
    # Short tick to keep tests fast; tests can override per-case.
    # Indexer registers under its module name by default — we keep
    # that so `Process.whereis(Indexer)` works in tests.
    default = [tick_ms: 50, retry_initial_ms: 50, retry_max_ms: 200]
    start_supervised!({Indexer, Keyword.merge(default, opts)})
  end

  describe "subscribe + dedupe" do
    test "consumes :wiki_page_written and emits one ingest with memory_type \"page\"" do
      pid = start_indexer!()
      assert is_pid(pid)

      {:ok, _page} = Wiki.upsert_page("org/a.md", %{content: "hello"})

      assert_receive {:ingest, [%{memory_type: "page", content: "hello"}]}, 1_000
    end

    test "dedupes two writes to the same page within a tick — one ingest, latest content" do
      pid = start_indexer!(tick_ms: 100)
      assert is_pid(pid)

      {:ok, _v1} = Wiki.upsert_page("org/dedupe.md", %{content: "v1"})
      {:ok, _v2} = Wiki.upsert_page("org/dedupe.md", %{content: "v2"})

      # Wait for the single flush.
      assert_receive {:ingest, entries}, 1_000
      assert [%{content: "v2", memory_type: "page", metadata: %{"version" => 2}}] = entries

      # No second ingest in the window after.
      refute_receive {:ingest, _}, 300
    end

    test "mixed page + journal in same tick: ingest splits per corpus" do
      _pid = start_indexer!(tick_ms: 100)

      {:ok, _} = Wiki.upsert_page("org/mixed.md", %{content: "page body"})
      {:ok, _} = Journal.append(%{content: "journal body", date: ~D[2026-05-19]})

      # Two separate ingest calls: one pages corpus, one journal corpus.
      assert_receive {:ingest, [%{memory_type: "page"}]}, 1_000
      assert_receive {:ingest, [%{memory_type: "journal"}]}, 1_000
    end

    test "delete-then-upsert in same tick: upsert wins" do
      _pid = start_indexer!(tick_ms: 100)

      {:ok, page} = Wiki.upsert_page("org/flip.md", %{content: "v1"})
      Indexer.flush_now()
      assert_receive {:ingest, [_]}, 1_000

      # Now: a delete event then a write event for the same id within
      # one tick window. Pages map ends with the id present; deletes
      # is empty.
      send(Process.whereis(Indexer), {:wiki_page_deleted, %{page_id: page.id}})

      send(
        Process.whereis(Indexer),
        {:wiki_page_written, %{page_id: page.id}}
      )

      Indexer.flush_now()

      # We expect ONE ingest (the upsert) and NO delete call.
      assert_receive {:ingest, _}, 1_000
      refute_receive {:delete, _}, 300
    end

    test "upsert-then-delete in same tick: delete wins" do
      _pid = start_indexer!(tick_ms: 100)

      {:ok, page} = Wiki.upsert_page("org/flop.md", %{content: "to be deleted"})

      # Immediately delete before the flush timer fires. Hand-fed event
      # ordering so we don't race the real PubSub broadcaster.
      send(
        Process.whereis(Indexer),
        {:wiki_page_deleted, %{page_id: page.id}}
      )

      Indexer.flush_now()

      # Expect ONE delete with the page id, and NO ingest.
      assert_receive {:delete, [delete_id]}, 1_000
      assert delete_id == to_string(page.id)
      refute_receive {:ingest, _}, 300
    end
  end

  describe "race safety" do
    test "page deleted between event and flush — Repo.get returns nil; flush skips silently" do
      _pid = start_indexer!(tick_ms: 100)

      {:ok, page} = Wiki.upsert_page("org/gone.md", %{content: "soon to be gone"})

      # Hard-delete via Repo to simulate the row vanishing between
      # event broadcast and flush.
      Repo.delete!(page)

      # Now manually fire a stale :wiki_page_written for the dead id.
      send(
        Process.whereis(Indexer),
        {:wiki_page_written, %{page_id: page.id}}
      )

      Indexer.flush_now()

      # Indexer must NOT crash and must NOT call ingest with a stale row.
      assert Process.alive?(Process.whereis(Indexer))
      refute_receive {:ingest, _}, 300
    end
  end

  describe "retry / backoff" do
    test "transient ingest failure re-enqueues; indexer stays alive" do
      # First call fails, subsequent calls succeed. Use a counter agent
      # so the stub's response varies across invocations.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      response = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: {:error, :timeout}, else: {:ok, 1}
      end

      Application.put_env(:platform, :memory_service,
        provider: StubProvider,
        test_pid: self(),
        ingest_response: response
      )

      _pid = start_indexer!(tick_ms: 50, retry_initial_ms: 50, retry_max_ms: 200)

      {:ok, _page} = Wiki.upsert_page("org/retry.md", %{content: "retry me"})

      # Two ingest calls — first fails, second succeeds.
      assert_receive {:ingest, _}, 1_000
      assert_receive {:ingest, _}, 2_000

      # Indexer alive throughout.
      assert Process.alive?(Process.whereis(Indexer))

      # State has empty pending after the successful retry.
      Indexer.flush_now()
      state = Indexer.state()
      assert state.pending_pages == %{}
      assert state.retry_attempts.pages == 0
    end
  end

  describe "disabled (Noop) provider" do
    test "events are consumed but no ingest/delete calls happen" do
      # Use the real Noop module (which is a no-op behaviour impl).
      Application.put_env(:platform, :memory_service,
        provider: Platform.Memory.Providers.Noop,
        test_pid: self()
      )

      _pid = start_indexer!(tick_ms: 50)

      {:ok, _} = Wiki.upsert_page("org/disabled.md", %{content: "x"})
      {:ok, _} = Journal.append(%{content: "y", date: ~D[2026-05-19]})

      Indexer.flush_now()

      # No ingest, no delete (the Noop module doesn't message us; the
      # StubProvider isn't in the chain at all here).
      refute_receive {:ingest, _}, 300
      refute_receive {:delete, _}, 300

      # Pending sets drained.
      state = Indexer.state()
      assert state.pending_pages == %{}
      assert state.pending_journal == %{}
      assert state.pending_deletes == %{}
      assert Process.alive?(Process.whereis(Indexer))
    end
  end

  describe "telemetry" do
    test "emits :flushed event with corpus counts and latency" do
      ref = make_ref()

      :telemetry.attach(
        "wiki-indexer-flushed-#{inspect(ref)}",
        [:platform, :org, :wiki_indexer, :flushed],
        fn _e, m, _md, pid -> send(pid, {:flushed_telemetry, ref, m}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("wiki-indexer-flushed-#{inspect(ref)}") end)

      _pid = start_indexer!(tick_ms: 50)

      {:ok, _} = Wiki.upsert_page("org/tele.md", %{content: "x"})

      assert_receive {:ingest, _}, 1_000

      assert_receive {:flushed_telemetry, ^ref,
                      %{pages_count: 1, journal_count: 0, deletes_count: 0, latency_us: latency}},
                     1_000

      assert is_integer(latency) and latency >= 0
    end
  end
end
