# ADR 0038: Unified Chat Membership and Author Snapshots

**Status:** Proposed
**Date:** 2026-04-18
**Deciders:** Rowan
**Related:** ADR 0019 (Space-Agent Roster, superseded), ADR 0027 (Active Agent Mutex), ADR 0037 (@-Mention Wire Format)

---

## Context

The chat subsystem has two membership tables that both try to answer "is this agent in this space?" and neither knows about the other.

| Table | Purpose when added | What it grew into |
|---|---|---|
| `chat_participants` | Row per `(space, participant)` — users *and* agents — with `left_at` soft-delete. FK target for messages, reactions, pins, canvases. | Still the source of truth for message authorship, presence, attention mode, last-read cursor. |
| `chat_space_agents` | Added in ADR 0019 to represent the "principal agent" of a space and allow a simple admin list. | Quietly became load-bearing: the attention router (`attention_router.ex:282`) reads it to gate mention routing. |

Two dismissal paths exist. Neither fully evicts:

- **UI "dismiss agent"** (`shell_live.ex:173`) → `Chat.remove_space_agent/3` → hard-deletes from `chat_space_agents`. Leaves `chat_participants` row untouched.
- **MCP `space_leave`** (`tool_surface.ex:1292`) → `Chat.remove_participant/1` → sets `left_at` on `chat_participants`. Leaves `chat_space_agents` untouched.

And every soft-deleted row is resurrected on the next LiveView mount by `Chat.ensure_agent_participant/3` (`chat.ex:604-613`) — which clears `left_at`, resets `joined_at`, and rewrites `attention_mode`. Eleven callers trip this path, the hottest being `PresenceHooks.ensure_native_agent_presence/1` (`presence_hooks.ex:379-397`), which fires on every chat enter. The user-visible effect: a dismissed agent reappears the instant anyone reloads the space.

The "we soft-delete to preserve message attribution" rationale does not survive inspection. The render path calls `sender_name(participants_map, msg.participant_id)` where `participants_map` is built from `Chat.list_participants/1`, which filters `is_nil(left_at)` by default. A message authored by a dismissed participant *already* renders as generic "User" with a default avatar. `left_at` is pure tech debt carrying no history feature today.

## Decision

**Collapse membership to a single hard-deleted table. Snapshot author identity onto the message row at write time.**

Concretely:

1. **One membership table: `chat_participants`.** Delete `chat_space_agents`. Move `role ∈ {principal, member}` onto `chat_participants`. `chat_spaces.primary_agent_id` already exists and stays.
2. **Hard-delete on dismissal.** Drop `chat_participants.left_at`. Drop the `include_left` option on `list_participants`. Membership is now a present-tense fact: either the row exists or it doesn't.
3. **Snapshot author identity onto `chat_messages`.** Add `author_display_name`, `author_avatar_url`, `author_participant_type`, `author_agent_id`, `author_user_id`. Written at `post_message` time, never mutated. Messages no longer depend on a live `chat_participants` row for rendering — if the author has since been dismissed, their historical messages still render with the name and avatar they had when they spoke.
4. **Delete `Chat.ensure_agent_participant/3`.** Its callers split into two narrower functions: `add_agent_participant/3` (insert-if-missing, for paths that legitimately want to create fresh membership) and `get_agent_participant/2` (strict lookup, returns nil if absent — for paths that should not create).
5. **Remove the LV-mount auto-join.** `PresenceHooks.ensure_native_agent_presence/1` goes away. If a workspace has a native agent, that agent is added when a space is *created* (channel, DM, execution space), not every time anyone opens it. Dismissal is durable.
6. **@-mention re-invites.** In `Chat.post_message/2`, after parsing mentions (ADR 0037's `@[Name]` format), any mentioned agent without a current `chat_participants` row gets inserted. No "reinstate" verb, no flag — just `INSERT ... ON CONFLICT DO NOTHING` followed by the normal flow.
7. **Append-only membership log (optional, Phase 2).** If product requires "who used to be in this space," add `chat_membership_events(space_id, participant_type, participant_id, display_name_at_event, event :: joined|left, actor_id, at)`. Obvious shape, no FKs, no state machine. Out of scope for this ADR; called out so we don't re-invent `left_at` under a different name.

The mental model for the product owner and for future contributors collapses to:

- **@mention an agent → they're in the space.** (Fresh row inserted if absent.)
- **Dismiss an agent → they're gone.** (Row deleted.)

No state machine. No nullability-encoded state. No verbs that only experts can say out loud.

## Alternatives considered

### 1. Keep `left_at`; stop `ensure_agent_participant` from resurrecting; add `reinstate_agent/2`

Smaller patch. Stops the immediate bleeding.

**Rejected.** Leaves the split-brain between `chat_participants` and `chat_space_agents` intact. Leaves `left_at` as vestigial state that no query consumes. Introduces `reinstate_agent` as a new verb whose existence is a signature of the state machine we said we were removing. Smaller diff, larger cognitive surface.

### 2. Keep both tables; make `chat_space_agents` authoritative for roster and `chat_participants` authoritative for messaging

Explicit split of responsibility.

**Rejected.** Two sources of truth for overlapping state never stop drifting. The dismissal split-brain we already have is exactly this failure mode. Product questions like "is Higgins in this space?" would have to specify which table they mean, which is an uncontrolled leak of the internal model.

### 3. Soft-delete but use `left_at` consistently everywhere

Fix the render path to surface dismissed participants' names on historical messages via `list_participants(include_left: true)`.

**Rejected.** Salvages `left_at` but the unique constraint `(space_id, participant_type, participant_id)` still forces re-adds to mutate in place, which is exactly the "state machine" the product owner rejected. Doesn't unify with `chat_space_agents`. Doesn't fix `ensure_agent_participant`'s footgun. Wrong axis of simplification.

### 4. Denormalize author identity onto messages *without* removing `left_at`

Keep soft-delete as an audit trail; read author from the message row.

**Rejected.** If we're denormalizing anyway, the only thing `left_at` is doing is enabling resurrection. With snapshots on messages, `left_at` earns nothing and costs the state-machine bugs we're trying to kill.

## Consequences

### Schema changes (single migration)

| Change | Why |
|---|---|
| `chat_messages`: add `author_display_name text`, `author_avatar_url text`, `author_participant_type text`, `author_agent_id uuid`, `author_user_id uuid` | Author identity snapshot. |
| `chat_pins`: add `pinned_by_display_name text`, `pinned_by_participant_type text` | Pin attribution survives dismissal. |
| `chat_canvases`: add `created_by_display_name text`, `created_by_participant_type text` | Canvas attribution survives dismissal. |
| Backfill from `chat_participants` JOIN for all three tables | One-shot. |
| `DELETE FROM chat_participants WHERE left_at IS NOT NULL` | Already invisible to the UI; backfill has preserved what was visible. |
| `chat_participants`: drop `left_at` | State machine gone. |
| `chat_participants`: add `role text NOT NULL DEFAULT 'member'` with CHECK `(role IN ('principal','member','admin','observer'))` | Absorb `chat_space_agents.role`. |
| `chat_participants`: backfill `role` from `chat_space_agents` for agent rows | Preserve existing principal designation. |
| `DROP TABLE chat_space_agents` | Unified. |
| Foreign keys: `chat_messages.participant_id`, `chat_reactions.participant_id`, `chat_pins.pinned_by`, `chat_canvases.created_by` → `ON DELETE SET NULL` | Rows survive participant deletion; rendering falls back to snapshot columns. |

### Code changes

**Deletions** (full function/module removal):

- `Chat.ensure_agent_participant/3` and all three clauses
- `Chat.add_space_agent/3`, `Chat.remove_space_agent/3`, `Chat.ensure_space_agent/3`, `Chat.list_space_agents/1`, `Chat.set_principal_agent/2`
- `Platform.Chat.SpaceAgent` module
- `PresenceHooks.ensure_native_agent_presence/1`
- `include_left` option on `Chat.list_participants/2`

**Additions**:

- `Chat.add_agent_participant/3` — insert-if-missing. Raises if a row already exists. No state check because there's no state.
- `Chat.get_agent_participant/2` — strict lookup; `nil` if absent.
- Mention-reinvite in `Chat.post_message/2` — after `AttentionRouter` extracts mention targets, any mentioned agent with no current participant row gets an `add_agent_participant` call; message write and reinvite happen in the same transaction.

**Callsite audit** (current `ensure_agent_participant` callers):

| Caller | New call | Why |
|---|---|---|
| `presence_hooks.ex:384` | **deleted** | Never auto-add on LV mount. Dismissal is durable. |
| `attention_router.ex:417` | `add_agent_participant` for execution-space assignee | Same semantics, no resurrect path. |
| `agent_responder.ex:290` | `get_agent_participant` + crash if missing | If the responder was invoked, the agent is already a participant — defensive guard, not auto-create. |
| `system_event_scheduler.ex:190` | `add_agent_participant` | Heartbeat target; add-if-missing is correct. |
| `federation.ex:179` | `add_agent_participant` | Federation add-me; explicit intent. |
| `tool_surface.ex:2741` | `get_agent_participant`; return structured error if missing | MCP caller not in space gets `{:error, :not_a_participant}`; no silent rejoin. |
| `execution_space.ex:61` | `add_agent_participant` on space creation | Legitimate first-insert. |
| `chat.ex:238, 304` (DM / group setup) | `add_agent_participant` | Legitimate first-insert. |
| `control_center_live.ex:339` | `add_agent_participant` | Admin "add agent" click. |
| `runtime_channel.ex:450`, `mcp_controller.ex:130` | `get_agent_participant` | Resolve for message attribution only. |

**AttentionRouter** (`attention_router.ex`):

- `route_agents/3`'s roster-gate (`roster_by_agent_id`) moves off `chat_space_agents` and onto `chat_participants.role` directly.
- The "agent is a participant but NOT in roster — block mention (ADR 0027)" branch collapses: there is no longer a separate roster.

### Tests

**Reshaped**:

- `test/platform/chat/space_agent_test.exs` — collapses to zero or folds into `participant_test.exs`.
- `test/platform/chat/attention_router_test.exs` — swap `ensure_agent_participant` setups for `add_agent_participant`. No behavioral change expected.
- `test/platform/federation/tool_surface_test.exs:736-757` ("idempotent leave") — semantics change: after leave, the row is gone; the "not found" path is now primary.
- `test/platform_web/channels/runtime_channel_test.exs:307` — "agent IS auto-joined" expectation inverts.

**New**:

- "Dismiss then LV reload does not re-add" — the original bug, now a regression test.
- "Dismiss then @-mention re-adds with a new `participant.id`" — the product behaviour.
- "Historical messages by a dismissed agent render with correct name + avatar via snapshot" — covers the denormalization.
- "Leaving a space clears the ActiveAgentStore entry if held" — existing behaviour, now load-bearing.

### Migration

Single-commit migration, safe to run online:

1. `ALTER TABLE` additions (nullable columns — zero-downtime).
2. Backfill in a single transaction per table. `chat_messages` is the largest; chunked UPDATE with `WHERE author_display_name IS NULL LIMIT 10000` batched.
3. Delete `chat_participants WHERE left_at IS NOT NULL`.
4. `ALTER TABLE chat_participants DROP COLUMN left_at`.
5. `chat_participants` gains `role` NOT NULL with default; backfill `'principal'` from `chat_space_agents`.
6. `DROP TABLE chat_space_agents`.

No shadow-write period needed — the snapshot columns are source-of-truth on day one for new messages, and backfilled for old ones in the same migration.

### Risks

- **Reactions by deleted participants**: FK set to null. Reactions still count but render without attribution. Acceptable — reactions are semi-anonymous in the UI already.
- **`last_read_message_id` on rejoin**: resets. Correct — someone kicked and @-mentioned back is a new arrival. Not a regression.
- **Federated callers holding stale `participant_id`**: `get_agent_participant` returns nil; MCP tool calls surface `{:error, :not_a_participant}`. External runtimes learn they were kicked on next tool call, which is the right signal.
- **Humans vs agents**: the model applies uniformly. A user kicked from a channel hard-deletes; their messages stay attributed via snapshot. No reason to special-case humans.
- **"Who used to be in this space" audit**: lost from the schema. Out of scope here; if product needs it, Phase 2 adds `chat_membership_events`. Not a reason to keep `left_at`.
