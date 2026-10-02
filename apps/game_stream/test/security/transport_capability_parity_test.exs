defmodule Platform.GameStream.TransportCapabilityParityTest do
  @moduledoc """
  Play's grant set in the M15 transport-parity proof (ADR 0055, task
  01a0ee08 stage 3). This is core's
  `test/security/transport_capability_parity_test.exs`, run over the one
  grant set that names Play's bundle, which can only be granted where Play is
  present. The helpers are core's, copied; the `files` direct-insert case
  stays in core. Core's moduledoc follows unchanged.

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
      and the WS verdict (`code: "forbidden"` or not) agree. Both verdicts are
      read off the STRUCTURAL denial field, never off the denial sentence; on
      top of that, each transport's message must equal
      `ToolAuthorization.deny_message/1` — the shared formatter — so a
      transport cannot start composing its own denial wording; and
    * CONTENT PARITY — for every tool advertised on BOTH transports, each
      non-blank prose field the WS definition map carries (`description`,
      `returns`, `limitations`, `when_to_use`) is findable in that same tool's
      HTTP payload. The transports carry it in DIFFERENT SHAPES — the WS push
      ships the definition map whole, so the four are separate keys, while
      `tools/list` projects onto the closed MCP tool object and
      `Platform.Federation.ToolDoc.render_description/1` folds three of them
      into `description` — so the claim is REACHABILITY, not key equality.
      Before task 01a08a0c the HTTP side dropped three of the four outright
      and this file did not notice, because it only ever compared NAMES.

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
  (`lib/platform/agents/agent_runtime.ex`) and
  `Platform.Federation.ToolSurface.all_bundles/0`
  (`lib/platform/federation/tool_surface.ex`) once DISAGREED: `files` was
  absent from the former, so the changeset could not grant it. Since task
  019ff110 (#706) `valid_bundles/0` includes `files`, and
  `test/platform/agents/agent_runtime_test.exs` holds the two lists equal.
  Every grant below is still a LITERAL list — nothing in this file reads
  `valid_bundles/0` or `all_bundles/0` — so the suite cannot silently start
  depending on the two lists agreeing. The `files` case still inserts its row
  DIRECTLY, bypassing the changeset, to pin the production row shape
  (`transport`, `trust_level` and `metadata` set on the struct, not derived by
  the changeset).
  """
  use PlatformWeb.ChannelCase, async: false

  # `Phoenix.ConnTest` also exports `connect/3`; importing it wholesale would
  # shadow `Phoenix.ChannelTest.connect/2`. Take only the HTTP helpers.
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo

  # Literal grant sets. Deliberately NOT derived from any module attribute in
  # the application code — see the moduledoc's non-dependency note.
  # The `play` grant set that lived in core's copy of this file until task
  # 01a0ee08 stage 3 moved Play into its own project (ADR 0055). Literal, as
  # core's are. With GAME_STREAM_ENABLED unset (the default here) `play`
  # lists nothing, and both transports must still agree on that.
  @grant_sets [
    {"production grant plus play",
     ~w(federation space context_read messaging review canvas task plan memory skill attachment play)}
  ]

  # Spans granted / ungranted / legacy-alias / external-allowlist names.
  @probes ~w(task_create space_list canvas_create send_media memory_delete stack_abandon prompt_template_update)

  # The prose a WS runtime reads off the definition map. Literal for the same
  # reason the grant sets are: nothing here reads `ToolDoc`'s section list, so
  # a renderer that quietly stops folding one of them still reddens.
  @prose_fields [:description, :returns, :limitations, :when_to_use]

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

    test "INTERNAL owner, #{label}: both transports carry the same tool prose", ctx do
      assert_content_parity(ctx, ctx.int.id, unquote(bundles))
    end

    test "EXTERNAL owner, #{label}: both transports carry the same tool prose", ctx do
      assert_content_parity(ctx, ctx.ext.id, unquote(bundles))
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

  # The third property: the two transports agree about what each tool SAYS,
  # not merely about which tools exist. Asserted as reachability because the
  # shapes differ on purpose — see the moduledoc.
  defp assert_content_parity(ctx, owner_user_id, bundles) do
    {runtime, token} = runtime_for(ctx, owner_user_id, bundles)
    {_socket, capabilities} = join_runtime(runtime, token)

    http_tools = http_tools_by_name(token)

    shared =
      Enum.filter(capabilities.tools, fn tool -> Map.has_key?(http_tools, tool.name) end)

    # A quiet empty intersection would make everything below vacuously true, so
    # pin that "advertised on both" is in fact the whole WS surface. (The
    # advertisement test owns the converse direction.)
    assert shared |> Enum.map(& &1.name) |> Enum.sort() == ws_tool_names(capabilities),
           "a WS-advertised tool had no HTTP payload to compare against"

    {checked, prose_checked, missing} =
      Enum.reduce(shared, {0, 0, []}, fn tool, acc ->
        haystack = payload_text(Map.fetch!(http_tools, tool.name))

        Enum.reduce(@prose_fields, acc, fn field, {checked, prose_checked, missing} ->
          case non_blank(Map.get(tool, field)) do
            nil ->
              {checked, prose_checked, missing}

            text ->
              prose_checked = if field == :description, do: prose_checked, else: prose_checked + 1

              missing =
                if String.contains?(haystack, text),
                  do: missing,
                  else: [{tool.name, field} | missing]

              {checked + 1, prose_checked, missing}
          end
        end)
      end)

    assert missing == [],
           """
           prose the WS transport carries was unreachable over HTTP \
           for bundles #{inspect(bundles)}
             #{missing |> Enum.reverse() |> Enum.map(fn {n, f} -> "#{n}.#{f}" end) |> Enum.join(", ")}
           """

    # ANTI-VACUITY. `missing == []` is satisfied by checking nothing, and a
    # field-by-field loop over blank values checks nothing while looking
    # thorough, so the counters have to be asserted too.
    #
    # The condition is the ADVERTISED surface, deliberately not `bundles != []`.
    # Keying it off the grant looks equivalent and is not: an EXTERNAL owner is
    # narrowed to `@external_chat_tools` by `ToolSurface.scope_for_external/2`,
    # so the external half of the `["federation"]` row advertises nothing at all
    # and a grant-keyed floor fails there for a reason that has nothing to do
    # with parity. When the surface IS empty we say so out loud rather than let
    # the case pass quietly on an empty loop.
    if shared == [] do
      assert ws_tool_names(capabilities) == [],
             "content parity checked nothing despite a non-empty advertised surface"
    else
      assert checked > 0, "content parity examined no fields at all for #{inspect(bundles)}"

      assert prose_checked > 0,
             "content parity examined only `description` for #{inspect(bundles)}; " <>
               "the returns/limitations/when_to_use claim was never exercised"
    end
  end

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_blank(_), do: nil

  # Location-agnostic by design: the property is "this prose is reachable in
  # this tool's HTTP payload", not "it lives in `description`". Today
  # `ToolDoc.render_description/1` puts it there; a future move into `_meta`
  # or a sibling key should not need this file edited to stay honest. Every
  # string VALUE in the tool object is flattened and searched (keys are not).
  defp payload_text(tool_payload), do: tool_payload |> collect_strings() |> Enum.join("\n")

  defp collect_strings(value) when is_binary(value), do: [value]

  defp collect_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_strings/1)

  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(_), do: []

  # ── HTTP transport (POST /mcp) ─────────────────────────────────────────

  defp http_tools_by_name(token) do
    conn = mcp_post(token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    Map.new(tools, fn tool -> {tool["name"], tool} end)
  end

  defp http_tool_names(token) do
    conn = mcp_post(token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    tools |> Enum.map(& &1["name"]) |> Enum.sort()
  end

  defp http_verdict(token, name) do
    conn = mcp_post(token, rpc("tools/call", %{"name" => name, "arguments" => %{}}))

    case json_response(conn, 200) do
      %{"error" => %{"code" => -32001, "message" => message}} ->
        # Same discipline as `ws_verdict/2`: classify on the structural JSON-RPC
        # code, then require the sentence to come from the shared formatter.
        # The two together are what makes a denial byte-identical on HTTP and
        # WS — the parity claim this file exists to hold.
        assert message == ToolAuthorization.deny_message(name)
        :denied

      _ ->
        :allowed
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
        # The VERDICT is read structurally, off `code: "forbidden"` — that is
        # the field both transports agree on and the only thing this file
        # classifies. The message is then compared to the SHARED formatter
        # rather than to a literal sentence, which is what this file actually
        # wants to pin: neither transport builds its own denial wording. A
        # literal here made a wording change (task 01a089c8, which split
        # "unknown tool" out of "missing grant") read as a security failure
        # even though the call was still denied. The wording itself is pinned
        # where wording is the subject —
        # `test/platform/federation/tool_authorization_test.exs`,
        # `mcp_controller_test.exs` and `runtime_channel_test.exs`.
        assert message == ToolAuthorization.deny_message(name)
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
