defmodule Platform.Federation.ToolSurfaceMeetingCompletionTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures
  alias Platform.Repo
  alias Platform.Agents.{Agent, AgentRuntime}

  alias Platform.Federation.{ReturnSchemas, ToolArguments, ToolSurface}

  @tools ~w(meeting_scribe_complete meeting_triage_file)

  test "completion entrypoints are in the meetings bundle and have return contracts" do
    definitions = ToolSurface.tool_definitions()

    for name <- @tools do
      tool = Enum.find(definitions, &(&1.name == name))
      assert tool.bundle == "meetings"
      assert tool.returns_schema == ReturnSchemas.for_tool(name)

      for key <- [:meeting_id, :run_id, :transcript_id, :canvas_id, :snapshot_hash] do
        assert tool.parameters[key].required
      end

      refute Map.has_key?(tool.parameters, :agent_id)
    end
  end

  test "caller-supplied identity cannot authenticate a filing" do
    args =
      Map.new(~w(meeting_id run_id transcript_id canvas_id agent_id), &{&1, Ecto.UUID.generate()})

    args = args |> Map.put("action_items", []) |> Map.put("snapshot_hash", "test-snapshot")

    for name <- @tools do
      assert {:error, %{code: :unauthorized}} = ToolArguments.dispatch(name, args, %{})
    end
  end

  test "required canonical identities are checked before dispatch" do
    for name <- @tools do
      assert {:error, _} = ToolArguments.dispatch(name, %{}, %{})
    end
  end

  test "priority item schema survives the hosted MCP export", %{conn: conn} do
    token = full_surface_token!()

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      |> json_response(200)

    tool = Enum.find(response["result"]["tools"], &(&1["name"] == "meeting_triage_file"))
    schema = tool["inputSchema"]["properties"]["action_items"]
    assert schema["type"] == "array"
    assert schema["items"]["type"] == "object"
    properties = schema["items"]["properties"]
    assert properties["priority"]["enum"] == ["low", "medium", "high", "critical"]
    assert properties["priority"]["default"] == "medium"
    refute "priority" in schema["items"]["required"]

    for field <-
          ~w(item_id title description source_segment_ids candidate_ids decision assignee_id assignee_type epic_id metadata) do
      assert Map.has_key?(properties, field)
    end
  end

  defp full_surface_token! do
    n = System.unique_integer([:positive])

    user = root_admin!()

    agent =
      Repo.insert!(%Agent{
        slug: "tool-doc-wire-#{n}",
        name: "ToolDoc Wire Agent #{n}",
        status: "active"
      })

    raw = AgentRuntime.generate_token()

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "tool-doc-wire-rt-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active",
        transport: "http",
        trust_level: "participant",
        metadata: %{}
      })

    Repo.insert!(%Platform.Access.RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ToolSurface.all_bundles(),
      restricted_permissions:
        Platform.Access.RuntimeProfiles.translated_permissions(ToolSurface.all_bundles())
    })

    raw
  end
end
