defmodule Platform.Memory.Providers.StartupSuiteTest do
  use ExUnit.Case, async: true

  alias Platform.Memory.Providers.StartupSuite

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

      assert {:ok, 2} = StartupSuite.ingest(entries, config())

      assert_receive {:req, conn}
      assert conn.request_path == "/ingest"
      assert conn.method == "POST"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert %{"entries" => [%{"id" => "a"}, %{"id" => "b"}]} = Jason.decode!(body)
    end

    test "returns {:error, {:http, status, body}} on non-2xx" do
      install_stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"detail" => "boom"}))
      end)

      assert {:error, {:http, 500, %{"detail" => "boom"}}} =
               StartupSuite.ingest([%{id: "a", content: "x", date: "2026-04-16"}], config())
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
               StartupSuite.search(
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

    test "omits nil/empty filters from the request body" do
      install_stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "workspace_id")
        refute Map.has_key?(decoded, "memory_type")
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, []} =
               StartupSuite.search("q", [workspace_id: nil, memory_type: ""], config())
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

      assert {:ok, 2} = StartupSuite.delete(["a", "b"], config())
    end
  end

  describe "health/1" do
    test "returns :ok when service reports status ok" do
      install_stub(fn conn ->
        assert conn.request_path == "/health"
        Req.Test.json(conn, %{"status" => "ok", "model_loaded" => true})
      end)

      assert :ok = StartupSuite.health(config())
    end

    test "returns {:error, {:service_status, other}} when loading" do
      install_stub(fn conn ->
        Req.Test.json(conn, %{"status" => "loading", "model_loaded" => false})
      end)

      assert {:error, {:service_status, "loading"}} = StartupSuite.health(config())
    end
  end
end
