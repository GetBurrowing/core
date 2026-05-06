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
    test "planning without plan instructs agent to create a plan with e2e_behavior + scoped manual_approval" do
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
      assert prompt =~ "manual_approval"

      # New e2e_behavior + scoping guidance — v2 plurals: 2-5 adversarial validations,
      # no planner-supplied failure_feedback.
      assert prompt =~ "e2e_behavior"
      assert prompt =~ "evaluation_payload"
      assert prompt =~ "setup"
      assert prompt =~ "actions"
      assert prompt =~ "expected"
      refute prompt =~ "\"failure_feedback\":"
      assert prompt =~ "2-5"
      assert prompt =~ "adversarial"

      # UI-touching tokens (matches stage 2 heuristic)
      assert prompt =~ ".heex"
      assert prompt =~ "tasks_live.ex"

      # Forbids code_review and overscoping
      assert prompt =~ "code_review"
      assert prompt =~ "Forbidden"
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

      # CDP evidence-capture path is embedded via @evidence_workflow_reference.
      assert prompt =~ "127.0.0.1:9222"
      assert prompt =~ "cdp_capture.sh"
      refute prompt =~ "rock-node-screenshot"
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

    test "in_review with manual_approval pending renders the UI judgment review prompt" do
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
          %{id: "val-pass-1", kind: "test_pass", status: "passed"},
          %{id: "val-manual-1", kind: "manual_approval", status: "pending"}
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # UI judgment focus (post stage-4 split)
      assert prompt =~ "Review task"
      assert prompt =~ "manual_approval"
      assert prompt =~ "screenshots"
      assert prompt =~ "local dev server"

      # Review tools
      assert prompt =~ "suite_review_request_create"
      assert prompt =~ "Do NOT self-approve `manual_approval` validations"

      # Validation contract (enrichment)
      assert prompt =~ "Current task_id: `task-review-1`"
      assert prompt =~ "Current stage_id: `stage-review-1`"
      assert prompt =~ "validation_id=`val-manual-1`"

      # Lifecycle rules
      assert prompt =~ "Do NOT call `task_update` for lifecycle status changes"

      # No deploy concerns
      refute prompt =~ "Open a PR"
      refute prompt =~ "open a PR"
      refute prompt =~ "CI status"

      # No e2e_behavior content (that lives in dispatch.review_e2e now)
      refute prompt =~ "e2e_behavior"
      refute prompt =~ "evaluation_payload"

      # CDP evidence-capture path (rock-node-screenshot is no longer canonical
      # for the dispatch flow; visual evidence runs through hive-local CDP).
      assert prompt =~ "127.0.0.1:9222"
      assert prompt =~ "cdp_capture.sh"
      refute prompt =~ "rock-node-screenshot"
      refute prompt =~ "openclaw nodes canvas navigate"
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

    test "deploying generates deploy prompt for pr_merge with single pr_merged validation" do
      task = %{
        id: "task-deploy-1",
        title: "Deploy feature",
        description: "Ship the feature",
        status: "deploying",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-1",
        position: 2,
        name: "Deploy: PR merge",
        validations: [%{id: "val-pr-merged-1", kind: "pr_merged"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "Deploy feature"
      assert prompt =~ "deploying"
      assert prompt =~ "pr_merge"
      assert prompt =~ "report_blocker"

      # Deploy contract with the new single pr_merged validation
      assert prompt =~ "Deploy Stage Contract"
      assert prompt =~ "Current stage_id: `stage-deploy-1`"
      assert prompt =~ "validation_id=`val-pr-merged-1`"
      # pr_merged auto-passes via webhook — agent must NOT create a review
      # request and must NOT call validation_pass directly. The prompt may
      # still mention `suite_review_request_create` in a *negative* form
      # (e.g. "do NOT create a suite_review_request_create"), so assert on
      # the prohibition rather than on absence of the bare token.
      assert prompt =~ "pull_request.closed` webhook"
      assert prompt =~ "Merge the PR in GitHub"
      assert prompt =~ "Do NOT create a `suite_review_request_create`"
      # No pr_merge stage should ever surface the legacy manual_approval
      # validation since the builder no longer emits it.
      refute prompt =~ "manual_approval"

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
      # `dispatch_prompt/3` has explicit clauses for planning / in_progress
      # / in_review / deploying. Use `backlog` (no specific clause) so the
      # generic fallback at the bottom runs.
      task = %{
        title: "Fix auth bug",
        description: "Auth is broken",
        status: "backlog",
        priority: "high"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert prompt =~ "Fix auth bug"
      assert prompt =~ "Auth is broken"
      assert prompt =~ "backlog"
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

    test "in_review with pending e2e_behavior renders dispatch.review_e2e (NOT dispatch.in_review)" do
      task = %{
        id: "task-e2e-1",
        title: "Render dependency badges",
        description: "Make blocked-by chips render and update live",
        status: "in_review",
        priority: "medium",
        execution_space_id: "exec-space-99",
        project: %{repo_url: "git@github.com:acme/widgets.git", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-task-level-review",
        position: 1,
        name: "Task-level review",
        validations: [
          %{
            id: "val-e2e-1",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{
              "setup" => "create A and B",
              "actions" => "complete A, refresh B",
              "expected" => "B's badge clears within 2 seconds"
            }
          }
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # Routed to the e2e template — v2 plural form, no failure_feedback in payload
      assert prompt =~ "evaluation_payload"
      assert prompt =~ "behavioral review"
      assert prompt =~ "val-e2e-1"
      assert prompt =~ "create A and B"
      assert prompt =~ "B's badge clears within 2 seconds"
      assert prompt =~ "exec-space-99"
      refute prompt =~ "\"failure_feedback\":"

      # NOT the manual_approval prompt — its core tokens are absent.
      # (The e2e prompt does mention "do NOT create a suite_review_request_create" as a
      # forbidden action, so we don't refute that exact string; instead we check for
      # markers unique to dispatch.in_review.)
      refute prompt =~ "UI judgment"
      refute prompt =~ "Do NOT self-approve `manual_approval` validations"
    end

    test "in_review with both e2e_behavior and manual_approval pending → e2e wins" do
      task = %{
        id: "task-mixed",
        title: "Mixed review task",
        status: "in_review",
        priority: "medium",
        execution_space_id: "exec-mixed",
        project: %{repo_url: "git@github.com:acme/widgets.git", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-mixed",
        position: 1,
        name: "Task-level review",
        validations: [
          %{id: "val-manual", kind: "manual_approval", status: "pending"},
          %{
            id: "val-e2e",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{
              "setup" => "s",
              "actions" => "a",
              "expected" => "e"
            }
          }
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # E2E wins — agent-driven gate fires before human gate
      assert prompt =~ "behavioral review"
      assert prompt =~ "val-e2e"
    end
  end

  describe "select_review_template/2" do
    test "returns dispatch.in_review with empty assigns for empty pending list" do
      assert {"dispatch.in_review", %{}} = HeartbeatScheduler.select_review_template([])
    end

    test "returns dispatch.in_review for manual_approval-only pending" do
      pending = [%{id: "v1", kind: "manual_approval", status: "pending"}]
      assert {"dispatch.in_review", %{}} = HeartbeatScheduler.select_review_template(pending)
    end

    test "returns dispatch.review_e2e with all pending e2e validations rendered as JSON" do
      pending = [
        %{
          id: "val-99",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "x"}
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-1",
                 execution_space_id: "exec-1"
               })

      # v2: assigns carry a JSON array of {validation_id, evaluation_payload}
      # objects under pending_e2e_validations_json — singular validation_id /
      # evaluation_payload_json keys are gone.
      refute Map.has_key?(assigns, :validation_id)
      refute Map.has_key?(assigns, :evaluation_payload_json)
      assert is_binary(assigns.pending_e2e_validations_json)
      assert assigns.pending_e2e_validations_json =~ "val-99"
      assert assigns.pending_e2e_validations_json =~ "setup"
      assert assigns.execution_space_id == "exec-1"
    end

    test "e2e wins when both kinds are pending" do
      pending = [
        %{id: "vm", kind: "manual_approval", status: "pending"},
        %{
          id: "ve",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "x"}
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending)

      assert assigns.pending_e2e_validations_json =~ "ve"
    end

    test "returns dispatch.review_e2e with all pending e2e validations when more than one is pending" do
      # v2: the planner authors 2-5 adversarial e2e validations per task; the
      # dispatcher must hand the review agent ALL of them in one shot, not just
      # the first one Enum.find finds.
      pending = [
        %{
          id: "val-aaa",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "s-a", "actions" => "a-a", "expected" => "e-a"}
        },
        %{
          id: "val-bbb",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "s-b", "actions" => "a-b", "expected" => "e-b"}
        },
        %{
          id: "val-ccc",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "s-c", "actions" => "a-c", "expected" => "e-c"}
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-multi",
                 execution_space_id: "exec-multi"
               })

      json = assigns.pending_e2e_validations_json

      # All three validation_ids show up in the rendered JSON.
      assert json =~ "val-aaa"
      assert json =~ "val-bbb"
      assert json =~ "val-ccc"

      # Each payload's setup field is included.
      assert json =~ "s-a"
      assert json =~ "s-b"
      assert json =~ "s-c"
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

  describe "dispatch_prompt/4 — provider-aware guidance" do
    @claude_marker "For Claude Code agents (mandatory)"

    defp planning_task do
      %{
        id: "task-019df0e1",
        title: "Provider-aware dispatch prompts",
        description: "Make Claude agents spawn subagents per task",
        status: "planning",
        priority: "medium"
      }
    end

    defp in_progress_task do
      %{
        id: "task-019df0e1",
        title: "Provider-aware dispatch prompts",
        description: "Make Claude agents spawn subagents per task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }
    end

    defp in_review_task do
      %{
        id: "task-019df0e1",
        title: "Provider-aware dispatch prompts",
        description: "Make Claude agents spawn subagents per task",
        status: "in_review",
        priority: "medium"
      }
    end

    defp simple_plan_with_stage do
      stage = %{id: "stage-1", position: 1, name: "review", validations: []}
      {%{version: 1, stages: [stage]}, stage}
    end

    defp claude_runtime do
      %Platform.Agents.AgentRuntime{
        runtime_id: "rowan-claude-agent-1",
        metadata: %{"client_info" => %{"product" => "claude_channel", "version" => "0.2.0"}}
      }
    end

    defp openclaw_runtime do
      %Platform.Agents.AgentRuntime{
        runtime_id: "rowan-coder",
        metadata: %{"client_info" => %{"product" => "openclaw", "version" => "0.6.2"}}
      }
    end

    defp claude_agent do
      %Platform.Agents.Agent{slug: "dalton", model_config: %{"primary" => "claude-opus-4-7"}}
    end

    defp openclaw_agent do
      %Platform.Agents.Agent{slug: "geordi", model_config: %{"primary" => "qwen3-coder"}}
    end

    test "planning dispatch to Claude-channel runtime contains the Claude block" do
      prompt =
        HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil,
          agent: claude_agent(),
          runtime: claude_runtime()
        )

      assert prompt =~ @claude_marker
      assert prompt =~ "subagent with fresh context"
    end

    test "planning dispatch to OpenClaw runtime omits the Claude block" do
      prompt =
        HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil,
          agent: openclaw_agent(),
          runtime: openclaw_runtime()
        )

      refute prompt =~ @claude_marker
    end

    test "planning dispatch with no agent context renders cleanly (back-compat)" do
      prompt = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)

      refute prompt =~ @claude_marker
      assert prompt =~ "Provider-aware dispatch prompts"
      assert prompt =~ "plan_create"
    end

    test "planning dispatch falls back to model name when runtime metadata is empty" do
      bare_runtime = %Platform.Agents.AgentRuntime{runtime_id: "rt", metadata: %{}}

      prompt =
        HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil,
          agent: claude_agent(),
          runtime: bare_runtime
        )

      assert prompt =~ @claude_marker
    end

    test "in_progress dispatch to Claude-channel runtime contains the Claude block" do
      {plan, stage} = simple_plan_with_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan, stage,
          agent: claude_agent(),
          runtime: claude_runtime()
        )

      assert prompt =~ @claude_marker
    end

    test "in_progress dispatch to OpenClaw runtime omits the Claude block" do
      {plan, stage} = simple_plan_with_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan, stage,
          agent: openclaw_agent(),
          runtime: openclaw_runtime()
        )

      refute prompt =~ @claude_marker
    end

    test "in_progress dispatch with no agent context renders cleanly (back-compat)" do
      {plan, stage} = simple_plan_with_stage()
      prompt = HeartbeatScheduler.dispatch_prompt(in_progress_task(), plan, stage)

      refute prompt =~ @claude_marker
      assert prompt =~ "Plan approved"
    end

    test "in_review dispatch to Claude-channel runtime contains the Claude block" do
      {plan, stage} = simple_plan_with_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(in_review_task(), plan, stage,
          agent: claude_agent(),
          runtime: claude_runtime()
        )

      assert prompt =~ @claude_marker
    end

    test "in_review dispatch to OpenClaw runtime omits the Claude block" do
      {plan, stage} = simple_plan_with_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(in_review_task(), plan, stage,
          agent: openclaw_agent(),
          runtime: openclaw_runtime()
        )

      refute prompt =~ @claude_marker
    end

    test "in_review dispatch with no agent context renders cleanly (back-compat)" do
      {plan, stage} = simple_plan_with_stage()
      prompt = HeartbeatScheduler.dispatch_prompt(in_review_task(), plan, stage)

      refute prompt =~ @claude_marker
      assert prompt =~ "Task is in review"
    end

    test "deploying dispatch ignores provider context (no Claude block)" do
      # The deploying clause exists but is intentionally not provider-aware in
      # this iteration — deploy work is mostly tooling, not agent reasoning.
      task = %{
        id: "task-019df0e1",
        title: "Provider-aware dispatch prompts",
        description: "...",
        status: "deploying",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      {plan, stage} = simple_plan_with_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(task, plan, stage,
          agent: claude_agent(),
          runtime: claude_runtime()
        )

      refute prompt =~ @claude_marker
    end
  end
end
