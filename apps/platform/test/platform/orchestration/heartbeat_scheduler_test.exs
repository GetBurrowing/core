defmodule Platform.Orchestration.HeartbeatSchedulerTest do
  use ExUnit.Case, async: true

  alias Platform.Orchestration.HeartbeatScheduler

  describe "interval_ms/1" do
    test "returns correct intervals per stage type" do
      assert HeartbeatScheduler.interval_ms("planning") == 15 * 60_000
      assert HeartbeatScheduler.interval_ms("coding") == 10 * 60_000
      assert HeartbeatScheduler.interval_ms("ci_check") == 5 * 60_000
      assert HeartbeatScheduler.interval_ms("review") == 20 * 60_000
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
      assert prompt =~ "PR opening happens after successful review in `in_review`"
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

    test "in_review generates explicit validation prompt" do
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

      assert prompt =~ "Review task"
      assert prompt =~ "validate the implementation"
      assert prompt =~ "suite_validation_evaluate"
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "manual_approval"
      assert prompt =~ "Do NOT self-approve `manual_approval` validations"
      assert prompt =~ "Current task_id: `task-review-1`"
      assert prompt =~ "Current stage_id: `stage-review-1`"
      assert prompt =~ "validation_id=`val-pass-1`"
      assert prompt =~ "validation_id=`val-manual-1`"
      assert prompt =~ "Do NOT call `task_update` for lifecycle status changes"
      assert prompt =~ "Review outcomes flow through validations and review requests"
      assert prompt =~ "If review evidence shows the feature is not good enough"
      assert prompt =~ "fail the relevant validation so the task can return to `in_progress`"
      assert prompt =~ "in_progress"
      refute prompt =~ "call `task_update` to move the task to `done`"
      refute prompt =~ "call `task_update` to move the task back to `in_progress`"
    end

    test "in_review strips placeholder repo git instructions from stale template" do
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

      refute prompt =~ "example.invalid"
      refute prompt =~ "git merge-base"
      refute prompt =~ "gh` CLI"
      refute prompt =~ "call `task_update` to move the task to `done`"
      refute prompt =~ "call `task_update` to move the task back to `in_progress`"
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "validation_id=`val-manual-local`"
      assert prompt =~ "Current stage_id: `stage-review-local`"
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
end
