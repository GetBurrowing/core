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

  describe "superseded_by_plan_id field" do
    test "is part of the schema" do
      assert :superseded_by_plan_id in Plan.__schema__(:fields)
      # Self-FK is preloadable via the :superseded_by association.
      assert :superseded_by in Plan.__schema__(:associations)
    end

    test "is cast by changeset/2 when provided", %{task: task} do
      successor_id = Ecto.UUID.generate()

      changeset =
        Plan.changeset(%Plan{}, %{
          task_id: task.id,
          version: 1,
          superseded_by_plan_id: successor_id
        })

      assert changeset.valid?
      assert get_change(changeset, :superseded_by_plan_id) == successor_id
    end

    test "is optional (changeset valid without it)", %{task: task} do
      changeset = Plan.changeset(%Plan{}, %{task_id: task.id, version: 1})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :superseded_by_plan_id)
    end

    test "an unknown UUID fails the foreign-key constraint at insert time",
         %{task: task} do
      bogus_successor = Ecto.UUID.generate()

      assert {:error, changeset} =
               %Plan{}
               |> Plan.changeset(%{
                 task_id: task.id,
                 version: 99,
                 superseded_by_plan_id: bogus_successor
               })
               |> Platform.Repo.insert()

      # Cast itself accepts the value (binary_id is permissive); the FK
      # constraint surfaces as a changeset error after the insert attempt.
      assert {_, _} = changeset.errors[:superseded_by_plan_id]
    end

    test "round-trips through the database with a real predecessor → successor link",
         %{task: task} do
      {:ok, plan_v1} = Tasks.create_plan(%{task_id: task.id})
      # Need plan_v1 in a non-blocking status before creating v2.
      {:ok, plan_v1} = Tasks.submit_plan_for_review(plan_v1)
      {:ok, _} = Tasks.reject_plan(plan_v1, Ecto.UUID.generate())
      {:ok, plan_v2} = Tasks.create_plan(%{task_id: task.id})

      {:ok, plan_v1_updated} =
        plan_v1
        |> Plan.changeset(%{superseded_by_plan_id: plan_v2.id})
        |> Platform.Repo.update()

      assert plan_v1_updated.superseded_by_plan_id == plan_v2.id

      reloaded = Platform.Repo.get!(Plan, plan_v1.id) |> Platform.Repo.preload(:superseded_by)
      assert reloaded.superseded_by_plan_id == plan_v2.id
      assert reloaded.superseded_by.id == plan_v2.id
    end
  end

  # Auto-approve plan (task 019f25f2) stage 1: schema-only foundation for
  # the timestamp future stages will stamp when the opt-in flag fires.
  # Distinct from :approved_at so downstream observers can tell auto- vs.
  # manual-review approvals apart. Nullable — most plans never carry it.
  describe "auto_approved_at (task 019f25f2 stage 1)" do
    test "is part of the schema" do
      assert :auto_approved_at in Plan.__schema__(:fields)
      assert Plan.__schema__(:type, :auto_approved_at) == :utc_datetime_usec
    end

    test "is cast by changeset/2 when provided", %{task: task} do
      ts = DateTime.utc_now()

      changeset =
        Plan.changeset(%Plan{}, %{
          task_id: task.id,
          version: 1,
          auto_approved_at: ts
        })

      assert changeset.valid?
      assert get_change(changeset, :auto_approved_at) == ts
    end

    test "is optional (nil is accepted, changeset valid without it)", %{task: task} do
      changeset = Plan.changeset(%Plan{}, %{task_id: task.id, version: 1})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :auto_approved_at)
    end

    test "round-trips through the database", %{task: task} do
      ts = DateTime.utc_now()

      {:ok, plan} =
        %Plan{}
        |> Plan.changeset(%{task_id: task.id, version: 1, auto_approved_at: ts})
        |> Platform.Repo.insert()

      reloaded = Platform.Repo.get!(Plan, plan.id)
      assert reloaded.auto_approved_at != nil
      assert DateTime.diff(reloaded.auto_approved_at, ts, :microsecond) == 0
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

  describe "approve_plan/2 auto-supersession" do
    # Helper: drive a task to having an approved v1 in place.
    defp approve_v1(task) do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")
      plan
    end

    defp draft_and_review(task) do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      plan
    end

    test "approving v2 auto-rejects an approved v1 with successor link + reason", %{task: task} do
      v1 = approve_v1(task)
      assert v1.status == "approved"

      v2_pending = draft_and_review(task)
      assert {:ok, v2} = Tasks.approve_plan(v2_pending, "system")
      assert v2.status == "approved"

      reloaded_v1 = Platform.Repo.get!(Plan, v1.id)
      assert reloaded_v1.status == "rejected"
      assert reloaded_v1.superseded_by_plan_id == v2.id
      assert reloaded_v1.rejection_reason == "Superseded by plan v#{v2.version}"
    end

    test "approving v2 auto-rejects a completed v1", %{task: task} do
      v1 = approve_v1(task)
      # Force v1 to "completed" to simulate the completion path.
      {:ok, v1_completed} =
        v1 |> Plan.changeset(%{status: "completed"}) |> Platform.Repo.update()

      v2_pending = draft_and_review(task)
      assert {:ok, v2} = Tasks.approve_plan(v2_pending, "system")
      assert v2.status == "approved"

      reloaded_v1 = Platform.Repo.get!(Plan, v1_completed.id)
      assert reloaded_v1.status == "rejected"
      assert reloaded_v1.superseded_by_plan_id == v2.id
      assert reloaded_v1.rejection_reason == "Superseded by plan v#{v2.version}"
    end

    test "approving v2 leaves a manually-rejected v1 untouched", %{task: task} do
      # v1: pending_review → manually rejected with custom reason.
      {:ok, v1} = Tasks.create_plan(%{task_id: task.id})
      {:ok, v1} = Tasks.submit_plan_for_review(v1)

      {:ok, v1_rejected} =
        Tasks.reject_plan(v1, Ecto.UUID.generate(), "Did not address auth path")

      v2_pending = draft_and_review(task)
      assert {:ok, v2} = Tasks.approve_plan(v2_pending, "system")
      assert v2.status == "approved"

      reloaded_v1 = Platform.Repo.get!(Plan, v1_rejected.id)
      assert reloaded_v1.status == "rejected"
      # Manual rejection metadata preserved — supersession does NOT overwrite.
      assert is_nil(reloaded_v1.superseded_by_plan_id)
      assert reloaded_v1.rejection_reason == "Did not address auth path"
    end

    test "approving the lone v1 with no siblings is a no-op for supersession", %{task: task} do
      plan = draft_and_review(task)
      assert {:ok, approved} = Tasks.approve_plan(plan, "system")
      assert approved.status == "approved"
      # No other plans exist; supersession path is empty and harmless.
      assert Tasks.list_plans(task.id) |> length() == 1
    end

    test "current_plan/1 returns v2 after auto-supersession", %{task: task} do
      _v1 = approve_v1(task)
      v2_pending = draft_and_review(task)
      {:ok, v2} = Tasks.approve_plan(v2_pending, "system")

      current = Tasks.current_plan(task.id)
      assert current.id == v2.id
      assert current.version == v2.version
    end

    test "broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan}", %{task: task} do
      v1 = approve_v1(task)

      :ok = Tasks.subscribe_board()

      v2_pending = draft_and_review(task)
      {:ok, v2} = Tasks.approve_plan(v2_pending, "system")

      # The supersedee (v1 → rejected) is broadcast first…
      assert_receive {:plan_updated, %Plan{id: id1, status: "rejected"} = sup}
      assert id1 == v1.id
      assert sup.superseded_by_plan_id == v2.id

      # …then the newly-approved v2.
      assert_receive {:plan_updated, %Plan{id: id2, status: "approved"}}
      assert id2 == v2.id
    end

    test "atomicity: a DB-level constraint violation on supersession rolls back the new plan",
         %{task: task} do
      v1 = approve_v1(task)
      v2_pending = draft_and_review(task)

      # Force the supersession `Repo.update!/1` to raise by planting a
      # row-level CHECK that the supersession write will violate. We add
      # a transient CHECK constraint that forbids `superseded_by_plan_id`
      # being set on the v1 row. The constraint is dropped at the end of
      # the test by the sandbox transaction rollback.
      #
      # Side note: the sandbox executes each test inside a SAVEPOINT;
      # adding a constraint here is sandboxed and cleaned up automatically.
      Platform.Repo.query!(
        "ALTER TABLE plans ADD CONSTRAINT no_supersession_v1 " <>
          "CHECK (id <> '#{v1.id}'::uuid OR superseded_by_plan_id IS NULL)"
      )

      # Now `approve_plan` runs the supersession `Repo.update!` against
      # v1 with `superseded_by_plan_id: v2.id`, which violates the CHECK.
      # `Repo.update!` raises (Ecto.ConstraintError or Postgrex.Error)
      # and `Repo.transaction` rolls back.
      result =
        try do
          Tasks.approve_plan(v2_pending, "system")
        rescue
          e in [Ecto.ConstraintError, Postgrex.Error] -> {:rescued, e.__struct__}
        end

      assert match?({:rescued, _}, result)

      # v2 must NOT be approved — the transaction rolled back.
      reloaded_v2 = Platform.Repo.get!(Plan, v2_pending.id)
      assert reloaded_v2.status == "pending_review"
      assert is_nil(reloaded_v2.approved_at)

      # v1's status is unchanged.
      reloaded_v1 = Platform.Repo.get!(Plan, v1.id)
      assert reloaded_v1.status == "approved"
      assert is_nil(reloaded_v1.superseded_by_plan_id)
    end
  end

  describe "reopen_with_feedback/3" do
    setup %{task: task} do
      # Drive the task through to done with an approved plan in place.
      # `deploy_target` set so the stage-2 (019f42db) `:deploying` guard passes.
      {:ok, task} =
        Tasks.update_task(task, %{status: "planning", deploy_target: "production"})

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
