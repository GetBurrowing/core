defmodule Platform.Tasks.TasksContextTest do
  @moduledoc "Integration tests for the Tasks context module."
  use Platform.DataCase, async: true

  alias Platform.Tasks

  describe "full hierarchy CRUD" do
    test "project → epic → task → plan → stage → validation" do
      # Project
      assert {:ok, project} =
               Tasks.create_project(%{
                 name: "Integration App",
                 repo_url: "https://github.com/org/app",
                 tech_stack: %{"language" => "elixir"}
               })

      assert project.slug == "integration-app"

      # Epic
      assert {:ok, epic} =
               Tasks.create_epic(%{
                 project_id: project.id,
                 name: "Auth System",
                 acceptance_criteria: "Users can log in"
               })

      # Task
      assert {:ok, task} =
               Tasks.create_task(%{
                 project_id: project.id,
                 epic_id: epic.id,
                 title: "Implement login",
                 priority: "high"
               })

      assert task.status == "backlog"

      # Plan (auto-versioned)
      assert {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      assert plan.version == 1

      # Stage
      assert {:ok, stage} =
               Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Code"})

      # Validation
      assert {:ok, validation} =
               Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      # Verify hierarchy reads
      assert Tasks.list_epics(project.id) |> length() == 1
      assert Tasks.list_tasks_by_project(project.id) |> length() == 1
      assert Tasks.list_tasks_by_epic(epic.id) |> length() == 1
      assert Tasks.list_plans(task.id) |> length() == 1
      assert Tasks.list_stages(plan.id) |> length() == 1
      assert Tasks.list_validations(stage.id) |> length() == 1

      # Evaluate the validation
      {:ok, _} = Tasks.evaluate_validation(validation.id, "passed", %{"ok" => true})
    end
  end

  describe "task status transition chain" do
    test "backlog → planning → ready → in_progress → in_review → done" do
      {:ok, project} = Tasks.create_project(%{name: "Status Project"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Full chain"})

      transitions = ~w(planning ready in_progress in_review done)

      final_task =
        Enum.reduce(transitions, task, fn status, t ->
          {:ok, updated} = Tasks.transition_task_status(t, status)
          assert updated.status == status
          updated
        end)

      assert final_task.status == "done"
    end
  end

  describe "plan approval flow end-to-end" do
    test "create → submit → approve moves task directly to in_progress" do
      {:ok, project} = Tasks.create_project(%{name: "Approve Project"})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Approvable", status: "planning"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _plan} = Tasks.approve_plan(plan, Ecto.UUID.generate())

      current = Tasks.current_plan(task.id)
      assert current != nil
      assert current.status == "approved"
      assert current.version == 1

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "in_progress"
    end
  end

  describe "cascade delete" do
    test "deleting a project cascades to tasks" do
      {:ok, project} = Tasks.create_project(%{name: "Cascade"})
      {:ok, _task} = Tasks.create_task(%{project_id: project.id, title: "Will be deleted"})

      Repo.delete!(project)
      assert Tasks.list_tasks_by_project(project.id) == []
    end
  end

  describe "legacy ETS-based list_tasks/0" do
    test "returns a list (may be empty without active runs)" do
      assert is_list(Tasks.list_tasks())
    end
  end
end
