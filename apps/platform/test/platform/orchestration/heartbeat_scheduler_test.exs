defmodule Platform.Orchestration.HeartbeatSchedulerTest do
  use ExUnit.Case, async: true

  alias Platform.Orchestration.HeartbeatScheduler

  describe "interval_ms/1" do
    test "returns correct intervals per stage type" do
      assert HeartbeatScheduler.interval_ms("planning") == 15 * 60_000
      assert HeartbeatScheduler.interval_ms("coding") == 10 * 60_000
      assert HeartbeatScheduler.interval_ms("ci_check") == 5 * 60_000
      assert HeartbeatScheduler.interval_ms("review") == 20 * 60_000
      assert HeartbeatScheduler.interval_ms("deploying") == 5 * 60_000
    end

    test "returns nil for manual_approval" do
      assert HeartbeatScheduler.interval_ms("manual_approval") == nil
    end

    test "returns default for unknown stage types" do
      assert HeartbeatScheduler.interval_ms("unknown") == 10 * 60_000
    end
  end

  describe "stall_threshold_ms/1" do
    test "returns correct thresholds per stage type" do
      assert HeartbeatScheduler.stall_threshold_ms("planning") == 30 * 60_000
      assert HeartbeatScheduler.stall_threshold_ms("coding") == 25 * 60_000
      assert HeartbeatScheduler.stall_threshold_ms("ci_check") == 15 * 60_000
      assert HeartbeatScheduler.stall_threshold_ms("review") == 60 * 60_000
      assert HeartbeatScheduler.stall_threshold_ms("deploying") == 15 * 60_000
    end

    test "returns nil for manual_approval" do
      assert HeartbeatScheduler.stall_threshold_ms("manual_approval") == nil
    end
  end

  describe "max_escalations/1" do
    test "returns correct escalation counts" do
      assert HeartbeatScheduler.max_escalations("planning") == 2
      assert HeartbeatScheduler.max_escalations("coding") == 2
      assert HeartbeatScheduler.max_escalations("ci_check") == 3
      assert HeartbeatScheduler.max_escalations("review") == 1
      assert HeartbeatScheduler.max_escalations("deploying") == 3
    end

    test "returns nil for manual_approval" do
      assert HeartbeatScheduler.max_escalations("manual_approval") == nil
    end
  end

  describe "manual_approval?/1" do
    test "returns true for manual_approval" do
      assert HeartbeatScheduler.manual_approval?("manual_approval") == true
    end

    test "returns false for other types" do
      refute HeartbeatScheduler.manual_approval?("coding")
      refute HeartbeatScheduler.manual_approval?("planning")
    end
  end

  describe "dispatch_prompt/3" do
    test "planning without plan instructs agent to create a plan" do
      task = %{
        title: "Fix auth bug",
        description: "Auth is broken",
        status: "planning",
        priority: "high"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert prompt =~ "Fix auth bug"
      assert prompt =~ "Auth is broken"
      assert prompt =~ "plan_create"
      assert prompt =~ "plan_submit"
      assert prompt =~ "Implementation stages"
      assert prompt =~ "test_pass"
      assert prompt =~ "lint_pass"
      assert prompt =~ "Push branch when implementation stages are complete"
      assert prompt =~ "do NOT open a PR yet"
      assert prompt =~ "Final review stage"
      assert prompt =~ "take a screenshot or canvas snapshot as evidence"
      assert prompt =~ "manual_approval"
      assert prompt =~ "suite_review_request_create"

      assert prompt =~
               "screenshot into the execution space so the human can review before approving"

      assert prompt =~ "open the PR and include the PR link as evidence on the final validation"
      assert prompt =~ "Do NOT include `code_review` as a validation kind"
      assert prompt =~ "Do not begin implementation until approved"
      assert prompt =~ "high"
    end

    test "in_progress generates execution prompt with git workflow and completion contract" do
      task = %{
        id: "task-1234abcd",
        title: "Fix auth bug",
        description: "Auth is broken",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-123",
        position: 1,
        name: "coding",
        validations: [%{id: "val-123", kind: "test_pass"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "Fix auth bug"
      assert prompt =~ "Plan approved"
      assert prompt =~ "validation_pass"
      assert prompt =~ "report_blocker"
      assert prompt =~ "Git Workflow (CRITICAL)"
      assert prompt =~ "git worktree add ../worktrees/task"
      assert prompt =~ "https://github.com/test/router"
      assert prompt =~ "Do NOT open a PR yet"
      assert prompt =~ "PR opening happens in the deploy phase"
      assert prompt =~ "Current stage_id: `stage-123`"
      assert prompt =~ "validation_id=`val-123`"
      assert prompt =~ "task_id=task-1234abcd"
    end

    test "in_progress omits git workflow for placeholder repos and still includes completion contract" do
      task = %{
        id: "task-local-proof",
        title: "Proof task",
        description: "Use the local proof stack",
        status: "in_progress",
        priority: "medium",
        project: %{
          repo_url: "https://example.invalid/local-task-lifecycle-proof",
          default_branch: "main"
        }
      }

      plan = %{version: 1, stages: [%{}]}
      stage = %{id: "stage-local", position: 1, name: "proof", validations: []}

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "Git Workflow (CRITICAL)"
      refute prompt =~ "example.invalid"
      assert prompt =~ "Current stage_id: `stage-local`"
      assert prompt =~ "This stage has no validations"
      assert prompt =~ "stage_complete"
      assert prompt =~ "report_blocker"
    end

    test "in_review generates experiential review prompt" do
      task = %{
        id: "task-review-1",
        title: "Review task",
        description: "Check it",
        status: "in_review",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-review-1",
        position: 1,
        name: "review",
        validations: [
          %{id: "val-pass-1", kind: "test_pass"},
          %{id: "val-manual-1", kind: "manual_approval"}
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # Experiential review focus
      assert prompt =~ "Review task"
      assert prompt =~ "exercise and validate the implementation"
      assert prompt =~ "experiential review"
      assert prompt =~ "screenshots"
      assert prompt =~ "local dev server"

      # Review tools
      assert prompt =~ "suite_validation_evaluate"
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "manual_approval"
      assert prompt =~ "Do NOT self-approve `manual_approval` validations"

      # Validation contract
      assert prompt =~ "Current task_id: `task-review-1`"
      assert prompt =~ "Current stage_id: `stage-review-1`"
      assert prompt =~ "validation_id=`val-pass-1`"
      assert prompt =~ "validation_id=`val-manual-1`"

      # Lifecycle rules
      assert prompt =~ "Do NOT call `task_update` for lifecycle status changes"
      assert prompt =~ "fail the relevant validation"
      assert prompt =~ "in_progress"

      # No deploy concerns
      refute prompt =~ "Open a PR"
      refute prompt =~ "open a PR"
      refute prompt =~ "CI status"
      refute prompt =~ "branch freshness"
      refute prompt =~ "merge conflict"

      # No mechanical re-checks
      refute prompt =~ "tests passed"
      refute prompt =~ "lint clean"
    end

    test "in_review does not include repo-specific git checks" do
      task = %{
        id: "task-review-local",
        title: "Proof review task",
        description: "Check the local proof",
        status: "in_review",
        priority: "medium",
        project: %{
          repo_url: "https://example.invalid/local-task-lifecycle-proof",
          default_branch: "main"
        }
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-review-local",
        position: 1,
        name: "review",
        validations: [%{id: "val-manual-local", kind: "manual_approval"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # No repo references — review is experiential, not git-based
      refute prompt =~ "example.invalid"
      refute prompt =~ "git merge-base"
      refute prompt =~ "gh` CLI"

      # Still has review tools and contract
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "validation_id=`val-manual-local`"
      assert prompt =~ "Current stage_id: `stage-review-local`"
    end

    test "deploying generates deploy prompt with strategy instructions" do
      task = %{
        id: "task-deploy-1",
        title: "Deploy feature",
        description: "Ship the feature",
        status: "deploying",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-1",
        position: 2,
        name: "Deploy: PR merge",
        validations: [
          %{id: "val-test-1", kind: "test_pass"},
          %{id: "val-manual-1", kind: "manual_approval"}
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "Deploy feature"
      assert prompt =~ "deploying"
      assert prompt =~ "pr_merge"
      assert prompt =~ "validation_pass"
      assert prompt =~ "report_blocker"

      # Deploy contract with phase-appropriate validation instructions
      assert prompt =~ "Deploy Stage Contract"
      assert prompt =~ "Current stage_id: `stage-deploy-1`"
      assert prompt =~ "validation_id=`val-test-1`"
      assert prompt =~ "validation_id=`val-manual-1`"
      # manual_approval gets review_request instruction, not validation_pass
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "human must merge"
      # blocker instruction specific to deploy
      assert prompt =~ "do NOT attempt code fixes"

      # Deploy boundaries — no code modification, no local test re-runs
      assert prompt =~ "Do NOT modify code"
      assert prompt =~ "Do NOT re-run tests or lint locally"
      assert prompt =~ "branch is already pushed from execution"
    end

    test "deploying uses manual fallback when no strategy set" do
      task = %{
        id: "task-deploy-2",
        title: "Deploy task",
        description: "Ship it",
        status: "deploying",
        priority: "medium",
        deploy_strategy: nil,
        project: %{repo_url: "", default_branch: "main", deploy_config: %{}}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-deploy-2",
        position: 1,
        name: "Deploy: Manual",
        validations: [%{id: "val-manual-2", kind: "manual_approval"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "manual"
      assert prompt =~ "Deploy task"
    end

    test "fallback generates generic assignment prompt" do
      task = %{
        title: "Fix auth bug",
        description: "Auth is broken",
        status: "ready",
        priority: "high"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert prompt =~ "Fix auth bug"
      assert prompt =~ "Auth is broken"
      assert prompt =~ "ready"
      assert prompt =~ "high"
      assert prompt =~ "assigned"
    end

    test "includes plan and stage info when present" do
      task = %{title: "Task", description: "Desc", status: "in_progress", priority: "medium"}
      plan = %{version: 2, stages: [%{}, %{}, %{}]}
      stage = %{position: 2, name: "coding"}

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "v2"
      assert prompt =~ "stage 2/3"
      assert prompt =~ "coding"
    end
  end

  describe "heartbeat_prompt/4" do
    test "generates heartbeat prompt with elapsed time and pending validations" do
      task = %{title: "Fix auth"}
      stage = %{name: "coding", status: "running"}
      validations = [%{kind: "test_pass"}, %{kind: "lint_pass"}]

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 2520, validations)

      assert prompt =~ "Fix auth"
      assert prompt =~ "coding"
      assert prompt =~ "42 minutes"
      assert prompt =~ "test_pass, lint_pass"
      assert prompt =~ "validation evidence"
    end

    test "handles zero pending validations" do
      task = %{id: "task-1", title: "Task"}
      stage = %{id: "stage-1", name: "review", status: "running"}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 60, [])

      assert prompt =~ "none"
      assert prompt =~ "Current stage_id: `stage-1`"
      assert prompt =~ "stage_complete"
    end

    test "formats hours correctly" do
      task = %{title: "Task"}
      stage = %{name: "coding", status: "running"}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 3660, [])

      assert prompt =~ "1h 1m"
    end
  end

  describe "heartbeat_prompt/5 plan-aware behavior" do
    test "returns plan-aware prompt when task is in planning with pending_review plan" do
      task = %{title: "Plan Task", status: "planning"}
      plan = %{status: "pending_review", version: 1}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 60, [], plan)

      assert prompt =~ "submitted"
      assert prompt =~ "awaiting human review"
      assert prompt =~ "do not create another plan"
      refute prompt =~ "validation evidence"
    end

    test "returns plan-aware prompt when task is in planning with draft plan" do
      task = %{title: "Draft Task", status: "planning"}
      plan = %{status: "draft", version: 1}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 60, [], plan)

      assert prompt =~ "draft"
      assert prompt =~ "Continue working"
      assert prompt =~ "plan_submit"
      refute prompt =~ "do not create another plan"
    end

    test "returns plan-aware prompt when task is in planning with rejected plan" do
      task = %{title: "Rejected Task", status: "planning"}
      plan = %{status: "rejected", version: 1}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 60, [], plan)

      assert prompt =~ "rejected"
      assert prompt =~ "revised plan"
      assert prompt =~ "plan_create"
    end

    test "returns standard heartbeat prompt when plan is nil" do
      task = %{title: "Standard Task"}
      stage = %{name: "coding", status: "running"}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 120, [], nil)

      assert prompt =~ "Standard Task"
      assert prompt =~ "coding"
      assert prompt =~ "2 minutes"
      assert prompt =~ "validation evidence"
    end

    test "returns standard heartbeat prompt when task is not in planning even with plan" do
      task = %{title: "In Progress Task", status: "in_progress"}
      stage = %{name: "coding", status: "running"}
      plan = %{status: "approved", version: 1}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 300, [], plan)

      assert prompt =~ "In Progress Task"
      assert prompt =~ "coding"
      assert prompt =~ "5 minutes"
      # Should be the standard prompt, not plan-aware
      assert prompt =~ "validation evidence"
      refute prompt =~ "do not create another plan"
    end
  end

  describe "heartbeat_prompt/5 nil-stage handling" do
    test "directs agent to start first pending stage when no stage is running" do
      task = %{title: "My Task", status: "in_progress"}

      plan = %{
        status: "approved",
        version: 1,
        stages: [
          %{id: "stage-pending-1", name: "Implement Feature", status: "pending"},
          %{id: "stage-pending-2", name: "Run Tests", status: "pending"}
        ]
      }

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 0, [], plan)

      assert prompt =~ "suite_stage_start"
      assert prompt =~ "stage-pending-1"
      assert prompt =~ "Implement Feature"
      assert prompt =~ "stage-pending-2"
      refute prompt =~ "unknown"
    end

    test "tells agent all stages complete when every stage is done" do
      task = %{title: "Done Task", status: "in_progress"}

      plan = %{
        status: "approved",
        version: 1,
        stages: [
          %{id: "s1", name: "Stage A", status: "passed"},
          %{id: "s2", name: "Stage B", status: "passed"}
        ]
      }

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 0, [], plan)

      assert prompt =~ "all plan stages are complete"
      assert prompt =~ "Done Task"
      refute prompt =~ "unknown"
    end

    test "tells agent to create a plan when plan is nil and task is not in planning" do
      task = %{title: "No Plan Task", status: "in_progress"}

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 0, [], nil)

      assert prompt =~ "plan_create"
      refute prompt =~ "unknown"
    end

    test "handles mixed stage statuses — only counts truly pending stages" do
      task = %{title: "Mixed Task", status: "in_progress"}

      plan = %{
        status: "approved",
        version: 1,
        stages: [
          %{id: "s1", name: "Done Stage", status: "passed"},
          %{id: "s2", name: "Next Stage", status: "pending"}
        ]
      }

      prompt = HeartbeatScheduler.heartbeat_prompt(task, nil, 0, [], plan)

      assert prompt =~ "s2"
      assert prompt =~ "Next Stage"
      assert prompt =~ "suite_stage_start"
    end

    test "running stage found by task_router still produces normal heartbeat" do
      task = %{title: "Running Task", status: "in_progress"}
      # When task_router falls back via current_running_stage, it passes the stage in.
      # Heartbeat scheduler should emit the normal prompt — not the nil-stage one.
      stage = %{id: "s1", name: "Implement Fix", status: "running"}

      plan = %{
        status: "approved",
        version: 1,
        stages: [%{id: "s1", name: "Implement Fix", status: "running"}]
      }

      prompt = HeartbeatScheduler.heartbeat_prompt(task, stage, 120, [], plan)

      assert prompt =~ "Implement Fix"
      assert prompt =~ "2 minutes"
      refute prompt =~ "suite_stage_start"
      refute prompt =~ "unknown"
    end
  end
end
