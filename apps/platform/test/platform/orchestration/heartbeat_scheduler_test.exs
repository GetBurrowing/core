defmodule Platform.Orchestration.HeartbeatSchedulerTest do
  use ExUnit.Case, async: true

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates

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
      assert prompt =~ "test_pass"
      assert prompt =~ "lint_pass"
      assert prompt =~ "manual_approval"

      # The "## Plan structure / **Implementation stages** / Push the branch …
      # do NOT open a PR" block used to be asserted here. It was never in the
      # `dispatch.planning` TEMPLATE — only in the hardcoded fallback — so the
      # planner has not been told it on the DB-served path for as long as that
      # path has existed. Since task 019ff10f this branch derives its fallback
      # from the same descriptor the row is seeded from, so the two paths now
      # agree, and they agree on NOT carrying it.
      #
      # Deliberately not fixed here by editing the descriptor:
      # `prompt_templates_test.exs:248` pins the live row equal to the shipped
      # default, so adding the paragraph requires a paired migration + descriptor
      # change, which this stage rules out of scope. Restoring the text to the
      # descriptor alone would break that pin; restoring it to the fallback alone
      # would recreate the restatement this task removed. It belongs in a
      # follow-up that writes both. The role-separation assertions below still
      # cover the "planner does not author a deploy stage" half of the same rule.

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
      assert prompt =~ "Merge the PR by hand in GitHub once CI is green"
      refute prompt =~ "it will merge automatically"
      assert prompt =~ "Do NOT create a `suite_review_request_create`"
      # No pr_merge stage should ever surface the legacy manual_approval
      # validation since the builder no longer emits it.
      refute prompt =~ "manual_approval"

      # Deploy Stage Contract red-CI + blocker lines (task 01a0e362). The
      # contract must agree with the ONE rule in Deploy boundaries. Controls
      # come BEFORE the refutes so a mutant fails on the refute by name.
      section = deploy_contract_section(prompt)

      assert section =~ "Current stage_id: `stage-deploy-1`"
      assert section =~ "A red CI follows the ONE rule"
      assert section =~ "call `task_update` with `task_id=task-deploy-1` and status `in_progress`"

      assert section =~
               "- Use `report_blocker` with `task_id=task-deploy-1` and `stage_id=stage-deploy-1` only when the deploy itself cannot proceed"

      assert prompt =~ "there is ONE rule"

      refute prompt =~ "do NOT attempt code fixes"
      refute prompt =~ "If CI fails or the deploy breaks"
      refute Regex.match?(~r/^- If CI fails.*with `task_id=/m, prompt)

      # Deploy boundaries — fix-forward inside the task's diff only, no local
      # test re-runs (the "Do NOT modify code" line was replaced by the ONE
      # rule on 2026-09-10; task_update to in_progress is the plan-change path)
      assert prompt =~ "Do not touch code outside the task's diff"
      assert prompt =~ "call `task_update` with status `in_progress`"
      assert prompt =~ "Do NOT re-run tests or lint locally"
      assert prompt =~ "branch is already pushed from execution"
    end

    test "execution_contract blocker line is unchanged by the report_blocker_instruction signature change (task 01a0e362)" do
      task = %{
        id: "task-exec-1",
        title: "Build",
        description: "Build it",
        status: "in_progress",
        priority: "medium"
      }

      stage = %{
        id: "stage-exec-1",
        position: 1,
        name: "Implement",
        validations: [%{id: "val-test-1", kind: "test_pass"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, %{version: 1, stages: [%{}]}, stage)

      assert prompt =~ "## Stage Execution Contract"

      assert prompt =~
               "\n- Use `report_blocker` with `task_id=task-exec-1` and `stage_id=stage-exec-1` if you cannot make forward progress.\n"
    end

    test "deploy contract blocker line keeps its verb when the stage has no id (task 01a0e362)" do
      task = %{
        id: "task-deploy-nil",
        title: "Deploy feature",
        description: "Ship the feature",
        status: "deploying",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"}
      }

      stage = %{
        position: 1,
        name: "Deploy: PR merge",
        validations: [%{id: "val-pr-merged-nil", kind: "pr_merged"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, %{version: 1, stages: [%{}]}, stage)
      section = deploy_contract_section(prompt)

      assert section =~
               "call `task_update` with `task_id=task-deploy-nil` and status `in_progress`"

      assert Regex.match?(
               ~r/^- Use `report_blocker` with .*only when the deploy itself cannot proceed/m,
               section
             )

      refute Regex.match?(~r/^- If CI fails/m, section)
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

      # The HAZARD is an EMPTY subagent_id, not one particular sentinel string.
      # Since task 019ff10f this branch DERIVES its body from the
      # `dispatch.in_progress` descriptor, whose ack preamble spells the
      # placeholder "<the id returned when you spawned the SuiteExecutor /
      # SuiteReviewer via the Agent tool>" rather than the hardcoded body's
      # "<unknown — spawn a subagent first>". Pinning either literal would pin
      # WHICH body rendered, which is not what this guard is about; the
      # `deploying` case below still pins the hardcoded sentinel, so that
      # spelling keeps a test of its own.
      assert prompt =~ ~r/subagent_id="<[^"]+>"/,
             "in_progress fallback must render a non-empty subagent_id placeholder in the ack call"

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

      # The HAZARD is an EMPTY subagent_id, not one particular sentinel string.
      # Since task 019ff10f this branch DERIVES its body from the
      # `dispatch.in_review` descriptor, whose ack preamble spells the
      # placeholder "<the id returned when you spawned the SuiteExecutor /
      # SuiteReviewer via the Agent tool>" rather than the hardcoded body's
      # "<unknown — spawn a subagent first>". Pinning either literal would pin
      # WHICH body rendered, which is not what this guard is about; the
      # `deploying` case below still pins the hardcoded sentinel, so that
      # spelling keeps a test of its own.
      assert prompt =~ ~r/subagent_id="<[^"]+>"/,
             "in_review fallback must render a non-empty subagent_id placeholder in the ack call"

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

  describe "select_review_template/3 payload_amendments (task 01a0acb4 stage 3)" do
    # The assign is pretty-printed JSON as of task 01a0e25e (it was `inspect/1`
    # output before: `encode_payload_json/1` was guarded `is_map/1` and the
    # rendered entries are a list). Entries are read back with `Jason.decode!/1`,
    # so a rendering that is not JSON fails here rather than being evaluated.
    defp rendered_entries(json), do: Jason.decode!(json)

    @amendment %{
      "prior_payload" => %{"setup" => "old-setup", "actions" => "old", "expected" => "old"},
      "amended_by" => "amender-slug",
      "actor_type" => "agent",
      "reason" => "the case sent a header the pipeline refuses",
      "amended_at" => "2026-09-27T10:00:00Z",
      "last_ruling" => nil
    }

    test "an amended case's entry carries payload_amendments" do
      pending = [
        %Platform.Tasks.Validation{
          id: "val-amended",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "new-setup"},
          payload_amendments: [@amendment]
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-am",
                 execution_space_id: "exec-am"
               })

      assert [entry] = rendered_entries(assigns.pending_e2e_validations_json)
      assert entry["payload_amendments"] == [@amendment]
      assert entry["validation_id"] == "val-amended"
    end

    test "an unamended case's entry has exactly validation_id and evaluation_payload" do
      pending = [
        %Platform.Tasks.Validation{
          id: "val-unamended",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "s-u"}
        },
        %{
          id: "val-map-empty",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "s-m"},
          payload_amendments: []
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-un",
                 execution_space_id: "exec-un"
               })

      # Literal pin of the JSON rendering (task 01a0e25e). HAND-WRITTEN: an
      # expectation computed with `Jason.encode!/2` here would be derived from
      # the function under test and could not fail. Keys are in sorted order
      # because Jason walks small maps in term order.
      expected =
        String.trim_trailing(~S"""
        [
          {
            "evaluation_payload": {
              "setup": "s-u"
            },
            "validation_id": "val-unamended"
          },
          {
            "evaluation_payload": {
              "setup": "s-m"
            },
            "validation_id": "val-map-empty"
          }
        ]
        """)

      assert assigns.pending_e2e_validations_json == expected

      for entry <- rendered_entries(assigns.pending_e2e_validations_json) do
        assert Map.keys(entry) |> Enum.sort() == ["evaluation_payload", "validation_id"]
      end
    end

    test "in a mixed dispatch only the amended entry carries the key" do
      pending = [
        %Platform.Tasks.Validation{
          id: "val-a",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "a"},
          payload_amendments: [@amendment]
        },
        %Platform.Tasks.Validation{
          id: "val-b",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: %{"setup" => "b"}
        }
      ]

      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-mixed",
                 execution_space_id: "exec-mixed"
               })

      assert [a, b] = rendered_entries(assigns.pending_e2e_validations_json)
      assert a["validation_id"] == "val-a"
      assert Map.has_key?(a, "payload_amendments")
      assert b["validation_id"] == "val-b"
      assert Map.keys(b) |> Enum.sort() == ["evaluation_payload", "validation_id"]
    end
  end

  describe "pending_e2e_validations_json is JSON and untruncated (task 01a0e25e)" do
    # Before task 01a0e25e this assign was `inspect/1` of a list: Elixir term
    # syntax, and every string cut at inspect's default 4096-byte
    # `printable_limit`. Sentinels sit at the TAIL of >4096-byte strings, so a
    # truncating renderer loses exactly the byte these tests look for. The
    # sentinels and lengths are literals, never recomputed from the code under
    # test. The rendered-prompt half (through `dispatch_prompt/4` and the
    # seeded template) needs the DB and lives in
    # `heartbeat_scheduler_unmet_gate_template_test.exs`.

    @tail_sentinel "TAIL-SENTINEL-01a0e25e"
    @amend_sentinel "AMEND-TAIL-01a0e25e"
    @quoted_expected ~s(he said "ok" \\ then ```done``` — café 🚀)

    @long_amendment %{
      "prior_payload" => %{"setup" => "old-setup", "actions" => "old", "expected" => "old"},
      "amended_by" => "amender-slug",
      "actor_type" => "agent",
      "reason" => String.duplicate("r", 4500) <> "AMEND-TAIL-01a0e25e",
      "amended_at" => "2026-09-27T10:00:00Z",
      "last_ruling" => nil
    }

    defp e2e_assigns(pending) do
      assert {"dispatch.review_e2e", assigns} =
               HeartbeatScheduler.select_review_template(pending, %{
                 id: "task-01a0e25e",
                 execution_space_id: "exec-01a0e25e"
               })

      assigns.pending_e2e_validations_json
    end

    test "a >4096-byte actions string survives whole, as JSON not term syntax" do
      actions = String.duplicate("a", 5000) <> @tail_sentinel

      json =
        e2e_assigns([
          %{
            id: "val-long",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{"setup" => "s", "actions" => actions, "expected" => "e"}
          }
        ])

      assert json =~ @tail_sentinel

      assert [entry] = Jason.decode!(json)
      decoded_actions = entry["evaluation_payload"]["actions"]
      assert String.length(decoded_actions) == 5022
      assert String.ends_with?(decoded_actions, @tail_sentinel)

      refute json =~ "%{"
      refute json =~ " => "
    end

    test "two validations render as a JSON array of two objects" do
      json =
        e2e_assigns([
          %{
            id: "val-1",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{"setup" => "one"}
          },
          %{
            id: "val-2",
            kind: "e2e_behavior",
            status: "failed",
            evaluation_payload: %{"setup" => "two"}
          }
        ])

      decoded = Jason.decode!(json)
      assert is_list(decoded)
      assert length(decoded) == 2
      assert Enum.all?(decoded, &is_map/1)
      assert Enum.map(decoded, & &1["validation_id"]) == ["val-1", "val-2"]

      assert json |> String.replace(~r/\s/, "") |> String.starts_with?("[{\"")
    end

    test "quotes, backslashes, fences and non-ASCII round-trip byte-equal" do
      json =
        e2e_assigns([
          %{
            id: "val-quoted",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{"setup" => "", "actions" => "a", "expected" => @quoted_expected}
          }
        ])

      assert [entry] = Jason.decode!(json)
      assert entry["evaluation_payload"]["expected"] == @quoted_expected
    end

    test "an amended entry carries its full payload_amendments, tail intact" do
      json =
        e2e_assigns([
          %Platform.Tasks.Validation{
            id: "val-amended-long",
            kind: "e2e_behavior",
            status: "pending",
            evaluation_payload: %{"setup" => "new-setup"},
            payload_amendments: [@long_amendment]
          }
        ])

      assert [entry] = Jason.decode!(json)
      assert entry["payload_amendments"] == [@long_amendment]
      assert [amendment] = entry["payload_amendments"]
      assert String.length(amendment["reason"]) == 4519
      assert String.ends_with?(amendment["reason"], @amend_sentinel)
      assert amendment["last_ruling"] == nil
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
    test "returns comma-separated UNMET UUIDs and skips only passed validations" do
      # Changed deliberately by task 01a01b00 stage 2 — was "v1, v3".
      #
      # `pending_validation_ids/1` classifies on
      # `Platform.Tasks.Validation.unmet_statuses/0` (pending | running |
      # failed), not on the literal "pending". The nudge exists to tell a
      # stalled agent what it still owes before `stage_complete`, and a
      # `failed` gate blocks completion — `PlanEngine.stage_verdict/1` answers
      # `:has_failures` for this stage, so listing `v4` is the honest answer
      # and omitting it rendered "(none — call stage_complete if work is
      # done)" for a stage that could not complete.
      #
      # `passed` is the ONLY status omitted, and the fixture keeps `v2` at
      # `passed` so this stays a discrimination rather than "list everything".
      stage = %{
        id: "s1",
        validations: [
          %{id: "v1", status: "pending"},
          %{id: "v2", status: "passed"},
          %{id: "v3", status: "running"},
          %{id: "v4", status: "failed"}
        ]
      }

      assert HeartbeatScheduler.pending_validation_ids(stage) == "v1, v3, v4"
    end

    test "returns empty string on nil stage or when every gate has passed" do
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
               stack_metadata: %{},
               stack_status: nil
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
               stack_metadata: %{},
               stack_status: nil
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
               stack_metadata: %{},
               stack_status: nil
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

    test "returns the full UUID for a non-stack task too" do
      # This assertion is inverted from what it pinned before task 019fb949,
      # and the reversal is deliberate. It used to read "returns the short
      # 8-char prefix for a non-stack task", recording a choice to keep
      # non-stack dispatch output byte-for-byte unchanged when PR #615 fixed
      # the stack path. That choice was wrong: chars 1-8 of a UUIDv7 are the
      # high 32 bits of its millisecond timestamp, so every task filed in the
      # same ~65-second bucket truncates to the same slug — one worktree, one
      # branch, two executors. Membership now decides only whether the
      # `## Task Stack Membership` block renders, never the slug.
      task = %{id: "019e2474-11c1-7000-8000-000000000001", stack_id: nil}
      assert HeartbeatScheduler.member_slug(task) == "019e2474-11c1-7000-8000-000000000001"
    end

    test "membership does not change the slug — same id, member and non-member alike" do
      id = "019e2474-11c1-7000-8000-000000000001"
      lone = %{id: id, stack_id: nil}

      member = %{
        id: id,
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: %{id: "019e2782-09d6-7e2c-9502-c106290e5add", slug: "meeting-module"}
      }

      assert HeartbeatScheduler.member_slug(lone) == HeartbeatScheduler.member_slug(member)
    end
  end

  # ── Task 019fb949 ────────────────────────────────────────────────────────
  # RED ON PURPOSE at the time of writing. `member_slug/1` truncates to the
  # first hyphen-segment for a NON-stack task, so both prompts below render the
  # byte-identical `git worktree add ../worktrees/019fb90f -b task/019fb90f
  # origin/main` and two concurrently-dispatched executors are sent into one
  # worktree on one branch. These assertions fail until the non-stack path also
  # routes through `full_task_id/1`.
  #
  # The collision is DETERMINISTIC, not a race. `Platform.Types.UUIDv7.generate/0`
  # lays out `<<timestamp_ms::big-48, ...>>`, so chars 1-8 of the id are the HIGH
  # 32 BITS of the 48-bit millisecond timestamp — constant across a 2^16 ms =
  # 65.536-second aligned bucket. The two literal ids below are the real
  # incident pair; they differ by 0x6226 - 0x36e3 = 11_075 ms, i.e. the tasks
  # were filed eleven seconds apart. Every task filed in the same ~minute-wide
  # bucket collides this way, which is why the fixtures are literal ids rather
  # than generated ones.
  describe "worktree/branch slugs for tasks sharing an 8-char id prefix" do
    @collide_a "019fb90f-36e3-7bff-a6f1-69cd689faa59"
    @collide_b "019fb90f-6226-7c68-9ec2-7bbc9378e8e2"

    setup do
      {plan, stage} = simple_plan_with_stage()

      {:ok,
       prompt_a: HeartbeatScheduler.dispatch_prompt(colliding_task(@collide_a), plan, stage),
       prompt_b: HeartbeatScheduler.dispatch_prompt(colliding_task(@collide_b), plan, stage)}
    end

    # `stack_id: nil` is the whole point — the stack path was already fixed and
    # this is the path it deliberately left behind. The real-looking `repo_url`
    # is load-bearing: a placeholder URL makes `maybe_strip_git_workflow/2`
    # delete the entire Git Workflow block, and every assertion below would then
    # pass vacuously against a prompt that contains no git commands at all.
    defp colliding_task(id) do
      %{
        id: id,
        title: "Colliding task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }
    end

    defp line_containing(prompt, needle) do
      prompt
      |> String.split("\n")
      |> Enum.find(fn line -> String.contains?(line, needle) end)
    end

    # Anti-vacuity guard. If the Git Workflow block were stripped, the three
    # tests below would "pass" by asserting things about nothing.
    test "both prompts actually carry a Git Workflow block", ctx do
      assert ctx.prompt_a =~ "Git Workflow (CRITICAL)"
      assert ctx.prompt_b =~ "Git Workflow (CRITICAL)"
      assert line_containing(ctx.prompt_a, "git worktree add")
      assert line_containing(ctx.prompt_b, "git worktree add")
    end

    test "the two tasks are sent to different worktree paths", ctx do
      add_a = line_containing(ctx.prompt_a, "git worktree add")
      add_b = line_containing(ctx.prompt_b, "git worktree add")

      assert add_a =~ "../worktrees/#{@collide_a}"
      assert add_b =~ "../worktrees/#{@collide_b}"
      refute add_a == add_b
    end

    test "the two tasks are sent to different branches", ctx do
      branch_of = fn prompt ->
        case Regex.run(~r{-b (task/\S+)}, prompt) do
          [_, branch] -> branch
          nil -> nil
        end
      end

      assert branch_of.(ctx.prompt_a) == "task/#{@collide_a}"
      assert branch_of.(ctx.prompt_b) == "task/#{@collide_b}"
      refute branch_of.(ctx.prompt_a) == branch_of.(ctx.prompt_b)
    end

    test "neither prompt mentions the truncated 8-char slug anywhere", ctx do
      for prompt <- [ctx.prompt_a, ctx.prompt_b] do
        refute prompt =~ "../worktrees/019fb90f "
        refute prompt =~ "-b task/019fb90f "
        refute prompt =~ "git push -u origin task/019fb90f\n"
      end

      # "Anywhere" literally. Enumerating known call sites left a hole: the
      # commit-message line ("referencing task <id>") interpolated the
      # truncated id too and none of the three refutes above could see it —
      # verified by mutation. Delete every legitimate full-uuid occurrence and
      # assert the residue never names the shared prefix, so a NEW truncating
      # interpolation reddens this test without anyone remembering to add a
      # refute for it.
      for {prompt, id} <- [{ctx.prompt_a, @collide_a}, {ctx.prompt_b, @collide_b}] do
        residue = String.replace(prompt, id, "<FULL_ID>")

        refute residue =~ "019fb90f",
               "prompt still names the ambiguous 8-char prefix outside a full uuid: " <>
                 inspect(line_containing(residue, "019fb90f"))
      end
    end
  end

  # ── Task 019fb949 stage 3 ────────────────────────────────────────────────
  # Unique slugs stop two CONCURRENT dispatches from colliding, but they do
  # nothing about a worktree that already exists for another reason: a stale
  # tree from an earlier task, a redispatch after a blocker, a hand-created
  # directory. The platform never runs `git worktree add` for a non-stack task —
  # the executor agent does, on its own box — so the dispatch prompt is the only
  # lever the orchestrator holds over that shell, and rendered text is the guard.
  # These assertions are therefore the ONLY thing holding it in place; there is
  # no server-side behavior to fall back on.
  describe "worktree preflight in the Git Workflow block" do
    # Two ids differing only in the FINAL character. Any truncation, at any
    # width short of the full uuid, renders these two prompts identical — so the
    # cross-refutes below double as a truncation detector.
    @preflight_solo_id "019e2474-11c1-7000-8000-00000000000a"
    @preflight_member_id "019e2474-11c1-7000-8000-00000000000b"

    setup do
      {plan, stage} = simple_plan_with_stage()

      solo = %{
        id: @preflight_solo_id,
        title: "Ordinary task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }

      member = %{
        id: @preflight_member_id,
        title: "Stack member task",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        stack: meeting_module_stack_ready()
      }

      {:ok,
       solo: HeartbeatScheduler.dispatch_prompt(solo, plan, stage),
       member: HeartbeatScheduler.dispatch_prompt(member, plan, stage)}
    end

    defp preflight_line(id) do
      "if [ -d ../worktrees/#{id} ]; then " <>
        "git -C ../worktrees/#{id} rev-parse --abbrev-ref HEAD; fi"
    end

    defp preflight_prompts(ctx) do
      [{ctx.solo, @preflight_solo_id}, {ctx.member, @preflight_member_id}]
    end

    test "both renderers emit the preflight with the task's OWN slug interpolated", ctx do
      assert ctx.solo =~ preflight_line(@preflight_solo_id)
      assert ctx.member =~ preflight_line(@preflight_member_id)

      # The slug is the task's, not a template literal shared by both renders.
      refute ctx.solo =~ @preflight_member_id
      refute ctx.member =~ @preflight_solo_id
    end

    test "the preflight renders as an EXECUTABLE line, not a comment", ctx do
      # A `=~` assertion cannot tell `if [ -d … ]; then …` from
      # `# if [ -d … ]; then …` — verified by mutation, the commented-out form
      # survived every other assertion in this describe. So pin the whole line,
      # trimmed, by equality: that refuses ANY prefix (a `#`, an `echo`, a
      # `true &&`) rather than enumerating the ones anyone thought of.
      for {prompt, id} <- preflight_prompts(ctx) do
        lines =
          prompt
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "rev-parse --abbrev-ref HEAD"))
          |> Enum.map(&String.trim/1)

        assert lines == [preflight_line(id)],
               "the preflight must be exactly one runnable command line, got: #{inspect(lines)}"
      end
    end

    test "both renderers tell the executor to refuse a mismatched worktree", ctx do
      for {prompt, id} <- preflight_prompts(ctx) do
        assert prompt =~ "Preflight printed ANYTHING ELSE: STOP."
        assert prompt =~ "do NOT `git worktree add` over it"

        assert prompt =~
                 "Call `report_blocker` naming both the expected branch `task/#{id}` " <>
                   "and the actual branch the preflight printed"

        # A refusal with no permitted alternative is what left the second
        # executor in the incident with no correct move. Both other outcomes
        # must resolve to a named action.
        assert prompt =~ "Preflight printed NOTHING: the worktree does not exist."
        assert prompt =~ "this is a redispatch of THIS task"
      end
    end

    test "the preflight renders BEFORE git worktree add, not after it", ctx do
      for {prompt, id} <- preflight_prompts(ctx) do
        {preflight_at, _} = :binary.match(prompt, preflight_line(id))
        {add_at, _} = :binary.match(prompt, "git worktree add ../worktrees/#{id}")

        assert preflight_at < add_at,
               "an instruction rendered AFTER the destructive command is decoration; " <>
                 "preflight at #{preflight_at}, `git worktree add` at #{add_at}"
      end
    end

    test "step 4 no longer forbids reusing this task's own worktree", ctx do
      for {prompt, id} <- preflight_prompts(ctx) do
        # The old wording ("NEVER work on an existing branch. ALWAYS branch from
        # latest origin/<default>") is false on every redispatch and contradicts
        # the preflight's reuse case. It must be gone, not merely supplemented.
        refute prompt =~ "NEVER work on an existing branch"
        assert prompt =~ "NEVER work on ANOTHER task's branch"
        assert prompt =~ "reuse an existing worktree ONLY when its HEAD is `task/#{id}`"
      end
    end

    test "the two renderers emit a byte-identical guard, modulo the slug", ctx do
      guard_of = fn prompt, id ->
        prompt
        |> String.split("\n")
        |> Enum.filter(&(String.contains?(&1, "reflight") or String.contains?(&1, "rev-parse")))
        |> Enum.map_join("\n", &String.replace(&1, id, "<SLUG>"))
      end

      solo_guard = guard_of.(ctx.solo, @preflight_solo_id)

      refute solo_guard == "", "the guard did not render at all"
      assert solo_guard == guard_of.(ctx.member, @preflight_member_id)
    end

    # HOW THE BLOCK ACTUALLY DISAPPEARS NOW (rewritten, task 019fba28 v2
    # stage 3). This comment used to say the strip "runs from
    # `## Git Workflow (CRITICAL)` to the next `The attention signal` marker
    # with the /s flag, so the added lines are consumed along with the rest",
    # and cited the two placeholder-repo tests as proof the invariant holds.
    # BOTH HALVES OF THAT ARE NOW WRONG.
    #
    #   * There is no `/s` regex any more, and no `\z` alternative. v2 stage 2
    #     rewrote `maybe_strip_git_workflow/2` to bound the block with the
    #     FIRST `HeartbeatScheduler.context_anchors/0` entry occurring after
    #     the heading, and to FAIL CLOSED — a heading it cannot bound is left
    #     in place and a `Logger.warning` is emitted. The old `|\z` branch was
    #     the regression: once v1 deleted "The attention signal …" from the
    #     dispatch bodies, the lazy quantifier ran to end-of-string and a
    #     repo-less execution dispatch lost 8,023 bytes.
    #   * On the DB-ROW path nothing is stripped at all. v2 stage 2 also made
    #     `in_progress_prompt/4` suppress `git_workflow_block` AT THE ASSIGN
    #     when `deploy_repos_present?/1` is false, so a repo-less task is never
    #     handed a block to delete. The strip is now a second line of defence
    #     for operator-customized rows that hardcode a literal git section.
    #
    # AND THESE TESTS PROVE NOTHING ABOUT THAT PATH. This file is
    # `use ExUnit.Case` with no DB ownership, so `PromptTemplates.render_template/2`
    # rescues its `Repo` call and every `dispatch_prompt/4` here silently takes
    # the HARDCODED FALLBACK. That is exactly how the regression shipped green.
    # Worse, every repo-less check in this file is a bare
    # `refute prompt =~ "Git Workflow (CRITICAL)"` — :381, :1885 and :2087 (the
    # three v2 stage 2 named, renumbered by this comment's own insertion), plus
    # :3021 and :3047. A refute cannot distinguish "correctly absent" from
    # "catastrophically deleted": an over-consuming strip satisfies one
    # perfectly.
    #
    # DB-path coverage, with survival ASSERTS and byte-offset comparisons,
    # lives in `heartbeat_scheduler_context_anchor_test.exs` (v2 stage 1) and
    # `heartbeat_scheduler_repoless_dispatch_test.exs` (v2 stage 2), both
    # `use Platform.DataCase`. The test below is kept for what it does cover:
    # that the non-stack preflight text travels with the block on the fallback
    # path, so a regression there is not misattributed to another file.
    test "a placeholder repo_url still strips the preflight along with the block" do
      {plan, stage} = simple_plan_with_stage()

      task = %{
        id: @preflight_solo_id,
        title: "Placeholder task",
        status: "in_progress",
        priority: "medium",
        project: %{
          repo_url: "https://example.invalid/local-task-lifecycle-proof",
          default_branch: "main"
        },
        stack_id: nil
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "Git Workflow (CRITICAL)"
      refute prompt =~ "rev-parse --abbrev-ref HEAD"
      refute prompt =~ "Preflight"
      refute prompt =~ "git worktree add"
    end
  end

  describe "git_workflow_section via in_progress dispatch — stack members" do
    setup do
      {plan, stage} = simple_plan_with_stage()
      {:ok, plan: plan, stage: stage}
    end

    # A `task_stacks` row as the orchestrator preloads it onto `task.stack`.
    # No `rollup_branch_ready` metadata stamp. Since task 01a05392 stage 1 the
    # stamp lands before any root is promoted, so this is the ANOMALOUS state:
    # the dispatch prompt refuses the `origin/<default_branch>` fallback and
    # tells the executor to stop (stage 4). No `status` on purpose — the
    # backstop only files a blocker for an `in_progress` stack, and that DB
    # path is covered by `heartbeat_scheduler_rollup_backstop_test.exs`.
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
        stack: meeting_module_stack_ready()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "Git Workflow (CRITICAL)"

      assert prompt =~
               "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001 origin/stack/meeting-module"

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
        stack: meeting_module_stack_ready()
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert prompt =~ "## Task Stack Membership"
      assert prompt =~ "This task is a stack member"
      assert prompt =~ "stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`"
      assert prompt =~ "Rollup branch: `stack/meeting-module`"
      # ADR-0042 Decision 2: the member is cut FROM the rollup and merges back
      # into it. The pre-01a05392 "INDEPENDENTLY" wording is gone from every
      # arm — the wrong-base state is no longer a supported mode.
      assert prompt =~ "cut from `origin/stack/meeting-module`"
      assert prompt =~ "Merge back into it via fast-forward on validation pass"
      refute prompt =~ "INDEPENDENTLY"
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
      stack = meeting_module_stack_ready()
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

    test "non-stack task dispatch has NO Task Stack Membership block but DOES use the full-UUID slug",
         %{plan: plan, stage: stage} do
      # Task 019fb949 split what membership controls. Before, membership picked
      # both the section shape AND the slug; the 8-char slug asserted here was
      # a deliberate byte-compatibility pin. The slug is now unconditional, so
      # this test pins the one thing membership still decides — the presence of
      # the `## Task Stack Membership` block — against a full-UUID slug.
      id = "019e2474-11c1-7000-8000-000000000003"

      task = %{
        id: id,
        title: "Ordinary task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      refute prompt =~ "Task Stack Membership"

      assert prompt =~
               "git worktree add ../worktrees/#{id} --track -b task/#{id} origin/task/#{id}"

      assert prompt =~ "git push -u origin task/#{id}"
      refute prompt =~ "../worktrees/019e2474 "
      refute prompt =~ "task/019e2474 "
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
    # work. Without the stamp the prompt (task 01a05392 stage 4) renders NO
    # `git worktree add` at all and tells the executor to stop and report —
    # never `origin/stack/foo` against a non-existent remote ref, and never
    # `origin/<default_branch>`, which is the divergence stage 2 escalates.

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

      # Task 01a05392 stage 4: the divergence loop lives in the prompt, since
      # the prompt is where an executor reads instructions. Rebase onto the
      # ROLLUP (never main), `--force-with-lease` (never bare `--force`), and
      # the stage 3 retry tool named exactly as declared, with THIS task's id.
      assert prompt =~ "### STACK-MEMBER GIT WORKFLOW"

      assert prompt =~
               "git fetch origin && git rebase origin/stack/meeting-module && git push --force-with-lease"

      assert prompt =~
               "call `stack_retry_member_merge` with `task_id` = `019e2474-11c1-7000-8000-000000000001`"

      refute prompt =~ "git rebase origin/main"
      refute prompt =~ "--force "
      refute prompt =~ "--force\n"
      # The ready arm never carries the stop instruction.
      refute prompt =~ "STOP — do not create a worktree or branch for this task"

      # `Base branch:` (an audit hint) still lists the project default so a
      # human reader can spot the retargeting.
      assert prompt =~ "Base branch: main"
    end

    test "stack member WITHOUT rollup_branch_ready stamp is told to STOP — no origin/<default_branch> fallback",
         %{plan: plan, stage: stage} do
      task = %{
        id: "019e2474-11c1-7000-8000-000000000001",
        title: "Stack member — missing stamp",
        status: "in_progress",
        priority: "high",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
        # No metadata stamp → the rollup branch cannot be assumed to exist.
        stack: meeting_module_stack()
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

          # The section still renders (the heading is what the strip and the
          # reader key on) but carries NO worktree/branch creation at all —
          # neither from the rollup (it may not exist) nor from main (that is
          # the divergence stage 2 escalates). `-b task/<id> origin/main` is the
          # exact instruction the old fallback rendered; a bare `main` refute
          # would be satisfied by the `Base branch: main` audit line.
          assert prompt =~ "Git Workflow (CRITICAL)"
          refute prompt =~ "git worktree add"

          refute prompt =~
                   "-b task/019e2474-11c1-7000-8000-000000000001 origin/main"

          refute prompt =~ "cut from `origin/main`"
          refute prompt =~ "INDEPENDENTLY"

          # The stop-and-report instruction, verbatim from the stop arm.
          assert prompt =~ "STOP — do not create a worktree or branch for this task"
          assert prompt =~ "there is NO supported fallback"
          assert prompt =~ "Call `report_blocker` now (needs_human: true)"
          assert prompt =~ "the missing `rollup_branch_ready` stamp"
          assert prompt =~ "Stop and report a blocker; do not proceed from `origin/main`."

          # The Task Stack Membership block still names the rollup branch — the
          # rollup exists at the schema level even if not yet pushed.
          assert prompt =~ "Rollup branch: `stack/meeting-module`"
          assert prompt =~ "stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`"
        end)

      # The anomaly is auditable — the warning names the stack and member so
      # ops can spot repeat offenders.
      assert log =~ "rollup not yet ready"
      assert log =~ "019e2782-09d6-7e2c-9502-c106290e5add"
      assert log =~ "019e2474-11c1-7000-8000-000000000001"
    end

    test "non-stack task dispatch is unchanged by the rollup-HEAD retargeting", %{
      plan: plan,
      stage: stage
    } do
      # Regression guard: only stack members participate in the retargeting.
      # The slug is full-UUID for everyone since task 019fb949, so the thing
      # under test here is the PARENT ref (origin/main, not origin/stack/…).
      id = "019e2474-11c1-7000-8000-000000000009"

      task = %{
        id: id,
        title: "Ordinary task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      # Full-UUID slug, tracking its own pre-created ref, no stack block, no
      # rollup ref anywhere.
      assert prompt =~
               "git worktree add ../worktrees/#{id} --track -b task/#{id} origin/task/#{id}"

      refute prompt =~ "Task Stack Membership"
      refute prompt =~ "origin/stack/"
      refute prompt =~ "rollup_branch_ready"
    end
  end

  # ── Task 01a001ac stage 5 ────────────────────────────────────────────────
  # The non-stack worktree command TRACKS the ref the router pre-creates at the
  # first execution dispatch instead of CREATING a local branch off the default
  # branch. The create form is what let task 01a00161 push `task/ext-app-badge`
  # instead of its recorded branch: `-b <name> origin/main` succeeds no matter
  # what the remote holds, so nothing downstream of it can tell a
  # correctly-provisioned executor from a confused one.
  #
  # Stack members are deliberately EXCLUDED — nothing pre-creates a member ref,
  # so a track form there would fail on every dispatch.
  describe "non-stack worktree tracks origin/task/<uuid> (task 01a001ac)" do
    @track_id "01a001ac-0ad8-7ece-bea6-2c524238fb86"

    defp track_task(overrides \\ []) do
      Enum.into(overrides, %{
        id: @track_id,
        title: "Tracking task",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"},
        stack_id: nil
      })
    end

    defp track_prompt(task) do
      {plan, stage} = simple_plan_with_stage()
      HeartbeatScheduler.dispatch_prompt(task, plan, stage)
    end

    test "the rendered add command uses --track against origin/task/<full uuid>" do
      prompt = track_prompt(track_task())

      # Anti-vacuity: the block must actually be present.
      assert prompt =~ "Git Workflow (CRITICAL)"

      assert prompt =~
               "git worktree add ../worktrees/#{@track_id} --track -b task/#{@track_id} origin/task/#{@track_id}"
    end

    test "the bare CREATE form is gone from the non-stack block" do
      prompt = track_prompt(track_task())

      refute prompt =~ "-b task/#{@track_id} origin/main"
    end

    test "the prompt forbids renaming, re-pointing, or reporting a different branch" do
      prompt = track_prompt(track_task())

      assert prompt =~ "Do NOT rename the branch"
      assert prompt =~ "do NOT re-point it at another name"
      assert prompt =~ "do NOT report a DIFFERENT branch back to Burrow"
      assert prompt =~ "an executor-reported branch name is never authoritative"
    end

    test "an absent ref is a report_blocker, NOT a fallback to the create form" do
      prompt = track_prompt(track_task())

      assert prompt =~ "FAILS LOUDLY"
      assert prompt =~ "NOT to fall back to creating a branch from origin/main"
    end

    test "the worktree preflight and its three outcome bullets are intact" do
      prompt = track_prompt(track_task())

      assert prompt =~
               "if [ -d ../worktrees/#{@track_id} ]; then git -C ../worktrees/#{@track_id} rev-parse --abbrev-ref HEAD; fi"

      assert prompt =~ "Preflight printed NOTHING"
      assert prompt =~ "Preflight printed exactly `task/#{@track_id}`"
      assert prompt =~ "Preflight printed ANYTHING ELSE"
      assert prompt =~ "reuse an existing worktree ONLY when its HEAD is `task/#{@track_id}`"
    end

    test "the stack-member section is UNCHANGED — it still creates from the rollup parent" do
      task =
        track_task(
          stack_id: "019e2782-09d6-7e2c-9502-c106290e5add",
          stack: meeting_module_stack_ready()
        )

      prompt = track_prompt(task)

      assert prompt =~
               "git worktree add ../worktrees/#{@track_id} -b task/#{@track_id} origin/stack/meeting-module"

      refute prompt =~ "--track"
      assert prompt =~ "Task Stack Membership"
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

    test "deploying dispatch for a non-stack task references the full-UUID branch" do
      # Was "…references the 8-char branch unchanged". The deploy phase has to
      # name the branch the in_progress dispatch told the executor to push; task
      # 019fb949 made that the full UUID for every task, so an 8-char reference
      # here would point the deployer at a ref nobody created.
      id = "019e2474-11c1-7000-8000-000000000002"

      task = %{
        id: id,
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

      assert prompt =~ "pushed to `task/#{id}`"
      refute prompt =~ "pushed to `task/019e2474`"
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

    test "e2e review assigns for a non-stack task carry the full-UUID slug" do
      # Was "…carry the 8-char slug unchanged". This assign is the reviewer's
      # only pointer to a tree, so after task 019fb949 it has to name the
      # full-UUID worktree the executor actually created.
      id = "019e2474-11c1-7000-8000-000000000002"

      task = %{
        id: id,
        execution_space_id: "space-2",
        project: %{repo_url: "https://github.com/test/app"},
        stack_id: nil
      }

      pending = [%{id: "val-e2e-2", kind: "e2e_behavior", evaluation_payload: %{"setup" => "y"}}]

      {_template_slug, assigns} = HeartbeatScheduler.select_review_template(pending, task)

      assert assigns.task_slug == id
    end
  end

  # Task 019fb949 stage 4. Stage 2 changed what NEW dispatches create; this
  # block covers the tasks that change strands. A task already in flight was
  # told to push `task/<first-hyphen-segment>` and its branch sits on the
  # remote under that name, but its deploy dispatch now names
  # `task/<full-uuid>` — a ref nobody created. Deploy is where the two meet,
  # because it is the first step that touches a ref an earlier phase made.
  #
  # The commands are pinned by EQUALITY over the backtick-delimited spans of
  # the recovery line rather than by `=~` on any one of them. A substring
  # match is satisfied by a truncated, unquoted or `--heads`-less variant that
  # still contains the fragment someone thought to assert on; the span list
  # refuses everything it is not.
  describe "transitional branch-name recovery in the pr_merge deploy flow" do
    @recovery_marker "ls-remote"

    defp deploying_prompt(id, opts \\ []) do
      strategy =
        Keyword.get(opts, :deploy_strategy, %{
          "type" => "pr_merge",
          "config" => %{"auto_merge" => false}
        })

      task = %{
        id: id,
        title: "Transitional deploy",
        description: "Ship it",
        status: "deploying",
        priority: "high",
        deploy_strategy: strategy,
        project: %{repo_url: "https://github.com/test/app", default_branch: "main"},
        stack_id: Keyword.get(opts, :stack_id)
      }

      plan = %{version: 1, stages: [%{}, %{}]}

      stage = %{
        id: "stage-deploy-transitional",
        position: 2,
        name: "Deploy",
        validations: [%{id: "val-pr-merged-transitional", kind: "pr_merged"}]
      }

      HeartbeatScheduler.dispatch_prompt(task, plan, stage)
    end

    defp recovery_lines(prompt) do
      prompt
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, @recovery_marker))
      |> Enum.map(&String.trim/1)
    end

    defp backtick_spans(line) do
      ~r/`([^`]+)`/
      |> Regex.scan(line, capture: :all_but_first)
      |> List.flatten()
    end

    test "the recovery line carries exactly the two ls-remote commands, full id then prefix" do
      id = "019fb90f-36e3-7bff-a6f1-69cd689faa59"

      lines = recovery_lines(deploying_prompt(id))

      assert length(lines) == 1,
             "the recovery guidance must be exactly one line, got: #{inspect(lines)}"

      [line] = lines

      assert backtick_spans(line) == [
               "git ls-remote --heads origin 'task/#{id}'",
               "git ls-remote --heads origin 'task/019fb90f*'",
               "task/#{id}"
             ]
    end

    test "the recovered prefix is derived from the id, strictly shorter than it" do
      # Derived from the rendered output rather than compared to a literal:
      # the defect this whole task exists to fix is a slug that was SHORTER
      # than the id it named, so the assertion has to be about the relation
      # between the two strings, not about one string someone typed out. A
      # mutation that hands `legacy_branch_prefix` the full slug renders a
      # perfectly plausible line and is caught only here and by the span pin.
      id = "019fb90f-6226-7c68-9ec2-7bbc9378e8e2"
      [line] = recovery_lines(deploying_prompt(id))

      assert [_full_ref_cmd, prefix_cmd, _new_dispatch_ref] = backtick_spans(line)
      assert [prefix] = Regex.run(~r/'task\/([^*']+)\*'/, prefix_cmd, capture: :all_but_first)

      assert String.starts_with?(id, prefix),
             "the recovery glob `#{prefix}` is not a prefix of `#{id}` — it would list " <>
               "branches belonging to unrelated tasks"

      assert byte_size(prefix) < byte_size(id),
             "the recovery glob equals the full id, so it can only find the branch that " <>
               "was already established to be missing"

      assert prefix == hd(String.split(id, "-"))
    end

    test "recovery is offered before the PR is opened, not after" do
      # An instruction to find the right branch that renders after `2. Open a
      # PR` is decoration: by then the deployer has already opened a PR
      # against a ref that does not exist. Same reasoning as the stage-3
      # preflight ordering assertion.
      prompt = deploying_prompt("019fb90f-36e3-7bff-a6f1-69cd689faa59")

      assert {recovery_at, _} = :binary.match(prompt, @recovery_marker)
      assert {open_pr_at, _} = :binary.match(prompt, "2. Open a PR against")
      assert recovery_at < open_pr_at
    end

    test "a stack member's deploy dispatch carries the same recovery guidance" do
      # Members were switched to the full uuid earlier than non-stack tasks,
      # but a member whose branch predates THAT change is stranded the same
      # way, and the deployer fetching `task/<8-char>` is a failure this repo
      # has already seen. Scoping the recovery to non-stack tasks would leave
      # that hole open.
      id = "019fb90f-36e3-7bff-a6f1-69cd689faa59"

      prompt =
        deploying_prompt(id,
          stack_id: "019e2782-09d6-7e2c-9502-c106290e5add"
        )

      assert [line] = recovery_lines(prompt)
      assert hd(backtick_spans(line)) == "git ls-remote --heads origin 'task/#{id}'"
    end

    test "no other deploy strategy renders the recovery line" do
      # docker_deploy and manual never reference a task branch, so a recovery
      # line there would be advice about a ref the flow does not use.
      for strategy <- [
            %{"type" => "docker_deploy", "config" => %{"host" => "h", "image" => "i"}},
            %{"type" => "manual", "config" => %{}}
          ] do
        prompt =
          deploying_prompt("019fb90f-36e3-7bff-a6f1-69cd689faa59", deploy_strategy: strategy)

        assert recovery_lines(prompt) == [],
               "#{strategy["type"]} rendered transitional pr_merge recovery guidance"
      end
    end

    # Task 01a001ac stage 4. The recovery line above is a conditional the
    # deployer runs; these cover the observation Suite already made through
    # `BranchReconciler`. The ordinary prompt must stay byte-identical, so
    # every negative here is paired against a rendered positive from the same
    # helper — a mismatch line that never renders at all would satisfy the
    # `:match` / `:unknown` assertions while proving nothing.
    @mismatch_marker "do not assume the recorded name"

    defmodule MismatchRunner do
      @moduledoc false
      @behaviour Platform.Tasks.BranchProvisioner.Runner

      @impl true
      def branch_head_sha(_args), do: {:error, :not_stubbed}

      @impl true
      def default_branch_sha(_), do: {:error, :not_used}

      @impl true
      def create_ref(_), do: {:error, :not_used}

      @impl true
      def list_matching_refs(_), do: {:ok, ["refs/heads/task/ext-app-badge"]}
    end

    defmodule MatchRunner do
      @moduledoc false
      @behaviour Platform.Tasks.BranchProvisioner.Runner

      @impl true
      def branch_head_sha(_args), do: {:error, :not_stubbed}

      @impl true
      def default_branch_sha(_), do: {:error, :not_used}

      @impl true
      def create_ref(_), do: {:error, :not_used}

      @impl true
      def list_matching_refs(%{ref: "heads/" <> prefix}),
        do: {:ok, ["refs/heads/" <> prefix <> "-0ad8-7ece-bea6-2c524238fb86"]}
    end

    defp with_runner(runner, fun) do
      previous = Application.get_env(:platform, :branch_provisioner)
      Application.put_env(:platform, :branch_provisioner, runner: runner)

      try do
        fun.()
      after
        if previous,
          do: Application.put_env(:platform, :branch_provisioner, previous),
          else: Application.delete_env(:platform, :branch_provisioner)
      end
    end

    @reconciler_id "01a001ac-0ad8-7ece-bea6-2c524238fb86"

    test "a mismatch renders a line naming BOTH the recorded and the found branch" do
      prompt = with_runner(MismatchRunner, fn -> deploying_prompt(@reconciler_id) end)

      assert [line] =
               prompt
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, @mismatch_marker))
               |> Enum.map(&String.trim/1)

      assert line =~ "`task/#{@reconciler_id}`"
      assert line =~ "`task/ext-app-badge`"
    end

    test ":match renders nothing extra and leaves the prompt byte-identical" do
      baseline = with_runner(MismatchRunner, fn -> deploying_prompt(@reconciler_id) end)
      matched = with_runner(MatchRunner, fn -> deploying_prompt(@reconciler_id) end)

      # Positive control: the helper CAN produce the mismatch line, so its
      # absence below is a fact about `:match`, not about the fixture.
      assert baseline =~ @mismatch_marker
      refute matched =~ @mismatch_marker

      # The pre-existing recovery line is untouched by this change.
      assert [line] = recovery_lines(matched)

      assert backtick_spans(line) == [
               "git ls-remote --heads origin 'task/#{@reconciler_id}'",
               "git ls-remote --heads origin 'task/01a001ac*'",
               "task/#{@reconciler_id}"
             ]
    end

    test ":unknown renders nothing extra either" do
      # `NoopRunner` is the configured test runner and answers
      # `{:error, :branch_provisioning_disabled}` — an unresolvable probe.
      prompt = deploying_prompt(@reconciler_id)

      refute prompt =~ @mismatch_marker
      assert [_line] = recovery_lines(prompt)
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
      #
      # The slug is the FULL task id: task 019fb949 deleted the truncating
      # helper this test's literals were written against. Derived through
      # `member_slug/1`, the chokepoint the renderer uses, rather than spelled
      # out again — a hand-written literal here is a second derivation, and
      # this suite has already been bitten by one (see
      # `deploy_merge_reconciler_test.exs`).
      slug = HeartbeatScheduler.member_slug(task)

      # Task 01a001ac stage 5: every clone TRACKS the pre-created ref rather
      # than minting a local branch off the default branch.
      assert section =~
               "../worktrees/#{slug}-core --track -b task/#{slug} origin/task/#{slug}"

      assert section =~
               "../worktrees/#{slug}-openclaw-suite-channel --track -b task/#{slug} origin/task/#{slug}"

      refute section =~ "-b task/#{slug} origin/main"
      refute section =~ "-b task/#{slug}-core"

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
      assert core_block =~ "Strategy config declares auto_merge: true"
      refute channel_block =~ "Strategy config declares auto_merge: true"
      # 01a08d81: the declaration must not be rendered as an armed state.
      assert core_block =~ "gh pr view <n> --json autoMergeRequest"
      refute prompt =~ "it will merge automatically"
      refute prompt =~ "auto-merge is enabled"

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
      assert prompt =~ "Merge the PR by hand in GitHub once CI is green"
    end

    test "declaring no repos renders the byte-identical Git Workflow section" do
      # Backward-compat pin. Every task in the system today declares no
      # `"repos"`, so this is the prompt almost every executor receives. If a
      # future change to the multi-repo block leaks into the single-repo path,
      # this fails with a diff rather than silently rewording nine thousand
      # dispatches.
      #
      # RE-BASELINED by task 019fb949, which is the only other change entitled
      # to move these bytes. Two things in the literal below are no longer what
      # 019fa63a pinned at a6664ede, and both are that task's deliberate
      # subject rather than multi-repo leakage:
      #
      #   * the slug is the FULL task id, not its first hyphen-segment — the
      #     8-char form is constant across a ~65s UUIDv7 bucket, so siblings
      #     collided on one branch and one worktree; and
      #   * the worktree preflight and the reworded step 4, which stop an
      #     executor adopting a directory that belongs to another task.
      #
      # What this test still guards is unchanged and is the reason to keep the
      # byte-for-byte form: nothing from `### Repositories in scope` may appear
      # here, and no line may differ from the single-repo rendering except by a
      # change that owns it.
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

      1. Create a worktree TRACKING the branch Burrow already created for this task:
         ```
         git fetch origin
         # Preflight: if the worktree already exists, it MUST be on this task's branch.
         if [ -d ../worktrees/task-1234abcd ]; then git -C ../worktrees/task-1234abcd rev-parse --abbrev-ref HEAD; fi
         git worktree add ../worktrees/task-1234abcd --track -b task/task-1234abcd origin/task/task-1234abcd
         cd ../worktrees/task-1234abcd
         ```
         - Preflight printed NOTHING: the worktree does not exist. Run `git worktree add` exactly as shown.
         - Preflight printed exactly `task/task-1234abcd`: this is a redispatch of THIS task. Skip `git worktree add`, `cd` into the existing worktree and continue on that branch.
         - Preflight printed ANYTHING ELSE: STOP. That directory belongs to another task. Do NOT `cd` into it, do NOT commit, do NOT `git worktree add` over it. Call `report_blocker` naming both the expected branch `task/task-1234abcd` and the actual branch the preflight printed.
      2. Do ALL work in the worktree directory.
      3. When implementation is complete:
         - Run the full test suite and lint checks
         - Commit all changes with a descriptive message referencing task task-1234abcd
         - Push the branch: `git push -u origin task/task-1234abcd`
         - Do NOT open a PR yet — PR opening happens in the deploy phase
      4. NEVER work on ANOTHER task's branch. `origin/task/task-1234abcd` already exists — the `--track` form above FAILS LOUDLY if it does not, which is the signal to `report_blocker`, NOT to fall back to creating a branch from origin/main; reuse an existing worktree ONLY when its HEAD is `task/task-1234abcd`.
      5. Do NOT rename the branch, do NOT re-point it at another name, and do NOT report a DIFFERENT branch back to Burrow. `task/task-1234abcd` is the only branch Burrow will merge; an executor-reported branch name is never authoritative, so pushing elsewhere and reporting it would get Burrow to merge the wrong place.
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

  # ── Stage description in the execution dispatch (task 019fba28 stage 1) ───
  #
  # This module is `use ExUnit.Case` with no DB ownership, so
  # `PromptTemplates.render_template/2` rescues its Repo call and every
  # `dispatch_prompt/4` here takes the HARDCODED FALLBACK path. That is the
  # branch these tests pin. The DB-row path — the one every migrated
  # environment actually serves — is pinned separately in
  # `heartbeat_scheduler_stage_description_test.exs`, which is `DataCase`.
  # Both are needed: deleting the assign breaks both, deleting the
  # `{{stage_description}}` placeholder from the template body breaks only the
  # DataCase one, and that asymmetry is what proves each covers its own path.
  describe "stage description in the in_progress dispatch — hardcoded fallback" do
    # A LITERAL. Never `stage.description` — an expectation re-derived from the
    # value under test cannot fail for any value that value takes.
    @sentinel "MUTATION-CONTROL-SENTINEL: the guard must be shown to fire"
    @heading "## Stage Description (authored by the planner — this is your specification)"

    defp stage_description_task do
      %{
        id: "019fba28-fadf-7fb1-804e-e62817c06211",
        title: "Carry the stage description into the execution dispatch",
        description: "Ticket body — planner-only material, must NOT reach this dispatch.",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }
    end

    defp stage_description_plan(description) do
      stage = %{
        id: "019fba30-c97d-7869-a2ec-975f0f176d3a",
        position: 1,
        name: "coding",
        description: description,
        validations: []
      }

      {%{version: 1, stages: [stage, %{}]}, stage}
    end

    test "renders the stage's own description verbatim under a labelled heading" do
      {plan, stage} = stage_description_plan("Prose before.\n\n#{@sentinel}\n\nProse after.")

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      assert prompt =~ @heading,
             "the execution dispatch must label the planner's stage description"

      assert prompt =~ @sentinel,
             "the stage description must reach the implementer verbatim"

      assert prompt =~ "Prose after.",
             "the block must not be truncated — the tail carries constraints too"
    end

    test "the description block lands after the Plan: v line, not in some other region" do
      {plan, stage} = stage_description_plan(@sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      plan_line_at = :binary.match(prompt, "Plan: v1 (stage 1/2 — coding)") |> elem(0)
      heading_at = :binary.match(prompt, @heading) |> elem(0)
      sentinel_at = :binary.match(prompt, @sentinel) |> elem(0)

      assert plan_line_at < heading_at,
             "the stage-description heading must follow the plan/stage line"

      assert heading_at < sentinel_at,
             "the sentinel must sit under its own heading"
    end

    test "a nil description renders no heading and does not crash" do
      {plan, stage} = stage_description_plan(nil)

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      refute prompt =~ "## Stage Description",
             "a nil description must render nothing at all — not a dangling heading"
    end

    test "a whitespace-only description renders no heading" do
      {plan, stage} = stage_description_plan("   ")

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      refute prompt =~ "## Stage Description",
             "a whitespace-only description must render nothing at all"
    end

    test "a stage with no description key at all renders no heading" do
      stage = %{id: "stage-no-desc", position: 1, name: "coding", validations: []}
      plan = %{version: 1, stages: [stage]}

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      refute prompt =~ "## Stage Description"
    end

    test "string-keyed description is read too (map shape from JSON payloads)" do
      stage = %{
        :id => "stage-string-key",
        :position => 1,
        :name => "coding",
        :validations => [],
        "description" => @sentinel
      }

      plan = %{version: 1, stages: [stage]}

      prompt = HeartbeatScheduler.dispatch_prompt(stage_description_task(), plan, stage)

      assert prompt =~ @sentinel
    end
  end

  # ── Stage description in the in_review dispatch (task 019fba28 stage 3) ────
  #
  # Same path note as the block above: this module has no DB ownership, so
  # every `dispatch_prompt/4` here renders the HARDCODED FALLBACK
  # (`hardcoded_dispatch_in_review/4`). The DB-row path — the one every
  # migrated environment actually serves — is pinned in
  # `heartbeat_scheduler_in_review_stage_description_test.exs`, which is
  # `DataCase`. The asymmetry is deliberate and is what proves each file covers
  # its own branch: dropping the assign from `review_prompt/5` reddens the
  # DataCase file only (this file never reaches that function), while dropping
  # the `#{stage_description}` interpolation from the hardcoded body reddens
  # this one only.
  describe "stage description in the in_review dispatch — hardcoded fallback" do
    # LITERALS. Never `stage.description`, and never a value recomputed by
    # calling the formatter under test.
    @review_sentinel "MUTATION-CONTROL-SENTINEL: the reviewer must be shown the specification"
    @review_tail_sentinel "NOT-IN-SCOPE-SENTINEL: the tail of the block must survive too"
    @review_heading "## Stage Description (authored by the planner — this is your specification)"

    defp review_description_task(status \\ "in_review") do
      %{
        id: "019fba28-fadf-7fb1-804e-e62817c06211",
        title: "Carry the stage description into the human-gate dispatch",
        description: "Ticket body — planner-only material, must NOT reach this dispatch.",
        status: status,
        priority: "medium",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }
    end

    # All-pending-manual_approval routes to `dispatch.in_review` via
    # `DispatchPhase.resolve/3`.
    defp review_description_plan(description) do
      stage = %{
        id: "019fba30-c97e-73b8-9480-9c93e6ce6a95",
        position: 1,
        name: "human gate",
        description: description,
        validations: [%{id: "val-manual-1", kind: "manual_approval", status: "pending"}]
      }

      {%{version: 1, stages: [stage, %{}]}, stage}
    end

    # The `"Deploy: "` prefix is what `DeployStageBuilder.deploy_stage_name?/1`
    # keys on, so this routes for real rather than by assertion.
    defp deploy_description_plan(description) do
      stage = %{
        id: "019fba30-dead-73b8-9480-9c93e6ce6a95",
        position: 2,
        name: "Deploy: PR merge",
        description: description,
        validations: [%{id: "val-pr-merged-1", kind: "pr_merged", status: "pending"}]
      }

      {%{version: 1, stages: [%{}, stage]}, stage}
    end

    test "renders the stage's own description verbatim under a labelled heading" do
      {plan, stage} =
        review_description_plan(
          "Prose before.\n\n#{@review_sentinel}\n\n#{@review_tail_sentinel}\n"
        )

      prompt = HeartbeatScheduler.dispatch_prompt(review_description_task(), plan, stage)

      assert prompt =~ @review_heading,
             "the review dispatch must label the planner's stage description"

      assert prompt =~ @review_sentinel,
             "the reviewer judges the stage against this text — it must arrive verbatim"

      assert prompt =~ @review_tail_sentinel,
             "the block must not be truncated — the tail carries constraints too"
    end

    test "the description block lands after the Plan: v line, not in some other region" do
      {plan, stage} = review_description_plan(@review_sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(review_description_task(), plan, stage)

      plan_line_at = :binary.match(prompt, "Plan: v1 (stage 1/2 — human gate)") |> elem(0)
      heading_at = :binary.match(prompt, @review_heading) |> elem(0)
      sentinel_at = :binary.match(prompt, @review_sentinel) |> elem(0)

      assert plan_line_at < heading_at
      assert heading_at < sentinel_at
    end

    test "nil and whitespace-only descriptions render no heading and do not crash" do
      for description <- [nil, "   ", "\n\n"] do
        {plan, stage} = review_description_plan(description)

        prompt = HeartbeatScheduler.dispatch_prompt(review_description_task(), plan, stage)

        refute prompt =~ "## Stage Description",
               "description #{inspect(description)} must render nothing, not a dangling heading"
      end
    end

    test "the fallback body no longer points the reviewer at a `context` field it cannot read" do
      {plan, stage} = review_description_plan(@review_sentinel)

      prompt = HeartbeatScheduler.dispatch_prompt(review_description_task(), plan, stage)

      refute prompt =~ "Use it as your source of truth"

      assert prompt =~
               "The Stage Description block above is the planner's own authored specification"

      assert prompt =~ "call `suite_plan_get` and read the stage description there"
    end

    test "DISCRIMINATION: the same description routed to deploy carries no sentinel" do
      # Without this, the tests above cannot distinguish "in_review carries the
      # description" from "every dispatch carries it" — which is the claim
      # actually being made. Identical description text on both fixtures; the
      # only difference is which stage `DispatchPhase.resolve/3` routes.
      description = "Prose before.\n\n#{@review_sentinel}\n\n#{@review_tail_sentinel}\n"

      {review_plan, review_stage} = review_description_plan(description)
      {deploy_plan, deploy_stage} = deploy_description_plan(description)

      review_prompt =
        HeartbeatScheduler.dispatch_prompt(review_description_task(), review_plan, review_stage)

      deploy_prompt =
        HeartbeatScheduler.dispatch_prompt(
          review_description_task("deploying"),
          deploy_plan,
          deploy_stage
        )

      # Positive half — proves the fixture text is capable of appearing at all.
      assert review_prompt =~ @review_sentinel
      assert review_prompt =~ @review_heading

      # The routing really happened: this is the deploy body, not the review one.
      assert deploy_prompt =~ "Deploy Stage Contract",
             "the deploy fixture must actually route to dispatch.deploying, or the " <>
               "refutes below are refuting the wrong prompt"

      refute deploy_prompt =~ @review_heading,
             "a deploy stage's description is engine-synthesized boilerplate from " <>
               "DeployStageBuilder — carrying it buys nothing and costs context"

      refute deploy_prompt =~ @review_sentinel
      refute deploy_prompt =~ @review_tail_sentinel
    end
  end

  describe "dispatch fallbacks DERIVE from the template descriptor (task 019ff10f)" do
    # These tests run with NO database row for the slug — this module is a plain
    # `ExUnit.Case` with no sandbox, so `PromptTemplates.render_template/2`'s
    # blanket rescue answers `{:error, :not_found}`, which is the real
    # production trigger (row missing, or DB unreachable). What renders is the
    # fallback.
    #
    # ## What "derivation" is asserted as, and why not a literal
    #
    # A test that asserted `prompt =~ "design_critique_request"` would pass on
    # d32dd1b1 too, where that paragraph was HAND-COPIED into the scheduler's
    # fallback string. It would pin today's tools and say nothing about
    # tomorrow's. So the discriminator is computed at run time: the tool names
    # the DESCRIPTOR names, minus every name that appears anywhere in
    # `heartbeat_scheduler.ex`'s source. A name in that difference cannot have
    # reached the rendered body by being restated in the scheduler — the only
    # route left is derivation from the descriptor.
    #
    # That set is the in-test equivalent of "add a tool mention to the source
    # descriptor and watch it appear in the fallback with no scheduler edit":
    # the descriptor is a compile-time module attribute, so a test cannot
    # rewrite it in place, but quantifying over the set re-evaluates the same
    # claim for every tool on every run — including one added tomorrow, with no
    # edit here.
    @scheduler_source "lib/platform/orchestration/heartbeat_scheduler.ex"

    # Same shape the parity test extracts: a backticked snake_case identifier.
    @tool_like ~r/`([a-z][a-z0-9]*(?:[._][a-z0-9]+)+)\(?/

    defp descriptor_only_tools(slug) do
      source = File.read!(@scheduler_source)

      @tool_like
      |> Regex.scan(PromptTemplates.default_content_for_slug(slug))
      |> Enum.map(fn [_full, name] -> name end)
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(source, &1))
    end

    test "the in_review fallback carries tool guidance that exists ONLY in the descriptor" do
      task = %{
        id: "task-derive-ir",
        title: "Derivation guard in_review",
        description: "Body",
        status: "in_review",
        priority: "medium"
      }

      plan = %{version: 1, stages: [%{}]}

      stage = %{
        id: "stage-derive-ir",
        position: 1,
        name: "review",
        validations: [%{id: "val-derive-manual", kind: "manual_approval", status: "pending"}]
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      discriminators = descriptor_only_tools("dispatch.in_review")

      # Anti-vacuity: an empty difference would make the loop below assert
      # nothing. It is also exactly the state d32dd1b1 was in for the tools it
      # hand-copied — the copy put them back into the scheduler source, so
      # nothing discriminated.
      refute discriminators == [],
             "the dispatch.in_review descriptor names no tool that is absent from " <>
               "#{@scheduler_source}. Either the fallback has been hand-restated back " <>
               "into the scheduler (the drift this guards against) or the descriptor " <>
               "stopped naming tools — do not delete this test to make it pass."

      for tool <- discriminators do
        assert prompt =~ tool,
               "`#{tool}` is named by the dispatch.in_review descriptor and appears " <>
                 "nowhere in #{@scheduler_source}, so the rendered fallback can only " <>
                 "carry it by DERIVING from the descriptor. It is missing, which means " <>
                 "the fallback is a restatement again."
      end
    end

    test "the planning fallback carries tool guidance that exists ONLY in the descriptor" do
      task = %{
        title: "Derivation guard planning",
        description: "Body",
        status: "planning",
        priority: "medium"
      }

      prompt = HeartbeatScheduler.dispatch_prompt(task, nil, nil)

      discriminators = descriptor_only_tools("dispatch.planning")

      refute discriminators == [],
             "the dispatch.planning descriptor names no tool absent from #{@scheduler_source}"

      for tool <- discriminators do
        assert prompt =~ tool,
               "`#{tool}` is descriptor-only and missing from the planning fallback"
      end
    end

    test "render_default/2 issues no database query" do
      # The branch's whole precondition is that the DB may be unreachable, so
      # the derivation path must not query. Asserted through Ecto's query
      # telemetry rather than by reading the code: a Repo call added inside
      # `resolve_content/3` (or anywhere below) would emit here even though the
      # sandbox would happily serve it in a DataCase.
      handler = {__MODULE__, :repo_free, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          # Ecto emits query telemetry in the process that RAN the query, and
          # this suite is `async: true` — without the pid filter a sibling
          # test's query lands in this mailbox and reds a correct
          # implementation.
          if self() == test_pid, do: send(test_pid, {:repo_query, meta[:query]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, body} =
               PromptTemplates.render_default("dispatch.in_review", %{task_title: "T"})

      assert body =~ "T", "the interpolation must actually have run"

      refute_receive {:repo_query, _}, 50

      assert PromptTemplates.render_default("no.such.slug", %{}) == {:error, :not_found}
    end
  end

  # The "## Deploy Stage Contract" section, up to the next `## ` heading or the
  # attention-signal anchor, whichever comes first.
  defp deploy_contract_section(prompt) do
    [_, rest] = String.split(prompt, "## Deploy Stage Contract", parts: 2)

    ["\n## ", "\nThe attention signal"]
    |> Enum.reduce(rest, fn anchor, acc ->
      acc |> String.split(anchor, parts: 2) |> hd()
    end)
  end
end
