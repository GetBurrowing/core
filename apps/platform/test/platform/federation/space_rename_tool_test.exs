defmodule Platform.Federation.SpaceRenameToolTest do
  @moduledoc """
  The `space_rename` MCP tool (task 01a19948 stage 2), a thin clause over
  `Platform.Chat.rename_space/3` with the calling agent as the actor, and the
  `origin` field `space_get_context` now returns.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Access.ToolPermissions
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defp unique, do: System.unique_integer([:positive])

  defp agent! do
    n = unique()

    Repo.insert!(%Agent{
      slug: "rename-tool-#{n}",
      name: "Burrow #{n}",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp user! do
    n = unique()

    Repo.insert!(%User{
      email: "rename-tool-#{n}@example.com",
      name: "Rename Tool #{n}",
      oidc_sub: "oidc-rename-tool-#{n}"
    })
  end

  defp channel!(metadata \\ %{}) do
    {:ok, space} =
      Chat.create_channel(%{
        name: "Plan this week's work",
        slug: "rename-tool-#{unique()}",
        org_id: acme_org_id(),
        created_by: user!().id,
        metadata: metadata
      })

    space
  end

  test "space_rename is listed in the space bundle with its docs and a chat.write permission" do
    tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "space_rename"))

    assert tool
    assert tool.parameters.space_id.required
    assert tool.parameters.name.required
    assert tool.returns =~ "slug"
    assert tool.limitations =~ "Channels only"
    assert tool.when_to_use =~ "first_run_goal"

    assert ToolPermissions.for_tool("space_rename") == "chat.write"
  end

  test "Burrow, as a participant, renames the channel" do
    agent = agent!()
    space = channel!()
    {:ok, _} = Chat.add_agent_participant(space.id, agent.id)

    assert {:ok, result} =
             ToolSurface.execute(
               "space_rename",
               %{"space_id" => space.id, "name" => "Spring launch plan"},
               %{agent_id: agent.id}
             )

    assert result == %{
             id: space.id,
             name: "Spring launch plan",
             slug: "spring-launch-plan",
             kind: "channel"
           }

    assert Repo.get!(Space, space.id).name == "Spring launch plan"
  end

  test "a non-participant agent is refused recoverably and nothing changes" do
    agent = agent!()
    space = channel!()

    assert {:error, %{recoverable: true, error: error}} =
             ToolSurface.execute(
               "space_rename",
               %{"space_id" => space.id, "name" => "Hijacked"},
               %{agent_id: agent.id}
             )

    assert error =~ "not a participant"
    assert Repo.get!(Space, space.id).name == space.name
  end

  test "a dm is refused recoverably as not applicable" do
    agent = agent!()
    user = user!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    assert {:error, %{recoverable: true, error: error}} =
             ToolSurface.execute(
               "space_rename",
               %{"space_id" => dm.id, "name" => "Renamed"},
               %{agent_id: agent.id}
             )

    assert error =~ "only channels"
  end

  test "missing arguments are refused recoverably" do
    agent = agent!()
    space = channel!()
    {:ok, _} = Chat.add_agent_participant(space.id, agent.id)

    assert {:error, %{recoverable: true, error: no_name}} =
             ToolSurface.execute("space_rename", %{"space_id" => space.id}, %{agent_id: agent.id})

    assert no_name =~ "`name` is required"

    assert {:error, %{recoverable: true, error: no_space}} =
             ToolSurface.execute("space_rename", %{"name" => "X"}, %{agent_id: agent.id})

    assert no_space =~ "`space_id` is required"

    assert {:error, %{recoverable: true}} =
             ToolSurface.execute(
               "space_rename",
               %{"space_id" => space.id, "name" => String.duplicate("a", 81)},
               %{agent_id: agent.id}
             )

    assert Repo.get!(Space, space.id).name == space.name
  end

  describe "space_get_context origin" do
    test "is first_run_goal for a channel a first goal opened" do
      agent = agent!()
      space = channel!(%{"origin" => "first_run_goal"})
      {:ok, _} = Chat.add_agent_participant(space.id, agent.id)

      assert {:ok, %{space: meta}} =
               ToolSurface.execute(
                 "space_get_context",
                 %{"space_id" => space.id},
                 %{agent_id: agent.id}
               )

      assert meta.origin == "first_run_goal"
      assert meta.id == space.id
    end

    test "is nil for any other channel" do
      agent = agent!()
      space = channel!()
      {:ok, _} = Chat.add_agent_participant(space.id, agent.id)

      assert {:ok, %{space: meta}} =
               ToolSurface.execute(
                 "space_get_context",
                 %{"space_id" => space.id},
                 %{agent_id: agent.id}
               )

      assert Map.has_key?(meta, :origin)
      assert meta.origin == nil
    end
  end
end
