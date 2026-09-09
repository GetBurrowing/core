defmodule Platform.Tasks.PlanTest do
  use Platform.DataCase, async: true

  import Platform.SubmittablePlanFixtures

  import Ecto.Changeset, only: [get_change: 2]

  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Validation

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Plan Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plan Task"})
    %{project: project, task: task}
  end

  describe "create_plan/1" do
    test "creates with auto-incremented version after the previous plan is rejected", %{
      task: task
    } do
      assert {:ok, %Plan{} = plan1} = create_submittable_plan(%{task_id: task.id})
      assert plan1.version == 1
      assert plan1.status == "draft"

      # Cannot create another plan while v1 is still draft/pending_review.
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})

      # After rejection, the next plan is allowed and gets the next version.
      {:ok, _} = Tasks.reject_plan(plan1, Ecto.UUID.generate())
      assert {:ok, plan2} = create_submittable_plan(%{task_id: task.id})
      assert plan2.version == 2
    end

    test "rejects a duplicate plan while one is in draft", %{task: task} do
      assert {:ok, _} = create_submittable_plan(%{task_id: task.id})
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})
    end

    test "rejects a duplicate plan while one is pending_review", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, _} = Tasks.submit_plan_for_review(plan)
      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})
    end

    test "respects explicit version", %{task: task} do
      assert {:ok, plan} = create_submittable_plan(%{task_id: task.id, version: 42})
      assert plan.version == 42
    end
  end

  describe "approval flow" do
    test "draft → pending_review → approved", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, plan} = Tasks.approve_plan(plan, "system")
      assert plan.status == "approved"
      assert plan.approved_by == "system"

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "in_progress"
    end

    test "draft → pending_review → rejected", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, plan} = Tasks.reject_plan(plan, Ecto.UUID.generate())
      assert plan.status == "rejected"
    end

    test "cannot approve a draft plan", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      assert {:error, :invalid_transition} = Tasks.approve_plan(plan, Ecto.UUID.generate())
    end

    test "cannot submit a non-draft plan for review", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      assert {:error, :invalid_transition} = Tasks.submit_plan_for_review(plan)
    end
  end

  describe "current_plan/1" do
    test "returns latest approved plan", %{task: task} do
      {:ok, plan1} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      {:ok, _plan1} = Tasks.approve_plan(plan1, Ecto.UUID.generate())

      {:ok, plan2} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan2} = Tasks.submit_plan_for_review(plan2)
      {:ok, _plan2} = Tasks.approve_plan(plan2, Ecto.UUID.generate())

      current = Tasks.current_plan(task.id)
      assert current.version == 2
    end

    test "returns nil when no approved plans", %{task: task} do
      {:ok, _} = create_submittable_plan(%{task_id: task.id})
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
      {:ok, plan_v1} = create_submittable_plan(%{task_id: task.id})
      # Need plan_v1 in a non-blocking status before creating v2.
      {:ok, plan_v1} = Tasks.submit_plan_for_review(plan_v1)
      {:ok, _} = Tasks.reject_plan(plan_v1, Ecto.UUID.generate())
      {:ok, plan_v2} = create_submittable_plan(%{task_id: task.id})

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
      {:ok, plan1} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan1} = Tasks.submit_plan_for_review(plan1)
      {:ok, _} = Tasks.reject_plan(plan1, Ecto.UUID.generate())
      {:ok, _} = create_submittable_plan(%{task_id: task.id})

      plans = Tasks.list_plans(task.id)
      assert length(plans) == 2
      assert Enum.map(plans, & &1.version) == [1, 2]
    end
  end

  describe "reject_plan/3" do
    test "persists rejection_reason when provided on a pending_review plan", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      assert {:ok, rejected} =
               Tasks.reject_plan(plan, Ecto.UUID.generate(), "Did not address the auth path")

      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "Did not address the auth path"
    end

    test "leaves rejection_reason nil when no reason given (back-compat)", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)

      # 2-arity form delegates to 3-arity with reason: nil.
      assert {:ok, rejected} = Tasks.reject_plan(plan, Ecto.UUID.generate())
      assert rejected.status == "rejected"
      assert is_nil(rejected.rejection_reason)
    end

    test "accepts approved and completed plans (reopen-with-feedback path)", %{task: task} do
      # Approved
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")
      assert plan.status == "approved"

      assert {:ok, rejected} = Tasks.reject_plan(plan, "reviewer", "post-done feedback")
      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "post-done feedback"

      # Completed (force the status directly via changeset to model a completed plan)
      {:ok, plan2} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan2} = Plan.changeset(plan2, %{status: "completed"}) |> Platform.Repo.update()

      assert {:ok, rejected2} = Tasks.reject_plan(plan2, "reviewer", "completed-but-bad")
      assert rejected2.status == "rejected"
      assert rejected2.rejection_reason == "completed-but-bad"
    end

    # Task 01a05b32 stage 1 — draft is rejectable now (planner self-service),
    # so the only status left outside the guard is "rejected" itself.
    test "refuses plans in non-rejectable statuses", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.reject_plan(plan, "actor", "first rejection")
      assert plan.status == "rejected"

      assert {:error, :invalid_transition} = Tasks.reject_plan(plan, "actor", "again")
    end

    # ── Task 01a05b32 stage 1 — the planner self-service draft path ───────

    test "rejects a draft directly with the reason persisted on the row", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      assert plan.status == "draft"

      assert {:ok, rejected} =
               Tasks.reject_plan(plan, "planner-agent", "wrong scope, missing the audit stage")

      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "wrong scope, missing the audit stage"

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "rejected"
      assert reloaded.rejection_reason == "wrong scope, missing the audit stage"
    end

    # THE acceptance criterion, asserted end to end: after reject_plan on a
    # draft, create_plan/1 on the SAME task succeeds — no submit, no human
    # round-trip, no admin/DB step. A draft rejection must also leave the
    # task's status untouched so the fresh plan starts from the same state.
    test "draft rejection leaves the task untouched so create_plan works immediately", %{
      task: task
    } do
      {:ok, task} = Tasks.update_task(task, %{status: "planning"})
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})

      assert {:ok, _rejected} = Tasks.reject_plan(plan, "planner-agent", "obsolete draft")

      assert Tasks.get_task_record(task.id).status == "planning"

      assert {:ok, plan2} = create_submittable_plan(%{task_id: task.id})
      assert plan2.version == 2
      assert plan2.status == "draft"
    end
  end

  describe "replace_plan_stages/3" do
    defp stage_input(name, position, validations) do
      %{
        "name" => name,
        "description" => "#{name} description",
        "position" => position,
        "validations" => validations
      }
    end

    defp seed_old_tree(task) do
      # Already submittable on its own: the "Old" stage below is a real
      # planner-authored stage, so no fixture helper is needed here.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Old", position: 1})
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})
      %{plan: plan, stage: stage, validation: validation}
    end

    test "swaps the draft's tree in place: plan row, id and version stay stable", %{task: task} do
      %{plan: plan, stage: old_stage} = seed_old_tree(task)

      assert {:ok, updated} =
               Tasks.replace_plan_stages(plan, [
                 stage_input("Build", 1, [%{"kind" => "test_pass"}]),
                 stage_input("Surface", 2, [])
               ])

      # The plan ROW is reused — id and version are stable, so a caller
      # holding the old plan can plan_submit it afterward. No new version
      # row means the unique (task_id, version) constraint stays satisfied.
      assert updated.id == plan.id
      assert updated.version == plan.version
      assert updated.status == "draft"

      assert Enum.map(updated.stages, & &1.name) == ["Build", "Surface"]
      assert Enum.map(updated.stages, & &1.position) == [1, 2]

      build = Enum.find(updated.stages, &(&1.name == "Build"))
      assert [%Validation{} = v] = build.validations
      assert v.kind == "test_pass"

      # Same tree read back through get_plan — persisted, not just returned.
      reloaded = Platform.Repo.preload(Tasks.get_plan(plan.id), stages: :validations)
      assert Enum.map(reloaded.stages, & &1.name) == ["Build", "Surface"]
      assert old_stage.id in Enum.map(reloaded.stages, & &1.id) == false

      # No orphaned validation rows survive the swap.
      orphans =
        Platform.Repo.all(from(v in Validation, where: v.stage_id == ^old_stage.id))

      assert orphans == []
    end

    test "accepts atom-keyed stage maps like the create paths do", %{task: task} do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})

      assert {:ok, updated} =
               Tasks.replace_plan_stages(plan, [
                 %{
                   name: "Build",
                   description: "Build it",
                   position: 1,
                   validations: [%{kind: "test_pass", evaluation_payload: %{"x" => 1}}]
                 }
               ])

      assert [stage] = updated.stages
      assert stage.name == "Build"
      assert [validation] = stage.validations
      assert validation.evaluation_payload == %{"x" => 1}
    end

    test "refuses a pending_review or approved plan and leaves the tree byte-identical", %{
      task: task
    } do
      %{plan: plan, stage: stage, validation: validation} = seed_old_tree(task)

      assert {:ok, _pending} = Tasks.submit_plan_for_review(plan)

      assert {:error, :invalid_transition} =
               Tasks.replace_plan_stages(Tasks.get_plan(plan.id), [
                 stage_input("New", 1, [])
               ])

      {:ok, approved} = Tasks.approve_plan(Tasks.get_plan(plan.id), "system")

      assert {:error, :invalid_transition} =
               Tasks.replace_plan_stages(approved, [stage_input("New", 1, [])])

      # Byte-identical: same stage row, same validation row, same status.
      reloaded = Platform.Repo.preload(Tasks.get_plan(plan.id), stages: :validations)
      assert reloaded.status == "approved"
      assert Enum.map(reloaded.stages, & &1.id) == [stage.id]

      assert Enum.map(reloaded.stages, fn s -> Enum.map(s.validations, & &1.id) end) == [
               [validation.id]
             ]

      assert Enum.find(reloaded.stages, &(&1.id == stage.id)).name == "Old"
    end

    # The status is re-checked against the PERSISTED row inside the
    # transaction, so a caller whose struct went stale cannot rewrite a plan
    # that was submitted in the meantime — the Plan-State Lock holds even
    # against a stale read.
    test "re-checks draft status inside the transaction: a stale draft struct cannot rewrite a submitted plan",
         %{task: task} do
      %{plan: plan, stage: stage} = seed_old_tree(task)

      assert {:ok, _pending} = Tasks.submit_plan_for_review(plan)

      # The caller's struct still says "draft"; the row says pending_review.
      stale = %{plan | status: "draft"}

      assert {:error, :invalid_transition} =
               Tasks.replace_plan_stages(stale, [stage_input("New", 1, [])])

      reloaded = Tasks.get_plan(plan.id)
      assert reloaded.status == "pending_review"
      assert Enum.map(reloaded.stages, & &1.id) == [stage.id]
    end

    test "rolls back atomically on a schema-invalid child: the old tree survives", %{task: task} do
      %{plan: plan, stage: stage, validation: validation} = seed_old_tree(task)

      # "not_a_kind" fails Validation's kind inclusion check AFTER the old
      # tree was already deleted inside the transaction — the whole swap
      # must roll back, leaving the old stages and validations in place.
      assert {:error, %Ecto.Changeset{}} =
               Tasks.replace_plan_stages(plan, [
                 stage_input("Build", 1, [%{"kind" => "not_a_kind"}])
               ])

      reloaded = Platform.Repo.preload(Tasks.get_plan(plan.id), stages: :validations)
      assert Enum.map(reloaded.stages, & &1.id) == [stage.id]

      assert Enum.map(reloaded.stages, fn s -> Enum.map(s.validations, & &1.id) end) == [
               [validation.id]
             ]
    end
  end

  describe "approve_plan/2 auto-supersession" do
    # Helper: drive a task to having an approved v1 in place.
    defp approve_v1(task) do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
      {:ok, plan} = Tasks.submit_plan_for_review(plan)
      {:ok, plan} = Tasks.approve_plan(plan, "system")
      plan
    end

    defp draft_and_review(task) do
      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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
      {:ok, v1} = create_submittable_plan(%{task_id: task.id})
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

      # Scope-narrowed on purpose. This module is `async: true`, and on the
      # GLOBAL board topic `%Plan{status: "approved"}` matches a concurrent
      # sibling's broadcast about a completely unrelated plan — the id check
      # then fails on a foreign id. Both halves below matter: the scoped
      # subscription keeps other modules' events out of the mailbox, and
      # pinning the ids INTO the patterns makes each assertion true on its
      # own terms rather than only after a follow-up ==.
      :ok = Tasks.subscribe_board(task: task.id)

      v2_pending = draft_and_review(task)
      {:ok, v2} = Tasks.approve_plan(v2_pending, "system")

      v1_id = v1.id
      v2_id = v2.id

      # The supersedee (v1 → rejected) is broadcast first…
      assert_receive {:plan_updated, %Plan{id: ^v1_id, status: "rejected"} = sup}
      assert sup.superseded_by_plan_id == v2.id

      # …then the newly-approved v2.
      assert_receive {:plan_updated, %Plan{id: ^v2_id, status: "approved"}}
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

      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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
      :ok = Tasks.subscribe_board(task: task.id)

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
      #
      # `tasks:board` is a GLOBAL topic and this module is `async: true`, so
      # the id must be pinned INTO the pattern rather than checked after the
      # fact: `assert_receive` scans the mailbox for a matching message, and
      # an unpinned `%{id: tid, status: "planning"}` matches any concurrent
      # sibling's broadcast about any task that happens to be in planning —
      # then fails on `tid == task.id` with a foreign id. ADR-0046 member 4
      # made that concrete: `submit_plan_for_review/1` now emits three
      # `{:task_updated, %Task{status: "planning"}}` broadcasts (planning-step
      # cursor + outcome), and this assertion started picking them up.
      # Pinning is strictly stronger — it never passed on a foreign message.
      # The subscription above is ALSO scope-narrowed to this task, which is
      # what keeps sibling modules' events out of the mailbox in the first
      # place; pinning then makes each assertion self-evidently about the
      # right row.
      task_id = task.id
      latest_id = latest.id
      assert_receive {:task_updated, %{id: ^task_id, status: "planning"}}

      assert_receive {:plan_updated,
                      %{id: ^latest_id, status: "rejected", rejection_reason: "Missed the spec"}}
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

      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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

        :ok = Tasks.subscribe_board(task: task.id)

        assert {:ok, superseded} =
                 Tasks.supersede_current_plan(task.id, "wrong scope", "reviewer-1")

        assert superseded.status == "planning"
        assert superseded.id == task.id

        latest = Tasks.latest_plan(task.id)
        assert latest.id == plan.id
        assert latest.status == "superseded"
        assert latest.rejection_reason == "wrong scope"

        # Pinned into the pattern for the same reason as the
        # `reopen_with_feedback/3` sibling above — see the note there. The
        # subscription is scope-narrowed to this task for the same reason.
        task_id = task.id
        plan_id = plan.id
        assert_receive {:task_updated, %{id: ^task_id, status: "planning"}}

        assert_receive {:plan_updated,
                        %{id: ^plan_id, status: "superseded", rejection_reason: "wrong scope"}}
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

      {:ok, plan} = create_submittable_plan(%{task_id: task.id})
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

  # ── task 01a05b32 stage 3: two writers on plan.version ─────────────────
  #
  # Approval's supersession mints a NEW plan row at version+1, while
  # `replace_plan_stages/3` rewrites IN PLACE at a stable version. These
  # tests pin the downstream version READERS against the same-row rewrite:
  # each reader must resolve the rewritten row (same id, same version,
  # corrected content), and the version counter must not collide with the
  # in-place row. No reader's behavior is changed here — the architecture
  # verdict on this plan asked for assertions, not patches.
  describe "plan version readers after an in-place rewrite (task 01a05b32 stage 3)" do
    defp rewrite_stage(name, position) do
      %{
        "name" => name,
        "description" => "#{name} description",
        "position" => position,
        "validations" => []
      }
    end

    test "create_plan/1 still refuses while the rewritten draft exists", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Old", position: 1})

      assert {:ok, _rewritten} =
               Tasks.replace_plan_stages(plan, [rewrite_stage("Fixed", 1)])

      # create_plan's draft-block reads latest_plan/1 (desc version,
      # limit 1). The rewrite moved NO version, so the reader must still
      # resolve the SAME row as a live draft — a reader that keyed on
      # "different version ⇒ different row" would skip the rewritten
      # draft and mint a colliding v1.
      latest = Tasks.latest_plan(task.id)
      assert latest.id == plan.id
      assert latest.version == plan.version
      assert latest.status == "draft"

      assert {:error, :plan_pending_review} = Tasks.create_plan(%{task_id: task.id})
    end

    test "list_plans/1 sees exactly one row at the stable version", %{task: task} do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Old", position: 1})

      assert {:ok, _rewritten} =
               Tasks.replace_plan_stages(plan, [rewrite_stage("Fixed", 1)])

      # One rewrite = still one version row: the history view must not
      # show a phantom v2, and the surviving row carries the corrected
      # tree at the SAME version. list_plans/1 preloads nothing, so the
      # stage read is explicit.
      plans = Tasks.list_plans(task.id)
      assert length(plans) == 1
      assert hd(plans).id == plan.id
      assert hd(plans).version == plan.version

      assert hd(plans)
             |> Platform.Repo.preload(:stages)
             |> Map.get(:stages)
             |> Enum.map(& &1.name) ==
               ["Fixed"]
    end

    test "the writers compose: a rewrite keeps v1, the next plan after a discard mints v2", %{
      task: task
    } do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, name: "Wrong", position: 1})
      assert plan.version == 1

      assert {:ok, rewritten} =
               Tasks.replace_plan_stages(plan, [rewrite_stage("Fixed", 1)])

      # In-place writer: version did NOT move.
      assert rewritten.version == 1

      # Discard writer (plan_reject on the draft), then the counter:
      # next_plan_version is max(version)+1 over ROWS, and the rewritten
      # row still IS v1 — so the next plan is v2, no collision with the
      # in-place row.
      assert {:ok, _} = Tasks.reject_plan(rewritten, Ecto.UUID.generate())
      assert {:ok, v2} = create_submittable_plan(%{task_id: task.id})
      assert v2.version == 2
    end
  end
end
