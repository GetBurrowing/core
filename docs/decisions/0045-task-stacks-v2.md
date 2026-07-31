# ADR 0045 — Task Stacks v2 — Atomic Feature Shipping

**Status:** Proposed
**Date:** 2026-07-09
**Author:** Dalton

---

## Context

Task Stacks shipped as a v1 primitive to bundle multiple tasks that must land together for a coherent feature: for example, a backend migration + a Phoenix context change + a LiveView surface + a client hook must all ship in the same PR-review round, otherwise reviewers see incoherent partial work and shipped code can carry backend surface with no UI to exercise it — the kind of state that becomes code rot the moment a follow-up gets deprioritized.

The v1 primitive covered the basic shape — group of tasks with dependencies — but a real end-to-end run of a stack surfaced 13 rough edges. This ADR captures the design decisions that resolve them.

The **product intent** of stacks: a stack is the sum total of tasks required to ship one feature. It behaves like a single task at the *reasoning* level — one sponsor, one merge, one atomic ship or no ship — while providing dependency-ordered execution underneath. If a shipped feature needs adjustment, that adjustment is a new individual task, not a stack re-open.

---

## Decision

Task stacks are treated as atomic feature-ship bundles. The engine enforces bundle-level atomicity across planning, execution, and deploy, and never allows partial state to escape the bundle. Specifically:

1. **Agents author dependencies.** Users declare stack membership; a planner agent computes dependency edges from task descriptions and stage contracts. A user can override the inferred graph, but the default is agent-authored.

2. **Rollup branch, single PR.** At `stack.start`, the engine creates a `stack/<name>` branch off `main`. Every member's task branch is created from `stack/<name>` (not `main`). Deploy phase opens exactly one PR (`stack/<name>` → `main`) after every member's validations have passed. No per-member `pr_merge` dispatch.

3. **Recursive plan cascade.** `stack.start_planning` recursively kicks planning on every member. With auto-accept off, each plan waits for its own approval; with auto-accept on, plans accept as they generate.

4. **Task commencement gate.** No task in a stack transitions to `in_progress` until every member has an approved plan. This is the invariant that prevents partial-execution states — if member A finishes before member C's plan is even authored, member A ships alone and the atomicity guarantee is broken.

5. **Federated agent capacity is opaque to the engine.** An assigned task stays assigned; federated agents queue and drain at their own pace. The engine does not preempt or reassign.

6. **No mid-stack lifecycle mutations.**
   - **No stop / cancel.** A stopped stack becomes orphaned but is never dismantled by the engine.
   - **No eject.** A member cannot leave the stack mid-flight.
   - **No cross-stack dependencies.** A task belongs to at most one stack. If work spans two, either merge the stacks or serialize them.

7. **Post-ship adjustments are individual tasks.** Once a stack merges, further changes to the shipped feature are addressed via new individual tasks, not by reopening the stack.

8. **Stack-level sponsor.** Stacks carry `sponsor_user_id`, mirroring tasks. The stack sponsor is the reasoning surface for filters like "show stacks I sponsor"; individual member sponsors may differ and drive per-task attention routing.

9. **Dep-graph UI is resizable.** The dependency canvas gets a user-resizable container so mobile and desktop users can expand it to the screen real estate they need.

---

## Architecture

### Stack lifecycle

```
create → members added → start_planning → (plans generated + approved) →
  → start (rollup branch created, commencement gate opens) →
  → members execute in dep order →
  → all members' validations pass →
  → deploy (single PR opened, CI runs, PR merges, rollup branch deleted) →
  → complete
```

Terminal states: `complete`, `abandoned`. `abandoned` leaves the rollup branch untouched (orphaned) and never re-enters the engine.

### Planning phase (decisions 1, 3)

`stack.start_planning` triggers:

- A **dep-inference pass** by a planner agent on all members. Uses task descriptions, referenced files, and (where present) stage contracts to build the DAG. Persists as `stack_dependencies` rows keyed by `(from_task_id, to_task_id, stack_id)`.
- A **plan cascade** — planning is dispatched to every member in topological order (roots first). Downstream members' planners receive the parent plan payload via MCP so their design decisions align.

Manual plan mode gates downstream plan dispatch on parent plan approval. Auto-plan mode does not gate — all planners dispatch concurrently, and the auto-accept flag controls whether individual plans require approval.

### Commencement gate (decision 4)

A task's `in_progress` transition is gated on:

```
stack.status == :in_progress
∧ every member.plan.status == :approved
```

The gate lives in the plan-engine transition function — no member task transitions past `pending` until it holds. Once open, tasks fire in dep order according to the rollup branch, respecting the federated-agent capacity model.

### Rollup branch lifecycle (decision 2)

- **`stack.start`** — engine creates `stack/<name>` from `origin/main`.
- **Per-member task branches** — `task/<uuid>` branches from `stack/<name>` HEAD, not `main`. Members merge back into `stack/<name>` via engine-driven fast-forward or PR (implementation choice — likely fast-forward on validated pass to keep history clean).
- **`stack.deploy`** — engine opens PR `stack/<name>` → `main`. CI runs against the rollup. On merge, `stack/<name>` is deleted.
- **`stack.abandon`** — rollup branch left in place, no cleanup. Human-driven.

### Branch model

Amended by task `019fb949`. This section states the naming rule for **every** task, not only stack members, and is the section source comments cite.

**The rule.** A task's worktree path is `../worktrees/<full task uuid>` and its branch is `task/<full task uuid>`. Both are a pure function of `tasks.id` and nothing else — no random suffix, no timestamp, no descriptive slug, no truncation. What the branch is cut *from* varies — rollup HEAD for a stack member, `epic.target_branch || project.default_branch` otherwise, per ADR 0031's epic-level target-branch section. What it is *called* does not.

**Why the full 36 characters and not a prefix.** Task ids are UUIDv7: `<<timestamp_ms::big-48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>`. The first 8 hex characters are the high 32 bits of the 48-bit millisecond timestamp, so they are **constant across a 2^16 ms ≈ 65.5-second aligned bucket**. Two tasks filed a few seconds apart do not *risk* a collision, they collide deterministically — which is how one incident put two live executors on the same `task/<8-char>` branch and the same worktree directory. Twelve characters cover the whole millisecond, narrowing the collision to same-millisecond creation, which is exactly what a batch insert from one agent produces. Sixteen add a constant version nibble plus 12 bits of `rand_a` drawn from a CSPRNG rather than a counter: a silent 1-in-4096 per same-millisecond pair, birthday-scaled across a batch. Only the full id inherits the primary key's uniqueness instead of arguing for it from bit widths.

**Second-order benefit.** The full form is the only one that takes the exact-equality path in `Platform.Changelog.extract_task_id_from_branch/1`. A prefix has to be resolved by LIKE-search, which must fail closed when it is ambiguous — so under truncation the deploy round-trip returned `nil` for exactly the colliding pairs it most needed to resolve. Deploy attribution was silently broken, not merely at risk. The visible cost is downstream of the `nil`: the changelog row lands unattributed, the `pr_merged` validation never closes, and the task parks in `deploying` until someone hand-passes it — twice on 2026-07-31, against `019fa63a-86a5` and `019fa63a-02a0`.

The cost is a 36-character directory name. Stack members have paid it since the v1 implementation; task `019fb949` extended it to non-stack tasks, deleting the truncating helper so no call site can reintroduce a short form.

### Cross-stack invariants (decision 6c)

`stack_add(stack_id, task_id)` is rejected if the task is already a member of another stack. `stack_add_dependency(a, b)` is rejected if `a` and `b` are in different stacks. These are engine-level constraints, not UI conventions.

### Sponsor (decision 8)

Schema:

```
stacks
  ...
  sponsor_user_id uuid null references users(id)
```

Filter surfaces (`SponsorFilter` client-state hook) apply the same "mine" pill to stacks that they already apply to tasks. Both filter states persist independently.

### Dep-graph UI (decision 9)

The task-stack canvas kind adopts a resizable container. `resize: both` on desktop, drag-handle bottom-right on mobile. Persist the last user-chosen size in `ClientState("tasks_ui", "stack_graph_size")`.

---

## Consequences

**Positive:**

- Features ship atomically. Reviewers see one PR that either contains a complete feature or does not merge. No latent backend surface without UI.
- Users delegate the mental cost of dep authoring to the planner agent.
- Bundle-level invariants (single PR, commencement gate, no cross-stack) close the classes of partial-ship bugs that surfaced in the v1 spike.

**Negative / trade-offs:**

- The commencement gate serializes stack lifecycle behind slowest-planner. Six fast tasks and one slow planner means the fast tasks wait.
- The single-PR model makes CI feedback coarser — a lint failure on member 3 blocks the whole rollup. Mitigation: pre-execution CI dry-runs at plan approval time (out of scope for this ADR).
- Orphaned rollup branches from abandoned stacks accumulate unless a periodic sweep task runs. Left as ops concern rather than engine responsibility.
- The "no post-ship reopening" convention shifts fix work back to individual tasks. This is desired but requires discipline — the engine won't prevent someone from filing a task labelled "fix stack X".

**Neutral:**

- The federated-agent capacity model stays unchanged. Backends that queue slowly will continue to queue slowly; the engine does not intervene.

---

## Rollout

This ADR is implemented as the `stack/stack-system-v2` task stack itself — a meta-test of the new invariants. Membership:

1. Dep-inference planner (decision 1)
2. Commencement gate transition (decision 4)
3. Rollup branch lifecycle (decision 2, branch side)
4. Single-PR deploy (decision 2, deploy side; depends on 3)
5. Stack-level sponsor schema + filter (decision 8)
6. Dep-graph resize UI (decision 9)
7. Auto-plan cascade + recursive planning (decision 3)

Dep edges: 2 depends on 1; 4 depends on 3. 1, 3, 5, 6, 7 can start in parallel once the stack's commencement gate opens.

---

## Related

- ADR-0018 — Tasks Persistent Model and Plan Engine (parent context)
- ADR-0031 — Epic Branch Targeting (related branch model)
- ADR-0034 — MCP Endpoint and Capability Bundles (planner MCP interface)
