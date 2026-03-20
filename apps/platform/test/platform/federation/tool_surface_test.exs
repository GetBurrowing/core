defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Federation.ToolSurface

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  describe "tool_definitions/0" do
    test "returns all 4 tools with required components" do
      tools = ToolSurface.tool_definitions()
      assert length(tools) == 4

      tool_names = Enum.map(tools, & &1.name)
      assert "canvas_create" in tool_names
      assert "canvas_update" in tool_names
      assert "task_create" in tool_names
      assert "task_complete" in tool_names

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :parameters)
        assert Map.has_key?(tool, :returns)
        assert Map.has_key?(tool, :limitations)
        assert Map.has_key?(tool, :when_to_use)
      end
    end
  end

  describe "execute/3" do
    test "canvas_create creates a canvas and returns structured result" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      {:ok, result} =
        ToolSurface.execute(
          "canvas_create",
          %{
            "canvas_type" => "table",
            "title" => "Test Table"
          },
          context
        )

      assert result.type == "table"
      assert result.title == "Test Table"
      assert is_binary(result.id)
    end

    test "canvas_create with invalid tool returns structured error" do
      {:error, error} =
        ToolSurface.execute("nonexistent_tool", %{}, %{})

      assert is_binary(error.error)
      assert is_boolean(error.recoverable)
      assert is_binary(error.suggestion)
    end

    test "task_create creates a task" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "title" => "Fix bug",
            "description" => "Something is broken"
          },
          context
        )

      assert result.title == "Fix bug"
      assert is_binary(result.id)
    end

    test "unknown tool returns structured error" do
      {:error, error} = ToolSurface.execute("nonexistent", %{}, %{})
      assert error.error =~ "Unknown tool"
      assert error.recoverable == false
    end
  end
end
