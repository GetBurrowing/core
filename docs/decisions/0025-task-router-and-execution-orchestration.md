# ADR 0025: Task Router and Execution Orchestration

**Status:** Accepted (2026-03-22) — amended 2026-07-15 (task 019f640d; see amendment section at bottom)  
**Superseded in part by:** ADR 0051 (TaskRouter Dispatch as a Debounced Reconcile, and Ack Durability Outside the Lease) — dispatch-trigger and ack-liveness sections  
**Date:** 2026-03-22  
**Related:** ADR 0002 (Domain Boundaries), ADR 0011 (Execution Runners), ADR 0013 (Attention Routing), ADR 0014 (Runtime Channel), ADR 0018 (Tasks Persistent Model and Plan Engine)  
**Deciders:** Rowan Ellis

---

## Context

ADR 0018 established the persistent task model and deterministic plan engine. ADR 0013 established attention routing — deciding who responds to a message. ADR 0011 established the execution runtime — local runners, RunServer, context plane.

A gap exists between these: once a task is assigned to an agent (federated or local), nothing is responsible for:

1. **Assembling and dispatching** the execution context deterministically to the right backend
2. **Tracking progression** through the plan engine stages
3. **Recovering from silence** — detecting when an assigned agent has stopped reporting and re-engaging it

The attention router answers: "who responds to this chat message?"  
The plan engine answers: "are the validations satisfied?"  
Neither answers: "is this task still moving, and what should happen next?"

That is the task router's job.

---

## Problem: Execution Drift

The core reliability problem is not agent bad intent — it is **execution drift**. An agent deep in multi-step work will progressively drop overhead steps (progress reporting, validation evidence pushes) because they are not immediately load-bearing for the task at hand. Reporting is the first casualty.

A stateless "complete this task" instruction is insufficient. What's needed is:

- Deterministic context assembly before dispatch (no LLM guessing what it needs to know)
- Scheduled re-engagement when an agent goes quiet
- Escalation to a human when re-engagement fails
- A clear, stateful heartbeat message that forces the agent to account for itself

---

## Decision

Introduce `Platform.Orchestration` — a new supervised domain responsible for task dispatch, heartbeat management, and execution escalation.

### Guiding Principle

**All router decisions are deterministic. No LLM in the router itself.**

| Deterministic (router) | LLM (agent) |
|---|---|
| Dispatch strategy selection | Plan generation |
| Context assembly | Code execution |
| Heartbeat cadence | Validation judgment (code review) |
| Escalation thresholds | Feedback interpretation |
| Stage progression monitoring | |

---

## Architecture

### `Platform.Orchestration` Domain

```
Platform.Orchestration
  ├── TaskRouter          — top-level orchestration: dispatch, heartbeat, escalation
  ├── TaskRouterSupervisor — DynamicSupervisor, one TaskRouter per active assignment
  ├── DispatchStrategy    — federated vs local path selection
  ├── ContextAssembler    — deterministic context snapshot for dispatch
  └── HeartbeatScheduler  — tick management, cadence config per stage type
```

### TaskRouter (GenServer)

One process per active task assignment. State:

```elixir
%TaskRouter.State{
  task_id: String.t(),
  assignee: %{type: :federated | :local, id: String.t()},
  current_stage_id: String.t() | nil,
  stage_started_at: DateTime.t() | nil,
  last_evidence_at: DateTime.t() | nil,
  heartbeat_ref: reference() | nil,
  escalation_count: non_neg_integer(),
  status: :dispatching | :running | :stalled | :complete | :escalated
}
```

### Dispatch Strategies

Two paths — same interface contract.

#### Federated Agent

Assemble context snapshot → send synthetic attention event via `RuntimeChannel` tagged `task_heartbeat`:

```elixir
# Initial dispatch (full context)
RuntimeChannel.push(runtime_id, "attention", %{
  signal: %{reason: "task_assigned", task_id: task_id},
  context: ContextAssembler.build(task_id),
  message: %{content: HeartbeatScheduler.dispatch_prompt(task, plan, stage)}
})

# Heartbeat (stateful interrogation)
RuntimeChannel.push(runtime_id, "attention", %{
  signal: %{reason: "task_heartbeat", task_id: task_id},
  context: ContextAssembler.build_delta(task_id, since: last_evidence_at),
  message: %{content: HeartbeatScheduler.heartbeat_prompt(task, stage, elapsed, pending_validations)}
})
```

The heartbeat prompt is stateful — it carries elapsed time, stage position, pending validations. Not a keepalive. An interrogation.

Example heartbeat message:
```
Task: Refactor auth module [stage 2/4 — unit tests]
Stage running for: 42 minutes
Pending validations: test_pass, lint_pass
Last evidence: none submitted

Either push validation evidence or report a blocker.
Context: <assembled project + epic + task + plan snapshot>
```

#### Local Agent

Dispatch to `Execution.RunServer` — same runner infrastructure as proof-of-life. The heartbeat is a `GenServer.call(:get_run)` against the RunServer process rather than a synthetic message.

```elixir
# Dispatch
{:ok, run} = Execution.start_run(%{
  task_id: task_id,
  runner: :local,  # or :docker
  context: ContextAssembler.build(task_id)
})

# Heartbeat check
case Execution.RunServer.get_run(run.id) do
  {:ok, %Run{status: :running}} -> :ok
  {:ok, %Run{status: :stalled}} -> handle_stall(state)
  {:error, :not_found}          -> handle_lost_run(state)
end
```

### ContextAssembler

Deterministic context snapshot for the executing agent. Walks the task hierarchy and assembles:

```elixir
def build(task_id) do
  task    = Tasks.get_task_detail(task_id)          # includes project, epic, plans, stages
  project = task.project
  epic    = task.epic

  %{
    project:   %{name: project.name, repo_url: project.repo_url,
                  tech_stack: project.tech_stack, deploy_config: project.deploy_config},
    epic:      epic && %{name: epic.name, description: epic.description,
                         acceptance_criteria: epic.acceptance_criteria},
    task:      %{title: task.title, description: task.description,
                  dependencies: task.dependencies},
    plan:      serialize_plan(Tasks.current_plan(task_id)),
    assignee:  %{type: :federated, runtime_id: task.assignee_id}
  }
end
```

No LLM. Pure data assembly.

### HeartbeatScheduler

Cadence is stage-type aware, not flat:

| Stage type | Initial dispatch | Heartbeat interval | Stall threshold | Escalation after |
|---|---|---|---|---|
| `planning` | immediate | 15 min | 30 min | 2 missed heartbeats |
| `coding` | immediate | 10 min | 25 min | 2 missed heartbeats |
| `ci_check` | immediate | 5 min | 15 min | 3 missed heartbeats |
| `review` | immediate | 20 min | 60 min | 1 missed heartbeat |
| `manual_approval` | n/a | n/a | n/a | human gate, no auto-escalation |

`manual_approval` stages pause the heartbeat entirely — they are human gates, not agent execution.

### Stage Progression Monitoring

The TaskRouter subscribes to the `tasks:board` PubSub topic. When the plan engine broadcasts `{:task_updated, task}` or `{:stage_transitioned, stage}`, the router updates its internal state and resets the heartbeat timer. Progress resets the clock.

```elixir
def handle_info({:task_updated, %Task{id: id}}, %{task_id: id} = state) do
  {:noreply, reset_heartbeat(state)}
end

def handle_info({:stage_transitioned, %Stage{} = stage}, state) do
  {:noreply, state |> update_current_stage(stage) |> reset_heartbeat()}
end
```

### Escalation Path

If an agent misses N consecutive heartbeats:

1. Router marks assignment `:stalled`
2. Broadcasts `{:task_stalled, task_id, assignee, reason}` to PubSub
3. Burrow chat surface posts a notification in the task's associated space
4. Human can: reassign, unblock, or force-complete the stage

After escalation, the router enters a slower polling mode (checks every 30 min) until a human intervenes.

---

## Relationship to Existing Components

| Component | Relationship |
|---|---|
| `PlanEngine` | Router reads stage/validation state; never writes it directly |
| `AttentionRouter` | Router borrows RuntimeChannel dispatch; does not replace attention routing |
| `ContextHydrator` (ADR 0018) | `ContextAssembler` supersedes/absorbs this for dispatch context |
| `RunServer` | Router supervises local runs; heartbeat is a GenServer query |
| `Federation.ToolSurface` | Federated agents push evidence through tool calls; router observes via PubSub |
| `Chat.AttentionRouter` | No conflict — task heartbeats are tagged `task_heartbeat`, not chat attention |

---

## Implementation Phases

### Phase 1: Core Router + Federated Dispatch
- `TaskRouter` GenServer with state machine
- `TaskRouterSupervisor` DynamicSupervisor
- `ContextAssembler` (deterministic context snapshot)
- Federated dispatch via `RuntimeChannel`
- Basic heartbeat with flat cadence
- PubSub subscription for plan engine events

### Phase 2: Heartbeat Scheduling + Escalation
- `HeartbeatScheduler` with stage-aware cadence
- Escalation path: stall detection → PubSub broadcast → chat notification
- Stateful heartbeat prompt generation
- Human intervention hooks (reassign, unblock, override)

### Phase 3: Local Agent Dispatch
- Integration with `Execution.RunServer` for local Claude Code runs
- RunServer heartbeat via GenServer query
- Docker runner support
- Context snapshot pushed into ETS context plane at run start

### Phase 4: Observability
- Router state visible in Tasks LiveView (stage timer, last evidence timestamp, heartbeat count)
- Stall indicators on kanban cards
- Escalation history in task detail

---

## What This Is Not

- **Not an LLM orchestrator.** No model decides routing, cadence, or escalation. This is a state machine with config.
- **Not a replacement for the plan engine.** Plan engine owns validation state. Router observes it.
- **Not a message queue.** Heartbeats are synthetic attention events, not queued jobs.

---

## Consequences

### Positive
- Task execution becomes observable and recoverable
- Agent execution drift is structurally mitigated rather than behaviorally required
- Federated and local agents share the same orchestration interface
- Context assembly is deterministic and reusable
- Escalation path ensures humans stay in the loop when agents stall

### Negative
- One GenServer per active task adds process count — acceptable at current scale, worth monitoring
- Heartbeat prompt quality matters: a poorly crafted interrogation produces a useless response
- Federated agents must respond to `task_heartbeat` events — requires plugin support (new signal type)

### Not Addressed
- Multi-agent coordination (parallel stages across agents) — deferred
- Cross-workspace task routing — deferred
- Heartbeat response parsing/evaluation — router trusts PubSub state, not response content

---

## References

- ADR 0002: Platform Domain Boundaries
- ADR 0011: Execution Runners, Context Plane, Run Control
- ADR 0013: Attention Routing (three-mode policy)
- ADR 0014: Runtime Channel and Federation Protocol
- ADR 0018: Tasks Persistent Model and Plan Engine
- `Platform.Tasks.PlanEngine` — stage/validation state machine
- `Platform.Federation.ToolSurface` — federated tool interface
- `Platform.Chat.AttentionRouter` — attention routing reference implementation

---

## 2026-07-15 Amendment: event-driven + ack-based liveness (task 019f640d)

The original decision above (fixed-cadence polling + a 1/3 → 2/3 → 3/3
escalation ladder) shipped and ran unchanged for ~30 days. It fired
false-positive stalls at a 100% rate: **165 stages breached a "missed
heartbeat" threshold, 0 of them were actually failed**. Every one was a
real agent working within normal-tail latency (long CI, human review sat
overnight, deploy blocked on a plate-of-glass migration). Meanwhile the
router paid a fat context-assembly cost on every polling tick because
`heartbeat_prompt/5` re-composed the full dispatch payload every ~10
minutes for the lifetime of the assignment.

This amendment records the redesign that landed in stages 2–5 of task
`019f640d`. The original sections above are preserved as historical
context — behaviour marked "retired" here is no longer wired.

### 1. What changes vs the original ADR

| Concern | Original | Amended |
|---|---|---|
| Liveness trigger | Fixed-cadence `Process.send_after(:heartbeat_tick)` every stage-kind-specific interval | Event-driven — timers armed on dispatch, extended on ack/progress, fired once at deadline |
| Detection ladder | 1/3 → 2/3 → 3/3 missed heartbeats, then `:stalled` and slow-polling every 30 min | Two flat deadlines: `no_ack_at` (5 min) and `safety_net_at` (stage-kind specific). No ladder. |
| Payload on every wake-up | Full `heartbeat_prompt/5` context (~7 KB per tick) | Initial dispatch is full; subsequent nudges are ~3-line "you're being pinged" preambles |
| Escape after false alert | Router bounced between `:stalled` ↔ `:running` on every late progress push | One `execution.blocked needs_human=true` post per fire; router stays `:stalled` until the human unblocks |
| Manual approval | Same cadence table (interval nil, effectively skipped) | Explicitly disabled at the timeout matrix: both `ack_ms` and `safety_net_ms` are `nil`; no timer is armed at all |

### 2. Why the change

- **Empirical: 100% false-positive stall rate.** Over 30 days, 165 stages tripped the escalation ladder; 0 needed human intervention to move forward. Every escalation resolved as "agent was still working, just outside the tuned interval". The threshold-tuning problem is bimodal and unsolvable at a single interval — deploy times, review times, and ci_check tails all have wide p50-to-p99 ratios. See the audit query in `audit/task_router_stall_baseline.exs`.
- **Payload flood.** `heartbeat_prompt/5` composed the full context (task, epic, project, plan, skills reference, evidence workflow, per-stage contract) on every tick. Measurable cost in both provider tokens and BEAM heap churn. The polling scheduler was the largest single write source into runtime channels.
- **Structural, not tunable.** No cadence table can distinguish a stuck 20-minute CI test from an actively-running 40-minute CI test. Only the agent (or its runtime) knows if it's alive. So ask it.

### 3. New state machine

Triggers that cause the router to `send(self(), :dispatch)`:

- `plan_updated approved` — task moves from `planning` → `in_progress`
- `stage_transitioned running` — new stage active
- `plan_updated completed` — task moves to `in_review` or `deploying`
- Failed-stage bounce — validation_failed on a stage the router owns

On each trigger, `do_dispatch/2`:

1. Composes context via `ContextAssembler.build/2` + prompt via `HeartbeatScheduler.dispatch_prompt/4` (full-fat body).
2. Broadcasts `attention` event to the assignee runtime.
3. Calls `LeaseManager.record_dispatch(task_id, stage_id, stage_kind, dispatched_at)` — this stamps `dispatched_at` and computes `no_ack_at = dispatched_at + ack_ms` and `safety_net_at = dispatched_at + safety_net_ms` from `stage_kind_timeouts()[stage_kind]`.
4. Arms one `:check_no_ack` timer and one `:check_safety_net` timer via `Process.send_after/3` — the router does not poll, it just wakes at those two instants.

Extension events:

- `execution.acked` runtime_event → `LeaseManager.record_ack/1` → clears `no_ack_at` (sets `nil`) and resets `no_ack_fired? = false`, then pushes `safety_net_at` forward to `now + safety_net_ms`.
- `execution.progress` / `execution.heartbeat` / validation_pass activity → `LeaseManager.record_progress/1` → pushes `safety_net_at` forward without touching the no-ack fields.

Fire paths (each gated by `LeaseManager.mark_*_fired/1` for once-only semantics — a spurious late wake-up cannot re-fire):

- `:check_no_ack` past `no_ack_at` with no ack → broadcast `execution.no_ack_timeout` runtime_event, post `execution.blocked needs_human=true` into the execution space, transition to `:stalled`. Router does **not** re-arm.
- `:check_safety_net` past `safety_net_at` with no progress → broadcast `execution.safety_net_fired` runtime_event, post the same `execution.blocked needs_human=true` message, transition to `:stalled`. Router does **not** re-arm.

Safety-net timeouts (source: p95 buffers from the audit):

| Stage kind | `ack_ms` | `safety_net_ms` |
|---|---|---|
| `coding` | 5 min | 90 min |
| `deploying` | 5 min | 90 min |
| `review` | 5 min | 90 min |
| `ci_check` | 5 min | 90 min |
| `planning` | 5 min | 120 min |
| `manual_approval` | `nil` | `nil` |

`manual_approval` values of `nil` are the router's signal to arm neither timer — human gates are not liveness-tracked here. A daily digest surfaces long-pending review requests separately (out of scope).

Full derivation and edge cases live inline in `Platform.Orchestration.LeaseManager.stage_kind_timeouts/0` (`apps/platform/lib/platform/orchestration/lease_manager.ex`).

### 4. Ack protocol

The `task_ack` MCP tool (introduced in stage 5 — see `Platform.Federation.ToolSurface` at the `task_ack` entry) is the executor's contract to prove liveness once per dispatch:

```
task_ack(task_id, stage_id \\ nil) ::
  %{task_id, stage_id, event_id, acked_at, next_safety_net_at}
```

- `task_id` required. `stage_id` optional — resolved via `current_running_stage(current_plan(task_id))` when omitted, so planning-phase agents (who ack before a plan exists) can still complete the handshake.
- Emits an `execution.acked` runtime_event through the standard runtime channel; the per-task `TaskRouter` consumes it in `apply_runtime_event/2`.
- Idempotent — re-calling is a soft ack refresh that emits a fresh event and extends the safety-net deadline. There is no ack-count budget.
- Returns `{:error, :not_found}` for unknown `task_id`, `{:error, :no_running_stage}` when no `stage_id` is supplied and none is running.

The dispatch prompt templates (SuiteExecutor, SuiteReviewer, SuiteDeployer, SuitePlanner) obligate every dispatched agent to call `task_ack` **as their first tool call**, before reading code or planning steps. This gives the router a positive signal within the 5-minute ack window and suppresses the no-ack alert without any need to guess how long a real ack should take.

### 5. Payload discipline

- **Initial dispatch** (`HeartbeatScheduler.dispatch_prompt/4`) — full context, unchanged size (~7 KB per audit test — task-status-specific body + `skills_reference` + `evidence_workflow_reference` + git workflow + per-stage execution/review/deploy contract). This is the runtime's one shot to load org conventions, evidence workflow, and the exact validation ids.
- **Safety-net / no-ack nudge** (`HeartbeatScheduler.nudge_prompt/2`) — target ~500 tokens (~2 KB), measured ~327–492 chars per stage 4/5 evidence. Two-line preamble plus a "## Completion Reminder" contract listing pending validation IDs and the action fork (ack / validation_pass / report_blocker). No skills reference, no evidence workflow, no task description, no org preamble. The runtime already has that from the initial dispatch — the nudge is a poke, not a re-brief.

The router routes accordingly: `do_dispatch/2` composes with `dispatch_prompt/4`; `fire_no_ack_alert/2` and `fire_safety_net_alert/2` compose with `nudge_prompt/2`. See `Platform.Orchestration.HeartbeatScheduler` module docs for the split rationale.

### 6. What was removed

- **The escalation ladder** (1/3 → 2/3 → 3/3 missed heartbeats). One `execution.blocked needs_human=true` fires per deadline breach; the router waits for a human, not for more of its own timers.
- **The polling scheduler** — `Process.send_after(:heartbeat_tick, interval)` and the `handle_info(:heartbeat_tick, ...)` clause are deleted. Timers are per-dispatch, not per-router-lifetime.
- **The 30-min re-poll after escalate.** `:stalled` is a real terminal state until a human intervenes.
- **`heartbeat_prompt/5`.** Deleted. Its DB template slug (`"heartbeat"`) is retained as DEPRECATED for one release cycle so migration readers aren't surprised — remove in the next cleanup.
- The `@cadence` table in `HeartbeatScheduler` is retained only for `deploy_failure` regression tests and is not consulted by production callers; the event-driven `LeaseManager` timeouts govern liveness.

### 7. Non-goals (v1 of the amended router)

- **Cross-agent liveness.** No liveness signals propagate between agents on parallel stages. Each dispatched agent owns its own ack + safety-net window.
- **Exponential backoff on repeat fires.** By construction there are no repeat fires — the once-only `mark_*_fired/1` gate makes backoff moot.
- **Per-task GenServer topology changes.** One `TaskRouter` per active assignment, same as ADR 0025 shipped. The redesign is behavioural, not structural.
- **Response-content parsing.** The router trusts runtime events and validation state; it does not read agent replies to decide liveness. Silent success is still success as long as the safety-net doesn't fire.

### 8. How to tune

Every operationally-tunable knob lives in a single map: `LeaseManager.stage_kind_timeouts/0` (`apps/platform/lib/platform/orchestration/lease_manager.ex`, module attribute `@stage_kind_timeouts`). Retuning is a one-line edit — no state-machine, prompt, or router changes required. Adding a new stage kind is an additional key in the same map; unknown stage kinds fall through to `%{ack_ms: nil, safety_net_ms: nil}` which armes no timers (i.e., safe default is "don't fire on things I don't understand").

If a stage kind starts producing false fires, the fix is to lift its `safety_net_ms` in that map. If it starts producing false negatives (real hangs sit past the deadline without anyone noticing), the fix is to lower it. Both are one-line PRs. No LLM, no ladder.

### Consequences of the amendment

**Positive**

- False-positive stalls collapse from 100% to (empirically) 0% in the 45-day post-ship window (see task 019f640d validation evidence).
- Payload cost drops from full-fat per polling tick to full-fat per state transition + short nudge on deadline breaches.
- The router is now describable in one page (7-item list above) instead of a cadence table + a ladder + a slow-polling recovery mode.
- Once-only fire semantics remove the router-bounce-between-`:running`-and-`:stalled` failure mode.

**Negative**

- Federated agents must call `task_ack` — old agent runtimes without the tool bound simply won't ack, which will fire a no-ack alert 5 minutes into every dispatch. Mitigation: `task_ack` is universally bound in the executor/reviewer/deployer/planner bundles as of stage 5; the deprecation window for legacy runtimes is the same one release cycle as the `"heartbeat"` template slug.
- Safety-net values are hard-coded per-stage-kind and not per-project. If a project has systematically slower CI than the p95 baseline, the amendment does not (yet) support per-project overrides — the tuning happens in the shared map. If this bites, revisit; do not add a per-project timeout table without evidence.

**Not addressed**

- Cross-workspace / cross-project liveness routing (same as original ADR).
- Multi-agent coordination on parallel stages (same as original ADR).
- Response-content-driven liveness (out of scope; the router remains deterministic).
