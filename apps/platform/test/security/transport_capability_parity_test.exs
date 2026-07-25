defmodule Platform.Security.TransportCapabilityParityTest do
  @moduledoc """
  M15 security suite — the "one enforcement point" proof.

  `Platform.Federation.ToolAuthorization` exists so the streamable-HTTP MCP
  endpoint (`POST /mcp`) and the WebSocket runtime channel (`runtime:*`) cannot
  answer a capability question differently. This file is the executable form of
  that claim: for a matrix of LITERAL grant sets crossed with internal/external
  ownership it drives BOTH transports against the same runtime row and asserts

    * ADVERTISEMENT PARITY — the sorted tool names from `tools/list` over HTTP
      equal the sorted names in the WS `capabilities` push; and
    * VERDICT PARITY — for a probe list spanning granted, ungranted, legacy
      alias and external-allowlist names, the HTTP verdict (`-32001` or not)
      and the WS verdict (`not in allowed bundles` / `code: "forbidden"` or
      not) agree.

  An edit that fixes or breaks one transport and forgets the other fails here
  instead of shipping — which is precisely how the original bug survived CI:
  `test/security/external_federation_scope_test.exs` drove `/mcp` only.

  The probe `canvas_create` is one of the two legacy undeclared names
  (`tool_surface.ex:2700` / `:2718` have `execute/3` clauses with no
  `tool_definitions/0` entry). Per the owner's MCP-only ruling they belong to
  no bundle and are denied on BOTH transports; that agreement is itself part of
  what this file pins.

  ## Explicit non-dependency

  `Platform.Agents.AgentRuntime.valid_bundles/0`
  (`lib/platform/agents/agent_runtime.ex`, 11 names) and
  `Platform.Federation.ToolSurface.all_bundles/0`
  (`lib/platform/federation/tool_surface.ex`, 12 names) DISAGREE: `files` is
  absent from the former, so `validate_subset/3` rejects it and it can never be
  granted through the changeset. That is a SEPARATE tracked issue and is
  deliberately NOT fixed here. Every grant below is a LITERAL list — nothing in
  this file reads `valid_bundles/0` or `all_bundles/0` — so the suite cannot
  silently start depending on the two lists agreeing. The `files` case inserts
  its row DIRECTLY, bypassing the changeset, because that is the shape prod
  actually carries: 16 of 20 active runtimes hold `files` despite the
  changeset refusing it.
  """
  use PlatformWeb.ChannelCase, async: false

  # `Phoenix.ConnTest` also exports `connect/3`; importing it wholesale would
  # shadow `Phoenix.ChannelTest.connect/2`. Take only the HTTP helpers.
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo

  # Literal grant sets. Deliberately NOT derived from any module attribute in
  # the application code — see the moduledoc's non-dependency note.
  @grant_sets [
    {"no bundles", []},
    {"federation only", ["federation"]},
    {"the default six", ~w(federation space context_read messaging attachment skill)},
    {"broad chat+task+canvas", ~w(messaging space context_read task canvas)},
    {"the full production grant",
     ~w(federation space context_read messaging review canvas task plan memory skill attachment)}
  ]

  # Spans granted / ungranted / legacy-alias / external-allowlist names.
  @probes ~w(task_create space_list canvas_create send_media memory_delete stack_abandon prompt_template_update)

  setup do
    world = World.external_world()
    Map.put(world, :agent, create_agent!())
  end

  for {label, bundles} <- @grant_sets do
    test "INTERNAL owner, #{label}: both transports advertise the same tools", ctx do
      assert_advertisement_parity(ctx, ctx.int.id, unquote(bundles))
    end

    test "EXTERNAL owner, #{label}: both transports advertise the same tools", ctx do
      assert_advertisement_parity(ctx, ctx.ext.id, unquote(bundles))
    end

    test "INTERNAL owner, #{label}: both transports return the same verdict per tool", ctx do
      assert_verdict_parity(ctx, ctx.int.id, unquote(bundles))
    end

    test "EXTERNAL owner, #{label}: both transports return the same verdict per tool", ctx do
      assert_verdict_parity(ctx, ctx.ext.id, unquote(bundles))
    end
  end

  # The `files` row cannot be produced by `AgentRuntime.changeset/2` — see the
  # moduledoc. Inserted directly so the parity property is proved against the
  # row shape prod actually carries, WITHOUT this file taking a position on the
  # two-list mismatch.
  describe "a directly-inserted runtime carrying the ungrantable `files` bundle" do
    test "still resolves identically on both transports", ctx do
      bundles = ~w(federation files)
      {runtime, token} = insert_runtime_directly!(ctx, ctx.int.id, bundles)
      {socket, capabilities} = join_runtime(runtime, token)

      assert http_tool_names(token) == ws_tool_names(capabilities)

      for probe <- @probes do
        assert http_verdict(token, probe) == ws_verdict(socket, probe),
               "transports disagreed on #{probe} for a files-carrying runtime"
      end
    end
  end

  # ── Parity assertions ──────────────────────────────────────────────────

  defp assert_advertisement_parity(ctx, owner_user_id, bundles) do
    {runtime, token} = runtime_for(ctx, owner_user_id, bundles)
    {_socket, capabilities} = join_runtime(runtime, token)

    http_names = http_tool_names(token)
    ws_names = ws_tool_names(capabilities)

    assert http_names == ws_names,
           """
           advertised surfaces diverged for bundles #{inspect(bundles)}
             only over HTTP: #{inspect(http_names -- ws_names)}
             only over WS:   #{inspect(ws_names -- http_names)}
           """
  end

  defp assert_verdict_parity(ctx, owner_user_id, bundles) do
    {runtime, token} = runtime_for(ctx, owner_user_id, bundles)

    # ONE socket for the whole probe sweep: the WS gate re-reads the grant per
    # call anyway (that is what makes mid-connection revocation bite), so a
    # fresh join per probe would only add channel processes.
    {socket, capabilities} = join_runtime(runtime, token)
    advertised = ws_tool_names(capabilities)

    for probe <- @probes do
      http = http_verdict(token, probe)
      ws = ws_verdict(socket, probe)

      assert http == ws,
             "transports disagreed on #{probe} for bundles #{inspect(bundles)}: " <>
               "HTTP #{http}, WS #{ws}"

      # And the verdict must match the advertisement: a tool can never be
      # listed-but-blocked or blocked-but-listed.
      expected = if probe in advertised, do: :allowed, else: :denied

      assert http == expected,
             "#{probe} is #{if probe in advertised, do: "advertised", else: "not advertised"} " <>
               "but the verdict was #{http}"
    end
  end

  # ── HTTP transport (POST /mcp) ─────────────────────────────────────────

  defp http_tool_names(token) do
    conn = mcp_post(token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    tools |> Enum.map(& &1["name"]) |> Enum.sort()
  end

  defp http_verdict(token, name) do
    conn = mcp_post(token, rpc("tools/call", %{"name" => name, "arguments" => %{}}))

    case json_response(conn, 200) do
      %{"error" => %{"code" => -32001}} -> :denied
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

  defp ws_tool_names(capabilities) do
    capabilities.tools |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp ws_verdict(socket, name) do
    call_id = "parity-#{System.unique_integer([:positive])}"
    push(socket, "tool_call", %{"call_id" => call_id, "tool" => name, "args" => %{}})
    assert_push("tool_result", %{call_id: ^call_id} = frame)

    case frame do
      %{status: "error", error: %{code: "forbidden", error: message}} ->
        assert message == "tool '#{name}' not in allowed bundles"
        :denied

      _ ->
        :allowed
    end
  end

  defp join_runtime(runtime, token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    assert_push("capabilities", capabilities)
    {socket, capabilities}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp runtime_for(ctx, owner_user_id, allowed_bundles) do
    raw_token = AgentRuntime.generate_token()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "parity-rt-#{System.unique_integer([:positive])}",
        owner_user_id: owner_user_id,
        agent_id: ctx.agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        allowed_bundles: allowed_bundles
      })
      |> Repo.insert()

    {runtime, raw_token}
  end

  defp insert_runtime_directly!(ctx, owner_user_id, allowed_bundles) do
    raw_token = AgentRuntime.generate_token()

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "parity-direct-#{System.unique_integer([:positive])}",
        owner_user_id: owner_user_id,
        agent_id: ctx.agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        transport: "websocket",
        trust_level: "participant",
        allowed_bundles: allowed_bundles,
        metadata: %{}
      })

    {runtime, raw_token}
  end

  defp create_agent! do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "parity-agent-#{System.unique_integer([:positive])}",
        name: "Parity Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end
end
