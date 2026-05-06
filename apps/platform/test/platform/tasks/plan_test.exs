defmodule Platform.Tasks.PlanTest do
  use Platform.DataCase, async: true

  import Ecto.Changeset, only: [get_change: 2]

  alias Platform.Tasks
  alias Platform.Tasks.Plan

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Plan Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan Task"})
    %{project: project, task: task}
  end

  describe "create_plan/1" do
    test "creates with auto-incremented version after the previous plan is rejected", %{
      task: task
    } do
      assert {:ok, %Plan{} = plan1} = Tasks.create_plan(%{task_id: task.id})
      assert plan1.version == 1
      assert plan1.status == "draft"

      # Cannot create another plan while v1 is still draft/pending_review.
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})

      # After rejection, the next plan is allowed and gets the next version.
      {:ok, _} = Tasks.reject_plan(plan1, Ecto.UUID.generate())
      assert {:ok, plan2} = Tasks.create_plan(%{task_id: task.id})
      assert plan2.version == 2
    end

    test "rejects a duplicate plan while one is in draft", %{task: task} do
      assert {:ok, _} = Tasks.create_plan(%{task_id: task.id})
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})
    end

    test "rejects a duplicate plan while one is pending_review", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _} = Tasks.submit_plan_for_review(plan)
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})
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

  describe "rejection_reason field" do
    test "is part of the schema" do
      assert :rejection_reason in Plan.__schema__(:fields)
      assert Plan.__schema__(:type, :rejection_reason) == :string
    end

    test "is cast by changeset/2 when provided", %{task: task} do
      changeset =
        Plan.changeset(%Plan{}, %{
          task_id: task.id,
          version: 1,
          rejection_reason: "test reason"
        })

      assert changeset.valid?
      assert get_change(changeset, :rejection_reason) == "test reason"
    end

    test "is optional (changeset valid without it)", %{task: task} do
      changeset = Plan.changeset(%Plan{}, %{task_id: task.id, version: 1})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :rejection_reason)
    end
  end

  describe "list_plans/1" do
    test "returns plans ordered by version", %{task: task} do
      # Two legitimate revisions: first is rejected, then a new one is drafted.
      {:ok, plan1} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      {:ok, _} = Tasks.reject_plan(plan1, Ecto.UUID.generate())
      {:ok, _} = Tasks.create_plan(%{task_id: task.id})

      plans = Tasks.list_plans(task.id)
      assert length(plans) == 2
      assert Enum.map(plans, & &1.version) == [1, 2]
    end
  end

  describe "reject_plan/3" do
    test "persists rejection_reason when provided on a pending_review plan", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, rejected} =
               Tasks.reject_plan(plan, Ecto.UUID.generate(), "Did not address the auth path")

      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "Did not address the auth path"
    end

    test "leaves rejection_reason nil when no reason given (back-compat)", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      # 2-arity form delegates to 3-arity with reason: nil.
      assert {:ok, rejected} = Tasks.reject_plan(plan, Ecto.UUID.generate())
      assert rejected.status == "rejected"
      assert is_nil(rejected.rejection_reason)
    end

    test "accepts approved and completed plans (reopen-with-feedback path)", %{task: task} do
      # Approved
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")
      assert plan.status == "approved"

      assert {:ok, rejected} = Tasks.reject_plan(plan, "reviewer", "post-done feedback")
      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "post-done feedback"

      # Completed (force the status directly via changeset to model a completed plan)
      {:ok, plan2} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan2} = Plan.changeset(plan2, %{status: "completed"}) |> Platform.Repo.update()

      assert {:ok, rejected2} = Tasks.reject_plan(plan2, "reviewer", "completed-but-bad")
      assert rejected2.status == "rejected"
      assert rejected2.rejection_reason == "completed-but-bad"
    end

    test "refuses plans in non-rejectable statuses", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      # status: "draft"
      assert {:error, :invalid_transition} = Tasks.reject_plan(plan, "actor", "x")
    end
  end

  describe "reopen_with_feedback/3" do
    setup %{task: task} do
      # Drive the task through to done with an approved plan in place.
      {:ok, task} = Tasks.update_task(task, %{status: "planning"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")
      # task is now "in_progress" via approve_plan's dispatch gate
      {:ok, task} = Tasks.transition_task_status(Tasks.get_task_record(task.id), "in_review")
      {:ok, task} = Tasks.transition_task_status(task, "deploying")
      {:ok, task} = Tasks.transition_task_status(task, "done")

      %{task: task, plan: plan}
    end

    test "happy path: task done → planning, plan rejected with reason, broadcast received",
         %{task: task} do
      :ok = Tasks.subscribe_board()

      assert {:ok, reopened} =
               Tasks.reopen_with_feedback(task.id, "Missed the spec", "reviewer-1")

      assert reopened.status == "planning"
      assert reopened.id == task.id

      # Plan went rejected with the reason persisted.
      [_v1] = Tasks.list_plans(task.id)
      latest = Tasks.latest_plan(task.id)
      assert latest.status == "rejected"
      assert latest.rejection_reason == "Missed the spec"

      # Both broadcasts fired on the board topic.
      assert_receive {:task_updated, %{id: tid, status: "planning"}}
      assert tid == task.id
      assert_receive {:plan_updated, %{status: "rejected", rejection_reason: "Missed the spec"}}
    end

    test "refuses when task is not in done", %{task: task} do
      # Move task off "done" so the precondition fails.
      {:ok, task} =
        task |> Platform.Tasks.Task.changeset(%{status: "in_progress"}) |> Platform.Repo.update()

      assert {:error, :not_done} =
               Tasks.reopen_with_feedback(task.id, "anything", "reviewer-1")
    end

    test "refuses when reason is nil or blank", %{task: task} do
      assert {:error, :reason_required} = Tasks.reopen_with_feedback(task.id, nil, "r1")
      assert {:error, :reason_required} = Tasks.reopen_with_feedback(task.id, "", "r1")
      assert {:error, :reason_required} = Tasks.reopen_with_feedback(task.id, "   ", "r1")
      assert {:error, :reason_required} = Tasks.reopen_with_feedback(task.id, "\t\n  ", "r1")

      # Task should remain in done — nothing happened.
      assert Tasks.get_task_record(task.id).status == "done"
    end

    test "returns :no_plan and aborts when task has no active plan", %{project: project} do
      # Build a task without going through the plan-approval path.
      {:ok, t} =
        Tasks.create_task(%{project_id: project.id, title: "No plan", status: "planning"})

      # Force-set status to "done" (bypass transitions — this models the
      # defensive invariant: a task whose plan history was somehow lost).
      {:ok, t} = t |> Platform.Tasks.Task.changeset(%{status: "done"}) |> Platform.Repo.update()

      assert {:error, :no_plan} = Tasks.reopen_with_feedback(t.id, "x", "r1")

      # Status preserved — atomic abort.
      assert Tasks.get_task_record(t.id).status == "done"
    end
  end
end
