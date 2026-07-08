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

  describe "supersede_current_plan/3" do
    # Seed helper: drive a fresh task from planning → approved-plan → the
    # target in-flight status. Returns %{task: task, plan: plan}.
    defp seed_in_flight(project, target_status) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Supersede Task #{target_status}",
          status: "planning"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")

      # approve_plan's dispatch gate flips task → in_progress. Walk it
      # forward to whichever in-flight status the test needs.
      task = Tasks.get_task_record(task.id)

      task =
        case target_status do
          "in_progress" ->
            task

          "in_review" ->
            {:ok, t} = Tasks.transition_task_status(task, "in_review")
            t

          "deploying" ->
            # Deploying gate requires a resolvable deploy target (added by
            # 019f42db deploy-consolidation). Set an explicit target directly
            # via the changeset so we don't have to plumb a project default.
            {:ok, task} =
              task
              |> Platform.Tasks.Task.changeset(%{deploy_target: "pr_merge"})
              |> Platform.Repo.update()

            {:ok, t} = Tasks.transition_task_status(task, "in_review")
            {:ok, t} = Tasks.transition_task_status(t, "deploying")
            t
        end

      %{task: task, plan: plan}
    end

    for target_status <- ~w(in_progress in_review deploying) do
      test "happy path: task in #{target_status} → planning, plan superseded with reason, broadcasts fire",
           %{project: project} do
        %{task: task, plan: plan} = seed_in_flight(project, unquote(target_status))

        :ok = Tasks.subscribe_board()

        assert {:ok, superseded} =
                 Tasks.supersede_current_plan(task.id, "wrong scope", "reviewer-1")

        assert superseded.status == "planning"
        assert superseded.id == task.id

        latest = Tasks.latest_plan(task.id)
        assert latest.id == plan.id
        assert latest.status == "superseded"
        assert latest.rejection_reason == "wrong scope"

        assert_receive {:task_updated, %{id: tid, status: "planning"}}
        assert tid == task.id
        assert_receive {:plan_updated, %{status: "superseded", rejection_reason: "wrong scope"}}
      end
    end

    for bad_status <- ~w(backlog planning blocked done cancelled stack_pending) do
      test "refuses :not_in_flight when task is in #{bad_status}", %{project: project} do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Refusal #{unquote(bad_status)}",
            status: "planning"
          })

        {:ok, task} =
          task
          |> Platform.Tasks.Task.changeset(%{status: unquote(bad_status)})
          |> Platform.Repo.update()

        assert {:error, :not_in_flight} =
                 Tasks.supersede_current_plan(task.id, "reason", "actor-1")

        # Task remains in its prior status — atomic abort before any writes.
        assert Tasks.get_task_record(task.id).status == unquote(bad_status)
      end
    end

    test "refuses :reason_required for nil / blank / whitespace-only reasons",
         %{project: project} do
      %{task: task} = seed_in_flight(project, "in_progress")

      assert {:error, :reason_required} = Tasks.supersede_current_plan(task.id, nil, "a1")
      assert {:error, :reason_required} = Tasks.supersede_current_plan(task.id, "", "a1")
      assert {:error, :reason_required} = Tasks.supersede_current_plan(task.id, "   ", "a1")
      assert {:error, :reason_required} = Tasks.supersede_current_plan(task.id, "\t\n  ", "a1")

      # Task untouched.
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "refuses :no_active_plan when task is in_progress but has no approved/executing plan",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "In-progress, no plan",
          status: "planning"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, _rejected} = Tasks.reject_plan(plan, "system")

      # Force task to in_progress even though its only plan is rejected.
      {:ok, task} =
        task
        |> Platform.Tasks.Task.changeset(%{status: "in_progress"})
        |> Platform.Repo.update()

      assert {:error, :no_active_plan} =
               Tasks.supersede_current_plan(task.id, "reason", "actor-1")

      # Neither task nor plan mutated.
      assert Tasks.get_task_record(task.id).status == "in_progress"
      assert Tasks.latest_plan(task.id).status == "rejected"
    end

    test "posts a log-only system message to the execution space", %{project: project} do
      %{task: task, plan: plan} = seed_in_flight(project, "in_progress")

      # Materialize the execution space so post_log has a target.
      {:ok, space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)

      assert {:ok, _} =
               Tasks.supersede_current_plan(task.id, "scope shifted", "reviewer-x")

      messages = Platform.Chat.list_messages(space.id, limit: 10)

      assert Enum.any?(messages, fn m ->
               m.content_type == "system" and
                 m.log_only == true and
                 String.contains?(m.content, "Plan v#{plan.version} superseded") and
                 String.contains?(m.content, "scope shifted")
             end),
             "expected superseded system log; got: #{inspect(Enum.map(messages, & &1.content))}"
    end

    test "returns :not_found for unknown task ids" do
      assert {:error, :not_found} =
               Tasks.supersede_current_plan(Ecto.UUID.generate(), "reason", "a1")
    end

    test "picks the highest-version approved plan when multiple exist", %{project: project} do
      # v1 rejected, v2 approved (in-flight) — supersede must target v2.
      %{task: task, plan: v_current} = seed_in_flight(project, "in_progress")

      assert v_current.version == 1

      # Sanity: v_current is the plan latest_executing_plan returns.
      assert Tasks.latest_plan(task.id).id == v_current.id

      assert {:ok, _} =
               Tasks.supersede_current_plan(task.id, "bad scope", "actor-1")

      superseded = Tasks.latest_plan(task.id)
      assert superseded.id == v_current.id
      assert superseded.status == "superseded"
    end

    test "reason is trimmed-aware but preserves inner whitespace", %{project: project} do
      %{task: task} = seed_in_flight(project, "in_progress")

      assert {:ok, _} =
               Tasks.supersede_current_plan(task.id, "  outer spaces  fine  ", "a1")

      # Whatever the caller passed is what we persist — no automatic trim
      # applied. Only nil/all-whitespace triggers :reason_required.
      assert Tasks.latest_plan(task.id).rejection_reason == "  outer spaces  fine  "
    end
  end
end
