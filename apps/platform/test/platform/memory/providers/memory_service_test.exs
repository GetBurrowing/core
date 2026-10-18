defmodule Platform.Memory.Providers.MemoryServiceTest.SlowPlug do
  @moduledoc """
  A real HTTP endpoint that stalls before answering like memory-service.

  A `Req.Test` stub runs in-process and never touches Finch, so it does not
  enforce `receive_timeout`; a timeout assertion against a stub passes
  whether or not the option is applied (task 01a0d8c9).

  `:sleep_ms` maps a request path to how long that path stalls.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Process.sleep(Map.fetch!(Keyword.fetch!(opts, :sleep_ms), conn.request_path))

    body =
      case conn.request_path do
        "/ingest" -> %{"ingested" => 1}
        "/search" -> %{"results" => []}
        _ -> %{"status" => "ok"}
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end

defmodule Platform.Memory.Providers.MemoryServiceTest do
  use ExUnit.Case, async: true

  alias Platform.Memory.Providers.MemoryService

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    on_exit(fn ->
      Application.delete_env(:platform, :memory_service_req_client)
    end)

    :ok
  end

  defp install_stub(fun) do
    Req.Test.stub(:memory_service_test, fun)

    Application.put_env(
      :platform,
      :memory_service_req_client,
      Req.new(plug: {Req.Test, :memory_service_test})
    )
  end

  defp config(extras \\ []) do
    Keyword.merge([base_url: "http://memory-service:8100", timeout: 1_000], extras)
  end

  describe "ingest/2" do
    test "POSTs /ingest with entries payload and returns the ingested count" do
      test_pid = self()

      install_stub(fn conn ->
        send(test_pid, {:req, conn})
        Req.Test.json(conn, %{"ingested" => 2})
      end)

      entries = [
        %{id: "a", content: "hi", date: "2026-04-16"},
        %{id: "b", content: "yo", date: "2026-04-16"}
      ]

      assert {:ok, 2} = MemoryService.ingest(entries, config())

      assert_receive {:req, conn}
      assert conn.request_path == "/ingest"
      assert conn.method == "POST"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert %{"entries" => [%{"id" => "a"}, %{"id" => "b"}]} = Jason.decode!(body)
    end

    test "passes through arbitrary memory_type strings (e.g. \"page\", \"journal\") unchanged" do
      # T3 (ADR-0041) stamps `memory_type: "page"` and `memory_type: "journal"`
      # on the new corpora. memory-service models.py declares `memory_type:
      # str = "daily"` with no enum constraint, so the value flows through
      # untouched. This guards against a future regression where someone
      # adds a Map.take/2 or whitelist that would strip unknown types.
      test_pid = self()

      install_stub(fn conn ->
        send(test_pid, {:req, conn})
        Req.Test.json(conn, %{"ingested" => 2})
      end)

      entries = [
        %{id: "p1", content: "page content", memory_type: "page", date: "2026-05-19"},
        %{id: "j1", content: "journal content", memory_type: "journal", date: "2026-05-19"}
      ]

      assert {:ok, 2} = MemoryService.ingest(entries, config())

      assert_receive {:req, conn}
      {:ok, body, _conn} = Plug.Conn.read_body(conn)

      assert %{
               "entries" => [
                 %{"id" => "p1", "memory_type" => "page"},
                 %{"id" => "j1", "memory_type" => "journal"}
               ]
             } = Jason.decode!(body)
    end

    test "returns {:error, {:http, status, body}} on non-2xx" do
      install_stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"detail" => "boom"}))
      end)

      assert {:error, {:http, 500, %{"detail" => "boom"}}} =
               MemoryService.ingest([%{id: "a", content: "x", date: "2026-04-16"}], config())
    end
  end

  describe "search/3" do
    test "POSTs /search with query + filters and normalizes result shape" do
      test_pid = self()

      install_stub(fn conn ->
        send(test_pid, {:req, conn})

        Req.Test.json(conn, %{
          "results" => [
            %{"entry_id" => "01foo", "score" => 0.87},
            %{"entry_id" => "01bar", "score" => 0.42}
          ]
        })
      end)

      assert {:ok, hits} =
               MemoryService.search(
                 "what did we decide",
                 [workspace_id: "ws-1", memory_type: "decision", limit: 5],
                 config(api_key: "sekret")
               )

      assert hits == [
               %{entry_id: "01foo", score: 0.87},
               %{entry_id: "01bar", score: 0.42}
             ]

      assert_receive {:req, conn}
      assert conn.request_path == "/search"

      headers = Map.new(conn.req_headers)
      assert headers["x-api-key"] == "sekret"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "query" => "what did we decide",
               "workspace_id" => "ws-1",
               "memory_type" => "decision",
               "limit" => 5
             }
    end

    # The corpus tag is optional on the wire. Req.Test stub only — never
    # asserts on the live memory-service.
    test "passes a non-empty memory_type through on each hit" do
      install_stub(fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{"entry_id" => "01foo", "score" => 0.87, "memory_type" => "journal"}
          ]
        })
      end)

      assert {:ok, hits} = MemoryService.search("q", [], config())
      assert hits == [%{entry_id: "01foo", score: 0.87, memory_type: "journal"}]
    end

    test "a legacy response without memory_type yields hits with no :memory_type key" do
      install_stub(fn conn ->
        Req.Test.json(conn, %{"results" => [%{"entry_id" => "01foo", "score" => 0.5}]})
      end)

      assert {:ok, [hit]} = MemoryService.search("q", [], config())
      refute Map.has_key?(hit, :memory_type)
      assert hit == %{entry_id: "01foo", score: 0.5}
    end

    test "an empty-string or null memory_type omits the key rather than passing nil" do
      install_stub(fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{"entry_id" => "01empty", "score" => 0.5, "memory_type" => ""},
            %{"entry_id" => "01null", "score" => 0.4, "memory_type" => nil}
          ]
        })
      end)

      assert {:ok, hits} = MemoryService.search("q", [], config())
      assert hits == [%{entry_id: "01empty", score: 0.5}, %{entry_id: "01null", score: 0.4}]
      refute Enum.any?(hits, &Map.has_key?(&1, :memory_type))
    end

    test "omits nil/empty filters from the request body" do
      install_stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "workspace_id")
        refute Map.has_key?(decoded, "memory_type")
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, []} =
               MemoryService.search("q", [workspace_id: nil, memory_type: ""], config())
    end
  end

  describe "delete/2" do
    test "sends DELETE /entries with entry_ids and returns deleted count" do
      install_stub(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/entries"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"entry_ids" => ["a", "b"]} = Jason.decode!(body)

        Req.Test.json(conn, %{"deleted" => 2})
      end)

      assert {:ok, 2} = MemoryService.delete(["a", "b"], config())
    end
  end

  describe "health/1" do
    test "returns :ok when service reports status ok" do
      install_stub(fn conn ->
        assert conn.request_path == "/health"
        Req.Test.json(conn, %{"status" => "ok", "model_loaded" => true})
      end)

      assert :ok = MemoryService.health(config())
    end

    test "returns {:error, {:service_status, other}} when loading" do
      install_stub(fn conn ->
        Req.Test.json(conn, %{"status" => "loading", "model_loaded" => false})
      end)

      assert {:error, {:service_status, "loading"}} = MemoryService.health(config())
    end
  end

  describe "timeouts (task 01a0d8c9)" do
    # Captures the receive_timeout each request actually carries, through
    # the real request path, without a socket.
    defp install_capture do
      test_pid = self()

      adapter = fn req ->
        send(test_pid, {:receive_timeout, req.url.path, req.options[:receive_timeout]})

        body =
          case req.url.path do
            "/ingest" -> %{"ingested" => 1}
            "/search" -> %{"results" => []}
            "/entries" -> %{"deleted" => 1}
            _ -> %{"status" => "ok"}
          end

        {req, Req.Response.json(body)}
      end

      Application.put_env(:platform, :memory_service_req_client, Req.new(adapter: adapter))
    end

    defp timeouts_for(config) do
      install_capture()
      assert {:ok, 1} = MemoryService.ingest([%{id: "a", content: "x"}], config)
      assert {:ok, []} = MemoryService.search("q", [], config)
      assert {:ok, 1} = MemoryService.delete(["a"], config)
      assert :ok = MemoryService.health(config)

      assert_receive {:receive_timeout, "/ingest", ingest}
      assert_receive {:receive_timeout, "/search", search}
      assert_receive {:receive_timeout, "/entries", delete}
      assert_receive {:receive_timeout, "/health", health}
      %{ingest: ingest, search: search, delete: delete, health: health}
    end

    test "default config: ingest waits at least 120s, search/delete/health keep 5s" do
      t = timeouts_for(base_url: "http://memory-service:8100")

      assert t.ingest >= 120_000
      assert t.search == 5_000
      assert t.delete == 5_000
      assert t.health == 5_000
    end

    test "an explicit :timeout does not change ingest's timeout" do
      t = timeouts_for(base_url: "http://memory-service:8100", timeout: 1_000)

      assert t.ingest >= 120_000
      assert t.search == 1_000
      assert t.delete == 1_000
      assert t.health == 1_000
    end

    test "an explicit :ingest_timeout governs ingest only" do
      t = timeouts_for(base_url: "http://memory-service:8100", ingest_timeout: 777)

      assert t.ingest == 777
      assert t.search == 5_000
    end

    test "over a real socket: ingest outlives :timeout, search does not" do
      # The adapter's default client, so the timeout reaches Finch.
      Application.delete_env(:platform, :memory_service_req_client)
      #
      # What this discriminates is the 200ms :timeout against each path's
      # stall. An ingest bounded by :timeout gives up at 200ms, 800ms before
      # /ingest answers at 1s. A search bounded by ingest_timeout waits out
      # /search's 10s stall and gets a 200.
      #
      # The other margins only have to survive a loaded machine. Before
      # task 019f5931 this was a 600ms stall on both paths against a 2_000ms
      # ingest_timeout. CI run 37017583264 failed it with the ingest timing
      # out, and on moon, under CPU contention, both halves failed: an
      # ingest answered more than 1.4s late, and a search whose 200ms timer
      # had not fired by the time the 600ms answer arrived. Now ingest has
      # 29s of slack and search 9.8s. The exact value reaching Req is pinned
      # by "an explicit :ingest_timeout governs ingest only" above.
      base_url = start_slow_server(%{"/ingest" => 1_000, "/search" => 10_000})
      config = [base_url: base_url, timeout: 200, ingest_timeout: 30_000]

      assert {:ok, 1} = MemoryService.ingest([%{id: "a", content: "x"}], config)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               MemoryService.search("q", [], config)
    end
  end

  defp start_slow_server(sleep_ms_by_path) do
    port = free_port()

    # shutdown_timeout 0: teardown does not wait out a stalled handler.
    start_supervised!(
      {Bandit,
       plug: {Platform.Memory.Providers.MemoryServiceTest.SlowPlug, sleep_ms: sleep_ms_by_path},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false,
       thousand_island_options: [shutdown_timeout: 0]}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
