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

  describe "subagent_id placeholder in hardcoded fallback dispatch prompts (task 019f6c73 stage 3)" do
    # Stage 3 extended the hardcoded @task_ack_preamble_template with a
    # __SUBAGENT_ID__ sentinel + spawn-first instruction. The private
    # render_task_ack_preamble/2,3 defaults the sentinel to a readable
    # "<unknown — spawn a subagent first>" fallback so every dispatch
    # slug renders it even before the orchestrator learns a real
    # subagent handle. These guards ensure no fallback branch silently
    # drops the placeholder.

    test "planning fallback carries NO ack call at all (task 019fa469 stage 5)" do
      # Inverted from an assert-the-ack-is-present test. That test was green
      # against a broken behaviour: the planning fallback rendered
      # `task_ack(task_id="...", stage_id="", subagent_id="<unknown — spawn a
      # subagent first>")`, which `ToolSurface.resolve_ack_stage_id/2` rejects
      # with `:no_running_stage` because a planning dispatch has no plan and so
      # no running stage. Nothing was armed for it to satisfy either —
      # `TaskRouter.arm_liveness_timers/3` no-ops on a nil stage.
      task = %{
        id: "task-subagent-planning",
        title: "Ack preamble subagent_id planning",
        description: "Body",
        status: "planning",
        priority: "medium"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      # Positive pin — without it every refute below passes on an empty or
      # errored render.
      assert prompt =~ "You have been assigned a task that requires a plan",
             "the planning fallback body must actually have rendered"

      assert prompt =~ "No ack is expected for this dispatch",
             "the planning fallback must say so explicitly rather than stay silent"

      refute prompt =~ "task_ack(",
             "planning fallback must not render an ack call it cannot satisfy"

      refute prompt =~ "<unknown — spawn a subagent first>",
             "the subagent_id sentinel belongs to the ack call, which is gone"

      refute prompt =~ "no-ack alert in 5 minutes",
             "no no-ack timer is armed for a stage-less dispatch"
    end

    test "in_progress fallback carries subagent_id placeholder + spawn-first ordering" do
      task = %{
        id: "task-subagent-ip",
        title: "Ack preamble subagent_id in_progress",
        description: "Body",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}
      stage = %{id: "stage-subagent-ip", position: 1, name: "coding", validations: []}

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "subagent_id=",
             "in_progress fallback must render subagent_id= in the ack call"

      assert prompt =~ "<unknown — spawn a subagent first>",
             "in_progress fallback must render the readable subagent_id sentinel default"

      assert prompt =~ "Spawn the subagent FIRST",
             "in_progress fallback must instruct spawn-first ordering"
    end

    test "in_review fallback carries subagent_id placeholder + spawn-first ordering" do
      task = %{
        id: "task-subagent-ir",
        title: "Ack preamble subagent_id in_review",
        description: "Body",
        status: "in_review",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-subagent-ir",
        position: 1,
        name: "review",
        validations: [%{id: "val-subagent-manual", kind: "manual_approval", status: "pending"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "subagent_id=",
             "in_review fallback must render subagent_id= in the ack call"

      assert prompt =~ "<unknown — spawn a subagent first>",
             "in_review fallback must render the readable subagent_id sentinel default"

      assert prompt =~ "Spawn the subagent FIRST",
             "in_review fallback must instruct spawn-first ordering"
    end

    test "deploying fallback carries subagent_id placeholder + spawn-first ordering" do
      task = %{
        id: "task-subagent-dep",
        title: "Ack preamble subagent_id deploying",
        description: "Body",
        status: "deploying",
        priority: "medium",
        project: %{
          repo_url: "https://github.com/test/router",
          default_branch: "main",
          deploy_strategy: %{"type" => "manual", "config" => %{}}
        }
      }

      plan = %{version: 1, stages: [%{}]}
      stage = %{id: "stage-subagent-dep", position: 1, name: "deploy", validations: []}

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "subagent_id=",
             "deploying fallback must render subagent_id= in the ack call"

      assert prompt =~ "<unknown — spawn a subagent first>",
             "deploying fallback must render the readable subagent_id sentinel default"

      assert prompt =~ "Spawn the subagent FIRST",
             "deploying fallback must instruct spawn-first ordering"
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

  describe "nudge_prompt/2 (task 019f640d stage 4 — short-form nudge)" do
    # Payload discipline: the nudge is the router's SAFETY-NET / NO-ACK re-poke
    # and must NOT carry the fat first-dispatch context (skills_reference,
    # evidence_workflow_reference, task description, git workflow, etc). The
    # tests below encode that as regression guards — the fat markers must stay
    # OUT of nudge output.

    defp big_task do
      %{
        id: "019f640d-2ff7-7215-a495-2c958716ce50",
        title: "Redesign TaskRouter",
        description:
          String.duplicate(
            "This is a large task description with lots of prose the nudge must strip out. ",
            40
          ),
        status: "in_progress",
        priority: "high"
      }
    end

    defp five_stage_stage(id, position) do
      %{
        id: id,
        name: "stage-#{position}",
        status: if(position == 3, do: "running", else: "pending"),
        position: position,
        started_at: DateTime.utc_now() |> DateTime.add(-7 * 60, :second),
        validations: [
          %{
            id: "val-#{position}-a",
            kind: "test_pass",
            status: "pending"
          },
          %{
            id: "val-#{position}-b",
            kind: "lint_pass",
            status: "pending"
          }
        ]
      }
    end

    test "output stays under 2000 chars for a 5-stage task with a full-body description" do
      # Regression guard on the <500 tokens (~<2000 chars) promise — the nudge
      # must NOT balloon back to full-context payload even when the task carries
      # heavy prose.
      task = big_task()
      # Pass the currently-running stage; the nudge does not enumerate siblings.
      stage = five_stage_stage("019f640d-stage-3", 3)

      prompt = HeartbeatScheduler.nudge_prompt(task, stage)

      len = String.length(prompt)

      assert len < 2000,
             "nudge_prompt/2 was #{len} chars — must stay <2000 (<500 tokens) to preserve the payload-split contract"
    end

    test "output does NOT contain full-context markers (skills, evidence, git workflow, description)" do
      task = big_task()
      stage = five_stage_stage("019f640d-stage-3", 3)

      prompt = HeartbeatScheduler.nudge_prompt(task, stage)

      refute prompt =~ "## Skill discovery",
             "nudge_prompt must strip the skills_reference block"

      refute prompt =~ "## Submitting evidence",
             "nudge_prompt must strip the evidence_workflow_reference block"

      refute prompt =~ "## Git Workflow",
             "nudge_prompt must strip the git workflow section"

      refute prompt =~ task.description,
             "nudge_prompt must strip the task description verbatim"
    end

    test "output includes task_id, stage_id, and pending validation IDs compactly" do
      task = big_task()
      stage = five_stage_stage("019f640d-stage-3", 3)

      prompt = HeartbeatScheduler.nudge_prompt(task, stage)

      assert prompt =~ task.id
      assert prompt =~ stage.id
      assert prompt =~ "val-3-a"
      assert prompt =~ "val-3-b"
      assert prompt =~ "## Completion Reminder"
      assert prompt =~ "ack, push validation_pass, or report_blocker"
    end

    test "handles a stage with no pending validations (all passed) — points at stage_complete" do
      task = big_task()

      stage = %{
        id: "019f640d-stage-final",
        name: "wrap-up",
        status: "running",
        started_at: DateTime.utc_now(),
        validations: [
          %{id: "val-final-a", kind: "test_pass", status: "passed"}
        ]
      }

      prompt = HeartbeatScheduler.nudge_prompt(task, stage)

      assert prompt =~ "No pending validation IDs"
      assert prompt =~ "stage_complete"
      # Fat-context guards still hold.
      refute prompt =~ "## Skill discovery"
    end

    test "renders cleanly when stage is nil" do
      # Router only nudges when a stage is armed, but be defensive — a nil
      # stage must not crash the composer.
      task = big_task()

      prompt = HeartbeatScheduler.nudge_prompt(task, nil)

      assert prompt =~ task.id
      # With no stage there's no completion-reminder body — just the preamble.
      assert prompt =~ "Please ack, push validation, or report_blocker"
    end

    test ":elapsed_ms opt from the router takes precedence over stage.started_at" do
      # The router keeps the authoritative elapsed value in LeaseManager. When
      # it hands it in, the nudge must use that, not the (possibly stale)
      # stage.started_at.
      task = big_task()

      stage = %{
        id: "019f640d-stage-3",
        name: "stage-3",
        status: "running",
        # stage.started_at says 100 minutes ago...
        started_at: DateTime.utc_now() |> DateTime.add(-100 * 60, :second),
        validations: []
      }

      # ...but the router's LeaseManager says 12 minutes.
      prompt = HeartbeatScheduler.nudge_prompt(task, stage, elapsed_ms: 12 * 60_000)

      assert prompt =~ "no ack in 12m"
      refute prompt =~ "no ack in 100m"
    end
  end

  describe "pending_validation_ids/1" do
    test "returns comma-separated pending UUIDs and skips non-pending validations" do
      stage = %{
        id: "s1",
        validations: [
          %{id: "v1", status: "pending"},
          %{id: "v2", status: "passed"},
          %{id: "v3", status: "pending"},
          %{id: "v4", status: "failed"}
        ]
      }

      assert HeartbeatScheduler.pending_validation_ids(stage) == "v1, v3"
    end

    test "returns empty string on nil stage or no pending" do
      assert HeartbeatScheduler.pending_validation_ids(nil) == ""

      empty = %{id: "s1", validations: []}
      assert HeartbeatScheduler.pending_validation_ids(empty) == ""

      all_passed = %{id: "s1", validations: [%{id: "v1", status: "passed"}]}
      assert HeartbeatScheduler.pending_validation_ids(all_passed) == ""
    end
  end

  describe "dispatch_prompt/4 vs nudge_prompt/2 regression guard" do
    # This encodes the payload-split invariant: dispatch stays FAT (initial
    # dispatch must load skills + evidence + task context on turn one), nudge
    # stays THIN (safety-net re-poke, <2000 chars). If either drifts, the
    # split is degrading and the operator-sanity win regresses.

    test "dispatch_prompt/4 stays fat (>3000 chars) while nudge_prompt/2 stays thin (<2000 chars)" do
      task = %{
        id: "019f640d-task",
        title: "Fat vs thin split",
        description: "Anything.",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      stage = %{
        id: "019f640d-stage",
        name: "coding",
        status: "running",
        position: 1,
        started_at: DateTime.utc_now(),
        validations: [
          %{id: "v1", kind: "test_pass", status: "pending"},
          %{id: "v2", kind: "lint_pass", status: "pending"}
        ]
      }

      plan = %{version: 1, stages: [stage]}

      dispatch = HeartbeatScheduler.dispatch_prompt(task, plan, stage)
      nudge = HeartbeatScheduler.nudge_prompt(task, stage)

      dispatch_len = String.length(dispatch)
      nudge_len = String.length(nudge)

      assert dispatch_len > 3000,
             "dispatch_prompt/4 dropped to #{dispatch_len} chars — full-context payload is degrading (should be >3000)"

      assert nudge_len < 2000,
             "nudge_prompt/2 grew to #{nudge_len} chars — short-form payload is degrading (should be <2000)"

      # Dispatch carries the fat markers.
      assert dispatch =~ "## Skill discovery"
      # Nudge does NOT.
      refute nudge =~ "## Skill discovery"
      refute nudge =~ "## Submitting evidence"

      # Log the sizes so the evidence in this stage's validation captures a
      # concrete number the next tuner can compare against.
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.puts(
        "\n[stage 4 payload split] dispatch=#{dispatch_len} chars, nudge=#{nudge_len} chars, ratio=#{Float.round(dispatch_len / nudge_len, 2)}x"
      )
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

  # Task 019f7b7e stage 3. Stage 2 reserves a per-stack migration timestamp
  # onto `task.metadata["reserved_migration_slots"]`; this block asserts the
  # in_progress dispatch actually surfaces it to the executor, and — just as
  # important — that it stays silent everywhere it shouldn't fire.
  #
  # No prompt template rows are seeded in this async test file, so
  # `render_template/2` returns `{:error, :not_found}` and every assertion
  # here exercises the HARDCODED fallback path. The DB-template path carries
  # the matching `{{migration_slot_section}}` placeholder, covered in
  # `prompt_templates_test.exs`.
  describe "migration slot section (task 019f7b7e stage 3)" do
    @slot_stage_id "019f7b84-a342-79fc-8f2c-053c33a6f828"
    @slot_stack_id "019e2782-09d6-7e2c-9502-c106290e5add"

    defp slot_plan_and_stage(stage_id \\ @slot_stage_id) do
      stage = %{id: stage_id, position: 3, name: "coding", validations: []}
      {%{version: 1, stages: [stage]}, stage}
    end

    defp slot_reservation(stage_id, timestamp) do
      %{
        "stage_id" => stage_id,
        "stage_name" => "Surface reserved slot in dispatch prompt",
        "timestamp" => timestamp,
        "allocated_at" => "2026-07-19T12:01:00Z"
      }
    end

    defp slot_task(opts) do
      %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member task",
        description: "Ship the stack member",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: Keyword.get(opts, :stack_id, @slot_stack_id),
        stack: %{
          id: @slot_stack_id,
          slug: "meeting-module",
          rollup_branch: "stack/meeting-module",
          metadata: %{}
        },
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end

    test "renders the full section when a reservation matches the dispatched stage" do
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [slot_reservation(@slot_stage_id, "20260719120100")]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Reserved migration timestamp"
      assert prompt =~ "`20260719120100`"
      # The rename instruction must carry the concrete filename prefix — a
      # generic "use the reserved timestamp" line is what executors ignore.
      assert prompt =~ "20260719120100_<name>.exs"
      assert prompt =~ "Do NOT allocate"
    end

    test "the reserved section precedes the Git Workflow block" do
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [slot_reservation(@slot_stage_id, "20260719120100")]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      slot_at = :binary.match(prompt, "## Reserved migration timestamp") |> elem(0)
      git_at = :binary.match(prompt, "## Git Workflow (CRITICAL)") |> elem(0)

      assert slot_at < git_at,
             "the reserved timestamp must be read before the branch/commit instructions"
    end

    test "filters to the dispatched stage — a sibling stage's reservation does not leak" do
      # Reservation belongs to stage A; we dispatch stage B. A plan with
      # migrations in two stages must not show the wrong timestamp.
      {plan, stage} = slot_plan_and_stage("019f7b84-0000-0000-0000-00000000000b")

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [
              slot_reservation("019f7b84-0000-0000-0000-00000000000a", "20260719120100")
            ]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
      refute prompt =~ "20260719120100"
    end

    test "picks the matching entry out of a multi-stage reservation list" do
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [
              slot_reservation("019f7b84-0000-0000-0000-00000000000a", "20260719120000"),
              slot_reservation(@slot_stage_id, "20260719120100"),
              slot_reservation("019f7b84-0000-0000-0000-00000000000c", "20260719120200")
            ]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "`20260719120100`"
      refute prompt =~ "20260719120000"
      refute prompt =~ "20260719120200"
    end

    test "renders nothing when metadata carries no reserved_migration_slots key" do
      {plan, stage} = slot_plan_and_stage()
      task = slot_task(metadata: %{"some_other_key" => "value"})

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
    end

    test "renders nothing when the reservation list is empty" do
      {plan, stage} = slot_plan_and_stage()
      task = slot_task(metadata: %{"reserved_migration_slots" => []})

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
    end

    test "renders nothing for a solo task even if metadata carries a reservation" do
      # The mechanism is strictly a stack concern — a stray key on a
      # non-stack task must not produce collision guidance that would
      # confuse a solo executor.
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          stack_id: nil,
          metadata: %{
            "reserved_migration_slots" => [slot_reservation(@slot_stage_id, "20260719120100")]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
      refute prompt =~ "20260719120100"
    end

    test "renders nothing when the task has no metadata field at all" do
      # Guards the pre-stage-2 shape: tasks dispatched before the
      # reservation hook existed have no metadata map preloaded.
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task([])
        |> Map.delete(:metadata)

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
    end

    test "tolerates malformed reservation entries without crashing" do
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [
              "not-a-map",
              %{"stage_id" => @slot_stage_id},
              %{"stage_id" => @slot_stage_id, "timestamp" => ""}
            ]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
    end

    test "renders nothing when the reservation list is not a list" do
      {plan, stage} = slot_plan_and_stage()
      task = slot_task(metadata: %{"reserved_migration_slots" => %{"stage_id" => "x"}})

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Reserved migration timestamp"
    end

    test "renders nothing when no stage is being dispatched" do
      # Task 019fa469 stage 2: with NO running stage, `DispatchPhase` routes to
      # `dispatch.fallback` instead of fabricating a stage-scoped in_progress
      # body around an empty stage_id — that fabrication is defect 4, and the
      # router stops sending this shape at all in stage 4. The refute below
      # would therefore pass by template-absence alone, so it is paired with a
      # positive pin on the fallback body plus a length floor.
      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [slot_reservation(@slot_stage_id, "20260719120100")]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, %{version: 1, stages: []}, nil)

      refute prompt =~ "## Reserved migration timestamp"
      assert prompt =~ "Stack member task"
      assert prompt =~ "assigned"
      assert String.length(prompt) > 200
    end

    test "still renders the reserved section for a stage-scoped dispatch on the same task" do
      # Anti-vacuity companion to the test above: the reservation IS surfaced
      # when a stage resolves, so the refute there is about the missing stage,
      # not about the section having quietly stopped rendering everywhere.
      {plan, stage} = slot_plan_and_stage()

      task =
        slot_task(
          metadata: %{
            "reserved_migration_slots" => [slot_reservation(@slot_stage_id, "20260719120100")]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Reserved migration timestamp"
      assert prompt =~ "`20260719120100`"
    end
  end

  # ── task 019fa63a stage 5: the resolved repo set in dispatch prompts ───────
  #
  # Every dispatch site used to read `project_attr(task, :repo_url, "")`. Both
  # cross-repo client tasks on 2026-07-27 (`019fa618-c860`, `019fa618-ca92`)
  # therefore received git blocks naming `Startup-Suite/core` — the PROJECT's
  # repo — rather than the repository their work actually lived in, and their
  # executors had to be told by hand to ignore the instruction.
  #
  # Every test below pairs a PRESENCE assertion with an ABSENCE assertion on
  # the same prompt. A presence assertion alone passes on template text that no
  # resolver produced: both repositories are plausible strings to find in a
  # dispatch, and the bug's signature is precisely that the WRONG one is there
  # too.
  describe "dispatch_prompt/3 — resolved repository set" do
    @core_url "https://github.com/Startup-Suite/core"
    @channel_url "Startup-Suite/openclaw-suite-channel"

    defp repo_set_task(attrs) do
      Map.merge(
        %{
          id: "task-1234abcd",
          title: "Cross-repo task",
          description: "Work spans more than the project repo",
          status: "in_progress",
          priority: "high",
          project: %{repo_url: @core_url, default_branch: "main"}
        },
        Map.new(attrs)
      )
    end

    defp repo_set_plan_and_stage do
      {%{version: 1, stages: [%{}]},
       %{
         id: "stage-repos",
         position: 1,
         name: "coding",
         validations: [%{id: "val-repos", kind: "test_pass"}]
       }}
    end

    defp git_workflow_section(prompt) do
      case String.split(prompt, "\n## Git Workflow (CRITICAL)\n", parts: 2) do
        [_before, rest] ->
          [section | _] = String.split(rest, "\n## Stage Execution Contract\n", parts: 2)
          section

        [_only] ->
          nil
      end
    end

    test "a one-entry repos override names the DECLARED repo and not the project's" do
      # The exact 2026-07-27 bug. The project points at core; the work lives in
      # openclaw-suite-channel; the declared entry is the one the executor must
      # be handed. Without the `refute` this test passes on a prompt that names
      # both, which is a strictly worse dispatch than naming only the wrong one
      # — the executor has to guess.
      {plan, stage} = repo_set_plan_and_stage()

      task =
        repo_set_task(
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => false},
            "repos" => [%{"repo_url" => @channel_url, "ci" => "none"}]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Git Workflow (CRITICAL)"
      assert prompt =~ "Repository: #{@channel_url}"
      refute prompt =~ @core_url
      refute prompt =~ "Startup-Suite/core"

      # A one-entry set is still ONE repository — no multi-repo block, so the
      # prompt an ordinary task reads is unchanged in shape.
      refute prompt =~ "### Repositories in scope"
    end

    test "a two-entry repos set names both repos and carries per-repo CI wording" do
      {plan, stage} = repo_set_plan_and_stage()

      task =
        repo_set_task(
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => false},
            "repos" => [
              %{"repo_url" => @core_url, "ci" => "required"},
              %{"repo_url" => @channel_url, "ci" => "none"}
            ]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)
      section = git_workflow_section(prompt)

      assert section
      assert section =~ "### Repositories in scope (2)"
      assert section =~ @core_url
      assert section =~ @channel_url

      # Index 0 is `:primary` — the singular `Repository:` line resolves to it.
      assert section =~ "Repository: #{@core_url}"
      assert section =~ "(primary, CI: required)"
      assert section =~ "(secondary, CI: none)"

      # ONE branch name across both worktrees — `Changelog.extract_task_id_from_branch/1`
      # reads the task id off the branch, so a per-repo suffix would break
      # resolution for every repository but one.
      assert section =~ "../worktrees/task-core -b task/task "
      assert section =~ "../worktrees/task-openclaw-suite-channel -b task/task "
      refute section =~ "-b task/task-core"

      # The behavioural half of the same bug: one green gate read as a
      # finished deploy.
      assert section =~ "one green gate is not a finished deploy"
    end

    test "the deploying dispatch enumerates one PR/CI/merge sequence per repo" do
      task =
        repo_set_task(
          status: "deploying",
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => true},
            "repos" => [
              %{"repo_url" => @core_url, "ci" => "required"},
              %{"repo_url" => @channel_url, "ci" => "none"}
            ]
          }
        )

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-repos",
        position: 2,
        name: "Deploy: PR merge",
        validations: [
          %{id: "val-pr-core", kind: "pr_merged"},
          %{id: "val-pr-channel", kind: "pr_merged"}
        ]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "This deploy covers 2 repositories"
      assert prompt =~ "### #{@core_url}"
      assert prompt =~ "### #{@channel_url}"

      # `ci: "none"` is not a softer `ci: "required"` — it inverts what a clean
      # merge state MEANS. Split the prompt at the second repo's heading so the
      # presence/absence pair is scoped to the right half; asserting on the
      # whole prompt would let the required-CI repo's block satisfy either one.
      [core_block, channel_block] = String.split(prompt, "### #{@channel_url}", parts: 2)

      assert channel_block =~ "A CLEAN merge state here means zero checks ran"
      assert channel_block =~ "Do NOT enable auto-merge here"
      refute core_block =~ "A CLEAN merge state here means zero checks ran"

      assert core_block =~ "Wait for CI to go green on the PR"
      refute channel_block =~ "Wait for CI to go green on the PR"

      # Auto-merge is declared true at strategy level. The required-CI repo
      # honours it; the zero-CI repo must not, because there is no check for
      # auto-merge to wait on.
      assert core_block =~ "auto-merge is enabled"
      refute channel_block =~ "auto-merge is enabled"

      assert prompt =~ "`pr_merged` gate PER repository and does NOT complete"
      assert prompt =~ "Do not read one passing gate as a finished deploy"
    end

    test "a single-repo deploying dispatch omits the multi-repo preamble entirely" do
      # Anti-vacuity companion to the test above. The "covers N repositories"
      # framing must not appear on the dispatch every ordinary task receives,
      # or the warning stops carrying information.
      task =
        repo_set_task(
          status: "deploying",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}
        )

      stage = %{
        id: "stage-deploy-solo",
        position: 2,
        name: "Deploy: PR merge",
        validations: [%{id: "val-pr-solo", kind: "pr_merged"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, %{version: 1, stages: [%{}, %{}]}, stage)

      refute prompt =~ "This deploy covers"
      refute prompt =~ "A CLEAN merge state here means zero checks ran"

      # And it still resolves the project repo through the same resolver.
      assert prompt =~ "### #{@core_url}"
      assert prompt =~ "Merge the PR in GitHub once CI is green"
    end

    test "declaring no repos renders the byte-identical Git Workflow section" do
      # Backward-compat pin. Every task in the system today declares no
      # `"repos"`, so this is the prompt almost every executor receives; the
      # literal below is the section as it rendered at a6664ede (stage 4 HEAD),
      # copied verbatim. If a future change to the multi-repo block leaks into
      # the single-repo path, this fails with a diff rather than silently
      # rewording nine thousand dispatches.
      {plan, stage} = repo_set_plan_and_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(
          repo_set_task(project: %{repo_url: @core_url, default_branch: "main"}),
          plan,
          stage
        )

      expected = """
      Repository: #{@core_url}
      Base branch: main

      1. Create a worktree from the latest main branch:
         ```
         git fetch origin
         git worktree add ../worktrees/task -b task/task origin/main
         cd ../worktrees/task
         ```
      2. Do ALL work in the worktree directory.
      3. When implementation is complete:
         - Run the full test suite and lint checks
         - Commit all changes with a descriptive message referencing task task
         - Push the branch: `git push -u origin task/task`
         - Do NOT open a PR yet — PR opening happens in the deploy phase
      4. NEVER work on an existing branch. ALWAYS branch from latest origin/main.
      """

      assert git_workflow_section(prompt) == expected
    end

    test "an unresolvable repo set strips the Git Workflow block, as a blank repo_url does" do
      # `resolve_deploy_repos/1` returning `[]` is the new "no repo" signal.
      # `example.invalid` is the fixture placeholder every local-proof task
      # uses; a bare word is the other way a project reaches `[]`.
      {plan, stage} = repo_set_plan_and_stage()

      for repo_url <- ["", "https://example.invalid/local-task-lifecycle-proof", "not-a-repo"] do
        prompt =
          HeartbeatScheduler.dispatch_prompt(
            repo_set_task(project: %{repo_url: repo_url, default_branch: "main"}),
            plan,
            stage
          )

        refute prompt =~ "## Git Workflow (CRITICAL)",
               "expected the git block stripped for repo_url #{inspect(repo_url)}"

        # Anti-vacuity: the prompt is still a real dispatch, not an empty
        # string that trivially satisfies every refute above.
        assert prompt =~ "Current stage_id: `stage-repos`"
      end
    end

    test "a DECLARED placeholder repo strips the block too, rather than sending an executor to it" do
      # Stage 1 KEEPS a declared-but-unresolvable entry (with `slug: nil`) so
      # its deploy gate cannot be matched by accident. That is a gate decision,
      # not a dispatch one: `real_repo_url?/1` still applies to the resolved
      # primary entry, so nobody is told to clone `example.invalid`.
      {plan, stage} = repo_set_plan_and_stage()

      task =
        repo_set_task(
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [%{"repo_url" => "https://example.invalid/nope", "ci" => "none"}]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "## Git Workflow (CRITICAL)"
      refute prompt =~ "example.invalid"
      assert prompt =~ "Current stage_id: `stage-repos`"
    end

    test "a stack member's git block resolves the declared repo, not the project's" do
      # The stack path builds its own section (full-UUID worktree + rollup
      # membership block) and read `project_attr(task, :repo_url, "")`
      # independently. Two readers, one bug — this pins the second.
      {plan, stage} = repo_set_plan_and_stage()

      task =
        repo_set_task(
          id: "019fa63a-86a5-779c-bbb4-088a15ddac51",
          stack_id: "019fa000-0000-7000-8000-000000000001",
          stack: %{
            slug: "cross-repo",
            rollup_branch: "stack/cross-repo",
            metadata: %{"rollup_branch_ready" => %{"at" => "2026-07-31T00:00:00Z"}}
          },
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [%{"repo_url" => @channel_url, "ci" => "none"}]
          }
        )

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Task Stack Membership"
      assert prompt =~ "Repository: #{@channel_url}"
      refute prompt =~ @core_url
      refute prompt =~ "Startup-Suite/core"
    end
  end
end
