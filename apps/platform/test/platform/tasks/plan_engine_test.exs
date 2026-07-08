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

    test "reopens a failed stage when its last failed validation later passes", %{
      stage: stage,
      v1: v1,
      v2: v2
    } do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "failed"})

      failed_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert failed_stage.status == "failed"
      assert failed_stage.completed_at != nil

      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      recovered_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert recovered_stage.status == "passed"
      assert recovered_stage.started_at != nil
      assert recovered_stage.completed_at != nil
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

    test "completes the plan when a previously failed final-stage validation later passes", %{
      plan: plan
    } do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "ci_check"})

      PlanEngine.evaluate_validation(v1.id, %{status: "failed"})
      failed_plan = Platform.Repo.get!(Platform.Tasks.Plan, plan.id)
      refute failed_plan.status == "completed"

      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})

      completed_plan = Platform.Repo.get!(Platform.Tasks.Plan, plan.id)
      assert completed_plan.status == "completed"

      recovered_stage = Platform.Repo.get!(Platform.Tasks.Stage, s1.id)
      assert recovered_stage.status == "passed"
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
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
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

      # Deploy stage should have a single pr_merged validation
      validations = Tasks.list_validations(deploy_stage.id)
      assert length(validations) == 1
      kinds = Enum.map(validations, & &1.kind) |> Enum.sort()
      assert kinds == ["pr_merged"]

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
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
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
            "default_strategy" => %{"type" => "docker_deploy", "config" => %{}},
            # Stage-2 deploy-target guard (task 019f42db) — inherit satisfies
            # the guard so this test can still exercise the strategy path.
            "default_deploy_target" => "production"
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
          status: "in_progress",
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage != nil
    end

    test "auto-injects deploy stage even when planner submitted a plan with NO deploy stage",
         %{project: project} do
      # Regression guard for the role-separation change: the planner's
      # responsibility is implementation + validation only. The deploy stage
      # is the deployer's domain and is auto-injected by PlanEngine when all
      # planner-authored stages are complete and the task is in a deployable
      # status. This test verifies that a plan submitted with ONLY
      # implementation stages still ends up running the deploy strategy.
      strategy = %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Planner omitted deploy stage",
          status: "in_progress",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      # Two implementation-only stages — NO "Deploy: …" stage authored by the planner.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build feature"})
      {:ok, _test} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test feature"})

      # No "Deploy: ..." stage was authored by the planner.
      stage_names_before = plan.id |> Tasks.list_stages() |> Enum.map(& &1.name)
      refute Enum.any?(stage_names_before, &String.starts_with?(&1, "Deploy:"))

      # Run the implementation stages to completion.
      {:ok, _} = PlanEngine.start_stage(build.id)
      {:ok, _} = PlanEngine.advance(plan.id)
      # Test stage was auto-started by maybe_advance_next; advance again to drain it.
      {:ok, plan_after_impl} = PlanEngine.advance(plan.id)

      # The system must have auto-injected the deploy stage from the resolved
      # pr_merge strategy, transitioned the task to "deploying", and started
      # that stage — even though the planner never authored one.
      deploy_stage =
        Enum.find(plan_after_impl.stages, &String.starts_with?(&1.name, "Deploy:"))

      assert deploy_stage != nil,
             "expected PlanEngine to auto-inject a deploy stage when the planner omitted one"

      assert deploy_stage.name == "Deploy: PR merge"
      assert deploy_stage.status == "running"

      validations = Tasks.list_validations(deploy_stage.id)
      assert Enum.map(validations, & &1.kind) == ["pr_merged"]

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "deploying"
    end

    test "does not double-inject deploy stage on second advance", %{project: project} do
      strategy = %{"type" => "manual"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No double inject",
          status: "in_progress",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
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

    # ── ADR 0041 (T5 stage 3): stack-member deploy-injection guard ───────

    test "stack member does NOT get a per-task deploy stage injected", %{project: project} do
      alias Platform.Tasks.Stacks

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "no-deploy-#{System.unique_integer([:positive])}",
          name: "No Deploy Stack",
          rollup_branch: "stack/no-deploy"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member task",
          status: "in_progress",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — s1 passes; the plan would normally inject a Deploy
      # stage, but the stack-member guard MUST skip injection and
      # complete the plan instead. T6's stack rollup PR carries the
      # deploy for all members.
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
      assert length(updated_plan.stages) == 1

      # Task status MUST NOT have been moved to "deploying"
      reloaded = Tasks.get_task_record(task.id)
      refute reloaded.status == "deploying"
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

  describe "build_deploy_plan/1" do
    test "returns stage definitions for pr_merge strategy" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Plan Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/deploy-plan",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "config" => %{"auto_merge" => false}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy plan test task"
        })

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.name == "Deploy: PR merge"
      assert stage_def.position == 1
      assert stage_def.validations == [%{kind: "pr_merged"}]
    end

    test "positions deploy stage after existing plan stages" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Pos Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/deploy-pos",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "docker_deploy",
              "config" => %{}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy position test"
        })

      {:ok, plan} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "approved"
        })

      {:ok, _s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.position == 3
      assert stage_def.name == "Deploy: Docker deploy"
      assert %{kind: "ci_passed"} in stage_def.validations
      assert %{kind: "test_pass"} in stage_def.validations
    end

    test "returns :skip for strategy type none" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Skip Test #{System.unique_integer([:positive])}",
          deploy_config: %{
            "default_strategy" => %{"type" => "none"}
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No deploy test"
        })

      assert {:ok, :skip} = PlanEngine.build_deploy_plan(task.id)
    end

    test "returns error for nonexistent task" do
      assert {:error, :task_not_found} =
               PlanEngine.build_deploy_plan("00000000-0000-0000-0000-000000000000")
    end

    test "auto_merge true still emits a single pr_merged validation" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Auto Merge Test #{System.unique_integer([:positive])}",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "config" => %{"auto_merge" => true, "merge_method" => "rebase"}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto merge test"
        })

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.validations == [%{kind: "pr_merged"}]
    end
  end

  # ── route_e2e_behavior_validations/1 ──────────────────────────────────

  describe "route_e2e_behavior_validations/1" do
    test "lifts an e2e_behavior validation from an implementation stage into a synthesized task-level review stage" do
      e2e_payload = %{
        "setup" => "create a fixture task",
        "actions" => "open the panel",
        "expected" => "panel renders"
      }

      stages = [
        %{
          "name" => "Build feature",
          "description" => "implement the new endpoint",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "lint_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
          ]
        }
      ]

      [build_stage, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      # Implementation stage no longer carries the e2e validation
      assert build_stage["validations"] == [
               %{"kind" => "test_pass"},
               %{"kind" => "lint_pass"}
             ]

      # Synthesized review stage carries it at the next position
      assert review_stage["name"] == "Task-level review"
      assert review_stage["position"] == 2

      assert review_stage["validations"] == [
               %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
             ]
    end

    test "appends e2e_behavior validations to an existing review-named stage instead of synthesizing one" do
      e2e_payload = %{
        "setup" => "x",
        "actions" => "y",
        "expected" => "z"
      }

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
          ]
        },
        %{
          "name" => "Review",
          "position" => 2,
          "validations" => [%{"kind" => "manual_approval"}]
        }
      ]

      [build_stage, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      assert build_stage["validations"] == [%{"kind" => "test_pass"}]

      assert review_stage["validations"] == [
               %{"kind" => "manual_approval"},
               %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
             ]
    end

    test "leaves stages untouched when no e2e_behavior validation is present" do
      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      assert PlanEngine.route_e2e_behavior_validations(stages) == stages
    end

    test "ignores Deploy: stages when looking for an existing review stage to attach to" do
      e2e_payload = %{
        "setup" => "x",
        "actions" => "y",
        "expected" => "z"
      }

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [%{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}]
        },
        %{
          "name" => "Deploy: PR merge — review",
          "position" => 2,
          "validations" => [%{"kind" => "pr_merged"}]
        }
      ]

      [_build, deploy, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      assert deploy["validations"] == [%{"kind" => "pr_merged"}]
      assert review_stage["name"] == "Task-level review"
    end

    test "preserves multiple e2e_behavior validations on the synthetic review stage" do
      # v2: the planner authors an adversarial test plan with 2-5 e2e_behavior
      # validations covering happy path + edges. They MUST all be lifted onto a
      # single synthetic Task-level review stage, in author order.
      payload_a = %{"setup" => "s-a", "actions" => "a-a", "expected" => "e-a"}
      payload_b = %{"setup" => "s-b", "actions" => "a-b", "expected" => "e-b"}
      payload_c = %{"setup" => "s-c", "actions" => "a-c", "expected" => "e-c"}

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_a},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_b}
          ]
        },
        %{
          "name" => "Wire UI",
          "position" => 2,
          "validations" => [
            %{"kind" => "lint_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_c}
          ]
        }
      ]

      [build_stage, ui_stage, review_stage] =
        PlanEngine.route_e2e_behavior_validations(stages)

      # Implementation stages keep only their non-e2e validations.
      assert build_stage["validations"] == [%{"kind" => "test_pass"}]
      assert ui_stage["validations"] == [%{"kind" => "lint_pass"}]

      # Synthesized review stage holds all three e2e validations, in author order.
      assert review_stage["name"] == "Task-level review"
      assert review_stage["position"] == 3

      assert review_stage["validations"] == [
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_a},
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_b},
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_c}
             ]
    end
  end

  # ── ui_touching?/1 + check_manual_approval_heuristic/1 ──────────────

  describe "ui_touching?/1" do
    test "returns true when description contains UI-touching tokens" do
      assert PlanEngine.ui_touching?("update the .heex template for the panel")
      assert PlanEngine.ui_touching?("modify assets/js/hooks/compose_input.js")
      assert PlanEngine.ui_touching?("change tasks_live.ex render path")
      assert PlanEngine.ui_touching?("add a new section in app.css")
    end

    test "returns false for descriptions with no UI tokens" do
      refute PlanEngine.ui_touching?("update database migration")
      refute PlanEngine.ui_touching?("refactor business logic in plan_engine.ex")
      refute PlanEngine.ui_touching?(nil)
      refute PlanEngine.ui_touching?("")
    end
  end

  describe "check_manual_approval_heuristic/1" do
    import ExUnit.CaptureLog

    test "warns when a UI-touching stage lacks manual_approval" do
      stages = [
        %{
          "name" => "Render new panel",
          "description" => "edit assets/js/hooks/compose_input.js to add draft persistence",
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      assert log =~ "likely missed UI manual_approval"
      assert log =~ "Render new panel"
    end

    test "warns when a non-UI stage carries manual_approval (likely overscoped)" do
      stages = [
        %{
          "name" => "Database migration",
          "description" => "add a jsonb column to validations table",
          "validations" => [%{"kind" => "manual_approval"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      assert log =~ "likely overscoped manual_approval"
      assert log =~ "Database migration"
    end

    test "is silent when planner-supplied manual_approval matches a UI-touching stage" do
      stages = [
        %{
          "name" => "Render new panel",
          "description" => "edit chat_live.ex to render badges",
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "manual_approval"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      refute log =~ "likely missed UI manual_approval"
      refute log =~ "likely overscoped manual_approval"
    end

    test "is silent when planner correctly omits manual_approval from a non-UI stage" do
      stages = [
        %{
          "name" => "Background worker",
          "description" => "implement Oban worker for the daily digest job",
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "lint_pass"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      refute log =~ "likely missed UI manual_approval"
      refute log =~ "likely overscoped manual_approval"
    end

    test "returns input untouched (planner authority wins)" do
      stages = [
        %{
          "name" => "X",
          "description" => "edit chat_live.ex without approval",
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      assert PlanEngine.check_manual_approval_heuristic(stages) == stages
    end
  end
end
