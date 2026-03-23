defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.SpaceAgent
  alias Platform.Tasks
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

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
    test "returns all 18 tools with required components" do
      tools = ToolSurface.tool_definitions()
      assert length(tools) == 18

      tool_names = Enum.map(tools, & &1.name)
      assert "send_media" in tool_names
      assert "space_list" in tool_names
      assert "canvas_create" in tool_names
      assert "canvas_update" in tool_names
      assert "project_list" in tool_names
      assert "epic_list" in tool_names
      assert "task_create" in tool_names
      assert "task_get" in tool_names
      assert "task_list" in tool_names
      assert "task_update" in tool_names
      assert "task_complete" in tool_names
      assert "plan_create" in tool_names
      assert "plan_get" in tool_names
      assert "plan_submit" in tool_names
      assert "stage_start" in tool_names
      assert "stage_list" in tool_names
      assert "validation_evaluate" in tool_names
      assert "validation_list" in tool_names

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

    # ── Plan tools ──────────────────────────────────────────────────────

    test "plan_create creates a plan with stages and validations" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan task"})

      {:ok, result} =
        ToolSurface.execute(
          "plan_create",
          %{
            "task_id" => task.id,
            "stages" => [
              %{
                "name" => "Build",
                "description" => "Build the thing",
                "position" => 1,
                "validations" => [%{"kind" => "ci_check"}, %{"kind" => "test_pass"}]
              },
              %{
                "name" => "Review",
                "description" => "Review the thing",
                "position" => 2,
                "validations" => [%{"kind" => "code_review"}]
              }
            ]
          },
          %{}
        )

      assert result.task_id == task.id
      assert result.status == "draft"
      assert length(result.stages) == 2

      build_stage = Enum.find(result.stages, &(&1.name == "Build"))
      assert length(build_stage.validations) == 2
      assert Enum.any?(build_stage.validations, &(&1.kind == "ci_check"))

      review_stage = Enum.find(result.stages, &(&1.name == "Review"))
      assert length(review_stage.validations) == 1
    end

    test "plan_create without task_id returns error" do
      {:error, error} =
        ToolSurface.execute("plan_create", %{"stages" => []}, %{})

      assert error.recoverable == true
    end

    test "plan_get returns current approved plan" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, "tester")

      {:ok, result} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.status == "approved"
    end

    test "plan_get with no approved plan returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "No plan"})

      {:error, error} =
        ToolSurface.execute("plan_get", %{"task_id" => task.id}, %{})

      assert error.error =~ "No approved plan"
      assert error.recoverable == false
    end

    test "plan_submit transitions draft to pending_review" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Submit task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, result} =
        ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert result.status == "pending_review"
    end

    test "plan_submit on non-draft plan returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Submit task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      {:error, error} =
        ToolSurface.execute("plan_submit", %{"plan_id" => plan.id}, %{})

      assert error.error =~ "draft"
    end

    test "plan_submit with unknown plan_id returns error" do
      {:error, error} =
        ToolSurface.execute("plan_submit", %{"plan_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Plan not found"
    end

    # ── Stage tools ─────────────────────────────────────────────────────

    test "stage_list returns stages with validations" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stage task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      {:ok, results} =
        ToolSurface.execute("stage_list", %{"plan_id" => plan.id}, %{})

      assert length(results) == 1
      assert hd(results).name == "Build"
      assert length(hd(results).validations) == 1
    end

    test "stage_start transitions pending to running" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Start task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})

      {:ok, result} =
        ToolSurface.execute("stage_start", %{"stage_id" => stage.id}, %{})

      assert result.status == "running"
      assert result.name == "Build"
    end

    # ── Validation tools ────────────────────────────────────────────────

    test "validation_list returns validations for a stage" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Val task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      {:ok, results} =
        ToolSurface.execute("validation_list", %{"stage_id" => stage.id}, %{})

      assert length(results) == 2
    end

    test "validation_evaluate records passed result" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Eval task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      # Start the stage so validations can be evaluated
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      {:ok, result} =
        ToolSurface.execute(
          "validation_evaluate",
          %{
            "validation_id" => validation.id,
            "status" => "passed",
            "evidence" => %{"ci_url" => "https://ci.example.com/123"},
            "evaluated_by" => "ci_bot"
          },
          %{}
        )

      assert result.status == "passed"
      assert result.kind == "ci_check"
      assert result.evaluated_by == "ci_bot"
      assert result.evidence["ci_url"] == "https://ci.example.com/123"
    end

    test "validation_evaluate with invalid status returns error" do
      {:error, error} =
        ToolSurface.execute(
          "validation_evaluate",
          %{"validation_id" => Ecto.UUID.generate(), "status" => "invalid"},
          %{}
        )

      assert error.error =~ "Invalid status"
      assert error.recoverable == true
    end

    # ── task_complete ────────────────────────────────────────────────────

    test "task_complete marks a task as done" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Finish me", status: "in_progress"})

      {:ok, result} =
        ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.status == "done"
    end

    test "task_complete on non-existent task returns error" do
      {:error, error} =
        ToolSurface.execute("task_complete", %{"task_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    test "task_complete on task that cannot transition to done returns error" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Backlog task"})

      {:error, error} =
        ToolSurface.execute("task_complete", %{"task_id" => task.id}, %{})

      assert error.error =~ "Cannot transition"
    end

    # ── space_list ───────────────────────────────────────────────────────

    test "space_list returns spaces the agent is a member of" do
      agent = create_agent()
      space = create_space(%{name: "Agent Space"})

      {:ok, _sa} =
        %SpaceAgent{}
        |> SpaceAgent.changeset(%{space_id: space.id, agent_id: agent.id, role: "member"})
        |> Repo.insert()

      {:ok, results} =
        ToolSurface.execute("space_list", %{}, %{agent_id: agent.id})

      assert is_list(results)
      assert Enum.any?(results, fn s -> s.id == space.id end)
      space_result = Enum.find(results, &(&1.id == space.id))
      assert space_result.name == "Agent Space"
      assert space_result.kind == "channel"
    end

    test "space_list filters by kind" do
      agent = create_agent()
      channel = create_space(%{name: "Channel", kind: "channel"})
      dm = create_space(%{name: "DM", kind: "dm", slug: unique_slug()})

      for s <- [channel, dm] do
        {:ok, _} =
          %SpaceAgent{}
          |> SpaceAgent.changeset(%{space_id: s.id, agent_id: agent.id, role: "member"})
          |> Repo.insert()
      end

      {:ok, results} =
        ToolSurface.execute("space_list", %{"kind" => "dm"}, %{agent_id: agent.id})

      assert length(results) == 1
      assert hd(results).name == "DM"
    end

    # ── send_media ───────────────────────────────────────────────────────

    test "send_media posts a message with file attachment" do
      space = create_space()
      participant = create_participant(space.id)

      # Use a writable temp path for uploads in test
      test_uploads = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, test_uploads)

      # Create a temp file for testing
      tmp_path = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.txt")
      File.write!(tmp_path, "hello world")

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      try do
        {:ok, result} =
          ToolSurface.execute(
            "send_media",
            %{
              "space_id" => space.id,
              "file_path" => tmp_path,
              "content" => "Here is the file",
              "filename" => "test.txt"
            },
            context
          )

        assert is_binary(result.message_id)
        assert result.space_id == space.id
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path)
        File.rm_rf(test_uploads)
      end
    end

    test "send_media with non-existent file returns error" do
      space = create_space()
      participant = create_participant(space.id)

      context = %{
        space_id: space.id,
        agent_participant_id: participant.id
      }

      {:error, error} =
        ToolSurface.execute(
          "send_media",
          %{
            "space_id" => space.id,
            "file_path" => "/tmp/nonexistent-file-#{Ecto.UUID.generate()}.txt"
          },
          context
        )

      assert error.error =~ "Failed to send media"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "TestAgent",
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
end
