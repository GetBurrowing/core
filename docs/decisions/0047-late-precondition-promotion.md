# ADR 0047 — Late-precondition promotion: a census of cascade-only status transitions

**Status:** Accepted

Census only — this ADR changes no runtime behaviour.

Date: 2026-08-07

## Context

The orchestration engine advances tasks, stacks and stages through statuses.
Most of those advances are written from *inside another operation's cascade*
(a function call made while some other transition is committing) or from an
*in-memory PubSub handler* (a `handle_info/2` in a per-task router process).

Both are **edge-triggered**. They fire at the instant a precondition becomes
true *while the triggering code is running*. Neither fires when the same
precondition becomes true **later** — because the plan was approved after the
stack opened, because the router was not alive when the broadcast went out,
because the process restarted mid-flight, or because the state was reached by
a code path that does not cross the specific edge the writer watches.

The defect class this ADR names:

> **A status transition whose only writer sits inside another operation's
> cascade or inside an in-memory PubSub handler, with no path that fires when
> the precondition becomes true LATER.**

Four instances were observed in a single day. Those four are merely the
instances that happened to be observed. This census exists so the search is
exhaustive rather than lucky, which is why it records the sites that turn out
**fine** as well as the ones that do not.

## Method

Writer set enumerated by grepping the transition entry points across
`apps/platform/lib`:

```
grep -rn 'transition_task\|update_stack_status\|PlanEngine.start_stage\|Tasks.update_task' \
  apps/platform/lib --include='*.ex'
```

Every call site was recorded with (a) its target status, (b) its trigger
(cascade call / PubSub `handle_info` / periodic tick in
`apps/platform/lib/platform/orchestration/task_router_watcher.ex` / operator
action), and (c) whether **any** reconcile or tick re-evaluates the same
precondition.

Line numbers are as of the commit that introduces this ADR. There is no
`update_stack_status/*` function in the tree; stack status is written inside
`do_start_stack/1` and the deploy path, so those are the sites recorded.

## Buckets

- `EVENT_ONLY_NO_RECONCILE` — **defect.** One edge-triggered writer, no timer
  or reconcile re-evaluates the precondition.
- `EVENT_PLUS_RECONCILE` — fine. An event path *and* a tick evaluate the same
  predicate.
- `CASCADE_ONLY_BY_DESIGN` — fine, with a stated reason: the precondition
  cannot become true later without re-entering the same operation, so there is
  no "later" for a reconcile to catch.
- `UNREACHABLE_DEAD` — nothing calls it.

---

## Bucket 1 — `EVENT_ONLY_NO_RECONCILE` (defect)

### 1.1 `stack_pending` → `in_progress` for a member of an already-`in_progress` stack

- Writer: `Stacks.try_promote/1`, `apps/platform/lib/platform/tasks/stacks.ex:3063`
  (`Tasks.transition_task(task, "in_progress")` at `:3065`).
- Sole production caller: `Stacks.sweep_stack_dependents/1`,
  `apps/platform/lib/platform/tasks/stacks.ex:3149`.
- Sole caller of *that*: `Tasks.maybe_sweep_stack_after_update/2`,
  `apps/platform/lib/platform/tasks.ex:952`, invoked from `Tasks.update_task/3`
  at `apps/platform/lib/platform/tasks.ex:598`.
- Trigger condition (`tasks.ex:955-959`): fires **only** on the nil → set edge
  of `metadata["merged_into_rollup_at"]`, and **only** when that edge is crossed
  by an `update_task/3` call. The threshold is the rollup-merge stamp, **not**
  `done`.
- Reconcile: none. `Stacks.reconcile_stack_lifecycle/0`
  (`stacks.ex:525`) selects `status == "forming"` stacks only (`:527`), plus
  `reconcile_deploying_stacks/0` (`:552`) which selects `status == "deploying"`.
  **No sweep visits `stack_pending` members of an `in_progress` stack.**

Consequences, both unswept:

- A member reaching `done` (or any other status) without crossing the stamp
  edge inside `update_task/3` leaves its dependents unswept forever.
- A stamp written by any path other than `update_task/3` — including a struct
  that already carried the stamp when loaded — never crosses the edge, so
  `try_promote/1` is never reached.

### 1.2 `stack_pending` member whose commencement gate opens after the stack is `in_progress`

- Writer that parks the member: `Tasks.apply_dispatch_gate/1`,
  `apps/platform/lib/platform/tasks.ex:3813`
  (`transition_task_status(task, "stack_pending")` when
  `Stacks.CommencementGate.open?/1` is false).
- The un-park path is `Stacks.commence_if_ready/1`,
  `apps/platform/lib/platform/tasks/stacks.ex:482`, whose head matches
  `%Stack{status: "forming"}` and which no-ops for every other stack status
  (`stacks.ex:506`).
- Triggers for `commence_if_ready/1`: the last-plan-approval broadcast path
  `Tasks.approve_plan/3` at `apps/platform/lib/platform/tasks.ex:3610`, and the
  5-minute tick via `reconcile_stack_lifecycle/0` (`stacks.ex:531`).
- Both triggers are `forming`-only. Once the stack is `in_progress`, a member
  parked at `stack_pending` by a *closed* gate has no promotion path other than
  1.1's rollup-merge edge, which is a different precondition entirely.

Also confirmed: `Stacks.start_stack/1` refuses any stack not `forming`
(`stacks.ex:377`), so an operator cannot re-open the cascade by hand once the
stack has moved on.

### 1.3 First execution stage start after plan approval

- Writer: `TaskRouter.ensure_execution_stage_started/2`,
  `apps/platform/lib/platform/orchestration/task_router.ex:2397`
  (`PlanEngine.start_stage/1` at `:2410`).
- Sole caller: the `{:plan_updated, status: "approved"}` branch of
  `handle_info/2`, `task_router.ex:1066`.
- Early return: `task_router.ex:2401` returns `state` unchanged unless
  `task.status == "in_progress"` and a current plan exists.
- Reconcile: none re-evaluates "approved plan, task now `in_progress`, no
  running stage". The watcher's tick (`task_router_watcher.ex:193`) runs
  `safe_reconcile/0` (start/stop routers), `sweep_in_review_stalls/0`,
  `Stacks.reconcile_stack_lifecycle/0`, `sweep_expired_architecture_gates/0`
  and `sweep_unsettled_auto_approvals/0` — none of which starts a pending
  first stage.

So a plan approved while the task is *not yet* `in_progress` (the ordinary
stack-member case: approval parks the member, the task reaches `in_progress`
later) never gets its first stage started, because the only writer already ran
and early-returned.

### 1.4 Task advance on plan completion is delivery-dependent

- Writer: `{:plan_updated, %{status: "completed"}}` handler,
  `apps/platform/lib/platform/orchestration/task_router.ex:1017`, which calls
  `LeaseManager.clear/1` (`:1027`) and re-dispatches (`:1030`).
- The handler head is `%State{task_id: task_id}` — it only runs **inside the
  per-task router process, for its own task**. If no router is alive for that
  task, if the router is alive but was started after the broadcast, or if it
  restarts mid-flight, the broadcast is simply not delivered to anyone.
- Reconcile: none. `safe_reconcile/0` starts routers for tasks matching
  `should_run?/1` (`task_router_watcher.ex:433`), but a newly started router
  does not replay the missed `plan_updated completed` event.

The correct characterisation of this face is therefore **not** "no code
exists" — the code exists and is correct. It is **event-delivery-dependent**:
its correctness is conditional on a process being alive and subscribed at the
instant of the broadcast, with no state-based re-derivation afterwards.

---

## Bucket 2 — `EVENT_PLUS_RECONCILE` (fine)

### 2.1 `in_review` → `deploying` for a stack member

- Writer: `Stacks.advance_member_to_deploying/1`, `stacks.ex:3287`.
- Event path: `StackDeployer` at
  `apps/platform/lib/platform/tasks/stack_deployer.ex:1241` (off the stamp it
  just wrote) and `PlanEngine` at
  `apps/platform/lib/platform/tasks/plan_engine.ex:217` (last validation pass).
- Timer path: `TaskRouterWatcher.sweep_in_review_stalls/0`,
  `task_router_watcher.ex:511`, calling the same function at `:584`.
- Both sides share one predicate, `Stacks.member_deploy_transition_ready?/1`
  (`stacks.ex:3188`). This is the shape the defect sites lack.

### 2.2 `forming` stack → commenced

- Event: `Tasks.approve_plan/3` at `tasks.ex:3610`.
- Timer: `reconcile_stack_lifecycle/0` at `stacks.ex:531`.
- Fine **for `forming` stacks only** — see 1.2 for the status this pair does
  not cover.

### 2.3 Rollup-PR open for a `deploying` stack

- Event: the fire-and-forget open inside the deployer.
- Timer: `Stacks.reconcile_deploying_stacks/0`, `stacks.ex:552`, re-firing
  `StackDeployer.maybe_open_stack_pr/1` (`stacks.ex:565`), gated idempotently
  on `rollup_pr_stamped?/1` (`stacks.ex:557`).

### 2.4 Architecture-gate expiry and unsettled auto-approvals

- `TaskRouterWatcher.sweep_expired_architecture_gates/0`,
  `task_router_watcher.ex:711`; `sweep_unsettled_auto_approvals/0`, `:871`.
- These are themselves the reconcile for a deadline whose event path may not
  fire. Both re-derive from persisted plan state, not from a delivered event.

### 2.5 Router start/stop

- `TaskRouterWatcher.handle_task_event/2` (`:327`) is the event path;
  `reconcile/0` (`:1095`) via the 5-minute tick and `boot_reconcile/0` (`:163`)
  re-derive the same `should_run?/1` predicate (`:433`) from the DB.

---

## Bucket 3 — `CASCADE_ONLY_BY_DESIGN` (fine, with reason)

### 3.1 `Stacks.cascade_member/4` → `in_progress` / `stack_pending` / `planning`

`stacks.ex:623-641`. Runs only inside `do_start_stack/1` / `start_planning/1`.
By design: the precondition is "this stack is being opened right now", which
cannot become true later without re-entering the same operation. The clauses
are idempotent (the wildcard at `:632` is a no-op), so re-entry is safe.

### 3.2 `Stacks.cascade_members_to_done/2` → `done`

`stacks.ex:2542`. Precondition is "the rollup PR merged", delivered as a
webhook (`stack_deployer.ex:1597`, `:1680`;
`apps/platform/lib/platform/tasks/rollup_webhook_processor.ex:147`). A merge is
a durable, replayable external fact and the cascade is idempotent (members
already `done` are rejected at `stacks.ex:2528`). Backfill entry point exists
at `apps/platform/lib/mix/tasks/platform/backfill_stack_deploy_cascade.ex:161`.

### 3.3 `Stacks.sweep_deploying_members_to_done/1` → `done`

`stacks.ex:2680`. Called from `stack_deployer.ex:1605`, `:1629`, `:1686` —
i.e. on *every* webhook delivery including replays, which is what makes it the
backstop for 3.2 rather than a second edge.

### 3.4 `Stacks.complete_no_op_member_if_rollup_merged/1` → `done`

`stacks.ex:2731`, called from the `transition_task_status/2` finalizer at
`tasks.ex:5185`. Fires on the member's own arrival at `deploying` and re-checks
the *stack's* merge state at `stacks.ex:2729` — a state read, not an event.
This is the late-arriving half of 3.2 and is why 3.2 is not a defect.

### 3.5 `Stacks.revert_regressed_dependents` → `stack_pending`

`stacks.ex:3420`. Reverting is a response to a specific regression event; there
is no standing precondition that could become true later.

### 3.6 Deploy-stage injection → `deploying`

`apps/platform/lib/platform/tasks/plan_engine.ex:1025`. Runs inside the stage
injection that creates the deploy stage; there is no state in which the task
should be `deploying` but the injection did not happen.

### 3.7 `PlanCompletion.transition_to_done/3` → `done`

`apps/platform/lib/platform/tasks/plan_completion.ex:163`. Cascade of plan
completion. The declines (`:151`, `:156`, `:161`) are deliberate — see the
comment block above `task_router.ex:1017` for why the router must not
re-advance what `PlanCompletion` declined.

### 3.8 `RollupWebhookProcessor.promote_member_to_done/2` → `done`

`rollup_webhook_processor.ex:296`. Webhook fan-out; idempotent replay guard at
`:286`.

### 3.9 Deploy/review stage-failure bounces → `in_progress`

`task_router.ex:932` (review stage failed) and `:3082` via
`handle_deploy_stage_failure/3`. Reaction to a failure event; nothing to
re-evaluate later.

### 3.10 `StackDeployer.bounce_member_to_in_progress/1` → `in_progress`

`stack_deployer.ex:2228`. Part of the atomic unstack/revert bounce, with an
explicit already-there no-op at `:2222`.

### 3.11 Review-request transitions → `in_review` / `in_progress`

`apps/platform/lib/platform/tasks/review_requests.ex:250` and `:355`. Both are
direct consequences of an operator/agent action on a review request.

### 3.12 `Tasks.maybe_start_planning_on_create/1` → `planning`

`tasks.ex:534`. Creation-time only; a task created at `backlog` is meant to
stay there. Refusals are logged (`:540`, `:547`) rather than retried.

### 3.13 `Tasks.apply_dispatch_gate/1` → `in_progress` / `blocked`

`tasks.ex:3819` / `:3830`. Approval-time derivation. The `blocked` branch has a
promotion path (3.14); the `stack_pending` branch does **not** — that is 1.2.

### 3.14 `Tasks.sweep_unblocked_dependents/1` → `in_progress`

`tasks.ex:5243`, called from the `done` finalizer at `tasks.ex:5146`,
transitioning via `unblock_task/1` at `:5288`. Cascade-only, but its threshold
is the dependency reaching `done`, which is itself the finalizer that runs this
sweep — so every way a dep can reach `done` runs the sweep. Distinct from 1.1:
different source status (any vs `done`), different candidate status
(`blocked` vs `stack_pending`), different threshold (`done` vs rollup-merge
stamp). They do not overlap, and only the `stack_pending` half is defective.

### 3.15 Operator-driven writes

`apps/platform/lib/platform/federation/tool_surface.ex:3984`, `:4199`, `:4804`,
`:6742`; `apps/platform/lib/platform_web/live/tasks_live.ex:1730`;
`apps/platform/lib/mix/tasks/platform/cleanup_ghost_tasks.ex:112`. A human or
agent asked for the transition. There is no precondition to become true later.

### 3.16 Metadata-only `Tasks.update_task/2` writes

`stacks.ex:1450`, `:1511`, `:3447`, `:3904`; `stack_deployer.ex:1222`, `:1344`,
`:2209`; `tasks_live.ex:1521`, `:1581`, `:1642`, `:1824`. Not status
transitions. Recorded because `update_task/3` is the host of the 1.1 hook —
`stack_deployer.ex:1222` is the write that *is* the rollup stamp and therefore
the one edge 1.1 depends on.

---

## Bucket 4 — `UNREACHABLE_DEAD`

### 4.1 `commence_open_gate/1` — documentation drift

Referenced in the `Stacks` docstring at
`apps/platform/lib/platform/tasks/stacks.ex:2660`. **Confirmed: no such
function is defined anywhere in the tree** (`grep -rn 'def commence_open_gate'
apps/platform/lib` returns nothing). The named function does not exist; the
prose it appears in describes the log-and-swallow convention shared by
`sweep_stack_dependents/1`, which does exist. Recorded as
`UNREACHABLE_DEAD` documentation drift.

---

## Seeds: confirmed / falsified

| Seed | Verdict |
| --- | --- |
| `start_stack/1` refuses non-`forming` stacks | **Confirmed** — `stacks.ex:377` |
| `commence_if_ready/1` + `reconcile_stack_lifecycle/0` sweep only `forming` (+ `deploying`); nothing sweeps `stack_pending` members of an `in_progress` stack | **Confirmed** — `stacks.ex:482`, `:506`, `:527`, `:552` |
| `sweep_stack_dependents/1` has exactly one caller, on the nil → set edge of the rollup stamp; a member reaching `done` without crossing that edge leaves dependents unswept | **Confirmed** — `tasks.ex:952-959`, `:598`; threshold is the rollup-merge stamp, not `done` |
| `commence_open_gate/1` does not exist | **Confirmed** — docstring `stacks.ex:2660` |
| `ensure_execution_stage_started/2` has one caller and early-returns unless `in_progress` | **Confirmed** — `task_router.ex:2397`, `:2401`, `:1066` |
| `{:plan_updated, "completed"}` does advance the task and clear the lease; the question is delivery | **Confirmed and refined** — `task_router.ex:1017`; the handler is scoped to the task's own router process, so it is event-delivery-dependent, not absent |

Line numbers in the ticket's seed list (`~L364`, `~L469`, `~L512`, `~L676`,
`~L2600`, `~L1553`, `~L633`, `~L580`) are approximate and predate later edits;
the numbers in this ADR are the ones in the tree at this commit.

## Secondary observation (not a bucket, worth a later look)

Two predicates disagree on the same stamp. `sweep_stack_dependents/1` tests
`is_nil(Map.get(metadata, "merged_into_rollup_at"))` (`stacks.ex:3142`) while
`member_has_merged_into_rollup_at?/1` tests `Map.has_key?/2`
(`stacks.ex:3199`). An explicit `nil` value under that key is "stamped" to one
and "unstamped" to the other. Not a promotion-path defect, but it is a second
way for a member to fall between the two paths.

## Decision

Record the classification. Later stages of this task act on Bucket 1: each of
1.1–1.4 needs a state-based re-derivation (a tick or a boot reconcile) that
evaluates the same precondition its event path evaluates — the shape Bucket 2
already has.

This ADR changes no runtime behaviour.

## Drift guard

`apps/platform/test/platform/orchestration/late_precondition_census_test.exs`
asserts the two structural facts later stages depend on: that
`Stacks.reconcile_stack_lifecycle/0` is exported, and that this ADR exists and
still names each seed above.

## Addendum (stage 4): face 3 falsified, and the census row that was wrong

Stage 4 was to fix "a completed plan does not advance the task". Reading the
tree at the fix commit, both the ticket's wording AND this ADR's own seed row
above are wrong, in opposite directions.

**The census row said** the `{:plan_updated, "completed"}` handler "does
advance the task and clear the lease", and classified the defect as
event-delivery dependence. The handler does **not** advance the task. It
clears the liveness lease and re-dispatches, and nothing else — its
status-mapping arm was deleted by task 019fa2fc stage 3.

**The advance moved to `Platform.Tasks.PlanCompletion`**, called synchronously
from `PlanEngine.complete_plan/2` — the only writer of
`plan.status = "completed"` — before the broadcast goes out. It is therefore
not event-delivery-dependent at all: no router needs to be alive, subscribed,
or restarted-in-time. Face 3 is **FALSIFIED**; it was fixed by task 019fa2fc
before this task was written, and this ADR's row is corrected here rather than
edited in place so the drift itself stays legible.

Bucket assignment for that seed changes from Bucket 1
(`EVENT_ONLY_NO_RECONCILE`) to Bucket 3 (`CASCADE_ONLY_BY_DESIGN`): the
transition rides the same transaction that writes the plan row, which is the
stronger guarantee a reconcile sweep would only approximate.

### Why the prescribed reconcile sweep was NOT built

The stage asked for a tick sweep applying "the same mapping the router uses"
(`in_progress -> in_review -> deploying -> done`) to any task whose current
plan is `completed`. Three independent reasons not to:

1. **That mapping no longer exists**, and its removal was the point. Task
   019fa2fc records that it manufactured this very stall class: `in_review` is
   a dead end in the single-plan model (review is a stage of the same plan),
   and `deploying` is a dead end for a task with no deploy stage and no deploy
   strategy to move it back out.
2. **A status-keyed sweep cannot see the completion reason.**
   `PlanCompletion` returns `:noop` for `:awaiting_rollup`, `:stack_member`,
   `:not_deployable` and `:degenerate_plan`. Those tasks sit at `in_progress`
   or `in_review` with a `completed` plan as their **correct** resting state.
   The reason is a call-site fact, not a column, so a sweep reading rows would
   advance them — marking undeployed work shipped.
3. **The duplicate has already been tried and reverted once.**
   `task_router_plan_completed_test.exs` exists specifically to pin that the
   second state machine is gone.

The reconcile half therefore ships as a falsification test:
`apps/platform/test/platform/orchestration/completed_plan_advance_router_independent_test.exs`
drives a plan to `completed` with no router alive and asserts the task
advanced anyway, and pins the control — one reconcile tick must leave a
declined task exactly where `PlanCompletion` left it. If a later change adds
the sweep, the control goes red.

### The suppression half that did ship

`handle_info(:check_safety_net, ...)` in
`apps/platform/lib/platform/orchestration/task_router.ex` now withholds the
`execution.safety_net_fired` alert when the task's current plan has no running
stage and no `pending`/`running` validation, reusing `any_open_validation?/1`.
The lease's one-shot is still consumed first, so suppression cannot loop. This
is what actually produced the false blocker: the safety net measures elapsed
time against a lease armed at dispatch and never re-reads whether there is
still anything to be slow about.

## Addendum (stage 6): verdict per face, and the bucket counts

The consolidation stage's regression suite is
`apps/platform/test/platform/orchestration/late_precondition_regression_test.exs`.
It holds one case per face that survived investigation, plus the anti-vacuity
controls. This section records what the investigation actually found, because
three of the five reported faces did not survive it.

### Verdicts

| Face | Verdict | Evidence |
| --- | --- | --- |
| 1 — commencement gate opens after the stack has commenced | **VERIFIED**, fixed | `Stacks.sweep_stack_pending_members/0`, called from `reconcile_stack_lifecycle/0`. Bucket 1.2. |
| 2 — task at `in_progress` with every stage `pending` | **VERIFIED**, fixed | `ensure_execution_stage_started/2` wired into the `{:task_updated, _}` handler. Bucket 1.3. |
| 3 — a completed plan does not advance the task | **FALSIFIED** | Already fixed by task 019fa2fc. `PlanCompletion.advance_task/2` runs synchronously inside `PlanEngine.complete_plan/2` — the only writer of `plan.status = "completed"` — before the broadcast, so router liveness cannot affect it. See the stage-4 addendum above; the seed's bucket moves 1 → 3. |
| 4 — an in-stack dependency clears after the stack has commenced | **VERIFIED**, fixed | Same sweep as face 1. Bucket 1.1. The threshold is `member_landed_on_rollup?/1`, the rollup-merge stamp **and** a landed status, not `done`. |
| 5 — an e2e failure bounce leaves nothing to dispatch from | **VERIFIED**, already guarded | The bounce reaches `in_progress`; with a pending stage the wiring for face 2 starts it, and with nothing pending the pre-existing `unresolved_stage_dispatch?/3` withholds the dispatch. Stage 3's own third prescribed edit was falsified as a duplicate of that guard. |

Stage 5's two items were **both falsified** and shipped no production code:

- `stage_list` returning a 500 for a `task_id`-shaped argument is **stale**.
  Task 019fa609 already gave the tool `plan_id`-or-`task_id` resolution with
  named refusal codes, blank-as-absent handling and a UUID guard.
- The stale-`stage_id`-in-dispatch claim is **false**. `do_dispatch/2` opens
  with a fresh `Tasks.current_plan/1` read and derives the stage from it; it
  never consults the router's cached `state.current_stage_id`. Dispatch and
  ack therefore share one source of truth and can differ only about *time* —
  an ack resolving to stage N+1 means the named stage genuinely completed in
  between, not that the payload was stale.

So of the six investigated claims (five faces plus the two tool edges, one of
which folded into face 2), **three were real and three were falsified.**

### Bucket counts

| Bucket | Entries | Sub-entries |
| --- | --- | --- |
| `EVENT_ONLY_NO_RECONCILE` | 4 | 1.1, 1.2, 1.3, 1.4 |
| `EVENT_PLUS_RECONCILE` | 5 | 2.1 – 2.5 |
| `CASCADE_ONLY_BY_DESIGN` | 16 | 3.1 – 3.16 |
| `UNREACHABLE_DEAD` | 1 | 4.1 |

Bucket 1 is 4 entries **as first censused**; after the stage-4 correction, 1.4
moves to Bucket 3, leaving Bucket 1 at **3 real defects** (1.1, 1.2, 1.3) and
Bucket 3 at **17**. All three were fixed by stages 2 and 3 of this task.

### What the regression suite can and cannot show

Each positive case was verified by reverting the stage 2–4 source changes and
confirming it goes red on a *behavioural* assertion — a member status or a
stage status — rather than on the shape of a sweep's return map. Two results
are worth recording as findings rather than smoothing over:

1. **Case 5 cannot be reddened.** With a plan that reaches `completed`, the
   safety-net alert is withheld because completion clears the lease and the
   handler takes its `nil`-lease early return — a path that predates this
   task. The suppression clause stage 4 added covers the *other* shape, a plan
   that settles without completing, and that shape is pinned by
   `task_router_safety_net_suppression_test.exs`. Case 5 therefore asserts a
   real operator-facing observable and names the mechanism it travels, but it
   is not a regression guard for anything stage 4 wrote.
2. **The promotion sweep does not read the commencement gate.**
   `try_promote/1` consults `unblocked_in_stack?/1` only. A dep-free member
   parked at `stack_pending` on an `in_progress` stack whose gate is still
   closed will be promoted by the sweep. That is a widening relative to the
   gate's stated purpose. It is not a defect the incident reported and no code
   was changed for it here, but it means the anti-vacuity control for face 1
   has to vary the dependency, not the gate — a gate-only control would pass
   for the wrong reason.

Case 3's green is likewise **over-determined**: three independent layers
refuse a double promotion — the sweep's query filter, `try_promote/1`'s
status-guarded head, and `transition_task/2` rejecting the identity
transition, since `@valid_task_transitions["in_progress"]` has no
`"in_progress"` edge. Stage 2's mutation probes against the first two, alone
and together, all stayed green. The test pins the observable; it does not
establish which guard is load-bearing.
