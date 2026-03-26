defmodule Platform.Tasks.PlanTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.Plan

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Plan Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan Task"})
    %{project: project, task: task}
  end

  describe "create_plan/1" do
    test "creates with auto-incremented version", %{task: task} do
      assert {:ok, %Plan{} = plan1} = Tasks.create_plan(%{task_id: task.id})
      assert plan1.version == 1
      assert plan1.status == "draft"

      assert {:ok, plan2} = Tasks.create_plan(%{task_id: task.id})
      assert plan2.version == 2
    end

    test "respects explicit version", %{task: task} do
      assert {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 42})
      assert plan.version == 42
    end
  end

  describe "approval flow" do
    test "draft → pending_review → approved", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      assert plan.status == "draft"

      assert {:ok, plan} = Tasks.submit_plan_for_review(plan)
      assert plan.status == "pending_review"

      approver_id = Ecto.UUID.generate()
      assert {:ok, plan} = Tasks.approve_plan(plan, approver_id)
      assert plan.status == "approved"
      assert plan.approved_by == approver_id
      assert plan.approved_at != nil
    end

    test "approval stores string actor id and moves planning task to in_progress", %{task: task} do
      {:ok, task} = Tasks.update_task(task, %{status: "planning"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, plan} = Tasks.approve_plan(plan, "system")
      assert plan.status == "approved"
      assert plan.approved_by == "system"

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "in_progress"
    end

    test "draft → pending_review → rejected", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, plan} = Tasks.reject_plan(plan, Ecto.UUID.generate())
      assert plan.status == "rejected"
    end

    test "cannot approve a draft plan", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      assert {:error, :invalid_transition} = Tasks.approve_plan(plan, Ecto.UUID.generate())
    end

    test "cannot submit a non-draft plan for review", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      assert {:error, :invalid_transition} = Tasks.submit_plan_for_review(plan)
    end
  end

  describe "current_plan/1" do
    test "returns latest approved plan", %{task: task} do
      {:ok, plan1} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      {:ok, _plan1} = Tasks.approve_plan(plan1, Ecto.UUID.generate())

      {:ok, plan2} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan2} = Tasks.submit_plan_for_review(plan2)
      {:ok, _plan2} = Tasks.approve_plan(plan2, Ecto.UUID.generate())

      current = Tasks.current_plan(task.id)
      assert current.version == 2
    end

    test "returns nil when no approved plans", %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id})
      assert Tasks.current_plan(task.id) == nil
    end
  end

  describe "list_plans/1" do
    test "returns plans ordered by version", %{task: task} do
      {:ok, _} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _} = Tasks.create_plan(%{task_id: task.id})

      plans = Tasks.list_plans(task.id)
      assert length(plans) == 2
      assert Enum.map(plans, & &1.version) == [1, 2]
    end
  end
end
