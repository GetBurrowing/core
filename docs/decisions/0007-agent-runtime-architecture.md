# ADR 0007: Agent Runtime Architecture

## Status

Accepted

## Context

The platform needs a native AI agent runtime — the ability to define, configure,
run, and orchestrate AI agents as first-class entities. The design goals are:

1. **Configuration compatibility with OpenClaw**. An agent's identity is defined
   by a folder structure (`.openclaw` workspace) containing config JSON, personality
   files (SOUL.md), long-term memory (MEMORY.md), workspace instructions, and daily
   memory logs. The platform must be able to import this folder and "revive" an
   agent with its full identity.

2. **Elixir-native orchestration**. Rather than wrapping external runtimes, agents
   run as supervised OTP processes. This gives us crash recovery, backpressure,
   process isolation, and observability for free — properties that are bolted on
   in other runtimes.

3. **Intelligent context sharing**. Parent-child agent relationships should have
   explicit, auditable context inheritance. The platform must control what context
   flows between agents, track provenance, and prevent accidental cross-contamination.

4. **Model provider integration**. Agents need to call LLM APIs. The runtime must
   support multiple providers (Anthropic, OpenAI, Google, etc.) with both API key
   and OAuth authentication, consuming credentials from the Vault (ADR 0006).

5. **No channel implementation**. The platform does not replicate messaging channel
   integrations (Telegram, Discord, etc.). Agents communicate through the platform's
   internal orchestration layer.

6. **Control Center**. A LiveView surface for editing agent configurations, browsing
   memories, monitoring runtime state, and tuning parameters.

### What an agent identity consists of

The OpenClaw workspace convention defines an agent's identity as:

| File | Purpose |
|------|---------|
| `openclaw.json` (agent entry) | Model config, tool profiles, heartbeat, concurrency |
| `SOUL.md` | Personality, voice, behavioral guidelines |
| `MEMORY.md` | Long-term curated memory |
| `AGENTS.md` | Workspace instructions and conventions |
| `IDENTITY.md` | Name, emoji, avatar metadata |
| `USER.md` | Context about the human the agent works with |
| `TOOLS.md` | Tool-specific notes and local configuration |
| `HEARTBEAT.md` | Periodic task instructions |
| `memory/*.md` | Daily memory logs |

This folder is the complete, portable unit of agent identity. The platform must
preserve this structure both for import compatibility and for the principle that
an agent's identity should be exportable back to a standalone runtime.

## Decision

### New platform domain: `Platform.Agents`

Agents is a top-level domain alongside Accounts, Vault, Audit, and the other
domains defined in ADR 0002. Agents are not a subcategory of Automations (those
are deterministic rules) or Integrations (those are connectors). Agents are
runtime entities that act across all domains.

```
Platform.Agents
├── Config          — OpenClaw config parser, schema mapping, import/export
├── Runtime         — OTP process lifecycle (AgentServer, supervisors, registry)
├── Memory          — Persistent memory layer (workspace files, long-term, daily)
├── Context         — Inheritance protocol, scoping, sharing, provenance
├── Orchestration   — Sub-agent spawning, work routing, pipelines
├── Providers       — Model provider behaviour + implementations
├── Router          — Model routing, fallback chains, rate limiting
└── Telemetry       — Observability, token accounting, session tracking
```

### Agent process model

Each agent runs as a supervised `GenServer` under a `DynamicSupervisor`. The
supervision tree is the orchestration tree — parent-child agent relationships
map directly to process relationships.

```
Platform.Agents.Supervisor (started with the application)
├── Platform.Agents.Registry
│   └── Registry for process name lookup by agent slug
├── Platform.Agents.RuntimeSupervisor (DynamicSupervisor)
│   ├── AgentServer {:agent, "zip"}
│   ├── AgentServer {:agent, "planner"}
│   ├── AgentServer {:agent, "executor"}
│   └── ... (started/stopped dynamically)
├── Platform.Agents.ContextBroker
│   └── Manages context inheritance rules and cross-agent sharing
└── Platform.Agents.HeartbeatScheduler
    └── Ticks agents on their configured heartbeat intervals
```

**Why GenServer per agent**: Each agent has distinct state (config, active context,
memory references, child session tracking). A GenServer gives us:
- Process isolation — one agent's crash does not affect others
- Sequential message processing — no race conditions on agent state
- Mailbox backpressure — work queues naturally via the process mailbox
- Introspection — `:sys.get_state/1`, `:observer`, process info

**Why DynamicSupervisor**: Agents are started and stopped at runtime (import a
new agent, pause an existing one, scale sub-agents up/down). Static supervision
trees don't fit.

### AgentServer state

Each `AgentServer` holds:

```elixir
%AgentState{
  agent_id: uuid,
  slug: string,
  config: %AgentConfig{},       # parsed from openclaw.json entry
  workspace: %Workspace{},      # SOUL.md, AGENTS.md, etc. (loaded from DB)
  memory_ref: reference,        # handle to memory backend
  active_context: %Context{},   # current working context
  active_sessions: [session_id],
  child_agents: [agent_id],     # sub-agents spawned by this agent
  parent_agent: agent_id | nil, # nil for top-level agents
  status: :idle | :working | :paused
}
```

On startup, the AgentServer loads its config and workspace files from the database.
Memory is loaded lazily — daily files and long-term memory are fetched on demand,
not preloaded.

### Config compatibility layer

`Platform.Agents.Config` handles bidirectional translation between the OpenClaw
config format and the platform's internal representation.

**Import (`.openclaw` → platform):**

1. Parse `openclaw.json` — extract the `agents.list` entries and `agents.defaults`
2. For each agent entry:
   - Map `model.primary`, `model.fallbacks` → `model_config` JSONB
   - Map `tools.profile`, `tools.alsoAllow` → `tools_config` JSONB
   - Map `thinkingDefault`, `heartbeat`, `maxConcurrent`, `sandbox` → columns
3. Read workspace files (SOUL.md, MEMORY.md, etc.) → `agent_workspace_files`
4. Read `memory/*.md` files → `agent_memories` (type: `daily`)
5. Parse `auth.profiles` → link to Vault credentials (ADR 0006)
6. Skip `channels`, `hooks`, `gateway` sections (not applicable)

**Export (platform → `.openclaw`):**

Reverse serialization. Any agent in the platform can be exported as a valid
`.openclaw` workspace folder, enabling portability back to standalone runtimes.

### Memory layer

`Platform.Agents.Memory` provides persistent, queryable memory backed by Postgres.
It replaces the filesystem-based `.md` file approach with a structured store while
preserving the same conceptual model.

**Memory types:**

| Type | Source | Equivalent |
|------|--------|-----------|
| `workspace_file` | Imported or edited in Control Center | SOUL.md, AGENTS.md, etc. |
| `long_term` | Agent-curated | MEMORY.md content |
| `daily` | Agent daily logs | memory/YYYY-MM-DD.md |
| `snapshot` | System-generated | Context snapshots at session boundaries |

**Workspace files** are stored in `agent_workspace_files` with versioning (integer
version column for optimistic locking and history). The Control Center reads and
writes these directly.

**Long-term and daily memories** are stored in `agent_memories` with bigserial IDs
(monotonic, matching ADR 0005 pattern). Agents append memories during operation;
the platform never mutates or deletes them (append-only by convention, following
the event stream principle).

**Memory recall** is keyword-based in v1: filter by agent, type, date range, and
full-text search on content. Semantic search (embeddings) is a future enhancement
that can be added without schema changes — add an `embedding` vector column and
a similarity index.

### Context sharing protocol

This is where the Elixir runtime provides a genuine advantage over process-external
orchestration.

**Core types:**

```elixir
defmodule Platform.Agents.Context do
  @type t :: %__MODULE__{
    agent_id: Ecto.UUID.t(),
    session_id: Ecto.UUID.t(),
    workspace: map(),        # workspace file contents
    memory: map(),           # loaded memory segments
    inherited: map(),        # context received from parent
    local: map(),            # context generated in this session
    metadata: map()          # provenance tracking
  }
end

defmodule Platform.Agents.ContextScope do
  @type t :: %__MODULE__{
    share: :full | :memory_only | :config_only | :custom,
    include_keys: [String.t()] | nil,
    exclude_keys: [String.t()] | nil,
    include_memory: boolean(),
    include_workspace: boolean(),
    max_depth: non_neg_integer() | :unlimited
  }
end

defmodule Platform.Agents.ContextDelta do
  @type t :: %__MODULE__{
    from_agent: Ecto.UUID.t(),
    from_session: Ecto.UUID.t(),
    additions: map(),
    removals: [String.t()],
    memory_updates: [Memory.t()],
    promote: boolean()  # should parent merge this?
  }
end
```

**Inheritance rules:**

1. When a parent agent spawns a sub-agent, it provides a `%ContextScope{}` that
   defines what the child receives.
2. The child gets an immutable snapshot of the inherited context — it cannot modify
   the parent's state.
3. During execution, the child accumulates local context changes.
4. On completion, the child returns a `%ContextDelta{}`. The parent decides whether
   to merge it (if `promote: true` and the parent's policy allows).
5. All context transfers are recorded in `agent_context_shares` for provenance.

**Why explicit message passing over shared state**: ETS or shared process state
would be faster but loses auditability. Every piece of context an agent has should
be traceable to its source — "this fact came from agent X in session Y, inherited
from parent Z." This matters for debugging, for trust, and for understanding why
an agent made a decision.

The `ContextBroker` GenServer manages sharing rules and can enforce platform-wide
policies (e.g., "agent-scoped vault credentials are never inherited by children"
or "daily memories older than 7 days are excluded from context by default").

### Model provider integration

Agents call LLM APIs through a provider abstraction that consumes Vault (ADR 0006)
for credentials.

**Provider behaviour:**

```elixir
defmodule Platform.Agents.Providers.Provider do
  @callback chat(credentials, messages, opts) ::
    {:ok, response} | {:error, reason}
  @callback stream(credentials, messages, opts) ::
    {:ok, Enumerable.t()} | {:error, reason}
  @callback models(credentials) ::
    {:ok, [model_info]} | {:error, reason}
  @callback validate_credentials(credentials) ::
    :ok | {:error, reason}
end
```

**Implementations:**

- `Providers.Anthropic` — Messages API, streaming via SSE
- `Providers.OpenAI` — Chat Completions API, streaming via SSE
- `Providers.Google` — Gemini API

Each implementation handles provider-specific message formatting, tool/function
calling conventions, streaming protocols, and error normalization.

**Credential resolution:**

1. AgentServer calls `Router.chat(agent_id, messages, opts)`
2. Router determines the target model from the agent's config (primary, then fallbacks)
3. Router resolves credentials: `Vault.get(credential_slug, accessor: {:agent, agent_id})`
4. Router delegates to the appropriate Provider implementation
5. On provider error/rate limit: try next fallback

**Router responsibilities:**
- Model selection from agent config (primary → fallback chain)
- Credential resolution via Vault
- Rate limit detection and backoff (respect 429 / Retry-After)
- Token budget enforcement (if configured per agent or workspace)
- Usage recording → Telemetry → Audit

### Data model

```sql
-- Agent definitions
CREATE TABLE agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID REFERENCES workspaces(id),
  slug VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'active',  -- active|paused|archived
  model_config JSONB NOT NULL DEFAULT '{}',  -- primary, fallbacks, models
  tools_config JSONB NOT NULL DEFAULT '{}',  -- profile, allow/deny
  thinking_default VARCHAR,
  heartbeat_config JSONB DEFAULT '{}',
  max_concurrent INTEGER DEFAULT 1,
  sandbox_mode VARCHAR DEFAULT 'off',
  parent_agent_id UUID REFERENCES agents(id),  -- for sub-agent definitions
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,

  CONSTRAINT unique_agent_slug UNIQUE (workspace_id, slug)
);

-- Workspace files (SOUL.md, MEMORY.md, etc.)
CREATE TABLE agent_workspace_files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  file_key VARCHAR NOT NULL,           -- "SOUL.md", "AGENTS.md", etc.
  content TEXT NOT NULL DEFAULT '',
  version INTEGER NOT NULL DEFAULT 1,  -- optimistic locking
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,

  CONSTRAINT unique_file_per_agent UNIQUE (agent_id, file_key)
);

-- Agent memories (append-only)
CREATE TABLE agent_memories (
  id BIGSERIAL PRIMARY KEY,            -- monotonic, ADR 0005 pattern
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  memory_type VARCHAR NOT NULL,        -- long_term|daily|snapshot
  date DATE,                           -- for daily memories
  content TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_agent_memories_agent_date ON agent_memories (agent_id, date DESC);
CREATE INDEX idx_agent_memories_agent_type ON agent_memories (agent_id, memory_type);

-- Agent sessions
CREATE TABLE agent_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES agents(id),
  parent_session_id UUID REFERENCES agent_sessions(id),
  status VARCHAR NOT NULL DEFAULT 'running',  -- running|completed|failed|cancelled
  context_snapshot JSONB,              -- context at session start
  model_used VARCHAR,
  token_usage JSONB DEFAULT '{}',      -- prompt_tokens, completion_tokens, total
  started_at TIMESTAMPTZ NOT NULL,
  ended_at TIMESTAMPTZ,

  CONSTRAINT valid_session_status CHECK (
    status IN ('running', 'completed', 'failed', 'cancelled')
  )
);

-- Context sharing records
CREATE TABLE agent_context_shares (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_session_id UUID NOT NULL REFERENCES agent_sessions(id),
  to_session_id UUID NOT NULL REFERENCES agent_sessions(id),
  scope VARCHAR NOT NULL,              -- full|memory_only|config_only|custom
  scope_filter JSONB,                  -- for custom scope: include/exclude rules
  delta JSONB,                         -- what was actually shared
  inserted_at TIMESTAMPTZ NOT NULL
);
```

### Orchestration

`Platform.Agents.Orchestration` handles multi-agent coordination:

**Sub-agent spawning:**

```elixir
# Parent agent requests a sub-agent
Orchestration.spawn_child(parent_agent_id, %{
  slug: "researcher",
  config: child_config,
  context_scope: %ContextScope{share: :memory_only},
  task: "Research the latest papers on context compression"
})
```

This:
1. Creates a child agent record (or uses an existing agent definition)
2. Starts a new `AgentServer` under `RuntimeSupervisor`
3. Creates an `agent_session` linked to the parent session
4. Shares context per the scope rules (recorded in `agent_context_shares`)
5. The child runs autonomously, supervised by OTP

**Work routing:**

Pipelines (like a multi-agent workflow) are defined as Elixir modules that
implement a routing behaviour. No hooks or webhook transforms — the routing
logic is compiled Elixir, testable, and type-checkable.

```elixir
defmodule Platform.Agents.Pipelines.TaskPipeline do
  @behaviour Platform.Agents.Pipeline

  def route(%Event{type: "task.created"} = event) do
    {:dispatch, "planner", event}
  end

  def route(%Event{type: "task.planned"} = event) do
    {:dispatch, "executor", event}
  end

  def route(%Event{type: "task.completed"} = event) do
    {:dispatch, "validator", event}
  end
end
```

### Control Center

A new LiveView surface under `platform_web/live/agents/`:

- **Dashboard** — agent list, status badges, health indicators, active sessions
- **Agent detail** — config editor with structured fields + raw markdown tabs
  for SOUL.md, MEMORY.md, AGENTS.md, etc.
- **Memory browser** — search across memories, filter by type/date, view/edit
- **Session viewer** — real-time session list, context flow visualization,
  parent-child tree
- **Import/Export** — upload `.openclaw` folder to create an agent; download
  agent as `.openclaw` folder
- **Model tuning** — per-agent model selection, thinking levels, token budgets
- **Pipeline editor** — view and configure multi-agent routing

The Control Center consumes the same Telemetry events as the Audit dashboard,
giving real-time visibility into agent operations.

### Telemetry events

```
[:platform, :agent, :started]
[:platform, :agent, :stopped]
[:platform, :agent, :session_started]
[:platform, :agent, :session_ended]
[:platform, :agent, :context_shared]
[:platform, :agent, :context_promoted]
[:platform, :agent, :model_called]
[:platform, :agent, :model_fallback]
[:platform, :agent, :model_error]
[:platform, :agent, :heartbeat_tick]
[:platform, :agent, :memory_written]
[:platform, :agent, :child_spawned]
[:platform, :agent, :child_completed]
```

Measurements include token counts, latencies, and costs. Metadata includes agent
IDs, session IDs, model names, and error details.

## Consequences

- Agents are supervised OTP processes. Crashes recover automatically. The platform
  does not need external health checks or restart logic for agents.
- Context sharing is explicit and auditable. Every piece of context an agent has
  is traceable to its source through `agent_context_shares` records.
- The OpenClaw folder format is the portable interchange format. Agents can be
  imported from and exported to standalone OpenClaw instances.
- Model provider calls go through a single path: AgentServer → Router → Vault →
  Provider. Credential management, rate limiting, fallbacks, and usage tracking
  are centralized.
- The Control Center provides full visibility into agent state without needing
  external monitoring tools.
- No channel implementations are included. Agent communication is internal to the
  platform, through OTP message passing and the orchestration layer.
- Adding a new provider requires implementing the `Provider` behaviour — four
  callbacks. No schema changes, no config changes.

## Follow-up

1. Scaffold `Platform.Agents` module tree
2. Implement `Config` — OpenClaw JSON parser and import/export
3. Implement `Runtime` — AgentServer, RuntimeSupervisor, Registry
4. Implement `Memory` — schemas, CRUD, recall
5. Implement `Context` — sharing protocol, ContextBroker
6. Implement `Providers` — Anthropic and OpenAI initially
7. Implement `Router` — model selection, fallbacks, Vault integration
8. Build Control Center LiveView pages
9. Write ADR for pipeline definition format (if complexity warrants)
