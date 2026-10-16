defmodule Platform.Security.RuntimeChannelCapabilityTest do
  @moduledoc """
  M15 security suite — federation half, WEBSOCKET transport.

  The mirror of `test/security/external_federation_scope_test.exs`, which
  drives `PlatformWeb.MCPController` (`POST /mcp`) exclusively. That asymmetry
  is the whole reason this file exists: the capability property was tested on
  the transport that HAD it and untested on the one that did NOT, so CI stayed
  green while `PlatformWeb.RuntimeChannel` advertised the entire catalogue and
  executed anything it was asked. The same adversarial world
  (`Platform.ExternalUserFixtures.external_world/0`) is now proved over the
  socket:

    * INTERNAL owner, `["federation"]` — the `capabilities` push carries
      exactly `["federation_status", "vault_fetch", "vault_list"]` (the
      vault tools joined the bundle in task 01a131c5), and `tool_call
      task_create` is denied
      with `not in allowed bundles` WITHOUT creating a row;
    * EXTERNAL owner, broad bundles — the push is exactly the six chat tools,
      `task_create` is denied and `space_list` is not;
    * FAIL-CLOSED INTERSECTION — EXTERNAL owner granted only `["task"]` gets an
      EMPTY push and `send_media` is denied (the external filter never injects
      a chat tool the bundles did not grant), matching
      `external_federation_scope_test.exs:76-92` over HTTP;
    * INTERNAL owner, `["canvas"]` — the DECLARED name `canvas.create`
      executes, and the legacy undeclared aliases `canvas_create` /
      `canvas_update` are DENIED.

  ## Deviation from the approved stage text (case 4), deliberate

  The approved plan asked this file to assert that the legacy alias
  `canvas_create` SUCCEEDS, as a "live-openclaw regression guard". That text
  predates the platform owner's ruling that openclaw plugins are transitioning
  to MCP-only and no longer call tools over WebSocket (higgins, the only active
  openclaw agent, is already MCP-configured). Stages 1-4 all shipped denial:
  `Platform.Federation.ToolAuthorization` has no `canonical_name/1` and no
  `@aliases` map, and `ToolSurface.tool_definitions/0` is the authorization
  vocabulary on both transports. The assertion is therefore inverted here —
  the aliases are pinned as DENIED, which is what the shipped code does.

  ## Explicit non-dependency

  `Platform.Agents.AgentRuntime.valid_bundles/0`
  (`lib/platform/agents/agent_runtime.ex`, 11 names) and
  `Platform.Federation.ToolSurface.all_bundles/0`
  (`lib/platform/federation/tool_surface.ex`, 12 names) DISAGREE: `files` is
  absent from the former, so it can never be granted through the changeset.
  That is a SEPARATE tracked issue and is deliberately NOT fixed here. Every
  grant in this file is a LITERAL list — nothing reads `valid_bundles/0` — so
  this suite cannot silently start depending on the two lists matching.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tasks

  @broad_bundles ~w(messaging space context_read task canvas)
  @chat_names ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  setup do
    world = World.external_world()
    agent = create_agent!()
    space = World.channel!(%{org_id: world.org_a.id})
    {:ok, _participant} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    Map.merge(world, %{agent: agent, agent_space: space})
  end

  # ── INTERNAL owner, narrow grant ───────────────────────────────────────

  describe "internal-owned runtime with only [federation]" do
    test "advertises exactly the federation bundle and denies task_create before executing it",
         ctx do
      {:ok, project} = Tasks.create_project(%{name: "WS scope #{unique()}"})
      before_count = Repo.aggregate(Tasks.Task, :count)

      {socket, capabilities} = join_runtime(ctx, ctx.int.id, ["federation"])

      assert tool_names(capabilities) == ["federation_status", "vault_fetch", "vault_list"]
      assert capabilities.tool_count == 3

      # Otherwise-valid arguments: this call WOULD have created a row had the
      # channel executed it, which is exactly what it used to do.
      frame =
        call_tool(socket, "task_create", %{
          "project_id" => project.id,
          "title" => "should never exist"
        })

      assert_denied(frame, "task_create")
      assert Repo.aggregate(Tasks.Task, :count) == before_count
      assert Repo.get_by(Tasks.Task, title: "should never exist") == nil
    end
  end

  # ── EXTERNAL owner, broad grant ────────────────────────────────────────

  describe "external-owned runtime with broad bundles" do
    test "advertises EXACTLY the six chat tools despite holding task and canvas", ctx do
      {_socket, capabilities} = join_runtime(ctx, ctx.ext.id, @broad_bundles)

      names = tool_names(capabilities)
      assert names == Enum.sort(@chat_names)
      assert capabilities.tool_count == 6

      refute "task_create" in names
      refute "canvas.create" in names
      refute "space_leave" in names
      refute "principal_search" in names
    end

    test "task_create is denied and space_list is not", ctx do
      {socket, _capabilities} = join_runtime(ctx, ctx.ext.id, @broad_bundles)

      assert_denied(call_tool(socket, "task_create", %{}), "task_create")

      allowed = call_tool(socket, "space_list", %{})
      assert allowed.status == "ok"
    end
  end

  # ── EXTERNAL owner, fail-closed intersection ───────────────────────────

  describe "external-owned runtime with only [task] (fail-closed)" do
    test "the capabilities push is EMPTY and send_media is denied", ctx do
      {socket, capabilities} = join_runtime(ctx, ctx.ext.id, ["task"])

      # The external allowlist is an INTERSECTION applied after bundle
      # scoping — it can only ever remove. A runtime granted `task` and
      # nothing else gets zero chat tools rather than the six.
      assert capabilities.tools == []
      assert capabilities.tool_count == 0

      assert_denied(call_tool(socket, "send_media", %{}), "send_media")
      assert_denied(call_tool(socket, "task_create", %{}), "task_create")
    end
  end

  # ── INTERNAL owner, canvas grant + the legacy aliases ──────────────────

  describe "internal-owned runtime with [canvas]" do
    test "the declared name canvas.create executes", ctx do
      {socket, capabilities} = join_runtime(ctx, ctx.int.id, ["canvas"])

      assert "canvas.create" in tool_names(capabilities)

      frame =
        call_tool(socket, "canvas.create", %{
          "space_id" => ctx.agent_space.id,
          "title" => "WS Capability Canvas",
          "document" => minimal_document()
        })

      assert frame.status == "ok"
      assert frame.result.title == "WS Capability Canvas"
    end

    # Inverted from the approved stage text on the owner's MCP-only ruling —
    # see the moduledoc. These two names have `execute/3` clauses
    # (`tool_surface.ex:2700` and `:2718`) but no `tool_definitions/0` entry,
    # so they belong to no bundle and are denied on BOTH transports. The
    # openclaw bridge must call `canvas.create` / `canvas.patch` instead.
    test "the legacy undeclared aliases canvas_create and canvas_update are DENIED", ctx do
      {socket, _capabilities} = join_runtime(ctx, ctx.int.id, ["canvas"])

      args = %{
        "space_id" => ctx.agent_space.id,
        "title" => "Legacy Alias Canvas",
        "document" => minimal_document()
      }

      assert_denied(call_tool(socket, "canvas_create", args), "canvas_create")
      assert_denied(call_tool(socket, "canvas_update", args), "canvas_update")

      # And they are never advertised either — the advertised set and the
      # callable set are the same list by construction.
      {_socket2, capabilities} = join_runtime(ctx, ctx.int.id, ["canvas"])
      names = tool_names(capabilities)
      refute "canvas_create" in names
      refute "canvas_update" in names
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp join_runtime(ctx, owner_user_id, tool_profile) do
    {runtime, token} = runtime_for(ctx, owner_user_id, tool_profile)

    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})

    assert_push("capabilities", capabilities)
    {socket, capabilities}
  end

  # Mirrors `external_federation_scope_test.exs`'s builder, plus an `agent_id`
  # so `tool_call` has an agent-shaped execution context. `tool_profile` is
  # always a literal list supplied by the caller.
  defp runtime_for(ctx, owner_user_id, tool_profile) do
    raw_token = AgentRuntime.generate_token()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "ws-cap-#{unique()}",
        owner_user_id: owner_user_id,
        agent_id: ctx.agent.id,
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

  defp call_tool(socket, tool, args) do
    call_id = "ws-cap-call-#{unique()}"
    push(socket, "tool_call", %{"call_id" => call_id, "tool" => tool, "args" => args})
    assert_push("tool_result", %{call_id: ^call_id} = frame)
    frame
  end

  # The denial frame shape is load-bearing: openclaw-suite-channel's
  # suite-client.ts rejects with `payload.error?.error`, and the wording is
  # byte-identical to the `-32001` message `/mcp` returns for the same refusal.
  #
  # DENIAL is asserted structurally — `status == "error"` plus
  # `code == "forbidden"` — and stays exactly as strict as it was. Only the
  # message expectation moved: it now comes from the shared formatter
  # `ToolAuthorization.deny_message/1` instead of a hardcoded sentence, which
  # is what actually holds the byte-identical-across-transports property. Task
  # 01a089c8 split the single sentence into "missing grant" vs "unknown tool";
  # a literal here turned that wording change into a false security failure on
  # the two undeclared canvas aliases even though both were still denied. The
  # sentences themselves are pinned literally where the wording IS the subject:
  # `test/platform/federation/tool_authorization_test.exs`,
  # `test/platform_web/controllers/mcp_controller_test.exs` and
  # `test/platform_web/channels/runtime_channel_test.exs`.
  defp assert_denied(frame, tool) do
    assert frame.status == "error"
    assert frame.error.error == ToolAuthorization.deny_message(tool)
    assert frame.error.code == "forbidden"
  end

  defp tool_names(capabilities), do: capabilities.tools |> Enum.map(& &1.name) |> Enum.sort()

  defp create_agent! do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "ws-cap-agent-#{unique()}",
        name: "WS Capability Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  defp minimal_document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "t",
            "type" => "text",
            "props" => %{"value" => "hello"},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp unique, do: System.unique_integer([:positive])
end
