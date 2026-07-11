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

  describe "heartbeat_suppressible?/2" do
    # Stage 1 of task 019e00cb: pure 2-arity predicate. The suppression policy
    # is deliberately conservative — we only suppress when EVERY pending
    # validation is a manual_approval AND every manual_approval has at least
    # one matching open review_request in the supplied list. Any other shape
    # falls back to false so the regular heartbeat / advance path runs.

    test "returns true when every pending manual_approval has a linked review_request" do
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "pending"},
          %{id: "val-mp-2", kind: "manual_approval", status: "pending"}
        ]
      }

      review_requests = [
        %{id: "rr-1", validation_id: "val-mp-1", status: "pending"},
        %{id: "rr-2", validation_id: "val-mp-2", status: "pending"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == true
    end

    test "returns true for a single pending manual_approval with one matching review_request" do
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "pending"}
        ]
      }

      review_requests = [
        %{id: "rr-1", validation_id: "val-mp-1", status: "pending"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == true
    end

    test "returns false when pending validations include a non-manual_approval kind" do
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "pending"},
          %{id: "val-tp-1", kind: "test_pass", status: "pending"}
        ]
      }

      review_requests = [
        %{id: "rr-1", validation_id: "val-mp-1", status: "pending"}
      ]

      # Mixed kinds = agent still has work to do — do not suppress.
      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == false
    end

    test "returns false when a pending manual_approval has no review_request in the list" do
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "pending"}
        ]
      }

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, []) == false
    end

    test "returns false when the supplied review_request points at a different validation" do
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "pending"}
        ]
      }

      # rr exists, but its validation_id doesn't match the pending validation —
      # broken/missing linkage. Guardrail: keep emitting heartbeats for
      # visibility rather than silently stalling.
      review_requests = [
        %{id: "rr-1", validation_id: "val-other", status: "pending"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == false
    end

    test "returns false when the stage has no pending validations" do
      # All validations are passed/failed/etc — the regular advance path
      # handles this. This predicate returns false so the caller's existing
      # logic runs unchanged (this is NOT a suppression case).
      stage = %{
        id: "stage-1",
        validations: [
          %{id: "val-mp-1", kind: "manual_approval", status: "passed"},
          %{id: "val-tp-1", kind: "test_pass", status: "passed"}
        ]
      }

      review_requests = [
        %{id: "rr-1", validation_id: "val-mp-1", status: "resolved"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == false
    end

    test "returns false defensively for a stage with no validations at all" do
      stage = %{id: "stage-empty", validations: []}
      assert HeartbeatScheduler.heartbeat_suppressible?(stage, []) == false
    end

    test "only the supplied stage's validations matter — sibling-stage validations don't leak" do
      # Stage A is what we're checking — it has a single pending manual_approval
      # with a matching review request, so suppression is true regardless of
      # what's happening on stage B (a sibling whose validations are NOT in
      # the supplied stage map).
      stage_a = %{
        id: "stage-a",
        validations: [
          %{id: "val-a-mp", kind: "manual_approval", status: "pending"}
        ]
      }

      # Sibling-stage data the caller did NOT pass into the predicate. The
      # predicate must not consult anything outside `stage` and
      # `pending_review_requests`. We assert that by constructing a mismatched
      # sibling stage and never handing it to the function.
      _stage_b = %{
        id: "stage-b",
        validations: [
          %{id: "val-b-tp", kind: "test_pass", status: "pending"}
        ]
      }

      # The review request list is task-scoped — it can include rrs for other
      # stages' validations. The predicate must ignore those when matching.
      review_requests = [
        %{id: "rr-a", validation_id: "val-a-mp", status: "pending"},
        %{id: "rr-b-noise", validation_id: "val-b-mp-not-in-stage-a", status: "pending"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage_a, review_requests) == true
    end

    test "accepts string-keyed maps for both stage and review_requests" do
      # Defensive shape compatibility — the rest of this module accepts both
      # atom-keyed structs and string-keyed maps via Map.get fallbacks. The
      # predicate must not crash on either.
      stage = %{
        "id" => "stage-1",
        "validations" => [
          %{"id" => "val-mp-1", "kind" => "manual_approval", "status" => "pending"}
        ]
      }

      review_requests = [
        %{"id" => "rr-1", "validation_id" => "val-mp-1", "status" => "pending"}
      ]

      assert HeartbeatScheduler.heartbeat_suppressible?(stage, review_requests) == true
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
      assert prompt =~ "Push the branch when implementation stages are complete"
      assert prompt =~ "do NOT open a PR"
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

      # Role-separation: planner must NOT author a deploy stage. The system
      # auto-injects it from the resolved deploy strategy when the task
      # transitions to `deploying` (see PlanEngine.maybe_inject_deploy_or_complete/2).
      assert prompt =~ "system auto-injects"
      assert prompt =~ "Deployer"
      assert prompt =~ "Stage scope"
      assert prompt =~ "Do NOT include a stage like"

      # The forbid-list names the deploy-authoring phrases the planner MUST
      # NOT emit; each appears ONCE inside that forbid sentence and nowhere
      # else in the prompt body.
      for phrase <- ["Deploy via PR merge", "Open PR", "Watch CI"] do
        occurrences = prompt |> String.split(phrase) |> length() |> Kernel.-(1)

        assert occurrences == 1,
               "expected #{inspect(phrase)} to appear exactly once (inside the forbid list); got #{occurrences}"
      end
    end

    test "planning dispatch surfaces previous_rejection_reason as a bounded section when set" do
      # Task 019dfad1 stage 3 — reopen-with-feedback: when the planner is
      # re-dispatched, the prompt must include "## Previous attempt — what
      # didn't work" with the verbatim rejection reason and a "Design v2 to
      # address that" instruction. Reason flows in via opts (assembled by
      # ContextAssembler.find_latest_rejected_reason/1 + plumbed through
      # task_router.do_dispatch/2).
      task = %{
        title: "Reopened task",
        description: "Was rejected once already",
        status: "planning",
        priority: "medium"
      }

      reason = "scope creep — split into two tasks"

      prompt =
        HeartbeatScheduler.dispatch_prompt(task, nil, nil, previous_rejection_reason: reason)

      assert prompt =~ "## Previous attempt — what didn't work"
      assert prompt =~ reason
      assert prompt =~ "Design v2 to address that"
    end

    test "planning dispatch omits the previous-attempt section when reason is nil or empty" do
      task = %{
        title: "Fresh planning task",
        description: "No prior rejection",
        status: "planning",
        priority: "medium"
      }

      for opts <- [[], [previous_rejection_reason: nil], [previous_rejection_reason: ""]] do
        prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil, opts)
        refute prompt =~ "## Previous attempt — what didn't work"
        refute prompt =~ "Design v2 to address that"
      end
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

      # CDP evidence-capture path is the canonical visual-evidence channel.
      assert prompt =~ "127.0.0.1:9222"
      assert prompt =~ "cdp_capture.sh"
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

  describe "skill-discovery step in hardcoded fallback dispatch prompts" do
    # These exercise the no-DB fallback path: with no prompt_templates rows
    # seeded, `dispatch_prompt/*` renders the `@skills_reference`-backed
    # `hardcoded_dispatch_*` strings. Stage 1 of task 019e280d added the
    # explicit skill-discovery step to `@skills_reference`, so it must appear
    # in every fallback variant.

    test "planning fallback names skill_list and skill_get" do
      task = %{
        title: "Wire up the task stack panel",
        description: "Add a panel",
        status: "planning",
        priority: "medium"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert prompt =~ "skill_list"
      assert prompt =~ "skill_get"
      assert prompt =~ "Skill discovery"
      assert prompt =~ "Derive this task's domain"
    end

    test "in_progress fallback names skill_list and skill_get" do
      task = %{
        id: "task-skill-ip",
        title: "Implement canvas kind",
        description: "Add a canvas kind",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}
      stage = %{id: "stage-skill-ip", position: 1, name: "coding", validations: []}

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "skill_list"
      assert prompt =~ "skill_get"
      assert prompt =~ "Skill discovery"
    end

    test "in_review fallback names skill_list and skill_get" do
      task = %{
        id: "task-skill-ir",
        title: "Review the migration",
        description: "Check it",
        status: "in_review",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-skill-ir",
        position: 1,
        name: "review",
        validations: [%{id: "val-skill-manual", kind: "manual_approval", status: "pending"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "skill_list"
      assert prompt =~ "skill_get"
    end

    test "generic fallback names skill_list and skill_get" do
      task = %{
        title: "Some backlog task",
        description: "Do the thing",
        status: "backlog",
        priority: "low"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      assert prompt =~ "skill_list"
      assert prompt =~ "skill_get"
    end

    test "fallback discovery is phrased as active tool calls, not a skills-key read" do
      # Regression guard mirroring the prompt_templates_test guard — the
      # hardcoded fallback must stay in sync and must not revert to passive
      # 'check the skills key' phrasing.
      task = %{
        title: "Regression guard task",
        description: "Guard the phrasing",
        status: "planning",
        priority: "medium"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      refute prompt =~ "check the `skills` key"
      refute prompt =~ "check the skills key"
      refute prompt =~ "read the attached skills object"
      assert prompt =~ "calling `skill_list` / `skill_get` yourself"
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
          # :position required by sort_by in nil_stage_heartbeat_prompt (added by #437)
          %{id: "stage-pending-1", name: "Implement Feature", status: "pending", position: 1},
          %{id: "stage-pending-2", name: "Run Tests", status: "pending", position: 2}
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
          %{id: "s1", name: "Stage A", status: "passed", position: 1},
          %{id: "s2", name: "Stage B", status: "passed", position: 2}
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
          %{id: "s1", name: "Done Stage", status: "passed", position: 1},
          %{id: "s2", name: "Next Stage", status: "pending", position: 2}
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

  describe "stack_membership/1" do
    test "returns nil for a task with no stack_id" do
      assert HeartbeatScheduler.stack_membership(%{id: "019e2790-f954-7032-8578-bb4569d889c0"}) ==
               nil
    end

    test "returns nil when stack_id is nil" do
      task = %{id: "t1", stack_id: nil, stack: nil}
      assert HeartbeatScheduler.stack_membership(task) == nil
    end

    test "returns nil when stack_id is blank or whitespace" do
      assert HeartbeatScheduler.stack_membership(%{id: "t1", stack_id: ""}) == nil
      assert HeartbeatScheduler.stack_membership(%{id: "t1", stack_id: "   "}) == nil
    end

    test "ignores a stale stack_id key inside metadata — only the column counts" do
      # The earlier (no-op) implementation read membership off `task.metadata`.
      # A metadata key alone, with a nil `stack_id` column, is NOT a stack member.
      task = %{
        id: "t1",
        stack_id: nil,
        metadata: %{"stack_id" => "019e2782-09d6-7e2c-9502-c106290e5add"}
      }

      assert HeartbeatScheduler.stack_membership(task) == nil
    end

    test "returns a populated map for a real stack member (stack_id column + preloaded stack)" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{
          id: "019e2782-09d6-7e2c-9502-c106290e5add",
          slug: "meeting-module",
          rollup_branch: "stack/meeting-module"
        }
      }

      assert HeartbeatScheduler.stack_membership(task) == %{
               stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
               stack_slug: "meeting-module",
               rollup_branch: "stack/meeting-module",
               stack_metadata: %{}
             }
    end

    test "derives rollup_branch from the stack slug when the stack row has none" do
      task = %{
        id: "t1",
        stack_id: "019e3000-0000-7000-8000-000000000001",
        stack: %{
          id: "019e3000-0000-7000-8000-000000000001",
          slug: "solo-stack",
          rollup_branch: nil
        }
      }

      assert HeartbeatScheduler.stack_membership(task) == %{
               stack_id: "019e3000-0000-7000-8000-000000000001",
               stack_slug: "solo-stack",
               rollup_branch: "stack/solo-stack",
               stack_metadata: %{}
             }
    end

    test "surfaces stack.metadata (including rollup_branch_ready stamp) on the membership map" do
      # ADR-0042 Decision 2: the git_workflow_section reads
      # `stack.metadata["rollup_branch_ready"]` to decide whether to cut member
      # branches from `origin/<rollup_branch>` or fall back to
      # `origin/<default_branch>`. `stack_membership/1` is the pass-through.
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{
          id: "019e2782-09d6-7e2c-9502-c106290e5add",
          slug: "meeting-module",
          rollup_branch: "stack/meeting-module",
          metadata: %{
            "rollup_branch_ready" => %{
              "at" => "2026-07-10T21:00:00Z",
              "base_sha" => "abc1234"
            }
          }
        }
      }

      assert %{stack_metadata: %{"rollup_branch_ready" => %{"base_sha" => "abc1234"}}} =
               HeartbeatScheduler.stack_membership(task)
    end

    test "still flags a stack member when the :stack association is not loaded" do
      # `stack_id` alone is authoritative for membership; an unloaded assoc just
      # means no slug/rollup_branch is available.
      task = %{
        id: "t1",
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %Ecto.Association.NotLoaded{
          __field__: :stack,
          __owner__: Platform.Tasks.Task,
          __cardinality__: :one
        }
      }

      assert HeartbeatScheduler.stack_membership(task) == %{
               stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
               stack_slug: nil,
               rollup_branch: nil,
               stack_metadata: %{}
             }
    end
  end

  describe "full_task_id/1" do
    test "returns the complete UUID, not the 8-char prefix" do
      task = %{id: "019e2474-11c1-7000-8000-000000000001"}
      assert HeartbeatScheduler.full_task_id(task) == "019e2474-11c1-7000-8000-000000000001"
    end

    test "falls back to \"task\" when no id is present" do
      assert HeartbeatScheduler.full_task_id(%{}) == "task"
    end
  end

  describe "member_slug/1" do
    test "returns the full UUID for a stack member" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{id: "019e2782-09d6-7e2c-9502-c106290e5add", slug: "meeting-module"}
      }

      assert HeartbeatScheduler.member_slug(task) == "019e2474-11c1-7000-8000-000000000001"
    end

    test "returns the short 8-char prefix for a non-stack task" do
      task = %{id: "019e2474-11c1-7000-8000-000000000001", stack_id: nil}
      assert HeartbeatScheduler.member_slug(task) == "019e2474"
    end
  end

  describe "git_workflow_section via in_progress dispatch — stack members" do
    setup do
      {plan, stage} = simple_plan_with_stage()
      {:ok, plan: plan, stage: stage}
    end

    # A `task_stacks` row as the orchestrator preloads it onto `task.stack`.
    # No `rollup_branch_ready` metadata stamp — mimics the pre-ADR-0042 default
    # where a member dispatches before StackDeployer's async ensure lands. The
    # dispatch prompt falls back to `origin/<default_branch>` in that state.
    defp meeting_module_stack do
      %{
        id: "019e2782-09d6-7e2c-9502-c106290e5add",
        slug: "meeting-module",
        rollup_branch: "stack/meeting-module",
        metadata: %{}
      }
    end

    # Same stack but with the `rollup_branch_ready` stamp set — meaning
    # `StackDeployer.do_create_rollup_branch/2` completed and the member is safe
    # to branch from `origin/#{rollup_branch}`. This is the ADR-0042 Decision 2
    # default state.
    defp meeting_module_stack_ready do
      %{
        meeting_module_stack()
        | metadata: %{
            "rollup_branch_ready" => %{
              "at" => "2026-07-10T21:00:00Z",
              "base_sha" => "abc1234"
            }
          }
      }
    end

    test "stack-member dispatch uses the FULL task UUID for worktree path and branch", %{
      plan: plan,
      stage: stage
    } do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member task",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: meeting_module_stack()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "Git Workflow (CRITICAL)"

      assert prompt =~
               "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001 origin/main"

      assert prompt =~ "cd ../worktrees/019e2474-11c1-7000-8000-000000000001"
      assert prompt =~ "git push -u origin task/019e2474-11c1-7000-8000-000000000001"
      # The truncated 8-char prefix must NOT appear as a worktree/branch slug.
      refute prompt =~ "../worktrees/019e2474 "
      refute prompt =~ "-b task/019e2474 "
    end

    test "stack-member dispatch includes the Task Stack Membership block", %{
      plan: plan,
      stage: stage
    } do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member task",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: meeting_module_stack()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Task Stack Membership"
      assert prompt =~ "This task is a stack member"
      assert prompt =~ "stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`"
      assert prompt =~ "Rollup branch: `stack/meeting-module`"
      # Independent-branching instruction per the task contract.
      assert prompt =~ "INDEPENDENTLY"
      assert prompt =~ "Do NOT depend on a sibling member's unpushed work"
    end

    test "rollup branch is derived from stack_slug when not explicitly stored", %{
      plan: plan,
      stage: stage
    } do
      task = %{
        id: "019e3000-0000-7000-8000-000000000001",
        title: "Solo stack member",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e3000-0000-7000-8000-0000000000ff",
        stack: %{
          id: "019e3000-0000-7000-8000-0000000000ff",
          slug: "solo-stack",
          rollup_branch: nil
        }
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Task Stack Membership"
      assert prompt =~ "Rollup branch: `stack/solo-stack`"
    end

    test "two stack members with a shared id prefix get DISTINCT worktree paths", %{
      plan: plan,
      stage: stage
    } do
      stack = meeting_module_stack()
      stack_id = stack.id

      task_f = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Member F",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: stack_id,
        stack: stack
      }

      task_g = %{
        id: "019e2474-609d-7000-8000-000000000002",
        title: "Member G",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: stack_id,
        stack: stack
      }

      prompt_f = HeartbeatScheduler.dispatch_prompt(task_f, plan, stage)
      prompt_g = HeartbeatScheduler.dispatch_prompt(task_g, plan, stage)

      assert prompt_f =~ "../worktrees/019e2474-11c1-7000-8000-000000000001"
      assert prompt_g =~ "../worktrees/019e2474-609d-7000-8000-000000000002"
      refute prompt_f =~ "019e2474-609d-7000-8000-000000000002"
      refute prompt_g =~ "019e2474-11c1-7000-8000-000000000001"
    end

    test "non-stack task dispatch has NO Task Stack Membership block and uses the 8-char slug", %{
      plan: plan,
      stage: stage
    } do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000003",
        title: "Ordinary task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "Task Stack Membership"
      assert prompt =~ "git worktree add ../worktrees/019e2474 -b task/019e2474 origin/main"
      assert prompt =~ "git push -u origin task/019e2474"
    end

    test "placeholder-repo stack member strips the whole Git Workflow + Stack Membership block",
         %{plan: plan, stage: stage} do
      # maybe_strip_git_workflow/2 must still match the new block shape — for a
      # stack member the regex has to consume the trailing Task Stack Membership
      # sub-block too, not leave it dangling.
      task = %{
        id: "019e2474-11c1-7000-8000-000000000004",
        title: "Placeholder stack member",
        status: "in_progress",
        priority: "medium",
        project: %{
          repo_url: "https://example.invalid/local-task-lifecycle-proof",
          default_branch: "main"
        },
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: meeting_module_stack()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "Git Workflow (CRITICAL)"
      refute prompt =~ "Task Stack Membership"
      refute prompt =~ "example.invalid"
    end

    # ─── ADR-0042 Decision 2: rollup-HEAD retargeting ─────────────────────
    #
    # These three tests cover the branch-parent decision surface introduced by
    # `stack.metadata["rollup_branch_ready"]`. With the stamp present, member
    # branches cut FROM the rollup HEAD so a member sees prior siblings' merged
    # work. Without the stamp (rollup push not yet landed on origin), we fall
    # back to `origin/<default_branch>` and log a warning so the race is
    # auditable — never dispatch a `git worktree add ... origin/stack/foo`
    # against a non-existent remote ref.

    test "stack member WITH rollup_branch_ready stamp branches from origin/<rollup_branch>", %{
      plan: plan,
      stage: stage
    } do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member — ready",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: meeting_module_stack_ready()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # The critical retargeting: member sees rollup HEAD, not raw main.
      assert prompt =~
               "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001 origin/stack/meeting-module"

      assert prompt =~ "cd ../worktrees/019e2474-11c1-7000-8000-000000000001"
      # Prose confirms the flip: member is cut FROM the rollup, sees siblings.
      assert prompt =~ "cut from `origin/stack/meeting-module`"
      assert prompt =~ "you see previously-merged sibling members"
      # Fast-forward, not per-member PR.
      assert prompt =~ "fast-forward on validation pass"
      # The old ADR-0041 "INDEPENDENTLY" wording MUST NOT leak into the ready
      # path — that would contradict the retargeting.
      refute prompt =~ "INDEPENDENTLY"

      # `Base branch:` (an audit hint) still lists the project default so a
      # human reader can spot the retargeting.
      assert prompt =~ "Base branch: main"
    end

    test "stack member WITHOUT rollup_branch_ready stamp falls back to origin/<default_branch>",
         %{plan: plan, stage: stage} do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member — fallback",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        # No metadata stamp → rollup push hasn't landed yet.
        stack: meeting_module_stack()
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

          # Legacy branch shape — no risk of `origin/stack/…` no-such-ref.
          assert prompt =~
                   "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001 origin/main"

          assert prompt =~ "cut from `origin/main`"
          assert prompt =~ "INDEPENDENTLY"
          # The Task Stack Membership block still names the rollup branch — the
          # rollup exists at the schema level even if not yet pushed.
          assert prompt =~ "Rollup branch: `stack/meeting-module`"
          refute prompt =~ "origin/stack/meeting-module"
        end)

      # The race is auditable — the fallback fires a warning naming the stack
      # and member so ops can spot repeat offenders.
      assert log =~ "rollup not yet ready"
      assert log =~ "019e2782-09d6-7e2c-9502-c106290e5add"
      assert log =~ "019e2474-11c1-7000-8000-000000000001"
    end

    test "non-stack task dispatch is unchanged by the rollup-HEAD retargeting", %{
      plan: plan,
      stage: stage
    } do
      # Regression guard: only stack members participate in the retargeting.
      task = %{
        id: "019e2474-11c1-7000-8000-000000000009",
        title: "Ordinary task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # 8-char slug, main-branched, no stack block, no rollup ref anywhere.
      assert prompt =~ "git worktree add ../worktrees/019e2474 -b task/019e2474 origin/main"
      refute prompt =~ "Task Stack Membership"
      refute prompt =~ "origin/stack/"
      refute prompt =~ "rollup_branch_ready"
    end
  end

  describe "stack-aware slug propagation — deploying + review dispatch surfaces" do
    test "deploying dispatch for a stack member references the full-UUID branch" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member deploy",
        description: "Ship it",
        status: "deploying",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{
          id: "019e2782-09d6-7e2c-9502-c106290e5add",
          slug: "meeting-module",
          rollup_branch: "stack/meeting-module"
        }
      }

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-1",
        position: 2,
        name: "Deploy: PR merge",
        validations: [%{id: "val-pr-merged-1", kind: "pr_merged"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "task/019e2474-11c1-7000-8000-000000000001"
      # The truncated prefix must NOT be referenced as a branch.
      refute prompt =~ "pushed to `task/019e2474`"
    end

    test "deploying dispatch for a non-stack task references the 8-char branch unchanged" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000002",
        title: "Ordinary deploy",
        description: "Ship it",
        status: "deploying",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"},
        stack_id: nil
      }

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-2",
        position: 2,
        name: "Deploy: PR merge",
        validations: [%{id: "val-pr-merged-2", kind: "pr_merged"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "pushed to `task/019e2474`"
    end

    test "in_progress and deploying dispatch for the same stack member name the SAME branch" do
      base = %{
        id: "019e3000-0000-7000-8000-0000000000aa",
        title: "Lifecycle-consistent stack member",
        description: "Ship it",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"},
        stack_id: "019e3000-0000-7000-8000-0000000000bb",
        stack: %{
          id: "019e3000-0000-7000-8000-0000000000bb",
          slug: "deploy-stack",
          rollup_branch: "stack/deploy-stack"
        }
      }

      plan = %{version: 1, stages: [%{}, %{}]}
      in_progress_stage = %{id: "s1", position: 1, name: "coding", validations: []}
      deploy_stage = %{id: "s2", position: 2, name: "Deploy", validations: []}

      in_progress_prompt =
        HeartbeatScheduler.dispatch_prompt(
          Map.put(base, :status, "in_progress"),
          plan,
          in_progress_stage
        )

      deploying_prompt =
        HeartbeatScheduler.dispatch_prompt(
          Map.put(base, :status, "deploying"),
          plan,
          deploy_stage
        )

      assert in_progress_prompt =~ "task/019e3000-0000-7000-8000-0000000000aa"
      assert deploying_prompt =~ "task/019e3000-0000-7000-8000-0000000000aa"
    end

    test "e2e review assigns for a stack member carry the full-UUID slug" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        execution_space_id: "space-1",
        project: %{repo_url: "https://github.com/test/app"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{id: "019e2782-09d6-7e2c-9502-c106290e5add", slug: "meeting-module"}
      }

      pending = [%{id: "val-e2e-1", kind: "e2e_behavior", evaluation_payload: %{"setup" => "x"}}]

      {template_slug, assigns} = HeartbeatScheduler.select_review_template(pending, task)

      assert template_slug == "dispatch.review_e2e"
      assert assigns.task_slug == "019e2474-11c1-7000-8000-000000000001"
    end

    test "e2e review assigns for a non-stack task carry the 8-char slug unchanged" do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000002",
        execution_space_id: "space-2",
        project: %{repo_url: "https://github.com/test/app"},
        stack_id: nil
      }

      pending = [%{id: "val-e2e-2", kind: "e2e_behavior", evaluation_payload: %{"setup" => "y"}}]

      {_template_slug, assigns} = HeartbeatScheduler.select_review_template(pending, task)

      assert assigns.task_slug == "019e2474"
    end
  end
end
