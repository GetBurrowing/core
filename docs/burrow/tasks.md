---
title: Tasks
summary: A task's lifecycle from planning to deploy, and how the task router dispatches agents.
order: 4
verified_at: "837fba6e"
---

# Tasks

## What it is

A task is one unit of work on a project's board. It has a description, a priority, a sponsor (the person who shepherds it) and assignees for each phase: planning, execution and review. Its plan holds the stages that do the work and the checks that prove it.

### Statuses

`backlog`, `planning`, `in_progress`, `in_review`, `deploying`, `done`, plus `blocked`, `cancelled` and `stack_pending` (a stack member waiting its turn).

### The lifecycle

1. **Planning.** The planning assignee writes a plan: ordered stages, each with the validations that prove it. The plan starts as a draft and is submitted for review (`pending_review`).
2. **Approval.** An architect agent may review the plan first; while that review is open, nobody can approve it. Then a person approves it, or Burrow approves it at once when the task has `auto_approve_plan` set. Approval moves the task to `in_progress`.
3. **Stages.** Stages run one at a time, in order. Each stage goes `pending`, `running`, then `passed` or `failed`. A stage passes only when every validation on it has passed or been skipped. When a stage passes, the next one starts automatically.
4. **Checks.** Validation kinds are `test_pass`, `lint_pass`, `type_check`, `ci_check`, `ci_passed`, `code_review`, `manual_approval`, `e2e_behavior` and `pr_merged`. The executor passes most of them with evidence.
5. **Review.** Behaviour checks (`e2e_behavior`) are collected into a task-level review stage at the end of the plan. When it starts, the task moves to `in_review` and a reviewer runs each scenario.
6. **The human gate.** A `manual_approval` validation waits for a person. The agent submits evidence, and a person approves or rejects each item in the task view.
7. **Deploy.** When review passes, Burrow adds a deploy stage built from the task's deploy target or the project's default strategy, and moves the task to `deploying`. For a pull-request deploy, the stage carries a `pr_merged` check for each repository, which passes when the pull request merges. The task is then `done`.

### The task router

Each active task has a router that sends work to the right agent. It dispatches when the task enters planning, when a plan is approved, and whenever a stage starts running, to the agent assigned to the current phase. The dispatch is posted in the task's execution space and carries everything needed: the task, the plan, the stage and its validation ids.

The router then watches for liveness:

- The agent must call `task_ack` within **5 minutes** of an execution, review or deploy dispatch.
- Each ack and progress event extends a **90-minute** safety net.
- If either lapses, the router posts a blocked notice that asks for a person.
- A `manual_approval` stage arms neither timer.

## When to use it

- **Any change that should be planned, checked and shipped:** create a task in the project.
- **Several tasks that must ship together:** put them in a task stack.
- **Work that needs a person's sign-off:** add a `manual_approval` validation to the stage that needs it.

## How agents use it

- **Find and shape work:** `task_create`, `task_get`, `task_list`, `task_update`, `task_start`, `task_dependencies`.
- **Planning:** `plan_create` writes a draft plan. `plan_update` rewrites a draft in place, `plan_reject` discards your own draft, and `plan_submit` sends it for review. `plan_approve` approves a plan in review once no architect review is open. `plan_get` reads the current plan.
- **Executing a stage:** call `task_ack` first, passing the id of the subagent doing the work. Then pass validations with `validation_pass` or `validation_evaluate`, with evidence, and call `stage_complete`. Use `stage_list` and `validation_list` to see what is still pending.
- **The human gate:** `review_request_create` submits labelled evidence, usually a canvas, for a `manual_approval` validation. `review_request_get` and `review_item_list` read the rulings.
- **Context for later dispatches:** `task_attach_canvas` attaches a canvas so it rides along.
- **When stuck:** `report_blocker` records a blocker. It requires three distinct attempts, an org memory reference, and the smallest action that would unblock you and who performs it.
- **When you cannot ack:** `alarm_silence` quiets the no-ack alarm for a stage you know is being worked.
- **Inspecting a task:** `task_transition_list` shows its status history, `runtime_event_list` its ack and progress events, and `execution_lease_list` its leases.
- **Closing out:** `task_complete` marks a task done. `task_close_as_delivered` records work that shipped without a plan cycle.

## Common mistakes

- **Writing a deploy stage into the plan.** Burrow adds the deploy stage itself. Plan only the implementation and its checks.
- **Acking a stage that is not running.** The ack is refused. Ack the stage your dispatch names, once it is running.
- **Stopping after one stage without saying so.** The next stage starts by itself and needs its own ack. If you are not continuing, say so in the execution space.
- **Filing a blocker to show you are alive.** A blocker parks the stage for a person. Use `task_ack` for liveness.
- **Creating a review request for a check that is not `manual_approval`.** Other kinds are passed with evidence, not by a person.
- **Rejecting a submitted plan.** `plan_reject` discards drafts only. A plan in review waits for its reviewer.

_Last verified at 837fba6e._
