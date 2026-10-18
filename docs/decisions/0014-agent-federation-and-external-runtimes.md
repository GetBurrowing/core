# ADR 0014: Agent Federation and External Runtimes

**Status:** Proposed  
**Date:** 2026-03-19  
**Deciders:** the product owner, Zip  
**Related:** ADR 0008 (Chat Backend), ADR 0013 (Attention Routing), ADR 0007 (Agent Runtime)  
**Research:** arXiv:2602.14878 (MCP Tool Description Quality), arXiv:2603.13417 (MCP Production Patterns)  

---

## Context

Burrow currently operates as a single-tenant system: one deployment, one
built-in agent runtime (bootstrapped from an OpenClaw workspace), and users who
interact through the web UI. This is sufficient for a solo operator or a small
team sharing one agent.

But a more powerful model is emerging from real usage: multiple people, each
running their own OpenClaw instance with their own agent, want to collaborate
in shared spaces where **both humans and agents** participate as peers.

Consider the scenario:

- the product owner runs OpenClaw with an agent named Zip.
- A coworker runs OpenClaw with an agent named Nova.
- Both want to use Burrow as a shared collaboration surface.
- the product owner can @mention Nova. The coworker can @mention Zip.
- Both agents follow the space's attention policy (ADR 0013).
- Agents can delegate to each other through the shared space.

This is not the "node" pattern (passive device endpoints). This is **agent
federation** — Burrow becomes a collaboration plane that multiple independent
agent runtimes connect to.

---

## Decision

We will introduce a **federated agent runtime model** that allows external
agent runtimes (OpenClaw instances, or any conforming runtime) to register
agents as participants in Burrow spaces, receive attention signals, and post
responses through a standardized protocol.

---

## Decision Details

### 1. Architecture: Burrow as collaboration plane

Burrow's role changes from "app with a built-in agent" to "collaboration plane
that agent runtimes connect to."

```
┌─────────────────────────────────────────────────┐
│                 Burrow                           │
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
│                  (Alex) (Alice)  (Bob)            │
└─────────────────────────────────────────────────┘
```

The existing built-in runtime (OpenClaw workspace bootstrap) becomes one
runtime among many. External runtimes connect over a defined protocol and
are treated identically by the attention router and chat system.

### 2. Runtime registration

An external runtime registers with Burrow by establishing an authenticated
connection and declaring its agent identity.

#### Registration handshake

```
Runtime → Burrow:  POST /api/runtimes/register
                  {
                    "runtime_id": "alex-openclaw-home",
                    "agent": {
                      "name": "Zip",
                      "slug": "zip",
                      "capabilities": ["chat", "tools", "canvas"],
                      "model_info": "claude-opus-4-6"
                    },
                    "transport": "websocket",
                    "callback_url": "wss://suite.example.com/runtime/ws"
                  }

Burrow → Runtime:  201 Created
                  {
                    "runtime_id": "alex-openclaw-home",
                    "agent_participant_id": "uuid-...",
                    "token": "runtime-session-token",
                    "spaces": [...]
                  }
```

After registration:
- Burrow creates (or reuses) an Agent record for the external agent
- Burrow can add the agent as a participant in spaces
- The runtime receives a session token for subsequent API/WebSocket calls

#### Authentication

Runtimes authenticate via one of:
- **API key** — simple shared secret, suitable for trusted environments
- **OIDC** — runtime authenticates as a service principal via the same OIDC
  provider Burrow uses for users
- **Mutual TLS** — for high-security deployments

The user who owns the runtime must authorize it first. A runtime cannot
self-register without the owning user's approval.

### 3. Transport: NAT-safe outbound WebSocket

Most OpenClaw instances run behind NAT on home networks, laptops, and
phones. Burrow cannot reach them with webhooks or inbound connections.

The connection must be **outbound from OpenClaw to Burrow**. OpenClaw
initiates a persistent WebSocket to Burrow's public endpoint. Burrow pushes
events down the established connection. This is the same pattern used by
every messaging channel plugin (Telegram, Discord) — the client reaches
out, the server pushes events down.

```
OpenClaw (behind NAT) ──outbound WSS──► Burrow (public)
                                            │
                     ◄── attention signals ──┘
                     ──► replies ────────────►
                     ◄── tool results ───────┘
                     ──► tool calls ─────────►
                     ◄── context updates ────┘
                     ──► presence ───────────►
```

One persistent WebSocket, initiated by OpenClaw. Everything flows over it:
messages, attention signals, tool calls and results, presence, typing
indicators. No inbound connectivity required on the OpenClaw side.

Burrow exposes a `/runtime/ws` endpoint. The OpenClaw channel plugin
connects to it and maintains the connection with automatic reconnection.

#### Why not webhooks?

Webhooks require the OpenClaw instance to have a publicly reachable URL.
Most won't — home networks, corporate firewalls, mobile devices. Webhooks
are not viable as the primary transport.

#### Why not MCP as primary transport?

MCP is fundamentally client→server (request-response). Burrow needs to push
unsolicited attention signals to the runtime. MCP doesn't do push. Using
MCP would require MCP for tools + a separate WebSocket for chat events +
something else for presence. Three protocols doing what one WebSocket
handles.

#### OpenClaw Channel Plugin (recommended integration)

For OpenClaw runtimes, Burrow is implemented as an **OpenClaw channel
plugin** — the same way Telegram or Discord work. The plugin:

1. Connects to Burrow's `/runtime/ws` as a registered runtime
2. Receives attention signals and maps them to OpenClaw's internal routing
3. Posts OpenClaw responses back to Burrow
4. Translates Burrow tool calls into the agent's tool execution loop

From the agent's perspective, Burrow looks like "just another messaging
surface." The attention routing, context management, and model selection
all happen inside OpenClaw. Zero changes to the agent itself.

```
OpenClaw (behind NAT)
  └── startup-suite-channel plugin ──outbound WSS──► Burrow /runtime/ws
         │
         ├── Inbound: attention signals → OpenClaw message routing
         ├── Outbound: agent replies → Burrow message posting
         └── Bidirectional: tool calls/results over same connection
```

### 4. Context injection (push, not pull)

Agents do not reliably call context-fetching tools. Research and direct
experience (GPT-5.4 ignoring required `initial_state` parameters across
5 retry iterations) confirm that relying on the agent to proactively query
context is a reliability hole.

**Context is pushed into the attention signal, not fetched by the agent.**

When Burrow routes an attention signal to a runtime, it bundles the relevant
context automatically:

```json
{
  "type": "attention",
  "signal": { "reason": "mention", "space_id": "..." },
  "message": { "content": "@Zip review the dashboard", "author": "the product owner" },
  "history": [ "...last 12 messages..." ],
  "context": {
    "space": {
      "name": "Engineering",
      "kind": "channel",
      "topic": "Q2 planning",
      "agent_attention": "on_mention",
      "participant_count": 4
    },
    "active_canvases": [
      { "id": "abc", "title": "SaaS Metrics", "type": "dashboard",
        "summary": "4 metric cards: Revenue, Users, Churn, NPS" }
    ],
    "active_tasks": [
      { "id": "def", "title": "Fix login bug", "status": "in_progress",
        "assignee": "Nova" }
    ],
    "other_agents": [
      { "name": "Nova", "state": "idle", "capabilities": ["chat", "tools"] }
    ],
    "recent_activity_summary": "Discussion about Q2 metrics. Nova created a review canvas 10 min ago."
  },
  "tools": [ "canvas_create", "canvas_update", "task_create" ]
}
```

The agent **sees** the context without calling anything. Burrow's attention
router already has access to all this data (ETS context plane, database
queries, participant state). Bundling it is mechanical work — the system
should do it.

This follows the core design principle: **deterministic system behavior
for mechanical tasks, LLM reasoning only where judgment is needed.**
Loading context is mechanical. Reasoning about it is where the agent adds
value.

### 5. Tool surface: write-only, compact, structured

Tools exposed to federated agents are **write actions only**. Read context
is injected (Section 4). This dramatically simplifies the tool surface and
removes the most unreliable class of tool calls.

#### MCP tool design principles

Based on empirical research (arXiv:2602.14878, 856 tools across 103 MCP
servers) and production experience:

1. **Fewer tools, clear boundaries.** Expose actions, not CRUD. Not
   `update_task(id, {any_fields})` but `complete_task(id)`,
   `assign_task(id, participant_id)`, `add_task_note(id, content)`.

2. **No optional parameter swamps.** If a parameter is optional, ask:
   does the agent benefit from knowing it exists? If not, leave it out.
   A second tool variant is better than an 8-parameter Swiss army knife.

3. **Purpose + when-to-use in one sentence.** "Create a live canvas in
   the current space. Use when the conversation calls for a shared visual
   artifact like a table, diagram, or dashboard."

4. **Parameter descriptions state format, not just type.** Not
   `space_id: string` but `space_id: UUID of the space (from the
   attention signal context)`.

5. **Return values describe what matters.** Not `returns: object` but
   `returns: {canvas_id, title} — use canvas_id for subsequent updates`.

6. **No examples in the schema.** Research shows examples bloat context
   without improving reliability (arXiv:2602.14878 RQ-3). If the agent
   needs guidance, put it in the attention signal context.

7. **Structured error responses.** Return
   `{error: "space_not_found", recoverable: true, suggestion: "verify
   space_id from the attention context"}` — not `500 Internal Server
   Error`. Agents can self-correct on structured errors (SERF pattern
   from arXiv:2603.13417).

#### The 6-component rubric (arXiv:2602.14878)

Every tool description should include these components in **compact**
form (verbose descriptions regressed 16.67% of cases in research):

| Component | Required | Notes |
|-----------|----------|-------|
| Purpose | Yes | One sentence: what it does |
| Parameters | Yes | Each param: name, type, format, constraints |
| Return value | Yes | What the tool gives back, what to use from it |
| Limitations | Yes | What it can't do, edge cases |
| Usage guidelines | Yes | When to use this vs. other tools |
| Examples | No | Skip — inflates tokens without helping |

#### Burrow's tool surface

```
canvas_create
  Purpose: Create a live collaborative canvas in a chat space.
  Params:
    space_id   — UUID of the space (from attention signal context)
    canvas_type — table | dashboard | code | diagram | custom
    title      — human-readable title (string)
    initial_state — object with type-specific content to render
  Returns: { canvas_id, title, canvas_type }
  Limitation: One canvas per call. Canvas is posted as a chat message.
  When: User requests a visual artifact, data display, or shared doc.

canvas_update
  Purpose: Update an existing canvas's content.
  Params:
    canvas_id — UUID (from attention context or prior canvas_create)
    patches   — array of patch operations [{op, path, value}]
  Returns: { canvas_id, updated_at }
  Limitation: Canvas must exist. Use canvas_create first.
  When: Modifying data in a canvas referenced in the conversation.

task_create
  Purpose: Create a tracked task visible in the space.
  Params:
    space_id    — UUID of the space
    title       — short task title (string)
    description — optional detail (string)
  Returns: { task_id, title }
  Limitation: Does not assign or schedule. Use assign_task separately.
  When: An actionable item emerges that should be tracked.

task_complete
  Purpose: Mark an existing task as done.
  Params:
    task_id — UUID of the task
  Returns: { task_id, status: "done" }
  Limitation: Task must exist and not already be done.
  When: Work on a task is confirmed finished.
```

Four tools. Clear boundaries. No parameter swamps. Context is pushed,
tools are for writes only.

### 4. Agent identity and trust

#### Agent ownership

Every external agent has an **owning user** in Burrow. The owning user:
- Authorized the runtime to register
- Controls which spaces the agent can join
- Can revoke the runtime's access at any time
- Is responsible for the agent's behavior (cost, conduct)

#### Agent identity persistence

External agents get real Agent records in Burrow's database, just like the
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
      [internally: Burrow routes delegation to Nova's runtime]
Nova: I've reviewed PR #42. Here are my findings...
```

Delegation happens through Burrow's message system — Zip posts a message
that @mentions Nova, which triggers Nova's attention signal. No special
agent-to-agent API needed; it's just chat.

### 6. Shared context plane (ETS)

Burrow maintains a shared context plane backed by ETS, updated automatically
via telemetry events (message_posted, canvas_created, task_updated, etc.).

```elixir
# ETS table owned by ContextPlane GenServer
:ets.new(:suite_context_plane, [:named_table, :set, :protected])

# Keyed by {scope, id, key}
{:space, space_id, :recent_activity}     → [last N message summaries]
{:space, space_id, :active_topics}       → ["PR review", "deploy plan"]
{:space, space_id, :agent_states}        → %{"zip" => :engaged, "nova" => :idle}
{:space, space_id, :canvas_summaries}    → [%{id, title, type, updated_at}]
{:agent, agent_id, :working_memory}      → %{current_task: "...", notes: [...]}
{:global, nil, :agent_capabilities}      → %{"zip" => [...], "nova" => [...]}
```

When the attention router prepares a signal for dispatch, it reads from
this plane to build the context bundle. No LLM call needed — it's a
deterministic ETS lookup.

**What gets shared vs. private:**

| Shared (Context Plane) | Private (per-runtime) |
|---|---|
| Space activity & topic summaries | Agent's internal reasoning |
| Who's working on what | Agent's system prompt & personality |
| Canvas state & recent changes | Conversation history with its owner |
| Task status & assignments | Model selection & config |
| Agent presence & capabilities | Tool execution internals |

For real-time context push (not polling), Burrow can send context-update
events down the channel WebSocket unprompted. The channel plugin surfaces
these as system events in the agent's session.

### 7. Schema changes

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

### 7. OpenClaw Channel Plugin: `startup-suite-channel`

The recommended integration path for OpenClaw runtimes is a channel plugin
that ships as an OpenClaw extension (similar to the `claude-runner` extension
pattern):

```
openclaw-startup-suite-channel/
├── index.ts          # Plugin registration
├── src/
│   ├── suite-client.ts    # WebSocket client to Burrow API
│   ├── message-bridge.ts  # Translate Burrow signals ↔ OpenClaw messages
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
      "url": "wss://burrow.example.com/runtime/ws",
      "runtimeId": "alex-openclaw-home",
      "apiKey": "...",
      "autoJoinSpaces": ["general"]
    }
  }
}
```

From the agent's perspective, messages from Burrow look identical to messages
from Telegram or Discord. The agent responds normally, and the plugin
translates the response back to Burrow.

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

- Build `openclaw-startup-suite-channel` extension
- Handle bidirectional message translation
- Sync attention state (engaged, silenced) between Burrow and OpenClaw
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

- Burrow becomes a true collaboration plane, not just a chat app with one agent
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

1. **How does Burrow handle conflicting agent responses?** If two agents both
   respond to the same message (e.g., both are in collaborative mode), does
   Burrow deduplicate, sequence, or let both through? Current leaning: let
   both through — the principal agent pattern (ADR 0013) should prevent
   this in most cases, and explicit @mentions are unambiguous.

2. **Should the protocol be Burrow-specific or generic?** A generic protocol
   (like an "Agent Channel Protocol") could allow Burrow to connect to runtimes
   beyond OpenClaw. But premature generalization risks over-engineering.
   Current leaning: Burrow-specific v1, extract a generic protocol if demand
   emerges.

3. **What happens to an agent's history when its runtime is revoked?** The
   messages and canvases persist (they're in Burrow's DB), but should the
   agent's participant record be anonymized or preserved? Current leaning:
   preserved — the work product belongs to the space, not the runtime.

4. **How much context is too much in the attention signal?** Bundling space
   state, canvas summaries, tasks, and activity into every signal could
   bloat tokens. Burrow should have a context budget (e.g., 4K tokens) and
   prioritize by relevance. The attention router already knows the signal
   reason — use it to select context.

5. **Should the built-in agent use the same tool surface?** Currently
   ToolRunner calls functions directly. Refactoring it to use the same
   tool surface as federated agents (same descriptions, same schemas,
   same error semantics) ensures parity. The built-in path is in-process;
   the federated path is over WebSocket. Same interface, different transport.

---

## References

- ADR 0007: Agent Runtime Architecture
- ADR 0008: Chat Backend Architecture
- ADR 0013: Attention Routing and Channel Policy
- OpenClaw channel plugin architecture
- OpenClaw `claude-runner` extension (prior art for runtime bridge pattern)
- Zap Channel project (prior art for custom OpenClaw channel backed by Phoenix)
