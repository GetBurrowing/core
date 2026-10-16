defmodule Platform.Social.TransportParityTest do
  @moduledoc """
  The `social` bundle on BOTH federation transports (task 01a140a9-4c70,
  Social 4/7 stage 3), modelled on Play's
  `apps/game_stream/test/security/transport_capability_parity_test.exs`; the
  HTTP and WS helpers are that file's, copied.

    * A runtime granted `social` sees exactly the nine `social_*` tools on the
      MCP `tools/list` (`POST /mcp`) AND in the runtime channel's
      `capabilities` push, each description carrying the human-approves
      sentence.
    * A runtime on the default bundles sees none.
    * No advertised name contains publish or approve.
    * `tools/call` to `social_post_publish` and `social_post_approve` is
      denied on both transports with the same text (the shared formatter,
      which Social words), and nothing is written.

  The grant sets are literal lists, as in Play's file.
  """
  use PlatformWeb.ChannelCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Social.{Clip, Post}

  # Social 4/7's six, Social 5/7's social_clip_list and social_clip_render,
  # and Social 6/7's social_task_request.
  @nine ~w(social_clip_list social_clip_propose social_clip_render social_draft_create
           social_draft_update social_post_list social_profile_get social_profile_list
           social_task_request)

  @granted ~w(federation space context_read messaging review canvas task plan memory skill attachment social)

  @sentence "A human approves this in Suite and the platform publishes it; agents cannot approve or publish."

  @deny "There is no publish or approve tool: a human approves in Suite and the platform publishes."

  setup do
    owner =
      Repo.insert!(%Platform.Accounts.User{
        email: "social-parity-#{System.unique_integer([:positive])}@example.com",
        name: "Social Parity Owner",
        oidc_sub: "social-parity-#{System.unique_integer([:positive])}"
      })

    %{owner: owner}
  end

  test "the granted runtime sees exactly the nine social tools on both transports", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    http = http_tools_by_name(token)

    http_social =
      http |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "social_")) |> Enum.sort()

    ws_social =
      capabilities |> ws_tool_names() |> Enum.filter(&String.starts_with?(&1, "social_"))

    assert http_social == @nine
    assert ws_social == @nine
    assert http |> Map.keys() |> Enum.sort() == ws_tool_names(capabilities)

    for name <- @nine do
      assert http[name]["description"] =~ @sentence
      ws_tool = Enum.find(capabilities.tools, &(&1.name == name))
      assert ws_tool.description =~ @sentence
    end
  end

  test "a default-bundles runtime sees no social tool on either transport", ctx do
    {runtime, token} = runtime_for(ctx, AgentRuntime.default_allowed_bundles())
    refute "social" in AgentRuntime.default_allowed_bundles()
    {_socket, capabilities} = join_runtime(runtime, token)

    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) == []
    assert capabilities |> ws_tool_names() |> Enum.filter(&social?/1) == []
  end

  # Scoped to the social bundle's names: core's own `plan` bundle carries
  # `plan_approve` (a plan gate, not a post), which this task does not own.
  test "no advertised social name contains publish or approve", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    names =
      (Map.keys(http_tools_by_name(token)) ++ ws_tool_names(capabilities))
      |> Enum.filter(&social?/1)

    # nine names, once per transport
    assert length(names) == 18
    assert Enum.filter(names, &(&1 =~ "publish" or &1 =~ "approve")) == []
  end

  test "publish and approve calls are denied on both transports, same text, nothing written",
       ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {socket, _capabilities} = join_runtime(runtime, token)
    before = {Repo.aggregate(Post, :count), Repo.aggregate(Clip, :count)}

    for name <- ~w(social_post_publish social_post_approve) do
      assert ToolAuthorization.deny_message(name) == @deny
      assert {:denied, http_message} = http_verdict(token, name)
      assert {:denied, ws_message} = ws_verdict(socket, name)
      assert http_message == @deny
      assert ws_message == @deny
    end

    assert {Repo.aggregate(Post, :count), Repo.aggregate(Clip, :count)} == before
  end

  test "a granted tool is allowed on both transports (the verdict probe is not vacuous)", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {socket, _capabilities} = join_runtime(runtime, token)

    for name <- ~w(social_profile_list social_task_request) do
      assert http_verdict(token, name) == :allowed
      assert ws_verdict(socket, name) == :allowed
    end
  end

  defp social?(name), do: String.starts_with?(name, "social_")

  # ── HTTP transport (POST /mcp) ─────────────────────────────────────────

  defp http_tools_by_name(token) do
    conn = mcp_post(token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    Map.new(tools, fn tool -> {tool["name"], tool} end)
  end

  defp http_verdict(token, name) do
    conn = mcp_post(token, rpc("tools/call", %{"name" => name, "arguments" => %{}}))

    case json_response(conn, 200) do
      %{"error" => %{"code" => -32001, "message" => message}} -> {:denied, message}
      _ -> :allowed
    end
  end

  defp mcp_post(token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  # ── WebSocket transport (runtime:*) ────────────────────────────────────

  defp ws_tool_names(capabilities), do: capabilities.tools |> Enum.map(& &1.name) |> Enum.sort()

  defp ws_verdict(socket, name) do
    call_id = "social-parity-#{System.unique_integer([:positive])}"
    push(socket, "tool_call", %{"call_id" => call_id, "tool" => name, "args" => %{}})
    assert_push("tool_result", %{call_id: ^call_id} = frame)

    case frame do
      %{status: "error", error: %{code: "forbidden", error: message}} -> {:denied, message}
      _ -> :allowed
    end
  end

  defp join_runtime(runtime, token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => runtime.runtime_id, "token" => token})

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    assert_push("capabilities", capabilities)
    {socket, capabilities}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp runtime_for(ctx, allowed_bundles) do
    raw_token = AgentRuntime.generate_token()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "social-parity-agent-#{System.unique_integer([:positive])}",
        name: "Social Parity Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "social-parity-rt-#{System.unique_integer([:positive])}",
        owner_user_id: ctx.owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        allowed_bundles: allowed_bundles
      })
      |> Repo.insert()

    {runtime, raw_token}
  end
end
