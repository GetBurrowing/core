# ADR 0014: Agent Federation and External Runtimes

**Status:** Proposed  
**Date:** 2026-03-19  
**Deciders:** Rowan, Zip  
**Related:** ADR 0008 (Chat Backend), ADR 0013 (Attention Routing), ADR 0007 (Agent Runtime)  

---

## Context

Startup Suite currently operates as a single-tenant system: one deployment, one
built-in agent runtime (bootstrapped from an OpenClaw workspace), and users who
interact through the web UI. This is sufficient for a solo operator or a small
team sharing one agent.

But a more powerful model is emerging from real usage: multiple people, each
running their own OpenClaw instance with their own agent, want to collaborate
in shared spaces where **both humans and agents** participate as peers.

Consider the scenario:

- Rowan runs OpenClaw with an agent named Zip.
- A coworker runs OpenClaw with an agent named Nova.
- Both want to use Startup Suite as a shared collaboration surface.
- Rowan can @mention Nova. The coworker can @mention Zip.
- Both agents follow the space's attention policy (ADR 0013).
- Agents can delegate to each other through the shared space.

This is not the "node" pattern (passive device endpoints). This is **agent
federation** — Suite becomes a collaboration plane that multiple independent
agent runtimes connect to.

---

## Decision

We will introduce a **federated agent runtime model** that allows external
agent runtimes (OpenClaw instances, or any conforming runtime) to register
agents as participants in Suite spaces, receive attention signals, and post
responses through a standardized protocol.

---

## Decision Details

### 1. Architecture: Suite as collaboration plane

Suite's role changes from "app with a built-in agent" to "collaboration plane
that agent runtimes connect to."

```
┌─────────────────────────────────────────────────┐
│                 Startup Suite                    │
│                                                  │
│   Spaces ─── Participants ─── Attention Router   │
│                    │                              │
│         ┌─────────┼──────────┐                   │
│         ▼         ▼          ▼                   │
│     [Users]   [Built-in]  [External]             │
│               [Runtime]   [Runtimes]             │
│                    │     ┌────┴────┐             │
│                    ▼     ▼         ▼             │
│                  Zip   Nova     Atlas             │
│                  (Rowan) (Alice)  (Bob)            │
└─────────────────────────────────────────────────┘
```

The existing built-in runtime (OpenClaw workspace bootstrap) becomes one
runtime among many. External runtimes connect over a defined protocol and
are treated identically by the attention router and chat system.

### 2. Runtime registration

An external runtime registers with Suite by establishing an authenticated
connection and declaring its agent identity.

#### Registration handshake

```
Runtime → Suite:  POST /api/runtimes/register
                  {
                    "runtime_id": "rowan-openclaw-home",
                    "agent": {
                      "name": "Zip",
                      "slug": "zip",
                      "capabilities": ["chat", "tools", "canvas"],
                      "model_info": "claude-opus-4-6"
                    },
                    "transport": "websocket",
                    "callback_url": "wss://suite.example.com/runtime/ws"
                  }

Suite → Runtime:  201 Created
                  {
                    "runtime_id": "rowan-openclaw-home",
                    "agent_participant_id": "uuid-...",
                    "token": "runtime-session-token",
                    "spaces": [...]
                  }
```

After registration:
- Suite creates (or reuses) an Agent record for the external agent
- Suite can add the agent as a participant in spaces
- The runtime receives a session token for subsequent API/WebSocket calls

#### Authentication

Runtimes authenticate via one of:
- **API key** — simple shared secret, suitable for trusted environments
- **OIDC** — runtime authenticates as a service principal via the same OIDC
  provider Suite uses for users
- **Mutual TLS** — for high-security deployments

The user who owns the runtime must authorize it first. A runtime cannot
self-register without the owning user's approval.

### 3. Transport: attention signals and responses

Once registered, the runtime needs to receive attention signals (messages
directed at its agent) and post responses back.

#### Option A: WebSocket (recommended for real-time)

```
Suite ──ws──► Runtime

Signal:   { "type": "attention", "signal": { "reason": "mention", ... }, "message": { ... }, "history": [...] }
Typing:   Runtime → Suite: { "type": "typing", "participant_id": "...", "typing": true }
Reply:    Runtime → Suite: { "type": "reply", "space_id": "...", "content": "...", "metadata": {...} }
Canvas:   Runtime → Suite: { "type": "canvas_create", "space_id": "...", "attrs": {...} }
```

The WebSocket carries the same signals that the built-in AgentResponder
currently receives — but over the network instead of in-process.

#### Option B: Webhooks (simpler, higher latency)

```
Suite → POST runtime_callback_url
        { "signal": {...}, "message": {...}, "history": [...] }

Runtime → POST suite_api/spaces/:id/messages
          { "content": "...", "participant_id": "..." }
```

Webhook transport adds latency but works through firewalls and doesn't
require persistent connections. Suitable for runtimes that aren't always
online.

#### Option C: OpenClaw Channel Plugin (bridge pattern)

For OpenClaw-specific runtimes, Suite can be implemented as an **OpenClaw
channel plugin** — the same way Telegram or Discord work. The plugin:

1. Connects to Suite's WebSocket API as a registered runtime
2. Maps Suite attention signals to OpenClaw's internal message routing
3. Posts OpenClaw responses back to Suite

This makes Suite look like "just another messaging surface" from OpenClaw's
perspective, which is architecturally elegant — the agent doesn't need to
know it's talking through Suite vs Telegram. The attention routing, context
management, and tool execution all happen inside OpenClaw.

```
Suite ◄──ws──► OpenClaw Channel Plugin ──► OpenClaw Gateway ──► Agent
```

This is the recommended path for OpenClaw runtimes because it requires zero
changes to the agent itself — it's purely a transport concern.

### 4. Agent identity and trust

#### Agent ownership

Every external agent has an **owning user** in Suite. The owning user:
- Authorized the runtime to register
- Controls which spaces the agent can join
- Can revoke the runtime's access at any time
- Is responsible for the agent's behavior (cost, conduct)

#### Agent identity persistence

External agents get real Agent records in Suite's database, just like the
built-in agent. Their participant records, attention state, message history,
and canvas contributions persist regardless of whether the runtime is
currently connected.

When a runtime disconnects:
- The agent's presence goes offline (gray dot)
- Attention signals queue (like heartbeat mode in ADR 0008)
- When the runtime reconnects, queued signals can be replayed or summarized

#### Trust levels

| Level | Description | Capabilities |
|-------|-------------|-------------|
| `viewer` | Agent can read spaces it's joined to | Read messages only |
| `participant` | Agent can chat and react | Post messages, reactions |
| `collaborator` | Agent can create artifacts | Canvases, tasks, tool use |
| `admin` | Agent can manage spaces | Invite, settings, archive |

Trust level is set per-agent by the owning user or a space admin.

### 5. Multi-agent attention (extending ADR 0013)

With multiple agents in a space, ADR 0013's attention router needs extension:

#### Principal agent per space (already designed)

Each space has one principal agent. When a user sends a message without
@mentioning a specific agent, the principal agent handles it (per the space's
attention mode).

#### Direct @mention override

@mentioning a specific agent always routes to that agent, regardless of
who the principal agent is. This is how a user "reaches past" the principal
to talk to another agent.

#### Agent-to-agent delegation

The principal agent can delegate to other agents in the space:

```
User: @Zip can you review this PR?
Zip:  I'll have Nova review it — she has the repo context.
      [internally: Suite routes delegation to Nova's runtime]
Nova: I've reviewed PR #42. Here are my findings...
```

Delegation happens through Suite's message system — Zip posts a message
that @mentions Nova, which triggers Nova's attention signal. No special
agent-to-agent API needed; it's just chat.

### 6. Schema changes

#### New table: `agent_runtimes`

```sql
CREATE TABLE agent_runtimes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  runtime_id VARCHAR NOT NULL UNIQUE,
  owner_user_id UUID NOT NULL REFERENCES users(id),
  agent_id UUID REFERENCES agents(id),
  display_name VARCHAR,
  transport VARCHAR NOT NULL DEFAULT 'websocket',
  callback_url VARCHAR,
  auth_method VARCHAR NOT NULL DEFAULT 'api_key',
  auth_credential_hash VARCHAR,
  status VARCHAR NOT NULL DEFAULT 'pending',
  -- pending | active | suspended | revoked
  trust_level VARCHAR NOT NULL DEFAULT 'participant',
  capabilities JSONB DEFAULT '[]',
  last_connected_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

#### `agents` table changes

```sql
ALTER TABLE agents ADD COLUMN runtime_type VARCHAR DEFAULT 'built_in';
-- Values: built_in | external
ALTER TABLE agents ADD COLUMN runtime_id UUID REFERENCES agent_runtimes(id);
```

### 7. OpenClaw Channel Plugin: `suite-channel`

The recommended integration path for OpenClaw runtimes is a channel plugin
that ships as an OpenClaw extension (similar to the `claude-runner` extension
pattern):

```
openclaw-suite-channel/
├── index.ts          # Plugin registration
├── src/
│   ├── suite-client.ts    # WebSocket client to Suite API
│   ├── message-bridge.ts  # Translate Suite signals ↔ OpenClaw messages
│   └── presence.ts        # Sync agent presence state
├── config.example.json
├── install.sh
└── openclaw.plugin.json
```

Configuration in OpenClaw:
```json
{
  "channels": {
    "suite": {
      "enabled": true,
      "url": "wss://suite.example.com/runtime/ws",
      "runtimeId": "rowan-openclaw-home",
      "apiKey": "...",
      "autoJoinSpaces": ["general"]
    }
  }
}
```

From the agent's perspective, messages from Suite look identical to messages
from Telegram or Discord. The agent responds normally, and the plugin
translates the response back to Suite.

---

## Implementation Phases

### Phase 1: Runtime registration and WebSocket transport

- `agent_runtimes` table and schema
- Runtime registration API (`POST /api/runtimes/register`)
- WebSocket endpoint for runtime connections (`/runtime/ws`)
- Extend AgentResponder to dispatch to external runtimes
- Presence tracking for external agents (online/offline)
- Admin UI for managing registered runtimes

### Phase 2: OpenClaw channel plugin

- Build `openclaw-suite-channel` extension
- Handle bidirectional message translation
- Sync attention state (engaged, silenced) between Suite and OpenClaw
- Handle reconnection and signal replay

### Phase 3: Multi-agent coordination

- Principal agent delegation through @mention chains
- Agent capability discovery (what can each agent do?)
- Cross-runtime canvas collaboration
- Cost attribution per runtime

### Phase 4: Trust and governance

- Granular trust levels with per-space overrides
- Audit trail for external agent actions
- Rate limiting per runtime
- Runtime health monitoring and automatic suspension

---

## Consequences

### Positive

- Suite becomes a true collaboration plane, not just a chat app with one agent
- Multiple people can bring their own agents to shared workspaces
- OpenClaw's existing channel plugin architecture makes integration natural
- Agents can specialize and delegate without tight coupling
- The built-in runtime remains the simplest path for solo operators

### Negative

- Adds networking complexity (WebSocket management, reconnection, auth)
- Multi-agent attention routing is more complex than single-agent
- External runtime failures are harder to debug than built-in ones
- Trust and security surface area increases significantly

### Risks

- Agent identity spoofing if auth is weak
- Runaway costs if external agents are poorly configured
- Conversation coherence degrades with too many agents in one space
- Users may not understand which agent does what without clear UX

---

## Open Questions

1. **Should external agents share memory/context?** Or is each agent's context
   strictly private to its runtime? The current design says private, but there
   may be use cases for shared context (e.g., a project knowledge base).

2. **How does Suite handle conflicting agent responses?** If two agents both
   respond to the same message (e.g., both are in collaborative mode), does
   Suite deduplicate, sequence, or let both through?

3. **Should the protocol be Suite-specific or generic?** A generic protocol
   (like an "Agent Channel Protocol") could allow Suite to connect to runtimes
   beyond OpenClaw. But premature generalization risks over-engineering.

4. **What happens to an agent's history when its runtime is revoked?** The
   messages and canvases persist (they're in Suite's DB), but should the
   agent's participant record be anonymized or preserved?

---

## References

- ADR 0007: Agent Runtime Architecture
- ADR 0008: Chat Backend Architecture
- ADR 0013: Attention Routing and Channel Policy
- OpenClaw channel plugin architecture
- OpenClaw `claude-runner` extension (prior art for runtime bridge pattern)
- Zap Channel project (prior art for custom OpenClaw channel backed by Phoenix)
