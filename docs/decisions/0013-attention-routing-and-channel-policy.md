# ADR 0013: Attention Routing and Channel Policy

**Status:** Proposed  
**Date:** 2026-03-19  
**Deciders:** the product owner, Zip  
**Supersedes:** Attention routing sections of ADR 0008  

---

## Context

ADR 0008 established three conceptual attention tiers for agent participation
in chat: mention-only, heartbeat digest, and active watcher. The current
implementation delivers Tier 1 (mention-only) via the `AttentionRouter`
GenServer, which matches `@display_name` in message content and dispatches to
`AgentResponder`.

This works but creates friction in practice:

1. **Multi-turn @mention fatigue** — once you summon an agent, you intuitively
   expect it to stay engaged. Having to re-mention it for every follow-up
   message is painful, especially on mobile.

2. **No channel-level policy** — attention mode is per-participant, not per-space.
   There is no way to say "agents in this channel should be collaborative" vs
   "agents here only respond when asked."

3. **No DM or group chat model** — the schema supports `kind: dm|group` on
   spaces, but there is no routing behavior that adapts to conversation type.
   A DM with an agent should not require @mentions at all.

4. **No cost-aware proactive engagement** — there is no mechanism for an agent
   to observe a conversation and decide to contribute without being summoned,
   while keeping costs bounded.

5. **No silencing or cooldown** — if an agent misjudges when to speak, there
   is no lightweight way for a user to tell it to back off.

---

## Decision

We will introduce a **channel-level attention policy** that governs how agents
participate in each space, with conversation-type defaults for DMs and groups,
a rolling conversation review mechanism for proactive engagement, and
first-class silencing controls.

---

## Decision Details

### 1. Three attention modes (space-level)

Each space gets a single `agent_attention` setting that controls the primary
agent's engagement style. This replaces per-participant `attention_mode` as the
primary control surface.

| Mode | Behavior | Default for |
|------|----------|-------------|
| `on_mention` | Agent responds only when @mentioned. Zero cost otherwise. | Channels |
| `collaborative` | Agent observes via periodic review. Engages when it can add value. Stays engaged after being summoned until dismissed or topic drifts. | Group DMs with agent |
| `directed` | Every message is directed at the agent. No @mention needed. | Agent DMs |

These are the only three options exposed to users. No sub-knobs, no threshold
sliders. The system handles cost control, triage model selection, and
engagement heuristics internally.

#### Conversation type defaults

| Space kind | Default mode | Rationale |
|------------|-------------|-----------|
| `channel` | `on_mention` | Channels are shared; agent should not dominate |
| `dm` (user ↔ agent) | `directed` | The whole point is talking to the agent |
| `dm` (user ↔ user) | N/A | No agent present unless explicitly added |
| `group` (with agent) | `collaborative` | Agent is a participant, not the focus |

Users can override the default for any space. A channel can be set to
`collaborative` if the team wants a more engaged agent. An agent DM can be
dialed back to `on_mention` if desired.

### 2. Collaborative mode: rolling conversation review

In `collaborative` mode, the agent does NOT receive every message as LLM input.
Instead:

1. **Messages accumulate in a buffer** (in-memory or lightweight persistence).

2. **A triage pass runs periodically** — triggered by either:
   - a message count threshold (e.g., every 5–10 messages), or
   - a time interval (e.g., every 60–120 seconds of activity), or
   - whichever comes first.

3. **The triage pass uses a cheap/fast model** (Haiku-class, local Ollama, or
   similar) and asks a structured question:
   - "Given this conversation excerpt, should the agent engage?"
   - "What could it contribute? (reply, canvas, task, nothing)"
   - "Confidence: high / medium / low"

4. **Only high-confidence triage results escalate** to the primary model for
   a full response.

5. **The triage prompt includes the agent's identity and role context** so the
   decision is grounded in what this specific agent is good at.

This is the cost control gate. The expensive model fires only when the cheap
model says "yes, engage now with this specific contribution type."

#### Triage decision categories

The triage model classifies its recommendation:

| Category | Action |
|----------|--------|
| `reply` | Agent should contribute a conversational reply |
| `react` | Agent should react with an emoji (lightweight acknowledgment) |
| `canvas` | Agent should create or update a canvas (plan, table, diagram) |
| `task` | Agent should create a task or action item |
| `observe` | Continue watching, don't engage yet |
| `disengage` | Conversation has moved away from agent's domain |

### 3. Sticky engagement ("conversation lease")

When an agent is summoned via @mention in `collaborative` or `on_mention` mode,
it enters a **sticky engagement** state for the current conversation context:

- The agent treats subsequent messages as directed at it without requiring
  re-mention.
- Sticky engagement continues until:
  - The user explicitly dismisses the agent ("thanks Zip", "that's all",
    or a UI silence control).
  - The conversation topic drifts significantly from the original summon
    context.
  - A configurable inactivity timeout elapses (no messages for N minutes).
- When sticky engagement would expire due to topic drift, the agent should
  **ask** whether it is still needed rather than silently disengaging.

The sticky state is tracked per-space (or per-thread if the summon happened
in a thread).

### 4. Silencing and cooldown

Users need dead-simple controls to manage agent participation:

| Control | Effect |
|---------|--------|
| "quiet" / "back off" (natural language) | Agent enters observe-only for the current conversation |
| Silence button (UI) | Same as above, with explicit duration option |
| "only when I ask" | Downgrades to `on_mention` for this session |
| "stay with us" | Upgrades to sticky engagement for current thread/topic |

Natural language silencing should be detectable by the triage model without
requiring a separate NLP pass — it's part of the same conversation review.

### 5. DM and group chat model

#### User ↔ Agent DM

- Default mode: `directed`
- Every message goes directly to the agent's primary model
- No triage pass needed — the user chose to talk to the agent
- This is the "ChatGPT desktop app" experience
- Agent has full tool access: reply, canvas, task creation, file ops

#### User ↔ User DM

- No agent present by default
- Either user can invite an agent, which converts the DM to a group
- Alternatively, a user can @ an agent from a DM if the platform supports
  cross-space agent invocation (future consideration)

#### Group DM / Group Chat

- Default mode: `collaborative`
- Behaves like a channel with attention policy
- Same triage mechanism, same silencing controls
- The key difference from channels: groups are typically smaller and more
  focused, so the triage threshold can be lower (agent engages more readily)

### 6. Principal agent and delegation

Rather than configuring attention policy per-agent in a space, the space has
one **principal agent** whose attention policy is configured at the space level.

- The principal agent is the one users interact with directly.
- If the principal agent determines that another agent or tool would better
  serve the request, it delegates internally.
- Users don't need to know about or configure secondary agents.
- This keeps the user-facing model simple: "this channel has Zip, and Zip is
  set to collaborative mode."

Multi-agent orchestration is an implementation detail of the agent runtime,
not a chat policy concern.

### 7. Cost control

Cost control is **implicit in the mode choice**, not a separate configuration
surface.

| Mode | Cost profile |
|------|-------------|
| `on_mention` | Zero cost when not mentioned. Full model cost per summon. |
| `collaborative` | Cheap triage cost per review cycle. Full model cost only on engagement. |
| `directed` | Full model cost per message. User opted in explicitly. |

For `collaborative` mode, the platform tracks:

- Triage calls per space per hour/day
- Full model engagements per space per hour/day
- Total token spend per space per billing period

If spend approaches a configured threshold, the system can:

1. Increase the triage interval (review less frequently)
2. Raise the confidence threshold for engagement
3. Fall back to `on_mention` mode with a notification to the space admin
4. Continue observing but suppress proactive engagement

These degradation steps happen automatically. The user sees "Zip is in
listen-only mode until tomorrow" rather than a cost configuration panel.

### 8. Schema changes

#### `chat_spaces` additions

```sql
ALTER TABLE chat_spaces ADD COLUMN agent_attention VARCHAR DEFAULT 'on_mention';
-- Values: on_mention | collaborative | directed
-- NULL means: use conversation-type default

ALTER TABLE chat_spaces ADD COLUMN attention_config JSONB DEFAULT '{}';
-- Internal config (triage interval, thresholds, budget)
-- Not directly user-editable; set by platform based on mode
```

#### `chat_participants` changes

The existing `attention_mode` field on participants becomes a **resolved
effective mode** rather than the primary configuration surface. It reflects
the space policy + any per-agent override.

#### New table: `chat_attention_state`

```sql
CREATE TABLE chat_attention_state (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  agent_participant_id UUID NOT NULL REFERENCES chat_participants(id),
  state VARCHAR NOT NULL DEFAULT 'idle',
  -- idle | engaged | silenced | observe_only
  engaged_since TIMESTAMPTZ,
  engaged_context TEXT,
  -- summary of what the agent was summoned for
  silenced_until TIMESTAMPTZ,
  last_triage_at TIMESTAMPTZ,
  triage_buffer_start_id UUID,
  -- first message id in current triage window
  metadata JSONB DEFAULT '{}',
  updated_at TIMESTAMPTZ NOT NULL
);
```

---

## Implementation phases

### Phase 1: Sticky engagement + DM model

- Add `agent_attention` column to `chat_spaces`
- Implement `directed` mode for agent DMs (no @mention required)
- Implement sticky engagement after @mention in channels
- Add basic silencing (natural language detection + UI button)
- No triage model yet — sticky engagement is the bridge

### Phase 2: Collaborative triage

- Implement rolling conversation buffer
- Add cheap model triage pass
- Implement triage decision categories (reply, react, canvas, task, observe)
- Add automatic budget degradation
- Instrument cost tracking per space

### Phase 3: Proactive artifact creation

- Enable canvas creation from triage decisions
- Enable task creation from triage decisions
- Add confidence thresholds for proactive actions
- Implement "agent is working on something" indicator in UI

### Phase 4: Multi-agent delegation

- Principal agent can delegate to specialized agents
- Delegation is transparent to the chat participant model
- Agent-to-agent coordination happens outside the attention router

---

## Consequences

### Positive

- Users get three simple, intuitive modes instead of a control panel
- Agents can be genuinely useful without constant @mention friction
- Cost is controlled structurally, not through user-facing budget knobs
- DMs with agents feel natural (like any chat AI product)
- The same model scales from 1:1 agent DMs to large collaborative channels

### Negative

- Triage model adds latency and (small) cost in collaborative mode
- Sticky engagement needs careful topic drift detection to avoid over-engagement
- Natural language silencing adds complexity to the triage prompt
- Principal agent pattern may limit flexibility for teams that want multiple
  independent agents in one channel

### Risks

- Cheap triage models may not be accurate enough, leading to either
  over-engagement (annoying) or under-engagement (useless)
- Proactive canvas/task creation may feel presumptuous if confidence
  calibration is wrong
- Cost degradation ("Zip is in listen-only mode") may frustrate users
  who don't understand why

---

## References

- ADR 0008: Chat Backend Architecture (attention tier concept)
- ADR 0012: Agent-Driven Live Canvas Architecture
- Platform principle: deterministic automation for mechanical tasks, LLM
  reasoning only where judgment is genuinely needed
- Operating principle: keep automations lean, clean, deterministic, and
  cost-conscious
