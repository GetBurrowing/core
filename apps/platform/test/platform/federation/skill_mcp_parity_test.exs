defmodule Platform.Federation.SkillMCPParityTest do
  @moduledoc """
  Cross-flavor parity test for the skill MCP surface.

  Verifies that two `AgentRuntime` rows distinguished only by their
  `metadata.client_info.product` value (`"claude_channel"` vs `"openclaw"`)
  see byte-equivalent responses from the canonical MCP chokepoint at
  `POST /mcp` when calling `tools/list`, `skill.list`, and `skill.get`.

  Both flavors converge on `PlatformWeb.MCPController` regardless of the
  upstream plugin, so exercising that controller directly via Phoenix
  ConnTest is the cheapest way to prove they cannot diverge by product.

  Also includes the anti-bulk-injection regression guard from task
  019dfaea: `Platform.Orchestration.ContextAssembler.build/2` must NOT
  splat every DB-resident skill into the dispatch payload — only those
  attached to the project/epic/task hierarchy are allowed through.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.Orchestration.ContextAssembler
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks

  # ── Setup helpers ────────────────────────────────────────────────────

  defp create_runtime(product) when product in ["claude_channel", "openclaw"] do
    user = root_admin!()

    raw_token = AgentRuntime.generate_token()

    attrs = %{
      runtime_id: "rt-#{product}-#{System.unique_integer([:positive])}",
      owner_user_id: user.id,
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
        ["skill"],
        Platform.Access.RuntimeProfiles.translated_permissions(["skill"])
      )

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

  defp seed_skill do
    suffix = System.unique_integer([:positive])
    name = "Parity Test Skill #{suffix}"

    {:ok, skill} =
      Skills.create_skill(%{
        name: name,
        description: "Deterministic skill for cross-flavor parity verification",
        content: """
        # #{name}

        This is a deterministic markdown body used to assert that
        `skill.get` returns identical bytes regardless of which
        federated agent flavor is calling. Includes some prose so
        the JSON round-trip exercises non-trivial content.
        """
      })

    skill
  end

  # ── Parity verification + anti-bulk-injection guard ──────────────────

  describe "DB-shipped skill MCP parity" do
    setup do
      skill = seed_skill()
      {claude_runtime, claude_token} = create_runtime("claude_channel")
      {openclaw_runtime, openclaw_token} = create_runtime("openclaw")

      %{
        skill: skill,
        claude_runtime: claude_runtime,
        claude_token: claude_token,
        openclaw_runtime: openclaw_runtime,
        openclaw_token: openclaw_token
      }
    end

    test "tools/list exposes the skill triple to both flavors", ctx do
      claude_tools = list_tool_names(ctx.claude_token)
      openclaw_tools = list_tool_names(ctx.openclaw_token)

      expected = MapSet.new(["skill.list", "skill.get", "skill.upsert"])

      assert MapSet.subset?(expected, claude_tools),
             "claude_channel runtime missing skill tools: #{inspect(MapSet.difference(expected, claude_tools))}"

      assert MapSet.subset?(expected, openclaw_tools),
             "openclaw runtime missing skill tools: #{inspect(MapSet.difference(expected, openclaw_tools))}"

      # Set equality: both flavors see the same tool list (ordering doesn't matter).
      assert claude_tools == openclaw_tools
    end

    test "skill.list responses are byte-equivalent across flavors", ctx do
      claude_body = call_skill_list(ctx.claude_token)
      openclaw_body = call_skill_list(ctx.openclaw_token)

      claude_norm = normalize_envelope(claude_body)
      openclaw_norm = normalize_envelope(openclaw_body)

      assert claude_norm == openclaw_norm,
             "skill.list diverged between flavors. claude=#{inspect(claude_norm)} openclaw=#{inspect(openclaw_norm)}"

      # Sanity: the seeded skill is actually visible (so the equality assertion above
      # isn't vacuously comparing two empty result sets).
      tool_payload = decode_tool_text(claude_norm)
      slugs = Enum.map(tool_payload["skills"], & &1["slug"])
      assert ctx.skill.slug in slugs
    end

    test "skill.get responses are byte-equivalent across flavors, including markdown content",
         ctx do
      claude_body = call_skill_get(ctx.claude_token, ctx.skill.slug)
      openclaw_body = call_skill_get(ctx.openclaw_token, ctx.skill.slug)

      claude_norm = normalize_envelope(claude_body)
      openclaw_norm = normalize_envelope(openclaw_body)

      assert claude_norm == openclaw_norm,
             "skill.get diverged between flavors. claude=#{inspect(claude_norm)} openclaw=#{inspect(openclaw_norm)}"

      tool_payload = decode_tool_text(claude_norm)
      assert tool_payload["slug"] == ctx.skill.slug
      assert tool_payload["content"] == ctx.skill.content
    end

    test "ContextAssembler does not bulk-inject DB skills into dispatch payload", ctx do
      # task 019dfaea — anti-bulk-injection guard for DB skills.
      # A skill that exists in the DB but is NOT attached to the task's
      # project/epic/task hierarchy must not appear in context.skills.
      # Otherwise a single seeded playbook would balloon every task's
      # dispatch payload and bypass the explicit attachment workflow.
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Parity guard task #{System.unique_integer([:positive])}",
          description: "Used to verify dispatch payload does not bulk-inject skills"
        })

      context = ContextAssembler.build(task.id)

      assert is_map(context),
             "ContextAssembler.build/2 returned nil for a freshly-created task"

      skills = Map.get(context, :skills) || []

      # Either nil/empty OR contains only org-context skill metadata.
      # Critically: the seeded skill (which is NOT attached to project/epic/task)
      # MUST NOT have its content body appear here.
      seeded_content = ctx.skill.content

      refute Enum.any?(skills, fn s -> Map.get(s, :content) == seeded_content end),
             "ContextAssembler bulk-injected the seeded DB skill into context.skills " <>
               "(task 019dfaea regression). Got: #{inspect(skills)}"

      refute Enum.any?(skills, fn s -> Map.get(s, :name) == ctx.skill.name end),
             "ContextAssembler leaked unattached skill name into context.skills " <>
               "(task 019dfaea regression). Got: #{inspect(skills)}"
    end
  end

  # ── Local helpers ────────────────────────────────────────────────────

  defp list_tool_names(token) do
    conn = Phoenix.ConnTest.build_conn()
    conn = mcp_post(conn, token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    tools |> Enum.map(& &1["name"]) |> MapSet.new()
  end

  defp call_skill_list(token) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      mcp_post(
        conn,
        token,
        rpc("tools/call", %{"name" => "skill.list", "arguments" => %{}})
      )

    json_response(conn, 200)
  end

  defp call_skill_get(token, slug) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      mcp_post(
        conn,
        token,
        rpc("tools/call", %{"name" => "skill.get", "arguments" => %{"slug" => slug}})
      )

    json_response(conn, 200)
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

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Skill Parity Project #{System.unique_integer([:positive])}"
      })

    project
  end
end
