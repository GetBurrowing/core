# ADR 0029: Task Lifecycle Responsibility Split

**Status:** Proposed  
**Date:** 2026-03-24  
**Related:** ADR 0018 (Tasks Persistent Model and Plan Engine), ADR 0025 (Task Router and Execution Orchestration), ADR 0026 (Task Execution Spaces), ADR 0028 (Federated Execution Leases and Runtime Adapters)

---

## Context

The current task lifecycle has the right high-level statuses (`planning`, `in_progress`, `in_review`, `done`) but the wrong responsibility boundaries.

In practice:

- **Planning** requires too many human actions before execution actually begins
- **Plan approval** moves work to an intermediate readiness state instead of meaningfully starting execution
- **In progress** often performs implementation, validations, screenshot gathering, PR preparation, and effectively completes the task
- **In review** becomes a mostly empty phase because the substantive validation already happened earlier

This creates several pathologies:

1. **Too much kickoff friction**  
   Human plan approval should mean “begin execution”, but the current flow often requires another manual “start” step.

2. **Validation happens in the wrong phase**  
   Machine checks, human approvals, and experiential review are all treated as the same kind of validation even though they belong in different phases.

3. **Manual review has a chicken-and-egg problem**  
   If a feature requires screenshots/canvas evidence and human approval, the system needs a review phase that can present those artifacts, wait for approval, and resume or reject accordingly.

4. **In-review lacks real work**  
   The review agent should exercise the feature in a local/dev environment and determine whether the implementation fulfills the task goal. Today, that work is often effectively done earlier.

5. **PR timing is too early**  
   Opening a PR during normal execution makes the review phase ceremonial. PR creation should be a consequence of successful review, not a synonym for “implementation is probably done”.

The desired outcome is a lifecycle where responsibilities are isolated and deterministic transitions are possible.

---

## Decision

Redefine the task lifecycle so each stage has a single, explicit responsibility.

### Lifecycle semantics

#### `planning`
Purpose:
- understand the task
- create the implementation/review plan
- obtain human approval of the plan

When a plan is approved:
- the task moves **directly to `in_progress`**
- no additional manual “start” action is required

Plan approval means: **execution is authorized to begin**.

#### `in_progress`
Purpose:
- implement the task
- run deterministic execution checks during implementation
- produce artifacts/evidence needed for review

Allowed activities include:
- coding / migration / wiring changes
- lint / typecheck / tests / build
- deterministic command-based smoke checks
- generation of screenshots or other evidence artifacts if needed for later review

`in_progress` ends when the implementation is ready to be exercised and judged.

At that point the task moves **deterministically to `in_review`**.

#### `in_review`
Purpose:
- exercise the feature in a local/dev environment
- check behavior against the task goal and validations
- gather screenshots/canvas artifacts
- request and await human approval where required
- decide pass/fail of the candidate implementation

This phase is agent-driven. The review agent should attempt to use the feature, observe the result, and decide whether it actually satisfies the goal.

If review fails:
- the task moves **back to `in_progress`** with a concrete reason

If review succeeds:
- the system may open a PR
- after merge/deploy completion, the task moves to `done`

#### `done`
Purpose:
- work is reviewed, accepted, merged, and deployed (or otherwise completed per task policy)

---

## Validation model split

The word “validation” currently hides two different classes of checks.

### 1. Execution checks
These are implementation-time checks that may happen in `in_progress`:
- lint passes
- typecheck passes
- tests pass
- build succeeds
- deterministic command-based smoke checks

These are useful evidence of build quality, but they do **not** replace review.

### 2. Review validations
These happen in `in_review`:
- feature behavior matches the task goal
- screenshots/canvas output match expectations
- manual approval items are presented and approved
- experiential verification by the review agent succeeds

These determine whether the candidate implementation is acceptable.

Execution checks and review validations must be modeled differently even if both are stored under a common validation framework.

---

## Review-phase manual approval

Manual approval belongs in `in_review`, not `in_progress`.

If the review agent needs human judgment:
- it should create/attach the relevant evidence (screenshots, canvas output, descriptions)
- it should move the task into a **blocked waiting-for-review** state within `in_review`
- it should stop normal progress heartbeats and instead report a structured blocked state
- approval or rejection should resume the review workflow

### Required behaviors

1. **Canvas-backed evidence presentation**  
   Review artifacts should be visible in the UI through the existing canvas mechanism.

2. **Existing approval mechanisms remain the authority**  
   This ADR does not invent a new approval primitive; it requires the existing mechanisms to be surfaced in review.

3. **Blocked review pauses heartbeat escalation**  
   The runtime should report `execution.blocked` / waiting-human-review rather than pretending the task is actively progressing.

4. **Rejection loops back to execution**  
   If review or approval fails, the task returns to `in_progress` with review findings.

---

## PR and merge timing

PR creation should happen **after successful review**, not during routine implementation.

### New sequencing
1. plan approved
2. task moves to `in_progress`
3. implementation complete
4. task moves to `in_review`
5. review passes
6. PR is opened
7. PR merges / CI deploys
8. task moves to `done`

This keeps `in_review` meaningful and prevents `in_progress` from implicitly doing the work of the review phase.

---

## State-machine implications

### Remove the extra manual kickoff after plan approval
- Plan approval should transition directly to `in_progress`
- The system should automatically begin the execution phase once the approval lands

### Deterministic transition from `in_progress` to `in_review`
- When implementation work is complete and execution checks are satisfied, move to `in_review`
- Do not wait for the review phase to be triggered manually

### Deterministic transition from `in_review` back to `in_progress`
- If review or manual approval fails, route back with structured findings

### Deterministic transition from successful review to PR/open-merge flow
- Review success should be the condition for PR creation
- `done` should reflect actual completion, not merely “PR exists”

---

## Router and runtime implications

This ADR builds on execution leases rather than replacing them.

### During `in_progress`
- runtime lease stays active while implementation work proceeds
- execution checks may generate evidence and progress updates

### During `in_review`
- review runtime lease stays active while the agent exercises the feature
- screenshot/canvas generation and experiential checks happen here

### During waiting-human-review
- runtime reports blocked state
- router does not treat the task as silently stalled
- heartbeat escalation is suspended in favor of explicit waiting state

This ensures the review phase can safely wait for human input without being mistaken for abandoned work.

---

## UI implications

This ADR implies several UI changes, though not all are required in the first implementation slice.

### Required eventually
- plan approval should visibly move the task into `in_progress`
- `in_review` should visibly host review artifacts and statuses
- manual review artifacts should display in canvas-backed UI
- approval/rejection controls should be available in the review phase
- review failure should visibly send work back to `in_progress`

### Acceptable interim state
The backend lifecycle may be corrected before the full review UI is complete, but the final architecture should assume review is a first-class active phase, not a placeholder.

---

## Consequences

### Positive
- each lifecycle stage has a clear responsibility
- plan approval becomes meaningful and deterministic
- in-review becomes a real agent-led verification phase
- manual approvals happen in the correct place
- PR timing aligns with successful review rather than implementation completion
- execution leases and blocked states map cleanly onto human review waits

### Costs
- lifecycle/state transitions will need refactoring across plan engine, router, UI, and plugin/runtime behavior
- validation storage and semantics likely need restructuring
- review tooling (canvas, screenshots, approvals) must become more integrated into the task flow

### Tradeoff accepted
We prefer a more opinionated lifecycle with stronger responsibility isolation over a looser system where every stage can do everything.

---

## Implementation direction

This ADR should land alongside the federated execution lease/runtime adapter work, not after it.

The immediate direction is:
1. keep proving the plugin/runtime loop locally in the dev environment
2. adjust lifecycle semantics so plan approval starts execution directly
3. move substantive validation behavior into `in_review`
4. model waiting-human-review as an explicit blocked review state
5. only then finalize PR/open-merge behavior in the task flow

The requirement for acceptance is not just passing tests, but a locally proven end-to-end task lifecycle through the real plugin infrastructure.

---

## Summary

The task system should separate **planning**, **implementation**, **review**, and **completion** into distinct responsibilities.

- Plan approval should begin execution
- Implementation should happen in `in_progress`
- Validation and experiential review should happen in `in_review`
- Manual approval should wait in review, not in progress
- PR creation should follow successful review

This makes the task lifecycle reliable, comprehensible, and compatible with agent-driven review and human approval.
