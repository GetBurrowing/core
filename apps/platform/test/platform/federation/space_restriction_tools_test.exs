defmodule Platform.Federation.SpaceRestrictionToolsTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures
  alias Platform.Access.Restrictions
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  test "rostered runtime reads before restriction; every read refuses afterward without leaking content" do
    owner = create_user!()
    org = Platform.Tenancy.get_org!(acme_org_id())
    plain_member!(owner, org)
    space = channel!(%{org_id: org.id, description: "secret description"})
    p = add_user!(space.id, owner.id)

    agent =
      Repo.insert!(%Agent{
        slug: "restr-tools-#{System.unique_integer([:positive])}",
        name: "Agent",
        status: "active"
      })

    add_agent!(space.id, agent.id)

    rt =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        runtime_id: "restr-tools-#{System.unique_integer([:positive])}",
        status: "active"
      })

    context = %{agent_id: agent.id, runtime_id: rt.runtime_id}
    marker = "restrictedfinancemarker"
    post!(space.id, p.id, marker)
    canvas = canvas!(space.id, p.id)
    args = %{"space_id" => space.id, "query" => marker}
    tools = ~w(space_get_messages space_get_context space_search_messages canvas_list)
    for tool <- tools, do: assert({:ok, _} = ToolSurface.execute(tool, args, context))
    assert {:ok, before} = ToolSurface.execute("space_get_messages", args, context)
    assert inspect(before) =~ marker
    assert {:ok, _} = ToolSurface.execute("canvas_get", %{"canvas_id" => canvas.id}, context)
    {:ok, _} = Restrictions.restrict_space(space, ["admin"], owner.id)

    for tool <- tools do
      assert {:error, denial} = ToolSurface.execute(tool, args, context)
      assert denial == Map.put(ToolSurface.space_write_denied(space.id), :restricted, true)
      refute inspect(denial) =~ marker
    end

    assert {:error, _} = ToolSurface.execute("canvas_get", %{"canvas_id" => canvas.id}, context)
    assert {:ok, %{spaces: rows}} = ToolSurface.execute("space_list", %{}, context)
    row = Enum.find(rows, &(&1.id == space.id))
    assert row.restricted and is_nil(row.description)
    # An in-process caller without a runtime must not bypass restrictions.
    assert {:error, %{restricted: true}} =
             ToolSurface.execute("space_get_messages", args, %{agent_id: agent.id})
  end
end
