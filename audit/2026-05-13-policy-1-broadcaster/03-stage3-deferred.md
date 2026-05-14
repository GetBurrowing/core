# Policy 1 Stage 3 — agent-side consumer wiring deferred

**Task:** `019e1e83-fe24-77c4-8a7b-8f90fb5cfca5` — Policy 1 narrow notification scoping for editable messages
**Plan stage:** 3 of 5 ("Agent runtime subscribes to its participant topic")
**Decision date:** 2026-05-13
**Decision:** Skip the consumer-side wiring. Ship Stages 1 + 2 (the producer half) alone.

## Why

The plan named two touch points for Stage 3:

- `apps/platform/lib/platform/agents/agent_runtime.ex`
- `apps/platform/lib/platform/agents/agent_server.ex`

Both files exist, but neither plays the role the plan assumed:

1. `agent_runtime.ex` is `Platform.Federation.AgentRuntime` — an Ecto schema
   for federation-runtime DB rows (the records that back this Claude Code
   plugin's `SUITE_RUNTIME_ID`). It is not a process, has no `handle_info`,
   and does not subscribe to PubSub.
2. `agent_server.ex` is `Platform.Agents.AgentServer` — a real GenServer,
   but its current `init/1` and `handle_info/2` clauses do not subscribe
   to any chat topic and have no consumer for `{:message_edited, _}`.

A repo-wide grep for `{:message_edited` confirms only two existing
consumers, both LiveView-side (user clients):

```
apps/platform/lib/platform_web/live/chat/messages_hooks.ex:533
apps/platform/lib/platform_web/live/chat/messages_hooks.ex:542
```

There is no agent-side `{:message_edited}` consumer to redirect from the
space topic to the participant topic. Stage 3 as specified would have us
add a `Phoenix.PubSub.subscribe(Platform.PubSub, "chat:participant:<id>")`
call inside an agent process that has nowhere to forward the event. That
would create a dead subscription — code that exists only to satisfy a
plan stage, with no behavior to test.

## Why shipping the producer alone is safe

`Phoenix.PubSub.broadcast/3` to a topic with zero subscribers is a silent
no-op: it returns `:ok`, costs ~one ETS lookup, and queues nothing. The
per-participant fan-out added in Stage 2 emits to `chat:participant:<id>`
topics that no process subscribes to today. That is fine — the broadcast
is fire-and-forget, and the privacy invariant Policy 1 cares about
("agents merely subscribed to the channel MUST NOT receive edits") holds
vacuously: no agent receives `{:message_edited}` on any topic, because no
agent subscribes.

When a future agent feature needs to react to edits (memory consolidation,
context invalidation, retraction handling), the consumer subscribes
**only** to its own `chat:participant:<id>` topic. The producer side is
already correctly scoped, so the privacy invariant is enforced at the
point of broadcast rather than in receiver code — exactly the
"privacy-by-construction" property the plan's Stage 1 rationale called
out as the reason to pick option (a) over option (b).

## What "broadcaster alone" leaves for follow-up

Whoever wires the agent-side consumer should:

1. Inside the agent's GenServer (`Platform.Agents.AgentServer` or its
   replacement), `Phoenix.PubSub.subscribe(Platform.PubSub,
   "chat:participant:" <> participant_id)` at the point the agent's
   participant binding is established for a space (i.e. wherever the
   agent learns it has a participant row in that space).
2. Add `handle_info({:message_edited, payload}, state)` and forward to
   whatever working-memory / context-invalidation hook the consumer
   needs.
3. Do **not** subscribe to the space topic for `{:message_edited}` on the
   agent side — that would re-introduce the Policy 1 violation.
4. Cleanly unsubscribe on agent shutdown / participant-binding loss.

The `chat:participant:<id>` topic name is the contract surface; the
Stage 4 adversarial tests in
`apps/platform/test/platform/chat/policy_1_edit_scoping_test.exs` pin it
down as a regression-prevention floor.

## Audit linkage

- Stage 4 of the original verification task
  (`019df569-b82a-7319-8ac4-b9419ffe87b9`,
  `audit/2026-05-12-editable-messages-verify/04-stage4-policy-coverage.md`)
  flagged Policy 1 as non-conformant because the broadcast was
  space-wide. With Stages 1 + 2 of this task shipped, the producer side
  is conformant for any consumer that subscribes correctly. The
  verification audit doc on that branch should be updated to mark Policy
  1 as **producer-conformant, consumer-deferred** rather than
  unconditionally conformant.
