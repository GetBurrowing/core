defmodule Platform.Tasks.DeployRollbackTest do
  @moduledoc """
  Tests for deploy failure rollback: PlanEngine deploy_stage? detection,
  deploy failure telemetry, and task transition on deploy stage failure.
  """
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Rollback Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/rollback",
        deploy_config: %{
          "default_strategy" => %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => false}
          }
        }
      })

    %{project: project}
  end

  describe "PlanEngine.deploy_stage?/1" do
    test "returns true for stage named Deploy:*", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Deploy detect"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      assert PlanEngine.deploy_stage?(stage)
    end

    test "returns true for stage with ci_passed validation", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "CI detect"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Final stage"
        })

      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_passed"})
      assert PlanEngine.deploy_stage?(stage)
    end

    test "returns true for stage with pr_merged validation", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "PR detect"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Merge stage"
        })

      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})
      assert PlanEngine.deploy_stage?(stage)
    end

    test "returns false for regular coding stage", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Regular"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Implementation"
        })

      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      refute PlanEngine.deploy_stage?(stage)
    end
  end

  describe "deploy stage failure → CI fail rollback" do
    test "failing ci_passed validation marks deploy stage as failed", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "CI fail rollback",
          status: "deploying"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      {:ok, _} = PlanEngine.start_stage(stage.id)

      {:ok, ci_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_passed"})
      {:ok, _pr_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      # Fail the ci_passed validation
      {:ok, _} =
        PlanEngine.evaluate_validation(ci_val.id, %{
          status: "failed",
          evidence: %{"conclusion" => "failure", "sha" => "abc123"},
          evaluated_by: "github_webhook"
        })

      # Stage should be failed
      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "failed"
    end
  end

  describe "deploy stage failure → merge conflict rollback" do
    test "failing pr_merged validation marks deploy stage as failed", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Merge conflict rollback",
          status: "deploying"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      {:ok, _} = PlanEngine.start_stage(stage.id)

      {:ok, ci_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_passed"})
      {:ok, pr_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      # Pass CI first
      {:ok, _} =
        PlanEngine.evaluate_validation(ci_val.id, %{
          status: "passed",
          evidence: %{"conclusion" => "success"},
          evaluated_by: "github_webhook"
        })

      # Fail the pr_merged validation (merge conflict)
      {:ok, _} =
        PlanEngine.evaluate_validation(pr_val.id, %{
          status: "failed",
          evidence: %{
            "reason" => "merge_conflict",
            "merge_sha" => "def456"
          },
          evaluated_by: "auto_merger"
        })

      # Stage should be failed
      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "failed"
    end
  end

  describe "deploy stage failure → health check rollback" do
    test "failing test_pass on deploy health check marks stage failed", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Health check rollback",
          status: "deploying"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: Docker deploy"
        })

      {:ok, _} = PlanEngine.start_stage(stage.id)

      {:ok, ci_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_passed"})
      {:ok, health_val} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      # Pass CI
      {:ok, _} =
        PlanEngine.evaluate_validation(ci_val.id, %{
          status: "passed",
          evidence: %{"conclusion" => "success"},
          evaluated_by: "github_webhook"
        })

      # Fail health check
      {:ok, _} =
        PlanEngine.evaluate_validation(health_val.id, %{
          status: "failed",
          evidence: %{
            "reason" => "health_check_failed",
            "sha" => "ghi789",
            "output" => "HTTP 503 Service Unavailable"
          },
          evaluated_by: "deploy_agent"
        })

      # Stage should be failed
      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "failed"
    end
  end

  describe "HeartbeatScheduler deploy_failure cadence" do
    alias Platform.Orchestration.HeartbeatScheduler

    test "deploy_failure has shorter intervals than regular deploying" do
      deploy_failure_interval = HeartbeatScheduler.interval_ms("deploy_failure")
      deploy_failure_stall = HeartbeatScheduler.stall_threshold_ms("deploy_failure")

      assert deploy_failure_interval == 5 * 60_000
      assert deploy_failure_stall == 10 * 60_000
    end

    test "deploy_failure has 3 max escalations" do
      assert HeartbeatScheduler.max_escalations("deploy_failure") == 3
    end
  end
end
