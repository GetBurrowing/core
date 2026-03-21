defmodule Platform.Tasks.PlanEngineTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Engine Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Engine Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    %{project: project, task: task, plan: plan}
  end

  # ── start_stage/1 ─────────────────────────────────────────────────────

  describe "start_stage/1" do
    test "transitions pending stage to running", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      assert {:ok, started} = PlanEngine.start_stage(stage.id)
      assert started.status == "running"
      assert started.started_at != nil
    end

    test "rejects starting a non-pending stage", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(stage.id)

      # Already running — can't start again
      assert {:error, :invalid_transition} = PlanEngine.start_stage(stage.id)
    end

    test "returns error for nonexistent stage" do
      assert {:error, :not_found} = PlanEngine.start_stage(Ecto.UUID.generate())
    end
  end

  # ── evaluate_validation/2 ─────────────────────────────────────────────

  describe "evaluate_validation/2" do
    setup %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(stage.id)
      stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)

      {:ok, v1} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      {:ok, v2} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

      %{stage: stage, v1: v1, v2: v2}
    end

    test "records pass result on a validation", %{v1: v1} do
      result = %{status: "passed", evidence: %{"exit_code" => 0}, evaluated_by: "system"}
      assert {:ok, updated} = PlanEngine.evaluate_validation(v1.id, result)
      assert updated.status == "passed"
      assert updated.evidence == %{"exit_code" => 0}
      assert updated.evaluated_by == "system"
      assert updated.evaluated_at != nil
    end

    test "records fail result on a validation", %{v1: v1} do
      result = %{status: "failed", evidence: %{"error" => "tests failed"}}
      assert {:ok, updated} = PlanEngine.evaluate_validation(v1.id, result)
      assert updated.status == "failed"
    end

    test "auto-advances stage when all validations pass", %{stage: stage, v1: v1, v2: v2} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "passed"
    end

    test "auto-advances stage to failed when a validation fails", %{stage: stage, v1: v1, v2: v2} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "failed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "failed"
    end

    test "does not advance when validations are still pending", %{stage: stage, v1: v1} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      # v2 still pending, so stage stays running
      assert updated_stage.status == "running"
    end

    test "raises on invalid result status", %{v1: v1} do
      assert_raise ArgumentError, fn ->
        PlanEngine.evaluate_validation(v1.id, %{status: "unknown"})
      end
    end
  end

  # ── advance/1 ─────────────────────────────────────────────────────────

  describe "advance/1" do
    test "advances to next stage when current passes", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      # No validations on s1 → all passed
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      stage_statuses = Enum.map(updated_plan.stages, & &1.status)
      assert List.first(stage_statuses) == "passed"
      assert List.last(stage_statuses) == "pending"
    end

    test "completes plan when last stage passes", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      # No validations → auto-passes
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      assert updated_plan.status == "completed"
    end

    test "marks stage failed when validations fail", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{"error" => "boom"})

      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      stage = Enum.find(updated_plan.stages, &(&1.position == 1))
      assert stage.status == "failed"
    end

    test "no-op when validations are still pending", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})

      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      stage = Enum.find(updated_plan.stages, &(&1.position == 1))
      assert stage.status == "running"
    end

    test "all stages passed completes the plan", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Run and pass s1
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # Run and pass s2
      {:ok, _} = PlanEngine.start_stage(s2.id)
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
    end

    test "plan not completed if a stage failed", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Pass s1
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # Fail s2
      {:ok, _} = PlanEngine.start_stage(s2.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{})
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      # Plan should NOT be completed because s2 failed
      refute updated_plan.status == "completed"
    end
  end

  # ── Full lifecycle ────────────────────────────────────────────────────

  describe "full plan lifecycle" do
    test "build → test → deploy with validations", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})
      {:ok, s3} = Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "Deploy"})

      # Stage 1: Build — no validations, just start and advance
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # Stage 2: Test — with validations
      {:ok, _} = PlanEngine.start_stage(s2.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      {:ok, v2} = Tasks.create_validation(%{stage_id: s2.id, kind: "lint_pass"})

      # Pass both validations — auto-advances stage
      PlanEngine.evaluate_validation(v1.id, %{status: "passed", evidence: %{"tests" => 42}})
      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      s2_updated = Platform.Repo.get!(Platform.Tasks.Stage, s2.id)
      assert s2_updated.status == "passed"

      # Stage 3: Deploy — no validations
      {:ok, _} = PlanEngine.start_stage(s3.id)
      {:ok, final_plan} = PlanEngine.advance(plan.id)

      assert final_plan.status == "completed"
      assert Enum.all?(final_plan.stages, &(&1.status == "passed"))
    end

    test "retry a failed stage", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})

      # Fail validation → stage auto-fails
      PlanEngine.evaluate_validation(v1.id, %{status: "failed"})
      s1_failed = Platform.Repo.get!(Platform.Tasks.Stage, s1.id)
      assert s1_failed.status == "failed"

      # Retry: transition failed → running
      {:ok, s1_retried} = PlanEngine.start_stage(s1.id)
      assert s1_retried.status == "running"
    end
  end
end
