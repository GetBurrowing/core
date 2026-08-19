defmodule Platform.Federation.SpaceCreateToolTest do
  @moduledoc """
  Tests for the `space_create` tool surface clause.

  The tool exists because the alternative — agents creating channels via a raw
  `Platform.Chat.create_channel/1` RPC and then hand-adding participants —
  repeatedly wrote `chat_participants` rows with a NULL `display_name`, which
  silently dropped every `@[Name]` mention of the affected agent. So the
  load-bearing assertion here is that every participant it writes has a
  non-null, correctly-resolved display name.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defp create_agent(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "agent-#{n}",
      name: "Dalton",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  describe "space_create" do
    test "creates a channel and every participant has a resolved display_name" do
      caller = create_agent(%{name: "Dalton"})
      other = create_agent(%{name: "Higgins"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{
                   "name" => "Webhook Intake",
                   "slug" => "webhook-intake-#{System.unique_integer([:positive])}",
                   "description" => "Inbound webhook triage",
                   "agent_ids" => [other.id]
                 },
                 %{agent_id: caller.id}
               )

      assert result.kind == "channel"
      assert result.name == "Webhook Intake"
      assert result.skipped == []

      # The whole point of the tool.
      refute Enum.any?(result.participants, &is_nil(&1.display_name))

      names = result.participants |> Enum.map(& &1.display_name) |> Enum.sort()
      assert "Dalton" in names
      assert "Higgins" in names

      # And it holds in the database, not just in the response payload.
      persisted = Chat.list_participants(result.id, participant_type: "agent")
      refute persisted == []
      refute Enum.any?(persisted, &(is_nil(&1.display_name) or &1.display_name == ""))
    end

    test "the calling agent is added as a participant" do
      caller = create_agent(%{name: "Dalton"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Files Module #{System.unique_integer([:positive])}"},
                 %{agent_id: caller.id}
               )

      assert Enum.any?(result.participants, &(&1.agent_id == caller.id))
    end

    test "derives a slug from the name when none is given" do
      caller = create_agent()

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Email  System!!"},
                 %{agent_id: caller.id}
               )

      assert result.slug == "email-system"
    end

    test "requires a name" do
      caller = create_agent()

      assert {:error, envelope} =
               ToolSurface.execute("space_create", %{}, %{agent_id: caller.id})

      assert envelope.error =~ "name"
      assert envelope.recoverable
    end

    test "a slug collision is a recoverable error, not a silent reuse" do
      caller = create_agent()
      slug = "certification-system-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Certification", "slug" => slug},
                 %{agent_id: caller.id}
               )

      assert {:error, envelope} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Certification", "slug" => slug},
                 %{agent_id: caller.id}
               )

      assert envelope.recoverable
    end

    test "unresolvable extra agents are reported in skipped, not fatal" do
      caller = create_agent()

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{
                   "name" => "Partial #{System.unique_integer([:positive])}",
                   "agent_ids" => ["not-a-real-agent"]
                 },
                 %{agent_id: caller.id}
               )

      assert [%{agent_id: "not-a-real-agent"}] = result.skipped
      assert Enum.any?(result.participants, &(&1.agent_id == caller.id))
    end

    test "is exposed in the space capability bundle" do
      names =
        ToolSurface.list_tools(["space"])
        |> Enum.map(& &1.name)

      assert "space_create" in names

      definition =
        ToolSurface.tool_definitions()
        |> Enum.find(&(&1.name == "space_create"))

      assert definition.bundle == "space"
    end
  end
end
