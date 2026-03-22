defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Tasks
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

  defp create_project(attrs \\ %{}) do
    default = %{name: "Test Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  describe "tool_definitions/0" do
    test "returns all 8 tools with required components" do
      tools = ToolSurface.tool_definitions()
      assert length(tools) == 8

      tool_names = Enum.map(tools, & &1.name)
      assert "canvas_create" in tool_names
      assert "canvas_update" in tool_names
      assert "project_list" in tool_names
      assert "epic_list" in tool_names
      assert "task_create" in tool_names
      assert "task_get" in tool_names
      assert "task_list" in tool_names
      assert "task_update" in tool_names

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

    test "task_create creates a task with project_id" do
      project = create_project()

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Fix bug",
            "description" => "Something is broken"
          },
          %{}
        )

      assert result.title == "Fix bug"
      assert result.project_id == project.id
      assert result.status == "backlog"
      assert is_binary(result.id)
    end

    test "task_create without project_id returns error" do
      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{"title" => "No project"},
          %{}
        )

      assert error.error =~ "project_id"
      assert error.recoverable == true
    end

    test "task_get returns task details" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Test task"})

      {:ok, result} =
        ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})

      assert result.id == task.id
      assert result.title == "Test task"
    end

    test "task_list returns tasks filtered by project" do
      project = create_project()
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Task A"})
      {:ok, _} = Tasks.create_task(%{project_id: project.id, title: "Task B"})

      {:ok, results} =
        ToolSurface.execute("task_list", %{"project_id" => project.id}, %{})

      assert length(results) == 2
    end

    test "task_update changes task fields" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Old title"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "New title", "priority" => "high"},
          %{}
        )

      assert result.title == "New title"
      assert result.priority == "high"
    end

    test "project_list returns projects" do
      _project = create_project(%{name: "Unique Project"})

      {:ok, results} = ToolSurface.execute("project_list", %{}, %{})

      assert is_list(results)
      assert Enum.any?(results, fn p -> p.name == "Unique Project" end)
    end

    test "unknown tool returns structured error" do
      {:error, error} = ToolSurface.execute("nonexistent", %{}, %{})
      assert error.error =~ "Unknown tool"
      assert error.recoverable == false
    end
  end
end
