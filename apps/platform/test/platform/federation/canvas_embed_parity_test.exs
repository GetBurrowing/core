defmodule Platform.Federation.CanvasEmbedParityTest do
  @moduledoc """
  Cross-flavor parity test for the canvas MCP surface — focused on the
  `embed` kind shipped in stages 1–2 of task 019e0307.

  Mirrors the structural template of `Platform.Federation.SkillMCPParityTest`
  (task 019dfaea): two `AgentRuntime` rows distinguished only by their
  `metadata.client_info.product` value (`"claude_channel"` vs `"openclaw"`),
  each granted `tool_profile: ["canvas"]`, see byte-equivalent
  responses from the canonical MCP chokepoint at `POST /mcp`.

  Both flavors converge on `PlatformWeb.MCPController` regardless of the
  upstream plugin, so exercising that controller directly via Phoenix
  ConnTest is the cheapest way to prove the embed kind cannot diverge by
  product.

  ## What's asserted

    * `tools/list` exposes the canvas tool quintet
      (`canvas_create`, `canvas_patch`, `canvas_describe`,
      `canvas_list_kinds`, `canvas_template`) to BOTH flavors with set
      equality.
    * `canvas_list_kinds` includes the `embed` summary (kind, props,
      example) for BOTH flavors with byte-equivalent payload.
    * Each flavor authors a canvas in a SHARED space whose root is a
      `stack` containing one `embed` node with identical `srcdoc` and
      `height`. Each then calls `canvas_describe` to read its canvas
      back. After normalizing volatile fields (canvas_id, space_id,
      revision, node ids), the embed-node payload (`type`, `props`) is
      byte-equivalent across both flavors.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Repo

  # Deterministic embed payload — identical bytes for both flavors so
  # divergence in the response is the only signal.
  @embed_srcdoc """
  <!doctype html>
  <html>
    <head><meta charset="utf-8"><title>parity mockup</title></head>
    <body><h1>cross-flavor parity</h1><p>task 019e0307 stage 3</p></body>
  </html>
  """
  @embed_height 480

  # ── Setup helpers ────────────────────────────────────────────────────

  defp create_runtime_for(product, space_id)
       when product in ["claude_channel", "openclaw"] do
    user = root_admin!()

    agent =
      Repo.insert!(%Agent{
        slug: "canvas-embed-parity-#{product}-#{System.unique_integer([:positive])}",
        name: "Canvas Embed Parity Agent (#{product})",
        status: "active"
      })

    {:ok, _participant} = Chat.add_agent_participant(space_id, agent)

    raw_token = AgentRuntime.generate_token()

    attrs = %{
      runtime_id: "rt-canvas-embed-#{product}-#{System.unique_integer([:positive])}",
      owner_user_id: user.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(raw_token),
      status: "active",
      metadata: %{"client_info" => %{"product" => product}}
    }

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(attrs)
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        ["canvas"],
        Platform.Access.RuntimeProfiles.translated_permissions(["canvas"])
      )

    {runtime, raw_token, agent}
  end

  defp create_shared_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas Embed Parity",
        slug: "canvas-embed-parity-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp embed_document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "embed-1",
            "type" => "embed",
            "props" => %{
              "srcdoc" => @embed_srcdoc,
              "height" => @embed_height
            }
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
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

  # ── Parity verification ──────────────────────────────────────────────

  describe "canvas embed MCP parity (task 019e0307)" do
    setup do
      space = create_shared_space()

      {claude_runtime, claude_token, _claude_agent} =
        create_runtime_for("claude_channel", space.id)

      {openclaw_runtime, openclaw_token, _openclaw_agent} =
        create_runtime_for("openclaw", space.id)

      %{
        space: space,
        claude_runtime: claude_runtime,
        claude_token: claude_token,
        openclaw_runtime: openclaw_runtime,
        openclaw_token: openclaw_token
      }
    end

    test "tools/list exposes the canvas tool surface to both flavors", ctx do
      claude_tools = list_tool_names(ctx.claude_token)
      openclaw_tools = list_tool_names(ctx.openclaw_token)

      expected =
        MapSet.new([
          "canvas_create",
          "canvas_patch",
          "canvas_describe",
          "canvas_list_kinds",
          "canvas_template"
        ])

      assert MapSet.subset?(expected, claude_tools),
             "claude_channel runtime missing canvas tools: #{inspect(MapSet.difference(expected, claude_tools))}"

      assert MapSet.subset?(expected, openclaw_tools),
             "openclaw runtime missing canvas tools: #{inspect(MapSet.difference(expected, openclaw_tools))}"

      # Set equality: both flavors see exactly the same canvas tool surface.
      assert claude_tools == openclaw_tools
    end

    test "canvas_list_kinds responses are byte-equivalent and include `embed`", ctx do
      claude_body = call_list_kinds(ctx.claude_token)
      openclaw_body = call_list_kinds(ctx.openclaw_token)

      claude_norm = normalize_envelope(claude_body)
      openclaw_norm = normalize_envelope(openclaw_body)

      assert claude_norm == openclaw_norm,
             "canvas_list_kinds diverged between flavors. " <>
               "claude=#{inspect(claude_norm)} openclaw=#{inspect(openclaw_norm)}"

      tool_payload = decode_tool_text(claude_norm)
      kinds = tool_payload["kinds"]
      assert is_list(kinds) and kinds != []

      embed = Enum.find(kinds, &(&1["kind"] == "embed"))

      assert is_map(embed),
             "embed kind missing from canvas_list_kinds payload (got kinds=#{inspect(Enum.map(kinds, & &1["kind"]))})"

      assert embed["accepts_children"] == "none"
      assert is_map(embed["props"])
      assert Map.has_key?(embed["props"], "srcdoc")
      assert Map.has_key?(embed["props"], "height")
      assert is_map(embed["example"])
      assert embed["example"]["type"] == "embed"
    end

    test "canvas_create + canvas_describe round-trip is byte-equivalent for embed nodes",
         ctx do
      # Each flavor authors its own canvas in the shared space with an
      # identical embed-bearing document; we then describe each canvas
      # and compare the embed-node payload after stripping volatile
      # fields (canvas_id, space_id, revision, presence, node ids).
      {claude_canvas_id, claude_describe} =
        author_and_describe(ctx.claude_token, ctx.space.id)

      {openclaw_canvas_id, openclaw_describe} =
        author_and_describe(ctx.openclaw_token, ctx.space.id)

      on_exit(fn ->
        CanvasServer.stop(claude_canvas_id)
        CanvasServer.stop(openclaw_canvas_id)
      end)

      claude_embed = extract_embed_payload(claude_describe)
      openclaw_embed = extract_embed_payload(openclaw_describe)

      # Sanity: the embed payload actually round-tripped (so equality below
      # isn't comparing two empty maps).
      assert claude_embed["type"] == "embed"
      assert claude_embed["props"]["srcdoc"] == @embed_srcdoc
      assert claude_embed["props"]["height"] == @embed_height

      assert openclaw_embed["type"] == "embed"
      assert openclaw_embed["props"]["srcdoc"] == @embed_srcdoc
      assert openclaw_embed["props"]["height"] == @embed_height

      assert claude_embed == openclaw_embed,
             "embed-node payload diverged between flavors. " <>
               "claude=#{inspect(claude_embed)} openclaw=#{inspect(openclaw_embed)}"

      # Whole-document parity (after volatile-field normalization): no
      # flavor-conditional keys may appear anywhere in the describe envelope.
      claude_norm = normalize_describe(claude_describe)
      openclaw_norm = normalize_describe(openclaw_describe)

      assert claude_norm == openclaw_norm,
             "canvas_describe envelope diverged between flavors. " <>
               "claude=#{inspect(claude_norm)} openclaw=#{inspect(openclaw_norm)}"
    end
  end

  # ── Local helpers ────────────────────────────────────────────────────

  defp list_tool_names(token) do
    conn = Phoenix.ConnTest.build_conn()
    conn = mcp_post(conn, token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    tools |> Enum.map(& &1["name"]) |> MapSet.new()
  end

  defp call_list_kinds(token) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      mcp_post(
        conn,
        token,
        rpc("tools/call", %{"name" => "canvas_list_kinds", "arguments" => %{}})
      )

    json_response(conn, 200)
  end

  defp call_create(token, space_id) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      mcp_post(
        conn,
        token,
        rpc("tools/call", %{
          "name" => "canvas_create",
          "arguments" => %{
            "space_id" => space_id,
            "title" => "Canvas Embed Parity",
            "document" => embed_document()
          }
        })
      )

    json_response(conn, 200)
  end

  defp call_describe(token, canvas_id) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      mcp_post(
        conn,
        token,
        rpc("tools/call", %{
          "name" => "canvas_describe",
          "arguments" => %{"canvas_id" => canvas_id}
        })
      )

    json_response(conn, 200)
  end

  defp author_and_describe(token, space_id) do
    create_body = call_create(token, space_id)
    create_payload = decode_tool_text(create_body)

    canvas_id = create_payload["canvas_id"]

    assert is_binary(canvas_id),
           "canvas_create did not return a canvas_id; envelope=#{inspect(create_body)}"

    describe_body = call_describe(token, canvas_id)

    {canvas_id, describe_body}
  end

  # Drop the per-request `id` field so the comparison is invariant to
  # request ordering, then round-trip through Jason to canonicalize key
  # ordering and any encoder quirks.
  defp normalize_envelope(body) do
    body
    |> Map.delete("id")
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp decode_tool_text(envelope) do
    %{"result" => %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}} =
      envelope

    Jason.decode!(text)
  end

  # Pluck the embed node from a canvas_describe envelope. The root is a
  # stack with a single embed child (per `embed_document/0`).
  defp extract_embed_payload(envelope) do
    payload = decode_tool_text(envelope)
    [embed_node] = payload["document"]["root"]["children"]
    Map.take(embed_node, ["type", "props"])
  end

  # Strip every volatile / instance-specific field so two structurally-identical
  # canvases authored by different flavors compare equal. Keeps `type`, `props`,
  # children structure, and the canonical document framing
  # (version, theme, bindings, meta).
  defp normalize_describe(envelope) do
    payload = decode_tool_text(envelope)

    document = payload["document"]
    root = scrub_node(document["root"])

    scrubbed_document =
      document
      |> Map.put("root", root)
      |> Map.delete("revision")

    %{
      "kind" => payload["kind"],
      "title" => payload["title"],
      "presence" => payload["presence"],
      "recent_events" => payload["recent_events"],
      "document" => scrubbed_document
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp scrub_node(node) when is_map(node) do
    children =
      case Map.get(node, "children") do
        list when is_list(list) -> Enum.map(list, &scrub_node/1)
        nil -> nil
      end

    base =
      node
      |> Map.delete("id")
      |> Map.put("props", Map.get(node, "props", %{}))

    if children, do: Map.put(base, "children", children), else: Map.delete(base, "children")
  end
end
