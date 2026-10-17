defmodule Platform.Security.ExternalFederationScopeTest do
  @moduledoc """
  M15 security suite — Stage 5 (S5), federation half: the MCP token surface (M11).

  POSTs real JSON-RPC to `/mcp` through the `:mcp` pipeline with a Bearer token
  (stored hash via `AgentRuntime.hash_token/1`). Proves the external-principal
  tool gate:

    * an EXTERNAL-owned runtime with broad bundles sees EXACTLY the six chat
      tools and NONE of task/canvas; `tools/call task_create` → `-32001`;
      `react` is NOT rejected by the external gate;
    * FAIL-CLOSED INTERSECTION — an EXTERNAL-owned runtime granted only
      `["task"]` sees an EMPTY surface and `send_media` → `-32001` (the filter
      never injects a chat tool the bundles did not grant);
    * REGRESSION — an INTERNAL-owned runtime with the same broad bundles sees
      task/canvas and `task_create` is NOT gated by the external filter.

  Binds to M11 shipped: `ToolSurface.scope_for_external/2`, `external_chat_tools/0`,
  `MCPController.effective_tools/1`, `Tenancy.external_user?/1`, error code `-32001`.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo

  @broad_bundles ~w(messaging space context_read task canvas)
  @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  setup do
    World.external_world()
  end

  # ── EXTERNAL owner, broad bundles ──────────────────────────────────────

  describe "external-owned runtime with broad bundles" do
    test "tools/list returns EXACTLY the six chat tools", ctx do
      {_rt, token} = runtime_for(ctx.ext.id, @broad_bundles)
      names = tool_names(build_conn(), token)

      assert names == Enum.sort(@chat_names)
      refute "task_create" in names
      refute "canvas_create" in names
      refute "space_leave" in names
      refute "principal_search" in names
    end

    test "tools/call task_create is forbidden with -32001", ctx do
      {_rt, token} = runtime_for(ctx.ext.id, @broad_bundles)

      conn =
        mcp_post(
          build_conn(),
          token,
          rpc("tools/call", %{"name" => "task_create", "arguments" => %{}})
        )

      %{"error" => %{"code" => code, "message" => message}} = json_response(conn, 200)
      assert code == -32001
      assert message =~ "requires permission"
    end

    test "tools/call react is NOT rejected by the external gate", ctx do
      {_rt, token} = runtime_for(ctx.ext.id, @broad_bundles)

      conn =
        mcp_post(build_conn(), token, rpc("tools/call", %{"name" => "react", "arguments" => %{}}))

      resp = json_response(conn, 200)
      refute get_in(resp, ["error", "code"]) == -32001
    end
  end

  # ── EXTERNAL owner, fail-closed intersection ───────────────────────────

  describe "external-owned runtime with only [task] bundle (fail-closed)" do
    test "tools/list is EMPTY and send_media → -32001", ctx do
      {_rt, token} = runtime_for(ctx.ext.id, ["task"])

      assert tool_names(build_conn(), token) == []

      conn =
        mcp_post(
          build_conn(),
          token,
          rpc("tools/call", %{"name" => "send_media", "arguments" => %{}})
        )

      %{"error" => %{"code" => code}} = json_response(conn, 200)
      assert code == -32001
    end
  end

  # ── INTERNAL owner regression ──────────────────────────────────────────

  describe "internal-owned runtime with the same broad bundles" do
    test "tools/list includes task_create + canvas_create and task_create is NOT gated", ctx do
      {_rt, token} = runtime_for(ctx.int.id, @broad_bundles)

      names = tool_names(build_conn(), token)
      assert "task_create" in names
      assert "canvas_create" in names

      conn =
        mcp_post(
          build_conn(),
          token,
          rpc("tools/call", %{"name" => "task_create", "arguments" => %{}})
        )

      resp = json_response(conn, 200)
      refute get_in(resp, ["error", "code"]) == -32001
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp runtime_for(owner_user_id, tool_profile) do
    raw_token = AgentRuntime.generate_token()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "m15-rt-#{System.unique_integer([:positive])}",
        owner_user_id: owner_user_id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        tool_profile,
        Platform.Access.RuntimeProfiles.translated_permissions(tool_profile)
      )

    {runtime, raw_token}
  end

  defp tool_names(conn, token) do
    conn = mcp_post(conn, token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    tools |> Enum.map(& &1["name"]) |> Enum.sort()
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
end
