# ADR 0026: Task Execution Spaces

**Status:** Proposed
**Date:** 2026-03-23
**Related:** ADR 0008 (Chat Backend), ADR 0013 (Attention Routing), ADR 0025 (Task Router and Execution Orchestration)
**Deciders:** Rowan Ellis

---

## Context

ADR 0025 established the TaskRouter — a per-task orchestration process that dispatches context, sends heartbeats, and escalates stalls. Currently, the TaskRouter communicates with agents via raw `Endpoint.broadcast` to the runtime channel. This works but has no persistence, no audit trail, and no way for humans to observe or intervene in the conversation between the orchestrator and the executing agent.

Chat spaces (ADR 0008) already provide persistent, observable, attention-routed messaging. The attention router (ADR 0013) already knows how to route messages to agents based on space-level policy.

The gap: task execution has no dedicated space, and orchestration messages bypass the chat layer entirely.

---

## Decision

Introduce **execution spaces** — a new space kind (`"execution"`) purpose-built for task orchestration. Each active task assignment gets an execution space where:

1. **Log-only messages** (system status updates, stage transitions, stall alerts) are persisted and visible in the UI but do NOT trigger attention routing to agents.
2. **Engagement messages** (heartbeats, dispatch prompts) are persisted AND routed to the assigned agent via the existing AttentionRouter → AgentResponder path.

This reuses the entire chat infrastructure (persistence, LiveView broadcasting, presence) while adding a single discriminator (`log_only` boolean on messages) that the AttentionRouter checks before dispatching.

### Key Design Choices

- **Execution spaces are excluded from `list_spaces/1` by default** — they are internal orchestration artifacts, not user-created conversations.
- **The `log_only` flag lives on the message**, not the space — a single space contains both log and engagement messages.
- **`ExecutionSpace.find_or_create/1` is idempotent** — the TaskRouter calls it on init; if the space already exists (e.g., router restart), it reuses it.
- **Archival on task completion** — when the TaskRouter stops, the execution space is archived, preserving the full execution log.

### Orchestrated Attention Mode

When the AttentionRouter processes a message in an execution space:
- If `log_only: true` → write to DB, broadcast to LiveView, skip agent dispatch.
- If `log_only: false` → route to the assigned agent as normal (directed mode).

This is the "orchestrated" attention mode — the TaskRouter controls when the agent is engaged, not the message content.

---

## Schema Changes

### `chat_spaces` table
- Add `"execution"` to the allowed `kind` values (no DB-level check constraint exists; validation is in the Elixir schema).

### `chat_messages` table
- Add `log_only` boolean column, default `false`.

### `Platform.Chat.Space`
- Add `"execution"` to `@kinds`.
- Execution spaces skip the channel validation (no slug/name required — auto-generated from task ID).

### `Platform.Chat.Message`
- Add `log_only` field (boolean, default false).

---

## New Module: `Platform.Orchestration.ExecutionSpace`

```elixir
ExecutionSpace.find_or_create(task_id)    # idempotent space creation
ExecutionSpace.archive(task_id)           # archive on task complete
ExecutionSpace.add_participant(space_id, agent_id)
ExecutionSpace.post_log(space_id, content)        # log_only: true
ExecutionSpace.post_engagement(space_id, content)  # log_only: false, triggers routing
```

---

## Integration Points

| Component | Change |
|---|---|
| `TaskRouter` | Creates execution space on init; posts logs and engagements instead of raw broadcasts |
| `ContextAssembler` | Includes `execution_space_id` in context bundle |
| `AttentionRouter` | Checks `log_only` flag for execution space messages |
| `Chat.list_spaces/1` | Excludes execution spaces by default |

---

## Consequences

### Positive
- Full audit trail of orchestration ↔ agent communication
- Humans can observe task execution in real-time via the chat UI
- Reuses existing chat infrastructure (no new transport layer)
- AttentionRouter remains the single routing decision point

### Negative
- Adds a boolean column to the high-write `chat_messages` table
- Execution spaces increase total space count (mitigated by default exclusion from listings)

### Not Addressed
- Execution space UI rendering (deferred to frontend work)
- Human intervention via execution space messages (future: humans post in execution space to redirect agent)

---

## References

- ADR 0008: Chat Backend Architecture
- ADR 0013: Attention Routing and Channel Policy
- ADR 0025: Task Router and Execution Orchestration
