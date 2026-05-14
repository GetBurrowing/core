defmodule Platform.Federation.ToolSurfaceTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat

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
    test "returns all 62 tools with required components" do
      tools = ToolSurface.tool_definitions()
      assert length(tools) == 62

      tool_names = Enum.map(tools, & &1.name)
      assert "send_media" in tool_names
      assert "react" in tool_names
      assert "canvas.versions" in tool_names
      assert "canvas.restore" in tool_names
      assert "space_list" in tool_names
      assert "space_list_agents" in tool_names
      assert "space_leave" in tool_names
      assert "canvas.create" in tool_names
      assert "canvas.patch" in tool_names
      assert "canvas.describe" in tool_names
      assert "canvas.list_kinds" in tool_names
      assert "canvas.template" in tool_names
      assert "skill.list" in tool_names
      assert "skill.get" in tool_names
      assert "skill.upsert" in tool_names
      assert "project_list" in tool_names
      assert "project_update" in tool_names
      assert "epic_list" in tool_names
      assert "task_create" in tool_names
      assert "task_get" in tool_names
      assert "task_list" in tool_names
      assert "task_update" in tool_names
      assert "task_start" in tool_names
      assert "task_complete" in tool_names
      assert "task_dependencies" in tool_names
      assert "stack_create" in tool_names
      assert "stack_get" in tool_names
      assert "stack_list" in tool_names
      assert "stack_add" in tool_names
      assert "stack_eject" in tool_names
      assert "stack_abandon" in tool_names
      assert "stack_start" in tool_names
      assert "stack_assign_agents" in tool_names
      assert "plan_create" in tool_names
      assert "plan_get" in tool_names
      assert "plan_submit" in tool_names
      assert "stage_start" in tool_names
      assert "stage_list" in tool_names
      assert "validation_evaluate" in tool_names
      assert "validation_pass" in tool_names
      assert "stage_complete" in tool_names
      assert "report_blocker" in tool_names
      assert "validation_list" in tool_names
      assert "review_request_create" in tool_names
      assert "prompt_template_list" in tool_names
      assert "prompt_template_update" in tool_names
      assert "federation_status" in tool_names
      # Context read tools
      assert "space_get_context" in tool_names
      assert "space_search_messages" in tool_names
      assert "space_get_messages" in tool_names
      assert "canvas_list" in tool_names
      assert "canvas_get" in tool_names
      assert "attachment.upload_inline" in tool_names
      assert "attachment.upload_start" in tool_names
      assert "attachment.get_inline" in tool_names

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :parameters)
        assert Map.has_key?(tool, :returns)
        assert Map.has_key?(tool, :limitations)
        assert Map.has_key?(tool, :when_to_use)
        assert Map.has_key?(tool, :bundle)
        assert tool.bundle in ToolSurface.all_bundles()
      end
    end
  end

  describe "list_tools/1" do
    test "scopes the surface to the requested bundles" do
      tools = ToolSurface.list_tools(["task"])
      names = Enum.map(tools, & &1.name)

      assert "task_create" in names
      assert "task_list" in names
      refute "canvas_create" in names
      refute "plan_create" in names
      assert Enum.all?(tools, &(&1.bundle == "task"))
    end

    test "returns the union when multiple bundles are requested" do
      tools = ToolSurface.list_tools(["federation", "messaging"])
      bundles = tools |> Enum.map(& &1.bundle) |> Enum.uniq() |> Enum.sort()

      assert bundles == ["federation", "messaging"]
      assert "federation_status" in Enum.map(tools, & &1.name)
      assert "send_media" in Enum.map(tools, & &1.name)
    end

    test "silently skips unknown bundle names" do
      known = ToolSurface.list_tools(["task"])
      mixed = ToolSurface.list_tools(["task", "does_not_exist"])

      assert known == mixed
    end

    test "returns an empty list for no bundles" do
      assert ToolSurface.list_tools([]) == []
    end

    test "matches tool_definitions/0 when all bundles are requested" do
      scoped = ToolSurface.list_tools(ToolSurface.all_bundles())
      full = ToolSurface.tool_definitions()

      assert Enum.map(scoped, & &1.name) |> Enum.sort() ==
               Enum.map(full, & &1.name) |> Enum.sort()
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

      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            %{
              "id" => "t",
              "type" => "table",
              "props" => %{
                "columns" => ["Name", "Owner"],
                "rows" => [%{"Name" => "One", "Owner" => "You"}]
              },
              "children" => []
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      {:ok, result} =
        ToolSurface.execute(
          "canvas_create",
          %{
            "title" => "Test Table",
            "document" => document
          },
          context
        )

      assert result.kind == "stack"
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

    test "task_update sets deploy_target so the deploying-phase dispatch can pin a target" do
      # Regression: deploy_target was castable on the schema but not exposed
      # by task_update, leaving any task that auto-advanced to `deploying`
      # without a target stuck waiting for a UI/psql change.
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Deploy me"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "deploy_target" => "production"},
          %{}
        )

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.deploy_target == "production"
      # The result map mirrors the existing task_update return shape; we
      # don't expand it here because the existing test above guards that
      # surface — only assert the new field round-trips through the DB.
      assert is_map(result)
    end

    test "project_update sets deploy_config.default_strategy" do
      project = create_project(%{name: "Default-strategy project"})

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "deploy_config" => %{"default_strategy" => %{"type" => "pr_merge"}}
          },
          %{}
        )

      assert result.deploy_config["default_strategy"] == %{"type" => "pr_merge"}

      reloaded = Tasks.get_project(project.id)
      assert reloaded.deploy_config["default_strategy"] == %{"type" => "pr_merge"}
    end

    test "project_update rejects unknown deploy strategy types with a recoverable error" do
      project = create_project()

      {:error, error} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "deploy_config" => %{"default_strategy" => %{"type" => "definitely-not-a-strategy"}}
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "unknown strategy type"
    end

    test "project_update returns not-found error for unknown project_id" do
      {:error, error} =
        ToolSurface.execute("project_update", %{"project_id" => Ecto.UUID.generate()}, %{})

      assert error.recoverable == false
      assert error.error =~ "Project not found"
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
      {:ok, _plan} = Tasks.approve_plan(plan, "00000000-0000-0000-0000-000000000001")

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

    test "validation_pass is an alias for passing a validation" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Alias task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      {:ok, result} =
        ToolSurface.execute(
          "validation_pass",
          %{"validation_id" => validation.id, "evidence" => %{"tests" => "green"}},
          %{}
        )

      assert result.status == "passed"
      assert result.evidence["tests"] == "green"
    end

    test "stage_complete advances a validation-free running stage" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Complete task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      {:ok, result} = ToolSurface.execute("stage_complete", %{"stage_id" => stage.id}, %{})

      assert result.stage_id == stage.id
      assert result.plan_id == plan.id
      assert result.plan_status in ["completed", "draft"]
    end

    test "report_blocker records a structured runtime blocker" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Blocked task"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Build", position: 1})

      {:ok, result} =
        ToolSurface.execute(
          "report_blocker",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "description" => "Missing deploy credentials",
            "needs_human" => true
          },
          %{runtime_id: "runtime:test", agent_id: "agent:test"}
        )

      assert result.blocked == true
      assert result.task_id == task.id
      assert is_binary(result.event_id)
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

    # ── task_dependencies ────────────────────────────────────────────────

    test "task_dependencies returns deps, unmet, and dependents for a task with both" do
      project = create_project()
      {:ok, dep_done} = Tasks.create_task(%{project_id: project.id, title: "Dep Done"})
      {:ok, dep_done} = Tasks.transition_task_status(dep_done, "in_progress")
      {:ok, dep_done} = Tasks.transition_task_status(dep_done, "done")

      {:ok, dep_in_progress} =
        Tasks.create_task(%{project_id: project.id, title: "Dep In Progress"})

      {:ok, dep_in_progress} = Tasks.transition_task_status(dep_in_progress, "in_progress")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Has deps",
          dependencies: [
            %{"task_id" => dep_done.id, "kind" => "blocks"},
            %{"task_id" => dep_in_progress.id, "kind" => "blocks"}
          ]
        })

      {:ok, dependent} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Listed-by",
          dependencies: [%{"task_id" => task.id, "kind" => "blocks"}]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert length(result.deps) == 2
      assert result.unmet == [dep_in_progress.id]

      assert result.dependents == [
               %{task_id: dependent.id, title: "Listed-by", status: "backlog"}
             ]
    end

    test "task_dependencies preserves authored order of deps" do
      project = create_project()
      {:ok, a} = Tasks.create_task(%{project_id: project.id, title: "Alpha"})
      {:ok, b} = Tasks.create_task(%{project_id: project.id, title: "Bravo"})
      {:ok, c} = Tasks.create_task(%{project_id: project.id, title: "Charlie"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ordered deps",
          dependencies: [
            %{"task_id" => c.id, "kind" => "blocks"},
            %{"task_id" => a.id, "kind" => "blocks"},
            %{"task_id" => b.id, "kind" => "blocks"}
          ]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert Enum.map(result.deps, & &1.task_id) == [c.id, a.id, b.id]
      assert Enum.map(result.deps, & &1.kind) == ["blocks", "blocks", "blocks"]
    end

    test "task_dependencies returns empty arrays for a task with neither deps nor dependents" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lonely"})

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      assert result == %{deps: [], unmet: [], dependents: []}
    end

    test "task_dependencies returns nil title/status for missing dep ids but keeps task_id + kind" do
      project = create_project()
      missing_id = Ecto.UUID.generate()
      {:ok, real} = Tasks.create_task(%{project_id: project.id, title: "Real"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mixed deps",
          dependencies: [
            %{"task_id" => missing_id, "kind" => "blocks"},
            %{"task_id" => real.id, "kind" => "blocks"}
          ]
        })

      {:ok, result} =
        ToolSurface.execute("task_dependencies", %{"task_id" => task.id}, %{})

      [first, second] = result.deps
      assert first == %{task_id: missing_id, title: nil, kind: "blocks", status: nil}
      assert second.task_id == real.id
      assert second.title == "Real"
      assert second.kind == "blocks"
      assert second.status == "backlog"
    end

    test "task_dependencies returns not-found error for unknown task_id" do
      {:error, error} =
        ToolSurface.execute(
          "task_dependencies",
          %{"task_id" => Ecto.UUID.generate()},
          %{}
        )

      assert error.error =~ "Task not found"
      assert error.recoverable == false
    end

    # ── space_list ───────────────────────────────────────────────────────

    test "space_list returns spaces the agent is a member of" do
      agent = create_agent()
      space = create_space(%{name: "Agent Space"})

      create_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name
      })

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
        create_participant(s.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name
        })
      end

      {:ok, results} =
        ToolSurface.execute("space_list", %{"kind" => "dm"}, %{agent_id: agent.id})

      assert length(results) == 1
      assert hd(results).name == "DM"
    end

    # ── space_list_agents ────────────────────────────────────────────────

    test "space_list_agents returns active agent participants enriched with slug + name" do
      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Engineering"})

      {:ok, higgins_p} =
        Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")

      {:ok, _geordi_p} =
        Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      {:ok, rows} = ToolSurface.execute("space_list_agents", %{"space_id" => space.id}, %{})

      assert length(rows) == 2
      higgins_row = Enum.find(rows, &(&1.agent_id == higgins.id))
      assert higgins_row.slug == higgins.slug
      assert higgins_row.name == "Higgins"
      assert higgins_row.display_name == "Higgins"
      assert higgins_row.participant_id == higgins_p.id
      assert %DateTime{} = higgins_row.joined_at
    end

    test "space_list_agents excludes human participants and left agents" do
      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Mixed"})

      {:ok, _} = Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")
      {:ok, geordi_p} = Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      # Human participant — uses a raw UUID, no corresponding agent row.
      human_user_id = Ecto.UUID.generate()

      create_participant(space.id, %{
        participant_type: "user",
        participant_id: human_user_id,
        display_name: "Human"
      })

      # Geordi leaves.
      {:ok, _} = Chat.remove_participant(geordi_p)

      {:ok, rows} = ToolSurface.execute("space_list_agents", %{"space_id" => space.id}, %{})

      agent_ids = Enum.map(rows, & &1.agent_id)
      assert higgins.id in agent_ids
      refute geordi.id in agent_ids
      refute human_user_id in agent_ids
    end

    test "space_list_agents returns an error when space_id is missing" do
      assert {:error, err} = ToolSurface.execute("space_list_agents", %{}, %{})
      assert err.error =~ "space_id is required"
    end

    # ── space_leave ──────────────────────────────────────────────────────

    test "space_leave removes the calling agent from the space (self-leave)" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space(%{name: "DM Stuck", kind: "dm", slug: unique_slug()})

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      {:ok, result} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert result.space_id == space.id
      assert result.agent_id == agent.id
      assert result.participant_id == participant.id
      assert result.removed == true
      assert result.self_removed == true
      assert %DateTime{} = result.removed_at

      # Hard-delete (ADR 0038): the row is gone.
      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end

    test "space_leave removes a different agent when agent_id is provided" do
      ensure_active_agent_store()

      higgins = create_agent(%{name: "Higgins"})
      geordi = create_agent(%{name: "Geordi"})
      space = create_space(%{name: "Engineering"})

      {:ok, _higgins_p} =
        Chat.add_agent_participant(space.id, higgins, display_name: "Higgins")

      {:ok, geordi_p} =
        Chat.add_agent_participant(space.id, geordi, display_name: "Geordi")

      {:ok, result} =
        ToolSurface.execute(
          "space_leave",
          %{"space_id" => space.id, "agent_id" => geordi.id},
          %{agent_id: higgins.id}
        )

      assert result.agent_id == geordi.id
      assert result.participant_id == geordi_p.id
      assert result.self_removed == false

      assert Chat.get_agent_participant(space.id, geordi.id) == nil
      # Caller stays put.
      refute Chat.list_participants(space.id) |> Enum.any?(&(&1.participant_id == geordi.id))
      assert Chat.list_participants(space.id) |> Enum.any?(&(&1.participant_id == higgins.id))
    end

    test "space_leave returns an error when the target agent is not in the space" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      assert {:error, error} =
               ToolSurface.execute(
                 "space_leave",
                 %{"space_id" => space.id},
                 %{agent_id: agent.id}
               )

      assert error.error =~ "not an active participant"
      assert error.recoverable == false
    end

    test "space_leave refuses to remove human participants (agent-only tool)" do
      ensure_active_agent_store()

      caller = create_agent()
      space = create_space()
      human = create_participant(space.id, %{display_name: "Rowan"})

      # Try to target the human's participant_id — the helper filters on
      # participant_type="agent", so this should come back with not-found
      # rather than actually removing the human.
      {:error, error} =
        ToolSurface.execute(
          "space_leave",
          %{"space_id" => space.id, "agent_id" => human.participant_id},
          %{agent_id: caller.id}
        )

      assert error.error =~ "not an active participant"
      # Human is still a participant.
      assert Repo.reload!(human)
    end

    test "space_leave is idempotent — already-left participants return not-found" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      {:ok, _participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      # First call removes cleanly.
      {:ok, _} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert Chat.get_agent_participant(space.id, agent.id) == nil

      # Second call: the participant row is gone, so the lookup returns nil
      # and the tool surfaces a clear error.
      {:error, error} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert error.error =~ "not an active participant"
    end

    test "space_leave clears the active-agent mutex if the leaver was holding it" do
      ensure_active_agent_store()

      agent = create_agent()
      space = create_space()

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: agent.name)

      Platform.Chat.ActiveAgentStore.set_active(space.id, participant.id)
      assert Platform.Chat.ActiveAgentStore.get_active(space.id) == participant.id

      {:ok, _} =
        ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{agent_id: agent.id})

      assert Platform.Chat.ActiveAgentStore.get_active(space.id) == nil
    end

    test "space_leave requires space_id" do
      agent = create_agent()

      assert {:error, error} =
               ToolSurface.execute("space_leave", %{}, %{agent_id: agent.id})

      assert error.error =~ "space_id is required"
    end

    test "space_leave requires an identifiable caller when agent_id arg is omitted" do
      space = create_space()

      assert {:error, error} =
               ToolSurface.execute("space_leave", %{"space_id" => space.id}, %{})

      assert error.error =~ "identity unresolved"
    end

    # ── send_media ───────────────────────────────────────────────────────

    test "send_media posts a message with single file attachment" do
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
        assert result.attachment_count == 1
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path)
        File.rm_rf(test_uploads)
      end
    end

    test "send_media posts a message with file_paths attachments" do
      space = create_space()
      participant = create_participant(space.id)

      test_uploads = Path.join(System.tmp_dir!(), "platform_test_uploads_#{Ecto.UUID.generate()}")
      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, test_uploads)

      tmp_path_1 = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.txt")
      tmp_path_2 = Path.join(System.tmp_dir!(), "test-upload-#{Ecto.UUID.generate()}.md")
      File.write!(tmp_path_1, "hello world")
      File.write!(tmp_path_2, "# hello")

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
              "file_paths" => [tmp_path_1, tmp_path_2],
              "content" => "Here are the files"
            },
            context
          )

        assert is_binary(result.message_id)
        assert result.space_id == space.id
        assert result.attachment_count == 2
      after
        Application.put_env(:platform, :chat_attachments_root, prev)
        File.rm(tmp_path_1)
        File.rm(tmp_path_2)
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

    # ── react ───────────────────────────────────────────────────────────

    test "react adds an emoji reaction to a message" do
      space = create_space()
      author = create_participant(space.id)
      agent_participant = create_participant(space.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      {:ok, result} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space.id,
            "message_id" => message.id,
            "emoji" => "👍"
          },
          %{space_id: space.id, agent_participant_id: agent_participant.id}
        )

      assert result.message_id == message.id
      assert result.space_id == space.id
      assert result.emoji == "👍"
      assert result.status == "added"

      assert [%{emoji: "👍"}] = Chat.list_reactions(message.id)
    end

    test "react is idempotent — second call returns already_reacted" do
      space = create_space()
      author = create_participant(space.id)
      agent_participant = create_participant(space.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      context = %{space_id: space.id, agent_participant_id: agent_participant.id}
      args = %{"space_id" => space.id, "message_id" => message.id, "emoji" => "🎉"}

      {:ok, first} = ToolSurface.execute("react", args, context)
      {:ok, second} = ToolSurface.execute("react", args, context)

      assert first.status == "added"
      assert second.status == "already_reacted"
      assert length(Chat.list_reactions(message.id)) == 1
    end

    test "react rejects a message from a different space" do
      space_a = create_space()
      space_b = create_space()
      author = create_participant(space_a.id)
      agent_participant = create_participant(space_b.id, %{display_name: "Agent"})

      {:ok, message} =
        Chat.post_message(%{
          space_id: space_a.id,
          participant_id: author.id,
          content_type: "text",
          content: "hello"
        })

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space_b.id,
            "message_id" => message.id,
            "emoji" => "👍"
          },
          %{space_id: space_b.id, agent_participant_id: agent_participant.id}
        )

      assert error.error =~ "does not belong to space"
      assert Chat.list_reactions(message.id) == []
    end

    test "react returns error for non-existent message" do
      space = create_space()
      participant = create_participant(space.id, %{display_name: "Agent"})

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{
            "space_id" => space.id,
            "message_id" => Ecto.UUID.generate(),
            "emoji" => "👍"
          },
          %{space_id: space.id, agent_participant_id: participant.id}
        )

      assert error.error =~ "not found"
    end

    test "react rejects missing emoji" do
      space = create_space()
      participant = create_participant(space.id, %{display_name: "Agent"})

      {:error, error} =
        ToolSurface.execute(
          "react",
          %{"space_id" => space.id, "message_id" => Ecto.UUID.generate(), "emoji" => ""},
          %{space_id: space.id, agent_participant_id: participant.id}
        )

      assert error.error =~ "emoji is required"
    end

    # ── Stack tools (ADR 0041) ────────────────────────────────────────

    test "stack_create creates a stack and returns stack_id + rollup_branch" do
      project = create_project()
      slug = "shim-create-#{System.unique_integer([:positive])}"

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Create"},
          %{}
        )

      assert is_binary(result.stack_id)
      assert result.rollup_branch == "stack/#{slug}"
    end

    test "stack_create returns slug_taken envelope on duplicate slug within project" do
      project = create_project()
      slug = "shim-dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "First"},
          %{}
        )

      {:error, error} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Second"},
          %{}
        )

      assert error.code == "slug_taken"
      assert error.recoverable == true
    end

    test "stack_create with invalid slug returns a clean error envelope" do
      project = create_project()

      {:error, error} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => "Bad Slug!", "name" => "Bad"},
          %{}
        )

      refute Map.get(error, :code) == "slug_taken"
      assert error.recoverable == true
      assert error.error =~ "Failed to create stack"
    end

    test "stack_get returns stack, members, edges, executable_now, cross_stack_deps" do
      project = create_project()
      slug = "shim-get-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Get"},
          %{}
        )

      {:ok, t1} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, t2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => t1.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => t1.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => t2.id}, %{})

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      assert result.stack.id == stack_id
      assert result.stack.slug == slug
      assert length(result.members) == 2
      assert Enum.any?(result.edges, &(&1.from_task_id == t2.id and &1.to_task_id == t1.id))
      assert t1.id in result.executable_now
      refute t2.id in result.executable_now
      assert result.cross_stack_deps == []
    end

    test "stack_get returns not-found envelope when stack missing" do
      {:error, error} =
        ToolSurface.execute("stack_get", %{"stack_id" => Ecto.UUID.generate()}, %{})

      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end

    test "stack_list filters by project_id" do
      project_a = create_project()
      project_b = create_project()

      slug_a = "list-a-#{System.unique_integer([:positive])}"
      slug_b = "list-b-#{System.unique_integer([:positive])}"

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project_a.id, "slug" => slug_a, "name" => "A"},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project_b.id, "slug" => slug_b, "name" => "B"},
          %{}
        )

      {:ok, results} =
        ToolSurface.execute("stack_list", %{"project_id" => project_a.id}, %{})

      slugs = Enum.map(results, & &1.slug)
      assert slug_a in slugs
      refute slug_b in slugs
    end

    test "stack_add returns task_id + stack_id + stack_position on success" do
      project = create_project()
      slug = "shim-add-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Shim Add"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

      {:ok, result} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end

    test "stack_add returns already_in_stack envelope when task is already a member" do
      project = create_project()
      slug = "shim-add-dup-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Dup Add"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "T"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      {:error, error} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert error.code == "already_in_stack"
    end

    test "stack_eject returns task_id + stack_id on success" do
      project = create_project()
      slug = "shim-eject-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ejectable"})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      {:ok, result} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert result.task_id == task.id
      assert result.stack_id == stack_id
    end

    test "stack_eject returns not_in_stack envelope when task isn't a member" do
      project = create_project()
      slug = "shim-eject-miss-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject Miss"},
          %{}
        )

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Floating"})

      {:error, error} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => task.id}, %{})

      assert error.code == "not_in_stack"
    end

    test "stack_eject returns has_dependents envelope with dependents payload" do
      project = create_project()
      slug = "shim-eject-deps-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Eject Deps"},
          %{}
        )

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      {:ok, _} =
        ToolSurface.execute("stack_add", %{"stack_id" => stack_id, "task_id" => child.id}, %{})

      {:error, error} =
        ToolSurface.execute("stack_eject", %{"stack_id" => stack_id, "task_id" => root.id}, %{})

      assert error.code == "has_dependents"
      assert Enum.any?(error.dependents, &(&1.id == child.id))
    end

    test "stack_abandon flips status to abandoned and records reason" do
      project = create_project()
      slug = "shim-abandon-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Abandon Me"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute(
          "stack_abandon",
          %{"stack_id" => stack_id, "reason" => "scope change"},
          %{}
        )

      assert result.status == "abandoned"
      assert result.description =~ "scope change"
    end

    test "stack_start transitions a forming stack to in_progress" do
      project = create_project()
      slug = "shim-start-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Start Me"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert result.status == "in_progress"
    end

    test "task_create with stack_id attaches the new task to the stack" do
      project = create_project()
      slug = "shim-tc-stack-#{System.unique_integer([:positive])}"

      {:ok, %{stack_id: stack_id}} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "TC Stack"},
          %{}
        )

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Stacked task",
            "stack_id" => stack_id
          },
          %{}
        )

      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end
  end

  # ── Context read tools ────────────────────────────────────────────

  describe "context read tools" do
    setup do
      agent = create_agent()
      space = create_space(%{name: "Read Space", description: "A test space"})

      participant =
        create_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name
        })

      context = %{agent_id: agent.id, agent_participant_id: participant.id}
      %{agent: agent, space: space, participant: participant, context: context}
    end

    # ── space_get_context ──────────────────────────────────────────

    test "space_get_context returns context bundle for a member space", ctx do
      {:ok, result} =
        ToolSurface.execute(
          "space_get_context",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert result.space.id == ctx.space.id
      assert result.space.name == "Read Space"
      assert is_list(result.active_canvases)
      assert is_binary(result.recent_activity_summary) or result.recent_activity_summary == ""
    end

    test "space_get_context denied for non-member agent", ctx do
      other_space = create_space(%{name: "Other"})

      {:error, error} =
        ToolSurface.execute(
          "space_get_context",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
      assert error.recoverable == false
    end

    test "space_get_context with nil space_id returns error", ctx do
      {:error, error} =
        ToolSurface.execute("space_get_context", %{}, ctx.context)

      assert error.error =~ "space_id is required"
    end

    # ── space_get_messages ─────────────────────────────────────────

    test "space_get_messages returns recent messages", ctx do
      # Post some messages
      for i <- 1..3 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Message #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert length(results) == 3
      # Newest first
      assert hd(results).content == "Message 3"
      assert is_binary(hd(results).id)
      assert is_binary(hd(results).inserted_at)
      # Stage 1: every row carries an attachments array (empty when none).
      for row <- results, do: assert(row.attachments == [])
    end

    test "space_get_messages returns attachments for messages that have them", ctx do
      {:ok, msg_with_attachment} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "with attachment"
        })

      {:ok, plain_msg} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "no attachment"
        })

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          message_id: msg_with_attachment.id,
          filename: "diagram.png",
          content_type: "image/png",
          byte_size: 9,
          storage_key: "chat/test/d-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      attached_row = Enum.find(results, &(&1.id == msg_with_attachment.id))
      plain_row = Enum.find(results, &(&1.id == plain_msg.id))

      assert plain_row.attachments == []

      assert [
               %{
                 url: url,
                 content_type: "image/png",
                 byte_size: 9,
                 filename: "diagram.png"
               }
             ] = attached_row.attachments

      assert url == "/chat/attachments/#{attachment.id}"
    end

    test "space_get_messages caps at 20", ctx do
      for i <- 1..25 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Msg #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id, "limit" => 50},
          ctx.context
        )

      assert length(results) == 20
    end

    test "space_get_messages denied for non-member", ctx do
      other_space = create_space(%{name: "Locked"})

      {:error, error} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    test "space_get_messages supports before_id cursor", ctx do
      {:ok, msg1} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "First"
        })

      {:ok, _msg2} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Second"
        })

      {:ok, msg3} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Third"
        })

      {:ok, results} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id, "before_id" => msg3.id},
          ctx.context
        )

      ids = Enum.map(results, & &1.id)
      refute msg3.id in ids
      assert msg1.id in ids
    end

    # ── space_search_messages ──────────────────────────────────────

    test "space_search_messages returns matching messages", ctx do
      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.participant.id,
        content_type: "text",
        content: "The deployment pipeline is working great"
      })

      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.participant.id,
        content_type: "text",
        content: "Unrelated conversation about lunch"
      })

      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "deployment pipeline"},
          ctx.context
        )

      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.content =~ "deployment" end)
    end

    test "space_search_messages caps at 10", ctx do
      for i <- 1..15 do
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "Search target keyword banana #{i}"
        })
      end

      {:ok, results} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => ctx.space.id, "query" => "banana", "limit" => 50},
          ctx.context
        )

      assert length(results) <= 10
    end

    test "space_search_messages denied for non-member", ctx do
      other_space = create_space(%{name: "Private"})

      {:error, error} =
        ToolSurface.execute(
          "space_search_messages",
          %{"space_id" => other_space.id, "query" => "test"},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    # ── canvas_list ────────────────────────────────────────────────

    test "canvas_list returns canvases in a space", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "Test Canvas"
        })

      {:ok, results} =
        ToolSurface.execute(
          "canvas_list",
          %{"space_id" => ctx.space.id},
          ctx.context
        )

      assert length(results) >= 1
      entry = Enum.find(results, &(&1.id == canvas.id))
      assert entry.title == "Test Canvas"
      assert entry.kind == "stack"
      assert is_binary(entry.inserted_at)
    end

    test "canvas_list denied for non-member", ctx do
      other_space = create_space(%{name: "No Access"})

      {:error, error} =
        ToolSurface.execute(
          "canvas_list",
          %{"space_id" => other_space.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    # ── canvas_get ─────────────────────────────────────────────────

    test "canvas_get returns summary by default", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "My Code"
        })

      {:ok, result} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id},
          ctx.context
        )

      assert result.id == canvas.id
      assert result.title == "My Code"
      assert result.kind == "stack"
      assert result.space_id == ctx.space.id
      refute Map.has_key?(result, :document)
    end

    test "canvas_get with mode=full includes the document", ctx do
      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(ctx.space.id, ctx.participant.id, %{
          "title" => "Data Table"
        })

      {:ok, result} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id, "mode" => "full"},
          ctx.context
        )

      assert result.id == canvas.id
      assert is_map(result.document)
      assert result.document["root"]["type"] == "stack"
    end

    test "canvas_get with non-existent canvas returns error", ctx do
      {:error, error} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => Ecto.UUID.generate()},
          ctx.context
        )

      assert error.error =~ "Canvas not found"
    end

    test "canvas_get denied for canvas in non-member space", ctx do
      other_space = create_space(%{name: "Locked Space"})
      other_participant = create_participant(other_space.id)

      {:ok, canvas, _msg} =
        Chat.create_canvas_with_message(other_space.id, other_participant.id, %{
          "title" => "Secret Canvas"
        })

      {:error, error} =
        ToolSurface.execute(
          "canvas_get",
          %{"canvas_id" => canvas.id},
          ctx.context
        )

      assert error.error =~ "Access denied"
    end

    # ── auth: missing agent_id ─────────────────────────────────────

    test "read tools fail without agent_id in context", ctx do
      no_agent_ctx = %{}

      {:error, error} =
        ToolSurface.execute(
          "space_get_messages",
          %{"space_id" => ctx.space.id},
          no_agent_ctx
        )

      assert error.error =~ "Agent identity required"
    end

    # ── attachment.get_inline ──────────────────────────────────────

    test "attachment.get_inline returns base64 bytes for in-space caller", ctx do
      root =
        Path.join(System.tmp_dir!(), "att-inline-test-#{Ecto.UUID.generate()}")

      prev = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev do
          Application.put_env(:platform, :chat_attachments_root, prev)
        else
          Application.delete_env(:platform, :chat_attachments_root)
        end
      end)

      bytes = "hello-bytes"
      storage_key = "chat/test/inline-#{Ecto.UUID.generate()}.bin"
      target = Path.join(root, storage_key)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: "blob.bin",
          content_type: "application/octet-stream",
          byte_size: byte_size(bytes),
          storage_key: storage_key,
          state: "ready"
        })

      {:ok, result} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert result.content_type == "application/octet-stream"
      assert result.byte_size == byte_size(bytes)
      assert result.filename == "blob.bin"
      assert {:ok, ^bytes} = Base.decode64(result.data_base64)
    end

    test "attachment.get_inline rejects payloads above the 25MB cap", ctx do
      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: "huge.bin",
          content_type: "application/octet-stream",
          # 25MB + 1 byte
          byte_size: 25 * 1024 * 1024 + 1,
          storage_key: "chat/test/huge-#{Ecto.UUID.generate()}.bin",
          state: "ready"
        })

      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert error.reason == :too_large
      assert error.error =~ "exceeds inline read cap"
    end

    test "attachment.get_inline denied for caller not in attachment's space", ctx do
      other_space = create_space(%{name: "Other"})

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: other_space.id,
          filename: "secret.bin",
          content_type: "application/octet-stream",
          byte_size: 4,
          storage_key: "chat/test/s-#{Ecto.UUID.generate()}.bin",
          state: "ready"
        })

      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => attachment.id},
          ctx.context
        )

      assert error.error =~ "not a participant"
    end

    test "attachment.get_inline 404 when attachment does not exist", ctx do
      {:error, error} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => Ecto.UUID.generate()},
          ctx.context
        )

      assert error.error =~ "not found"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # `space_leave` calls ActiveAgentStore.clear_if_match/2 — start the GenServer
  # the first time a test needs it and allow the test process to share the
  # repo sandbox connection.
  defp ensure_active_agent_store do
    alias Ecto.Adapters.SQL.Sandbox
    alias Platform.Chat.ActiveAgentStore

    pid =
      case Process.whereis(ActiveAgentStore) do
        nil -> start_supervised!({ActiveAgentStore, []})
        existing -> existing
      end

    Sandbox.allow(Repo, self(), pid)
    :ok
  end

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
