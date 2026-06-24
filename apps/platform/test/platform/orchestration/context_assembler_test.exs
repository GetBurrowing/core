defmodule Platform.Orchestration.ContextAssemblerTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ContextAssembler
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments

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

    test "previous_rejection_reason is nil when no plans were rejected", %{task: task} do
      # The seeded plan in setup is approved, so no qualifying rejected plan exists.
      context = ContextAssembler.build(task.id)
      assert context.previous_rejection_reason == nil
    end

    test "previous_rejection_reason surfaces the latest rejected plan's reason",
         %{task: task} do
      {:ok, rejected_plan} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "rejected",
          version: 2,
          rejection_reason: "scope creep — split into two tasks"
        })

      context = ContextAssembler.build(task.id)
      assert context.previous_rejection_reason == "scope creep — split into two tasks"

      # And the higher-version rejected plan wins over earlier ones.
      {:ok, _newer} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "rejected",
          version: 3,
          rejection_reason: "missing failure-mode coverage"
        })

      context2 = ContextAssembler.build(task.id)
      assert context2.previous_rejection_reason == "missing failure-mode coverage"

      # Pin the IDs so the compiler doesn't dead-code-eliminate the asserts.
      assert is_binary(rejected_plan.id)
    end

    test "previous_rejection_reason ignores rejected plans with nil reason",
         %{task: task} do
      {:ok, _no_reason} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "rejected",
          version: 2,
          rejection_reason: nil
        })

      context = ContextAssembler.build(task.id)
      assert context.previous_rejection_reason == nil
    end

    # task_attach_canvas stage 4 — :canvases surfaces attachments in the
    # dispatch payload so the executing agent sees them automatically.

    test "canvases is [] when no canvases are attached", %{task: task} do
      context = ContextAssembler.build(task.id)
      assert context.canvases == []
    end

    test "surfaces an attached canvas in :canvases with flat fields", %{task: task} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Canvas Surface Space",
          slug: "canvas-surface-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Design sketch"
        })

      {:ok, _} =
        CanvasAttachments.attach_canvas(task.id, canvas.id,
          note: "first draft",
          attached_by: %{kind: "user", id: participant.id}
        )

      context = ContextAssembler.build(task.id)
      assert [entry] = context.canvases
      assert entry.id == canvas.id
      assert entry.title == "Design sketch"
      # Default canvas document root is a `stack` node.
      assert entry.kind == "stack"
      assert entry.note == "first draft"
      assert entry.canvas_present == true
      assert %DateTime{} = entry.attached_at
    end

    test "soft-deleted canvas survives in :canvases with canvas_present: false",
         %{task: task} do
      {:ok, space} =
        Chat.create_space(%{
          name: "Soft Delete Space",
          slug: "canvas-soft-delete-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Doomed canvas"
        })

      {:ok, _} =
        CanvasAttachments.attach_canvas(task.id, canvas.id,
          note: "will rot",
          attached_by: %{kind: "user", id: participant.id}
        )

      {:ok, _} = Chat.delete_canvas(canvas)

      context = ContextAssembler.build(task.id)
      assert [entry] = context.canvases
      assert entry.id == canvas.id
      assert entry.canvas_present == false
      # The note (from the attachment row) still surfaces so the agent can
      # decide whether to detach it.
      assert entry.note == "will rot"
    end
  end

  describe "rejection feedback chain (Tasks.reject_plan → ContextAssembler → dispatch_prompt)" do
    # Regression test: pins the end-to-end chain that surfaces a planner's
    # rejection feedback into the next planner dispatch. Any future change to
    # Tasks.reject_plan, ContextAssembler.build, or HeartbeatScheduler's
    # planning-status dispatch_prompt that breaks this wiring fails here.
    test "reject feedback flows verbatim into the next planning dispatch prompt",
         %{project: project} do
      reason = "Stages too coarse — split stage 2 into two."
      reviewer_id = "00000000-0000-0000-0000-000000000abc"

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Rejection chain task",
          description: "Exercise the end-to-end rejection feedback chain.",
          priority: "high",
          status: "planning"
        })

      {:ok, plan_v1} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "pending_review",
          version: 1
        })

      # Step 1: reject the plan with feedback.
      assert {:ok, rejected} = Tasks.reject_plan(plan_v1, reviewer_id, reason)
      assert rejected.status == "rejected"
      assert rejected.rejection_reason == reason

      # Step 2: ContextAssembler surfaces that reason verbatim.
      ctx = ContextAssembler.build(task.id)
      assert ctx.previous_rejection_reason == reason

      # Step 3: HeartbeatScheduler.dispatch_prompt threads it into the
      # planning prompt's "Previous attempt" section verbatim.
      planning_task = %{task | status: "planning"}

      prompt =
        HeartbeatScheduler.dispatch_prompt(planning_task, nil, nil,
          previous_rejection_reason: ctx.previous_rejection_reason
        )

      assert prompt =~ "## Previous attempt — what didn't work"
      assert prompt =~ reason
      assert prompt =~ "Design v2 to address that"
    end
  end
end
