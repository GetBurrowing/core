defmodule PlatformWeb.MCPControllerTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo
  alias Platform.Tenancy

  defp create_runtime(attrs \\ %{}) do
    user =
      Repo.insert!(%User{
        email: "mcp_test_#{System.unique_integer([:positive])}@example.com",
        name: "MCP Test User",
        oidc_sub: "oidc-mcp-test-#{System.unique_integer([:positive])}"
      })

    raw_token = AgentRuntime.generate_token()

    base_attrs = %{
      runtime_id: "mcp-rt-#{System.unique_integer([:positive])}",
      owner_user_id: user.id,
      auth_token_hash: AgentRuntime.hash_token(raw_token),
      status: "active",
      allowed_bundles: AgentRuntime.valid_bundles()
    }

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(Map.merge(base_attrs, attrs))
      |> Repo.insert()

    {runtime, raw_token}
  end

  defp mcp_post(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  describe "authentication" do
    test "rejects requests with no authorization header", %{conn: conn} do
      conn = post(conn, "/mcp", rpc("initialize"))
      assert conn.status == 401
    end

    test "rejects requests with a bogus token", %{conn: conn} do
      conn = mcp_post(conn, "not-a-real-token", rpc("initialize"))
      assert conn.status == 401
    end

    test "rejects non-active runtimes", %{conn: conn} do
      {_runtime, token} = create_runtime(%{status: "suspended"})
      conn = mcp_post(conn, token, rpc("initialize"))
      assert conn.status == 401
    end

    test "accepts a valid bearer token for an active runtime", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("initialize"))
      assert conn.status == 200
    end
  end

  describe "initialize" do
    test "returns serverInfo and protocol version", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("initialize"))
      body = json_response(conn, 200)

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["serverInfo"]["name"] == "startup-suite"
      assert is_binary(body["result"]["protocolVersion"])
      assert body["result"]["capabilities"]["tools"]
    end
  end

  describe "tools/list" do
    test "returns the full surface when all bundles are allowed", %{conn: conn} do
      {_runtime, token} = create_runtime()
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "federation_status" in names
      assert "task_create" in names
      assert "canvas.create" in names
      assert "canvas.patch" in names
      assert "canvas.describe" in names
      assert Enum.all?(tools, &Map.has_key?(&1, "inputSchema"))
    end

    test "scopes the surface to allowed_bundles", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = Enum.map(tools, & &1["name"])
      assert "federation_status" in names
      refute "task_create" in names
      refute "canvas.create" in names
    end

    test "returns an empty list when no bundles are allowed", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: []})
      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      assert tools == []
    end
  end

  describe "tools/call" do
    test "runs a tool that is in scope", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "federation_status", "arguments" => %{}})
        )

      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == false
      [%{"type" => "text", "text" => text}] = result["content"]
      assert is_binary(text)
      assert String.contains?(text, "runtimes")
    end

    test "refuses a tool that is out of scope with -32001", %{conn: conn} do
      {_runtime, token} = create_runtime(%{allowed_bundles: ["federation"]})

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "task_create", "arguments" => %{}})
        )

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "not in allowed bundles"
    end

    test "returns -32602 when arguments are missing", %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn =
        mcp_post(
          conn,
          token,
          rpc("tools/call", %{"name" => "federation_status"})
        )

      %{"error" => %{"code" => code}} = json_response(conn, 200)
      assert code == -32602
    end
  end

  describe "external-principal tool scoping (M11)" do
    @broad_bundles ~w(messaging space context_read task canvas)
    @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

    defp mark_owner_external(runtime) do
      {:ok, _} =
        Tenancy.mark_membership_external(%{
          user_id: runtime.owner_user_id,
          org_id: fabrikam_org_id()
        })

      runtime
    end

    test "external owner with broad bundles sees ONLY the six chat tools", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == Enum.sort(@chat_names)
      refute "task_create" in names
      refute "canvas.create" in names
      refute "space_leave" in names
    end

    test "external owner: tools/call task_create is forbidden with -32001", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "not in allowed bundles"
    end

    test "external owner: react is NOT gated (chat tool reaches execution)", %{conn: conn} do
      {runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})
      mark_owner_external(runtime)

      conn =
        mcp_post(conn, token, rpc("tools/call", %{"name" => "react", "arguments" => %{}}))

      resp = json_response(conn, 200)
      # The external-scope gate must not reject react; it passes authorize
      # and reaches ToolSurface.execute (which may then return its own
      # arg-level result, but never the -32001 forbidden error).
      refute get_in(resp, ["error", "code"]) == -32001
    end

    test "external owner with only [task] bundle sees an EMPTY surface (fail-closed)", %{
      conn: conn
    } do
      {runtime, token} = create_runtime(%{allowed_bundles: ["task"]})
      mark_owner_external(runtime)

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      assert tools == []

      # send_media is a chat tool but was never granted → still -32001.
      conn2 =
        build_conn()
        |> mcp_post(token, rpc("tools/call", %{"name" => "send_media", "arguments" => %{}}))

      %{"error" => %{"code" => code}} = json_response(conn2, 200)
      assert code == -32001
    end

    test "internal owner with the same bundles is UNAFFECTED", %{conn: conn} do
      # Default create_runtime owner has no external membership → internal.
      {_runtime, token} = create_runtime(%{allowed_bundles: @broad_bundles})

      conn = mcp_post(conn, token, rpc("tools/list"))
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = Enum.map(tools, & &1["name"])
      assert "task_create" in names
      assert "canvas.create" in names

      conn2 =
        build_conn()
        |> mcp_post(token, rpc("tools/call", %{"name" => "task_create", "arguments" => %{}}))

      resp = json_response(conn2, 200)
      # Not blocked by the external gate (may fail its own arg validation).
      refute get_in(resp, ["error", "code"]) == -32001
    end
  end

  describe "unknown methods" do
    test "returns -32601 method not found", %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn = mcp_post(conn, token, rpc("does/not/exist"))
      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)

      assert code == -32601
      assert message =~ "does/not/exist"
    end
  end

  describe "GET /mcp" do
    test "returns 405 Method Not Allowed (no server-initiated notifications yet)",
         %{conn: conn} do
      {_runtime, token} = create_runtime()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/mcp")

      assert conn.status == 405
    end
  end
end
