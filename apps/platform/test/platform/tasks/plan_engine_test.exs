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
    test "advances to next stage when current passes (auto-starts next)", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      # No validations on s1 → all passed → next stage auto-starts
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      stage_statuses = Enum.map(updated_plan.stages, & &1.status)
      assert List.first(stage_statuses) == "passed"
      # Next stage is auto-started to "running" (not left as "pending")
      assert List.last(stage_statuses) == "running"
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
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Run and pass s1 — s2 auto-starts
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # s2 is already running (auto-started), advance again to complete
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
    end

    test "plan not completed if a stage failed", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Pass s1 — s2 auto-starts
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # s2 is already running (auto-started), add a failing validation
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{})
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      # Plan should NOT be completed because s2 failed
      refute updated_plan.status == "completed"
    end
  end

  # ── Deploy stage injection ─────────────────────────────────────────────

  describe "deploy stage injection" do
    test "injects deploy stage when strategy is not none", %{project: project} do
      strategy = %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deployable task",
          status: "in_progress",
          deploy_strategy: strategy
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — s1 has no validations, passes immediately
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      # Plan should NOT be completed yet
      refute updated_plan.status == "completed"

      # Deploy stage should be injected and running
      stages = updated_plan.stages
      assert length(stages) == 2

      deploy_stage = Enum.find(stages, &(&1.name == "Deploy: PR merge"))
      assert deploy_stage != nil
      assert deploy_stage.position == 2
      assert deploy_stage.status == "running"

      # Deploy stage should have validations
      validations = Tasks.list_validations(deploy_stage.id)
      assert length(validations) == 2
      kinds = Enum.map(validations, & &1.kind) |> Enum.sort()
      assert kinds == ["manual_approval", "test_pass"]

      # Task should be in deploying status
      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "deploying"
    end

    test "completes plan normally when strategy is none", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No-deploy task",
          status: "in_progress",
          deploy_strategy: %{"type" => "none"}
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
      assert length(updated_plan.stages) == 1
    end

    test "completes plan when deploy stage passes", %{project: project} do
      strategy = %{"type" => "manual"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy then done",
          status: "in_progress",
          deploy_strategy: strategy
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — injects deploy stage
      {:ok, plan_after_inject} = PlanEngine.advance(plan.id)
      refute plan_after_inject.status == "completed"

      deploy_stage = Enum.find(plan_after_inject.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage.status == "running"

      # Pass the deploy stage's manual_approval validation
      [validation] = Tasks.list_validations(deploy_stage.id)
      assert validation.kind == "manual_approval"

      PlanEngine.evaluate_validation(validation.id, %{
        status: "passed",
        evaluated_by: "test"
      })

      # Now the plan should be completed
      final_plan = Tasks.get_plan(plan.id)
      assert final_plan.status == "completed"
    end

    test "uses project default strategy when task has no override", %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{
            "default_strategy" => %{"type" => "docker_deploy", "config" => %{}}
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Inherit strategy",
          status: "in_progress"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Docker deploy"))
      assert deploy_stage != nil
      assert deploy_stage.status == "running"
    end

    test "falls back to manual strategy when no strategy set anywhere", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Fallback manual",
          status: "in_progress"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage != nil
    end

    test "does not double-inject deploy stage on second advance", %{project: project} do
      strategy = %{"type" => "manual"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No double inject",
          status: "in_progress",
          deploy_strategy: strategy
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # First advance — injects deploy stage
      {:ok, plan_v1} = PlanEngine.advance(plan.id)
      assert length(plan_v1.stages) == 2

      # Second advance — deploy stage is running, has pending validation
      # Should NOT inject another deploy stage
      {:ok, plan_v2} = PlanEngine.advance(plan.id)
      assert length(plan_v2.stages) == 2
    end
  end

  # ── Full lifecycle ────────────────────────────────────────────────────

  describe "full plan lifecycle" do
    test "build → test → deploy with validations", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})
      {:ok, _s3} = Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "Deploy"})

      # Stage 1: Build — no validations, just start and advance
      # s2 auto-starts after s1 passes
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # Stage 2: Test — already running (auto-started), add validations
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      {:ok, v2} = Tasks.create_validation(%{stage_id: s2.id, kind: "lint_pass"})

      # Pass both validations — auto-advances stage, s3 auto-starts
      PlanEngine.evaluate_validation(v1.id, %{status: "passed", evidence: %{"tests" => 42}})
      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      s2_updated = Platform.Repo.get!(Platform.Tasks.Stage, s2.id)
      assert s2_updated.status == "passed"

      # Stage 3: Deploy — already running (auto-started), no validations
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
