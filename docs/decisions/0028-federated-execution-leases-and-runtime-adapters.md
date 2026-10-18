# ADR 0028: Federated Execution Leases and Runtime Adapters

**Status:** Proposed  
**Date:** 2026-03-24  
**Related:** ADR 0011 (Execution Runners), ADR 0013 (Attention Routing), ADR 0014 (Agent Federation and External Runtimes), ADR 0018 (Tasks Persistent Model and Plan Engine), ADR 0025 (Task Router and Execution Orchestration), ADR 0026 (Task Execution Spaces)  
**Deciders:** the product owner

---

## Context

ADR 0025 introduced the TaskRouter as the deterministic orchestrator for assigned work. ADR 0026 introduced task execution spaces so humans and agents can observe execution as a shared conversation.

That closes the visibility gap, but not the supervision gap.

Today the TaskRouter can see:
- that a task was assigned
- that an execution space exists
- that validation evidence eventually appears
- that silence has persisted long enough to trigger a heartbeat or escalation

It still cannot reliably distinguish between these very different realities:

1. **The assigned runtime is actively working** and simply has not produced validation evidence yet
2. **The assigned runtime delegated to a child worker** and forgot to narrate the delegation
3. **The assigned runtime died or disconnected** after taking the task
4. **The assigned runtime is blocked** but failed to emit a structured blocker
5. **The assigned runtime restarted and lost local session state** even though the task is still recoverable

This becomes acute once we support multiple federated runtimes.

### The near-term problem

For OpenClaw-backed agents, a task may be assigned to a runtime worker that then spawns:
- a durable parent task session
- ACP coding sessions
- subagents
- other child workers

The child work can still be healthy while the TaskRouter sees only "no new evidence yet." That makes the router treat healthy delegated execution as possible silence.

### The long-term problem

The future Claude Code channel is not an OpenClaw deployment at all. It is another federated runtime. It may have its own worker/session model, but Burrow cannot depend on OpenClaw-specific concepts like parent task sessions, ACP, or subagents.

The orchestrator therefore needs a supervision primitive that is:
- **runtime-neutral**
- **durable**
- **idempotent**
- **observable in execution spaces**
- **good enough for both OpenClaw and non-OpenClaw runtimes**

---

## Problem

### Session-based supervision does not generalize

OpenClaw has rich internal runtime constructs, but those are implementation details. If Burrow supervision depends on them, federation is fake.

A non-OpenClaw runtime may have:
- a single remote worker process
- a thread in a hosted coding tool
- a queue-backed job runner
- a proprietary session abstraction

Burrow must not care.

### Validation evidence is necessary but insufficient

Validation evidence is the right signal for stage completion, but it is the wrong signal for liveness.

A healthy runtime can go 20 minutes with:
- no validation pass yet
- no human-facing commentary yet
- active execution still underway

Without another primitive, the router has to infer liveness from absence, which is exactly what creates false stalls and duplicate re-dispatch.

---

## Decision

Introduce a **runtime-neutral execution lease contract** in Burrow and make every federated runtime implement it through an adapter.

### Core idea

The TaskRouter does **not** supervise sessions, threads, ACP runs, or subagents.

The TaskRouter supervises:
1. a **runtime assignment**
2. an **execution lease** held by that runtime
3. a stream of normalized **runtime execution events**

### Practical interpretation

- **Burrow owns truth** for assignment, lease state, and escalation policy
- **Each runtime owns implementation details** for how work actually runs
- **Execution spaces remain the human-visible timeline**, but they are no longer the only source of liveness information
- **OpenClaw implements one runtime adapter**
- **Claude Code channel implements another runtime adapter**
- Both adapters emit the same external lifecycle signals back to Burrow

---

## Principles

### 1. Supervise leases, not sessions

A session is runtime-specific. A lease is orchestration-specific.

### 2. Liveness is explicit

Silence should mean silence, not "maybe delegated somewhere invisible."

### 3. Delegation is internal to the runtime

If OpenClaw delegates from a parent task session to a coding agent, that is OpenClaw's business. Burrow only needs the runtime to continue renewing its lease and publishing meaningful events.

### 4. Execution spaces are transparency layers, not authority

Humans should see what is happening there, but the TaskRouter should make lease decisions from structured runtime state, not from heuristics over chat commentary.

### 5. Idempotency is mandatory

Federated runtimes will retry, reconnect, and occasionally duplicate outbound events. The contract must tolerate that without double-spawning, double-finishing, or contradictory state.

---

## Data Model

### RuntimeAssignment

Represents the current contractual relationship between a task phase and a federated runtime.

Suggested shape:

```elixir
%RuntimeAssignment{
  id: Ecto.UUID.t(),
  task_id: Ecto.UUID.t(),
  phase: :planning | :execution | :review,
  runtime_id: String.t(),
  status: :assigned | :accepted | :rejected | :abandoned | :superseded | :completed,
  assigned_at: DateTime.t(),
  accepted_at: DateTime.t() | nil,
  closed_at: DateTime.t() | nil,
  metadata: map()
}
```

### ExecutionLease

Represents an active claim that the runtime is still doing work for the assignment.

Suggested shape:

```elixir
%ExecutionLease{
  id: Ecto.UUID.t(),
  assignment_id: Ecto.UUID.t(),
  task_id: Ecto.UUID.t(),
  phase: :planning | :execution | :review,
  runtime_id: String.t(),
  runtime_worker_ref: String.t() | nil,
  status: :active | :blocked | :finished | :failed | :expired | :abandoned,
  started_at: DateTime.t(),
  last_heartbeat_at: DateTime.t() | nil,
  last_progress_at: DateTime.t() | nil,
  expires_at: DateTime.t(),
  block_reason: String.t() | nil,
  metadata: map()
}
```

### RuntimeEvent

Immutable event history for auditability and replay-safe supervision.

```elixir
%RuntimeEvent{
  id: Ecto.UUID.t(),
  task_id: Ecto.UUID.t(),
  phase: :planning | :execution | :review,
  runtime_id: String.t(),
  assignment_id: Ecto.UUID.t(),
  lease_id: Ecto.UUID.t() | nil,
  event_type: String.t(),
  occurred_at: DateTime.t(),
  idempotency_key: String.t(),
  payload: map()
}
```

---

## Contract: Normalized Runtime Events

The first version of the contract should stay small.

### Assignment events

- `assignment.accepted`
- `assignment.rejected`

### Execution events

- `execution.started`
- `execution.heartbeat`
- `execution.progress`
- `execution.blocked`
- `execution.unblocked`
- `execution.finished`
- `execution.failed`
- `execution.abandoned`

### Meaning of each event

#### `assignment.accepted`
The runtime acknowledges ownership of the assignment and is now accountable for execution state.

#### `execution.started`
The runtime has actually started work and opened a lease.

#### `execution.heartbeat`
The runtime is still alive and still owns the work. This is a liveness renewal, not necessarily a visible milestone.

#### `execution.progress`
The runtime has something material to report. This renews the lease and can be mirrored into the execution space.

#### `execution.blocked`
The runtime knows it cannot proceed. This is explicit and should pause silence-based escalation.

#### `execution.finished`
The runtime has concluded execution responsibility cleanly. This closes the lease but does not automatically imply plan validation has already succeeded.

#### `execution.failed`
The runtime has concluded execution responsibility unsuccessfully and cannot continue without reassignment or intervention.

#### `execution.abandoned`
The runtime is intentionally relinquishing the assignment, usually due to unrecoverable local state loss or explicit unbind.

---

## Router Semantics

The TaskRouter becomes lease-aware.

### Router questions

Instead of asking:
- "Did validation evidence arrive yet?"
- "Has the assignee gone silent long enough to re-dispatch?"

It should ask:
- "Has the runtime accepted the assignment?"
- "Is there an active execution lease?"
- "When was the lease last renewed?"
- "Is the runtime explicitly blocked?"
- "Has the lease expired?"

### Router rules

#### If no assignment is accepted
Dispatch or re-dispatch.

#### If assignment is accepted and lease is active
Do not duplicate-dispatch, even if no validation evidence exists yet.

#### If lease is active but only heartbeat events exist
Treat the task as healthy but quiet.

#### If lease is blocked
Pause silence escalation and route through blocker handling.

#### If lease expires
Escalate deterministically. Possible actions:
- poke runtime once
- reassign
- notify human
- mark stalled in task UI

The exact policy can be stage-specific, but the trigger should be lease expiry, not vague silence.

---

## Relationship to Execution Spaces

ADR 0026 still stands: each task assignment gets an execution space.

This ADR changes what the execution space is used for.

### Execution space remains for:
- working commentary
- human intervention
- structured machine lifecycle messages
- audit trail of what happened during execution

### Execution space is no longer the only sign of health

A runtime may emit:
- machine heartbeats
- progress events
- failure events

These may be mirrored into the execution space as log-only system messages, but the authoritative supervision signal is the runtime event stream and lease state.

### Suggested machine log messages

Examples:

```text
[system] OpenClaw accepted assignment for stage execution
[system] Runtime worker started (worker_ref=task:019d...:execution)
[system] Runtime heartbeat received — last local activity 41s ago
[system] Runtime reported blocker — waiting on schema clarification
[system] Runtime finished execution — awaiting validation outcome
[system] Lease expired after 15m without heartbeat — escalating
```

These are not ordinary engagement messages. They are visibility artifacts.

---

## OpenClaw Runtime Adapter

OpenClaw needs explicit adapter work to participate cleanly in the lease model.

### Why

OpenClaw has richer internal machinery than the shared federation contract:
- local task sessions
- ACP sessions
- subagents
- background processes
- plugin runtime state

That machinery is useful, but it is local. The adapter's job is to translate it into the normalized contract.

### Required OpenClaw-side components

#### 1. TaskWorkerController
A local registry keyed by `task_id + phase`.

Responsibilities:
- create or resume a local runtime worker for a task phase
- prevent duplicate worker creation on reconnect or repeated signals
- map local worker identity to assignment + lease state

Suggested local state:

```ts
interface TaskWorkerRecord {
  taskId: string;
  phase: "planning" | "execution" | "review";
  assignmentId: string;
  leaseId?: string;
  executionSpaceId: string;
  sessionKey?: string;
  status: "assigned" | "running" | "blocked" | "finished" | "failed";
  runtimeWorkerRef: string;
  childRuns: Array<{ kind: string; id: string }>;
  lastObservedAt?: string;
  lastEventSentAt?: string;
}
```

#### 2. Idempotent assignment handling
On `task_assigned` / reconnect / duplicate dispatch:
- if no worker exists: create one
- if a healthy worker exists: bind to it and do not spawn another
- if the worker exists but local session died: attempt recovery, else emit failure/abandonment

#### 3. Durable parent worker
For OpenClaw, a durable task worker session is still useful as the local accountable actor, even though Burrow does not know or care about it.

That parent worker may delegate, but the adapter remains responsible for reporting coherent lease state.

#### 4. ChildRunRegistry + ChildRunObserver
If the OpenClaw worker delegates to ACP/subagents/other children, the plugin must observe that structurally.

The plugin should not rely on the parent agent to narrate child state correctly.

Observed signals should include:
- child spawn success/failure
- last output time
- alive/dead state
- completion
- error
- timeout
- abandonment

#### 5. Heartbeat synthesis
If a child run is still active, the runtime worker is still active.

That means the adapter can emit:
- `execution.heartbeat` when there is liveness but no visible milestone
- `execution.progress` when there is meaningful local advancement worth mirroring

#### 6. Restart recovery
On plugin restart, the adapter must:
- rebuild local worker registry
- scan live sessions/children
- rebind them to task workers where possible
- emit fresh lease events
- mark unrecoverable workers failed/abandoned

This prevents restart from looking identical to silent abandonment.

---

## Non-OpenClaw Runtimes

The future Claude Code channel must implement the same external contract without inheriting any OpenClaw assumptions.

That runtime may choose to represent a worker as:
- a hosted thread
- a remote execution job
- a coding session
- a queue-backed worker

Burrow should only require:
- assignment acceptance or rejection
- execution started
- periodic heartbeat/progress while active
- explicit blocked / finished / failed / abandoned events

This is the key federation guarantee: OpenClaw and Claude Code do not need shared internals, only a shared lease contract.

---

## API Surface

Burrow should expose a minimal runtime-facing API.

### Required operations

- accept assignment
- reject assignment
- publish execution event
- fetch current assignment + lease snapshot

### Important contract requirements

#### Idempotency
Every runtime event must include an idempotency key so retries do not double-advance state.

#### Authentication
Each federated runtime authenticates as itself, not as an arbitrary agent.

#### Phase awareness
All runtime events are scoped to `task_id + phase + runtime_id`, not just task id.

#### Safe duplicate delivery
The same event posted twice should be harmless.

---

## Failure Semantics

The orchestration layer should treat failures explicitly.

### Runtime restarted but recovered local worker
Emit a heartbeat or progress event; keep assignment and lease coherent.

### Runtime restarted and cannot recover local worker
Emit `execution.abandoned` or `execution.failed` with a clear reason.

### Runtime is healthy but quiet
Emit heartbeats. Do not force fake progress.

### Runtime is blocked
Emit `execution.blocked`. Do not wait to be inferred as stalled.

### Runtime disappears entirely
Lease expires. Router escalates deterministically.

---

## Tooling and Prompt Contract Cleanup

This ADR does not depend on prompt wording, but prompt/tool mismatch still harms reliability.

The runtime-facing instructions must not refer to nonexistent tools.

If the system wants runtimes to report blockers or stage completion, the surface must either:
- expose exact tool names that exist, or
- provide aliases that match the prompt contract

This is a correctness requirement adjacent to the lease model.

---

## Testing Strategy

### Contract tests

- assignment accepted opens runtime accountability
- duplicate heartbeat delivery is idempotent
- progress renews active lease
- blocked state suppresses silence escalation
- expired lease triggers deterministic escalation

### OpenClaw adapter tests

- duplicate task assignment does not create duplicate workers
- active child run produces runtime heartbeat even without visible evidence
- plugin restart rebinds healthy workers
- unrecoverable worker emits failed/abandoned state cleanly

### End-to-end scenarios

#### Healthy quiet execution
Task runs for 20+ minutes with heartbeats only; no duplicate dispatch occurs.

#### Delegated child execution
Parent OpenClaw worker delegates to child run; child activity keeps the lease alive.

#### Explicit blocker
Runtime emits blocked state; router shifts from stall inference to blocker handling.

#### Runtime restart
Adapter restarts, recovers worker, and lease continuity remains intact.

#### Runtime disappearance
No heartbeats arrive, lease expires, router escalates exactly once.

---

## Implementation Plan

This should be delivered in slices.

### Slice 1: Burrow contract and observability
- add runtime assignment, execution lease, and runtime event models
- add runtime event ingest API with idempotency
- mirror runtime lifecycle events into execution spaces as machine log-only messages
- do not yet make router behavior depend fully on lease state

### Slice 2: OpenClaw adapter MVP
- upgrade OpenClaw path to public plugin SDK usage
- add TaskWorkerController
- accept assignments idempotently
- emit `assignment.accepted`, `execution.started`, `execution.heartbeat`, `execution.finished`, `execution.failed`

### Slice 3: OpenClaw delegated-run resilience
- add child run registry and observation
- synthesize parent worker liveness from child activity
- add restart recovery
- improve execution-space log mirroring

### Slice 4: Router hard switch
- make TaskRouter supervision lease-driven
- reduce old silence heuristics to fallback behavior only
- tune expiry thresholds per phase/stage type

### Slice 5: Second runtime adoption
- implement the same contract for the Claude Code channel or other federated runtime
- verify no OpenClaw-specific assumptions remain in Burrow supervision logic

---

## Consequences

### Positive
- federated runtime supervision becomes real rather than implied
- healthy quiet work no longer looks identical to silence
- OpenClaw delegation becomes observable and recoverable
- Claude Code channel can participate without OpenClaw internals
- execution spaces gain clearer machine-level transparency

### Costs
- more persistent orchestration state in Burrow
- more adapter complexity on the OpenClaw side
- additional runtime API and idempotency requirements
- more scenario testing than a simple prompt-based fix

### Tradeoff accepted
We are deliberately choosing a more explicit orchestration model over a cheaper heuristic one, because the heuristic model breaks as soon as federation becomes real.

---

## Out of Scope

This ADR does not define:
- the exact wire protocol shape for every runtime transport
- the exact UI for assignment/lease inspection in the control surface
- the complete blocker taxonomy
- whether OpenClaw local parent sessions are exposed in any Burrow UI

Those are follow-on design tasks. The key decision here is where supervision truth lives and what contract federated runtimes must honor.

---

## Summary

Burrow should supervise **runtime assignments and execution leases**, not runtime-specific session abstractions.

OpenClaw remains a rich local implementation with task sessions and child workers, but it must report through the same normalized contract that future non-OpenClaw runtimes will use.

That is what closes the current orchestration gap without baking OpenClaw assumptions into federation.
