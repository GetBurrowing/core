defmodule Platform.Memory.Providers.StartupSuiteTest do
  use ExUnit.Case, async: false

  alias Platform.Memory.Providers.StartupSuite

  setup do
    # Configure a Req.Test plug for the memory service client
    test_pid = self()

    req_client =
      Req.new(
        adapter: fn request ->
          send(test_pid, {:req, request})

          response =
            case {request.method, request.url.path} do
              {:post, "/ingest"} ->
                Req.Response.new(status: 200, body: %{"ingested" => 1})

              {:post, "/search"} ->
                Req.Response.new(
                  status: 200,
                  body: %{
                    "results" => [
                      %{"entry_id" => "id-1", "score" => 0.95},
                      %{"entry_id" => "id-2", "score" => 0.82}
                    ]
                  }
                )

              {:delete, "/entries"} ->
                Req.Response.new(status: 200, body: %{"deleted" => 1})

              _ ->
                Req.Response.new(status: 404, body: %{"error" => "not found"})
            end

          {request, response}
        end
      )

    Application.put_env(:platform, :memory_service_req_client, req_client)

    on_exit(fn ->
      Application.delete_env(:platform, :memory_service_req_client)
    end)

    :ok
  end

  describe "ingest/1" do
    test "sends POST to /ingest with entry data" do
      entry = %{
        id: "test-id-123",
        content: "A test memory entry",
        memory_type: "daily",
        date: ~D[2026-04-15],
        workspace_id: nil,
        metadata: %{}
      }

      assert :ok = StartupSuite.ingest(entry)

      assert_received {:req, request}
      assert request.method == :post
      assert request.url.path == "/ingest"
    end

    test "returns error on non-2xx status" do
      req_client =
        Req.new(
          adapter: fn request ->
            {request, Req.Response.new(status: 500, body: %{"error" => "internal"})}
          end
        )

      Application.put_env(:platform, :memory_service_req_client, req_client)

      entry = %{
        id: "id",
        content: "c",
        memory_type: "daily",
        date: ~D[2026-04-15],
        workspace_id: nil,
        metadata: %{}
      }
      assert {:error, {:unexpected_status, 500}} = StartupSuite.ingest(entry)
    end
  end

  describe "search/2" do
    test "sends POST to /search and normalizes results" do
      assert {:ok, results} = StartupSuite.search("test query", limit: 10)

      assert [%{entry_id: "id-1", score: 0.95}, %{entry_id: "id-2", score: 0.82}] = results

      assert_received {:req, request}
      assert request.method == :post
      assert request.url.path == "/search"
    end

    test "passes opts through to request body" do
      {:ok, _results} =
        StartupSuite.search("query", workspace_id: "ws-1", memory_type: "daily", limit: 25)

      assert_received {:req, request}
      assert request.method == :post
    end
  end

  describe "delete/1" do
    test "sends DELETE to /entries" do
      assert :ok = StartupSuite.delete("entry-id-to-remove")

      assert_received {:req, request}
      assert request.method == :delete
      assert request.url.path == "/entries"
    end
  end
end
