defmodule Platform.Orchestration.ContextAssemblerTest do
  use Platform.DataCase, async: false

  alias Platform.Orchestration.ContextAssembler
  alias Platform.Skills
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Test Project",
        repo_url: "https://github.com/test/project",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"}
      })

    {:ok, epic} =
      Tasks.create_epic(%{
        project_id: project.id,
        name: "Test Epic",
        description: "Epic description",
        acceptance_criteria: "All tests pass"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        epic_id: epic.id,
        title: "Test Task",
        description: "Task description",
        priority: "high"
      })

    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        status: "approved",
        version: 1
      })

    {:ok, stage1} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write the code"
      })

    {:ok, _validation} =
      Tasks.create_validation(%{
        stage_id: stage1.id,
        kind: "test_pass"
      })

    {:ok, stage2} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "review",
        description: "Code review"
      })

    %{project: project, epic: epic, task: task, plan: plan, stage1: stage1, stage2: stage2}
  end

  describe "build/1" do
    test "returns nil for non-existent task" do
      assert ContextAssembler.build("00000000-0000-0000-0000-000000000000") == nil
    end

    test "assembles full context snapshot", %{task: task, project: project, epic: epic} do
      context = ContextAssembler.build(task.id)

      assert context.project.name == project.name
      assert context.project.repo_url == project.repo_url
      assert context.project.tech_stack == project.tech_stack
      assert context.project.deploy_config == project.deploy_config

      assert context.epic.name == epic.name
      assert context.epic.description == epic.description
      assert context.epic.acceptance_criteria == epic.acceptance_criteria

      assert context.task.id == task.id
      assert context.task.title == task.title
      assert context.task.description == task.description
      assert context.task.priority == "high"
    end

    test "includes resolved_deploy_strategy in context", %{task: task} do
      context = ContextAssembler.build(task.id)

      # Task and project have no strategy set, so should fall back to manual
      assert context.resolved_deploy_strategy == %{"type" => "manual"}
    end

    test "includes plan with stages and validations", %{task: task} do
      context = ContextAssembler.build(task.id)

      assert context.plan != nil
      assert context.plan.version == 1
      assert context.plan.status == "approved"
      assert length(context.plan.stages) == 2

      [stage1, stage2] = Enum.sort_by(context.plan.stages, & &1.position)
      assert stage1.name == "coding"
      assert stage2.name == "review"
      assert length(stage1.validations) == 1
      assert hd(stage1.validations).kind == "test_pass"
    end

    test "handles task with no plan", %{project: project} do
      {:ok, task_no_plan} =
        Tasks.create_task(%{project_id: project.id, title: "No Plan Task"})

      context = ContextAssembler.build(task_no_plan.id)

      assert context.task.title == "No Plan Task"
      assert context.plan == nil
    end

    test "handles task with no epic", %{project: project} do
      {:ok, task_no_epic} =
        Tasks.create_task(%{project_id: project.id, title: "No Epic Task"})

      context = ContextAssembler.build(task_no_epic.id)

      assert context.epic == nil
      assert context.task.title == "No Epic Task"
    end

    test "includes empty skills list when no skills attached", %{task: task} do
      context = ContextAssembler.build(task.id)
      assert context.skills == []
    end

    test "includes attached skills in context", %{task: task, project: project} do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "Coding Guide",
          content: "# Coding Guide\nFollow conventions."
        })

      {:ok, _} = Skills.attach_skill(skill.id, "project", project.id)

      context = ContextAssembler.build(task.id)
      assert length(context.skills) == 1
      assert hd(context.skills).name == "Coding Guide"
      assert hd(context.skills).content == "# Coding Guide\nFollow conventions."
    end

    test "includes skills from multiple hierarchy levels", %{task: task, project: project} do
      {:ok, s1} = Skills.create_skill(%{name: "Project Skill", content: "proj content"})
      {:ok, s2} = Skills.create_skill(%{name: "Task Skill", content: "task content"})
      {:ok, _} = Skills.attach_skill(s1.id, "project", project.id)
      {:ok, _} = Skills.attach_skill(s2.id, "task", task.id)

      context = ContextAssembler.build(task.id)
      assert length(context.skills) == 2
      names = Enum.map(context.skills, & &1.name) |> Enum.sort()
      assert names == ["Project Skill", "Task Skill"]
    end
  end
end
