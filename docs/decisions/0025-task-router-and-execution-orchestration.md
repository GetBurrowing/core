# ADR 0025: Task Router and Execution Orchestration

**Status:** Proposed  
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
3. Suite chat surface posts a notification in the task's associated space
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
