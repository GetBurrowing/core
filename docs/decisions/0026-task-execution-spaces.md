# ADR 0026: Task Execution Spaces

**Status:** Draft  
**Date:** 2026-03-23  
**Related:** ADR 0008 (Chat Backend), ADR 0013 (Attention Routing), ADR 0014 (Agent Federation), ADR 0018 (Tasks — Plan Engine), ADR 0025 (Task Router)  
**Deciders:** Rowan Ellis

---

## Context

ADR 0025 introduced the TaskRouter — a supervised GenServer per active task assignment responsible for dispatch, heartbeat, and escalation. It dispatches to federated agents via `RuntimeChannel` attention events and observes progress via PubSub plan engine events.

A gap remains: **execution is opaque in real time.**

The TaskRouter knows a task was dispatched and knows when a validation passes. It does not know what the agent is doing between those two moments. The agent's working commentary, intermediate decisions, and blockers are invisible to the orchestrator and to the human team until the stage resolves.

This is the same problem we solved for human collaboration: use a shared space. A space provides:
- A persistent, ordered message stream
- Participant-aware routing (the agent is already a participant)
- Read access for all space members — agents and humans alike
- Native tool surface (canvas, task, task operations)
- No new primitives required

The insight: **task execution is a conversation between the TaskRouter and the assigned agent.** Suite already knows how to host conversations.

---

## Problem: Execution Opacity

Without a shared execution space:
- The TaskRouter dispatches via RuntimeChannel — a fire-and-forget attention signal
- The agent works silently; only terminal outcomes (validation evidence, stage transitions) surface via PubSub
- Humans cannot observe the work in progress without polling the task detail panel
- The orchestrator cannot distinguish "agent is working" from "agent has stalled" until the stall threshold fires
- There is no persistent record of what the agent tried, what it found, or why it made a decision

This creates a reliability problem (stalls are detected late) and an accountability problem (no audit trail for agent decisions).

---

## Decision

For each task assignment, the TaskRouter creates (or reuses) a **dedicated Suite space** scoped to that task. This space serves as the execution channel: the agent streams its working commentary, the TaskRouter posts structured status events, and humans can observe or intervene at any time.

This space is called the **task execution space**.

---

## Design

### Space lifecycle

```
assign_task(task_id, assignee)
  └── TaskRouter.init
        ├── find_or_create_execution_space(task_id)    # idempotent
        ├── ensure_agent_participant(space_id, agent)   # agent joins if not already
        ├── ensure_orchestrator_participant(space_id)   # TaskRouter as system participant
        └── dispatch initial attention event (with space_id in context)
```

On `unassign_task/1` or task completion, the space is **archived, not deleted**. It becomes a permanent audit trail for what happened during execution.

### Space identity

Spaces are named deterministically:
```
task-exec-{task_id_short}
```

e.g. `task-exec-019d18f1` — human-readable, unique, collision-free.

The space `kind` is a new value: `"execution"`. This distinguishes execution spaces from regular channels and DMs, allows filtering in the UI, and signals to the attention router that different policies apply.

### Who participates

| Participant | Role | Why |
|---|---|---|
| Assigned agent | `collaborator` | Primary worker; posts progress, receives heartbeats |
| TaskRouter | System participant | Posts structured status events; monitors activity |
| Task owner (human) | `participant` | Passive observer by default; can intervene |
| Other agents | Optional | Added explicitly if delegation happens |

The TaskRouter participates as a system actor, not as a human user. It posts structured events (dispatch confirmation, heartbeat pings, stall alerts, escalation notices) as chat messages. This gives humans a readable timeline of orchestration events alongside the agent's commentary.

### Two classes of messages in an execution space

Not all messages in an execution space are equal. A sub-agent streaming its progress should not activate the implementing agent on every update — that burns tokens and defeats the purpose. The space is a transparent log first, and an engagement channel second.

Messages in an execution space fall into two categories:

| Class | Examples | Triggers agent attention? |
|---|---|---|
| **Engagement** | TaskRouter heartbeat, human feedback | ✅ Yes |
| **Log-only** | Sub-agent progress, system lifecycle events, tool outputs | ❌ No |

The distinction is carried on the message itself — a `log_only: true` flag (or a dedicated participant role) that tells the attention router to write the message to the space but not route it to the implementing agent.

The implementing agent's relationship to the space:
- **Reacts to**: heartbeats from the TaskRouter, direct messages from humans
- **Ignores (in terms of attention)**: everything else in the space
- **Can reference**: the full space history at any time via the existing tools — if it wants to understand what its sub-agents have done, the log is there. It just isn't poked every time something is written.

This keeps the execution space as a transparency layer for humans without turning the implementing agent into a token sink that responds to every sub-agent progress update.

### Attention routing in execution spaces

Execution spaces use a new attention mode: **`orchestrated`**.

In `orchestrated` mode:
- Only **engagement-class** messages trigger the agent's attention
- Log-only messages are written to the space but bypass attention routing entirely
- @mentions from humans always trigger attention (override)
- TaskRouter heartbeats are always engagement-class regardless of other message volume

This is distinct from the existing `directed` mode (ADR 0013), which still routes all messages to the principal agent. `orchestrated` adds the log/engage split on top.

### What the agent posts

The implementing agent uses the execution space for:
- **Working commentary** — what it's doing, what it found, intermediate decisions (log-only by default, unless it @mentions someone)
- **Evidence pushes** — validation evidence via tool calls (triggers plan engine via PubSub, not via space attention)
- **Blocker reports** — via `report_blocker` tool (engagement-class — triggers TaskRouter and human)
- **Direct human reply** — when a human posts in the space, the agent's response goes here

The agent's commentary is a side-channel for human observers. It does not drive routing decisions.

### What the TaskRouter posts

The TaskRouter posts two kinds of messages:

**Engagement (heartbeats — delivered to agent):**
```
[heartbeat] Stage: coding | 12 min elapsed | Pending: test_pass, lint_pass
Last evidence: none submitted.
Either push validation evidence or report a blocker.
<context snapshot>
```

**Log-only (lifecycle events — visible to humans, not delivered to agent):**
```
[system] Task assigned: "Implement ContextAssembler"
         Stage 1/7 | Assignee: higgins | Heartbeat: 10min

[system] ⚠ Stall detected (28 min, 2 missed heartbeats) — escalating

[system] Stage 1 complete — test_pass ✓ lint_pass ✓ — advancing to stage 2
```

The human observer sees both streams interleaved: the orchestrator's lifecycle events, the agent's commentary, and the heartbeat exchanges. Full picture.

### Heartbeat delivery

The TaskRouter's heartbeat posts an engagement-class message to the execution space. The attention router delivers it to the agent — same path as any human message.

```
TaskRouter heartbeat fires
  └── Chat.post_message(execution_space_id, task_router_participant_id,
        content: HeartbeatScheduler.heartbeat_prompt(...),
        metadata: %{class: :engagement, signal: :task_heartbeat})
        # attention router sees class: :engagement → routes to agent
```

Advantages over raw RuntimeChannel broadcast:
- Heartbeat is visible to humans — they can see what prompt the agent received
- Agent's response is in the same space — full accountability
- Offline queueing works for free (existing attention router behavior)
- Log-only messages don't waste agent tokens

### New tool: `report_blocker`

Agents gain one new structured tool call for explicit blocker reporting:

```
report_blocker
  Purpose: Report a blocker that prevents stage progress.
  Params:
    task_id      — UUID of the task
    stage_id     — UUID of the current stage
    description  — What is blocked and why (string)
    needs_human  — true if human intervention is required (boolean)
  Returns: { blocker_id, escalated }
  When: Agent cannot proceed and needs to surface the reason explicitly.
```

This is distinct from going silent (stall). It is an explicit signal — "I know I am blocked, here is why." The TaskRouter receives it via PubSub, pauses the heartbeat timer, and (if `needs_human: true`) escalates immediately rather than waiting for the stall threshold.

---

## Relationship to Existing Components

| Component | Impact |
|---|---|
| `TaskRouter` | Gains `execution_space_id` in state; heartbeat posts to space instead of raw broadcast |
| `ContextAssembler` | Includes `execution_space_id` in context bundle so agent knows where to post |
| `Chat.AttentionRouter` | Learns `directed` mode for execution spaces |
| `ToolSurface` | Gains `report_blocker` tool |
| `Tasks LiveView` | Can link to execution space from task detail panel |
| `Chat spaces` | New `kind: "execution"` value; archival behavior on completion |

---

## Space Discovery and the Spaces Manifest

Execution spaces are **explicitly excluded from the `spaces_manifest` push** sent to agents at handshake time (ADR 0014 §3, `RuntimeChannel.handle_info(:send_spaces_manifest, ...)`).

### Why

An agent running tasks over months or years could accumulate participation in thousands of execution spaces. Including them all in the handshake manifest would:
- Bloat the capabilities/manifest payload with irrelevant historical data
- Pollute the agent's ambient context with every task it has ever touched
- Undermine the "push only what's relevant" principle from ADR 0014

### How the agent learns about its execution space

The agent does **not** need to know its execution space at handshake time. It learns about it exactly when it becomes relevant — in the dispatch context:

```json
{
  "signal": { "reason": "task_assigned", "task_id": "..." },
  "context": {
    "execution_space": {
      "id": "uuid",
      "name": "task-exec-019d18f1"
    },
    ...
  }
}
```

`ContextAssembler.build/1` always includes `execution_space_id` in the context bundle. The agent has the space reference for the duration of the task assignment. When the task ends, the space becomes archive — the agent doesn't need to carry it forward.

### What the spaces manifest does include

The manifest push contains only spaces where the agent is an **active participant** in a non-execution context:
- Regular channels (`kind: "channel"`)
- Group spaces (`kind: "group"`)
- DMs (`kind: "dm"`)

Execution spaces (`kind: "execution"`) are filtered out at the manifest query level — `list_spaces_for_agent/1` excludes them by default via `include_execution: false`.

### Discovery for canvas/artifact use

If an agent needs to post a canvas, screenshot, or arch diagram **to an execution space**, it uses the `execution_space.id` from the dispatch context — not the manifest. This is the correct and sufficient path. The agent already has the space ID from the context bundle; it doesn't need to discover it.

---

## What This Is Not

- **Not a replacement for the plan engine.** Stage/validation state still lives in `Platform.Tasks`. The execution space is a communication layer, not a state machine.
- **Not a new persistence model.** Uses existing `Chat.Space` and message infrastructure. No new tables needed beyond `kind: "execution"` on spaces.
- **Not mandatory for all tasks.** Tasks without an assigned agent (human-only or manually progressed) do not get execution spaces. The space is created when `assign_task/2` is called.

---

## Implementation Phases

### Phase 1: Execution space creation and agent participation
- `kind: "execution"` on `chat_spaces` (migration + schema)
- `Platform.Orchestration.ExecutionSpace` — `find_or_create/1`, `archive/1`
- TaskRouter gains `execution_space_id` in state; creates space on init
- ContextAssembler includes space_id in dispatch context

### Phase 2: Heartbeat via space posts
- TaskRouter posts heartbeat as chat message instead of raw RuntimeChannel broadcast
- `directed` attention mode for execution spaces
- TaskRouter participant identity (system actor)

### Phase 3: Structured system messages
- TaskRouter posts structured lifecycle events (assigned, stall, stage complete, escalation)
- Tasks LiveView links to execution space from task detail panel

### Phase 4: `report_blocker` tool
- Add to ToolSurface
- TaskRouter handles `{:blocker_reported, ...}` PubSub event

---

## Open Questions

1. **Space visibility and navigation.** Execution spaces do not appear in the main channels/DMs sidebar — they would create noise at volume. Accessible from the task detail panel via a "View execution space" link. A filtered view showing all active execution spaces (e.g. in the task board or a debug panel) may be useful during early rollout.

2. **Multi-agent tasks.** If a stage is reassigned mid-execution (agent stalls, human reassigns), does the new agent join the existing space or get a new one? Leaning: join the existing space — the new agent benefits from seeing what the prior agent tried. The full history is the handoff context.

3. **Execution space quotas.** Long-running projects could accumulate many archived execution spaces. Leaning: keep indefinitely for now; add a configurable retention policy when storage becomes a concern.

4. **Agent commentary quality.** The heartbeat prompt should explicitly instruct the agent to post working commentary to the execution space. Nothing enforces this structurally — the prompt is the lever.

5. **Sub-agent log messages.** When a sub-agent spawned by the implementing agent makes progress, what posts to the execution space? Simplest path: the implementing agent posts on behalf of its sub-agents as it receives updates. Sub-agents as direct participants is a future extension. This is an implementation detail, not a protocol decision.

---

## Consequences

### Positive
- Execution becomes observable in real time without burning tokens on the implementing agent
- Log/engage split means sub-agent progress streams freely without activating the implementing agent
- Heartbeat delivery uses existing attention routing — no special-casing
- Humans can observe and intervene via the same interface they use for everything else
- Persistent audit trail for every task execution; archived spaces are the execution record
- `report_blocker` closes the gap between "going silent" and "explicitly stuck"
- Spaces don't clutter the main nav — accessible on demand from the task detail panel

### Negative
- Creates one space per task assignment — space count grows with task volume
- `orchestrated` attention mode adds complexity to the attention router
- Agent commentary quality is not structurally enforceable — depends on prompt quality
- Sub-agent log streaming requires the implementing agent to actively post updates (or a new sub-agent participant model later)

---

## References

- ADR 0008: Chat Backend Architecture
- ADR 0013: Attention Routing and Channel Policy
- ADR 0014: Agent Federation and External Runtimes
- ADR 0018: Tasks — Persistent Model and Plan Engine
- ADR 0025: Task Router and Execution Orchestration
- `Platform.Orchestration.TaskRouter` — dispatch and heartbeat implementation
- `Platform.Chat.AttentionRouter` — existing attention mode reference
