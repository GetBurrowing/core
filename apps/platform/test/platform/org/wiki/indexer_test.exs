defmodule Platform.Org.Wiki.IndexerTest.CountingIngestPlug do
  @moduledoc """
  A real memory-service stand-in for the 01a0d8c9 incident repro: reports
  every `POST /ingest` (with its entry ids) to the test process on ARRIVAL,
  then sleeps before answering. A `Req.Test` stub would not enforce the
  provider's receive_timeout, so the repro needs a real socket.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    ids = raw |> Jason.decode!() |> Map.get("entries", []) |> Enum.map(& &1["id"])
    send(Keyword.fetch!(opts, :test_pid), {:ingest_request, ids})

    Process.sleep(Keyword.fetch!(opts, :sleep_ms))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"ingested" => length(ids)}))
  end
end

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

      # `:timeout` is a receive timeout, which now carries a backoff floor
      # (task 01a0d8c9); keep the floor small so the retry lands in-window.
      _pid =
        start_indexer!(
          tick_ms: 50,
          retry_initial_ms: 50,
          retry_max_ms: 200,
          retry_timeout_floor_ms: 50
        )

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

  describe "supervision" do
    test "restarts under a one_for_one supervisor and re-subscribes" do
      # Start the indexer under a local Supervisor with restart: :permanent
      # so we can verify it self-recovers (the real Application.start/2
      # tree uses the same strategy).
      sup_opts = [strategy: :one_for_one]

      {:ok, sup} =
        Supervisor.start_link(
          [
            Supervisor.child_spec(
              {Indexer, tick_ms: 50, retry_initial_ms: 50, retry_max_ms: 200},
              restart: :permanent
            )
          ],
          sup_opts
        )

      on_exit(fn ->
        # The supervisor isn't ExUnit-managed (we didn't use
        # start_supervised), so tear it down manually. Use :shutdown
        # since :normal would race the indexer's restart logic.
        if Process.alive?(sup) do
          ref = Process.monitor(sup)
          Process.exit(sup, :shutdown)

          receive do
            {:DOWN, ^ref, :process, ^sup, _} -> :ok
          after
            1_000 -> :ok
          end
        end
      end)

      pid_before = Process.whereis(Indexer)
      assert is_pid(pid_before) and Process.alive?(pid_before)

      # First write — confirm the subscription is live.
      {:ok, _} = Wiki.upsert_page("org/restart-pre.md", %{content: "before"})
      assert_receive {:ingest, _}, 1_000

      # Kill the indexer; the supervisor restarts it.
      ref = Process.monitor(pid_before)
      Process.exit(pid_before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_before, :killed}, 1_000

      # Wait for the supervisor to bring up the replacement.
      pid_after = wait_for_indexer_restart(pid_before, 1_000)
      assert is_pid(pid_after)
      assert pid_after != pid_before
      assert Process.alive?(pid_after)

      # Second write — confirm the new indexer re-subscribed at init/1
      # (otherwise it would never see this event).
      {:ok, _} = Wiki.upsert_page("org/restart-post.md", %{content: "after"})
      assert_receive {:ingest, _}, 1_000
    end

    defp wait_for_indexer_restart(old_pid, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_for_restart(old_pid, deadline)
    end

    defp do_wait_for_restart(old_pid, deadline) do
      case Process.whereis(Indexer) do
        nil ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("Indexer did not restart within timeout")
          else
            Process.sleep(20)
            do_wait_for_restart(old_pid, deadline)
          end

        ^old_pid ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("Indexer pid unchanged after kill")
          else
            Process.sleep(20)
            do_wait_for_restart(old_pid, deadline)
          end

        pid when is_pid(pid) ->
          pid
      end
    end
  end

  describe "end-to-end via the real PubSub topic" do
    test "Wiki.upsert_page → indexer ingest with memory_type \"page\"" do
      _pid = start_indexer!(tick_ms: 50)

      {:ok, _} = Wiki.upsert_page("org/e2e-page.md", %{content: "page body"})

      assert_receive {:ingest,
                      [
                        %{
                          memory_type: "page",
                          content: "page body",
                          metadata: %{"file_key" => "org/e2e-page.md"}
                        }
                      ]},
                     1_000
    end

    test "Journal.append → indexer ingest with memory_type \"journal\"" do
      _pid = start_indexer!(tick_ms: 50)

      {:ok, _} = Journal.append(%{content: "journal body", date: ~D[2026-05-19]})

      assert_receive {:ingest, [%{memory_type: "journal", content: "journal body"}]},
                     1_000
    end

    test "upsert then delete → ingest followed by delete with the page id" do
      _pid = start_indexer!(tick_ms: 50)

      {:ok, page} = Wiki.upsert_page("org/round-trip.md", %{content: "initial"})

      assert_receive {:ingest, _}, 1_000

      {:ok, _} = Wiki.delete_page("org/round-trip.md")

      assert_receive {:delete, [id]}, 1_000
      assert id == to_string(page.id)
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

  describe "resend on receive timeout (task 01a0d8c9)" do
    defp use_stub_response(response) do
      Application.put_env(:platform, :memory_service,
        provider: StubProvider,
        test_pid: self(),
        ingest_response: response
      )
    end

    @timeout_error {:error, %Req.TransportError{reason: :timeout}}

    test "a receive timeout holds the page for retry_timeout_floor_ms; a journal event does not resend it" do
      use_stub_response(@timeout_error)
      _pid = start_indexer!(retry_timeout_floor_ms: 1_000)

      {:ok, page} = Wiki.upsert_page("org/floor.md", %{content: "big page"})
      page_id = to_string(page.id)
      assert_receive {:ingest, [%{id: ^page_id, memory_type: "page"}]}, 1_000

      {:ok, _} = Journal.append(%{content: "unrelated", date: ~D[2026-09-25]})
      assert_receive {:ingest, [%{memory_type: "journal"}]}, 1_000

      # Plain backoff would retry after 50ms; the floor holds it to 1s.
      refute_receive {:ingest, [%{memory_type: "page"} | _]}, 600

      # The hold is released by the page corpus's own retry timer.
      assert_receive {:ingest, [%{id: ^page_id, memory_type: "page"}]}, 1_500
    end

    test "an event-triggered flush does not dispatch a corpus in backoff" do
      # A non-timeout error, so only the plain backoff (1s here) applies:
      # this isolates the per-corpus hold from the timeout floor.
      use_stub_response({:error, :econnrefused})
      _pid = start_indexer!(retry_initial_ms: 1_000, retry_max_ms: 1_000)

      {:ok, page} = Wiki.upsert_page("org/hold.md", %{content: "held page"})
      page_id = to_string(page.id)
      assert_receive {:ingest, [%{id: ^page_id}]}, 1_000

      {:ok, _} = Journal.append(%{content: "unrelated", date: ~D[2026-09-25]})
      assert_receive {:ingest, [%{memory_type: "journal"}]}, 1_000

      refute_receive {:ingest, [%{memory_type: "page"} | _]}, 500
      assert Indexer.state().pending_pages |> Map.has_key?(page.id)

      # A page written during the hold waits for the retry, and goes with it.
      {:ok, page2} = Wiki.upsert_page("org/hold-2.md", %{content: "second page"})
      page2_id = to_string(page2.id)
      refute_receive {:ingest, [%{memory_type: "page"} | _]}, 200

      assert_receive {:ingest, [%{memory_type: "page"} | _] = entries}, 1_500
      assert entries |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([page_id, page2_id])
    end

    test "retries are bounded by max_attempts: terminal log, :gave_up telemetry, ids dropped" do
      use_stub_response(@timeout_error)
      ref = make_ref()
      handler = "wiki-indexer-gave-up-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:platform, :org, :wiki_indexer, :gave_up],
        fn _e, m, md, pid -> send(pid, {:gave_up, ref, m, md}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          _pid =
            start_indexer!(
              max_attempts: 3,
              retry_timeout_floor_ms: 50,
              retry_initial_ms: 50,
              retry_max_ms: 100
            )

          {:ok, page} = Wiki.upsert_page("org/bounded.md", %{content: "never lands"})
          page_id = to_string(page.id)
          send(self(), {:page_id, page_id})

          for _ <- 1..3, do: assert_receive({:ingest, [%{id: ^page_id}]}, 1_000)
          refute_receive {:ingest, _}, 600

          assert_receive {:gave_up, ^ref, %{attempts: 3, count: 1},
                          %{kind: :pages, ids: [gave_up_id]}},
                         100

          assert to_string(gave_up_id) == page_id

          state = Indexer.state()
          assert state.pending_pages == %{}
          assert state.retry_attempts.pages == 0
        end)

      assert_receive {:page_id, page_id}
      assert log =~ "giving up on pages after 3 consecutive failed attempts"
      assert log =~ page_id
      assert log =~ "timeout"
    end
  end

  describe "incident repro over a real socket (task 01a0d8c9)" do
    @tag :slow
    @tag timeout: 60_000
    test "a page ingest slower than 5s is sent exactly once, even with a journal event behind it" do
      port = free_port()

      start_supervised!(
        {Bandit,
         plug:
           {Platform.Org.Wiki.IndexerTest.CountingIngestPlug, test_pid: self(), sleep_ms: 6_000},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: port,
         startup_log: false}
      )

      # The real provider with its DEFAULT ingest timeout: no :timeout and no
      # :ingest_timeout in config. The retry knobs are all minimal, including
      # the timeout floor, so the only thing standing between a 5s timeout
      # and a resend within the window is the ingest timeout itself.
      Application.put_env(:platform, :memory_service,
        provider: Platform.Memory.Providers.MemoryService,
        base_url: "http://127.0.0.1:#{port}"
      )

      _pid =
        start_indexer!(
          retry_initial_ms: 50,
          retry_max_ms: 200,
          retry_timeout_floor_ms: 50
        )

      started = System.monotonic_time(:millisecond)
      {:ok, page} = Wiki.upsert_page("org/slow-page.md", %{content: "slow to embed"})
      page_id = to_string(page.id)
      assert_receive {:ingest_request, [^page_id]}, 2_000

      # An unrelated journal entry while the page request is still sleeping.
      {:ok, entry} = Journal.append(%{content: "unrelated", date: ~D[2026-09-25]})
      entry_id = to_string(entry.id)

      # The first request was consumed above; collect the rest of the window.
      requests = [[page_id] | collect_ingest_requests(started + 8_500)]

      assert Enum.count(requests, &(page_id in &1)) == 1,
             "expected exactly one /ingest carrying the page, got: #{inspect(requests)}"

      # The journal entry was not lost behind the slow page.
      assert Enum.any?(requests, &(entry_id in &1))
    end
  end

  defp collect_ingest_requests(deadline, acc \\ []) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:ingest_request, ids} -> collect_ingest_requests(deadline, [ids | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
