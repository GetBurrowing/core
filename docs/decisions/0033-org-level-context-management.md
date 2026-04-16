# ADR 0033 — Org-Level Context Management

**Status:** Accepted (Phase 3 revised 2026-04-14)  
**Date:** 2026-04-08  
**Author:** Sloane Scott / Hal

---

## Context

Individual agents have persistent personal knowledge via SOUL.md, MEMORY.md, AGENTS.md, and similar workspace files. There is no equivalent shared organizational layer — agents cannot access org-wide knowledge or recall past organizational decisions and events. This ADR covers three components: (1) Org Context Files for shared persistent knowledge, (2) Org Memory Search via an external memory service, and (3) Agent-driven memory lifecycle (daily summaries + dreaming).

---

## Org Context Files

### Schema

**`org_context_files`** — stores named org-level documents (analogous to agent workspace files):

| Column       | Type                | Notes                                      |
|--------------|---------------------|--------------------------------------------|
| id           | uuid v7             | PK                                         |
| workspace_id | uuid (nullable)     | Single-org in v1; nullable for future multi-tenancy |
| file_key     | text                | e.g. `ORG_IDENTITY.md`                     |
| content      | text                |                                            |
| version      | integer             | Increments on every write                  |
| updated_by   | uuid                | FK → users or agent identity               |
| inserted_at  | utc_datetime_usec   |                                            |
| updated_at   | utc_datetime_usec   |                                            |

**`org_memory_entries`** — append-only log for daily notes and long-term memory:

| Column      | Type                | Notes                                       |
|-------------|---------------------|---------------------------------------------|
| id          | bigserial           | PK, monotonic ordering                      |
| workspace_id| uuid (nullable)     | Same multi-tenancy insurance                |
| memory_type | text                | `daily` or `long_term`                      |
| date        | date                | Relevant date for daily entries              |
| content     | text                |                                             |
| authored_by | uuid                |                                             |
| metadata    | jsonb               |                                             |
| inserted_at | utc_datetime_usec   |                                             |

### Default Seed Files

- **ORG_IDENTITY.md** — who the org is, mission, values, product summary
- **ORG_MEMORY.md** — long-term curated org knowledge (analogue to agent MEMORY.md)
- **ORG_AGENTS.md** — registered agents and their roles
### Memory Model

- `ORG_MEMORY.md` holds long-term curated knowledge (manually written or agent-curated)
- `org_memory_entries` with `memory_type=daily` provides rolling daily notes, surfaced to agents as `ORG_NOTES-YYYY-MM-DD` (analogue to agent daily memory files)
- `org_memory_entries` with `memory_type=long_term` backs the curated ORG_MEMORY.md content

### Access Control (v1)

Any user or agent can read and write org context files. No ACLs in v1 — revisit when the need arises.

---

## Context Injection Strategy

A tiered model controls when and how org context reaches agents:

### Always (per-message)
- Space ID + name
- Current space participants
- Agent identity

### On Session Start (first message)
- ORG_IDENTITY.md
- ORG_MEMORY.md
- ORG_AGENTS.md
- Last 2 days of `org_memory_entries` (daily) as ORG_NOTES-YYYY-MM-DD

### On Demand (tools)
- `org_context_read`, `org_context_write`, `org_context_list`
- `org_memory_append`, `org_memory_search`

### Injection Location

The channel plugin currently injects full context on every message — this is a known inefficiency. Preferred approach: inject org context into the **system prompt** directly (not the first human message) to avoid polluting conversation history and to survive session resumption. Appending to the first human message is the fallback if system prompt injection is infeasible.

### Prompt Template Updates

Agent prompt templates (`dispatch.in_progress`, `dispatch.planning`) will be updated with guidance on when to write org memory entries: key decisions, completed milestones, important context shifts, notable events.

---

## Org Memory Search

### Architecture

Org memory search runs on an **external memory service** deployed on dedicated hardware (separate repo). The main application communicates with it via a pluggable `MemoryProvider` behaviour, allowing third parties to implement alternative backends (Qdrant, Pinecone, etc.).

The search corpus is **`org_memory_entries` only** — daily summaries and long-term memory entries. `ORG_MEMORY.md` is not searched; it is injected into agent session context at start (see Context Injection Strategy above).

### Memory Provider Behaviour

```elixir
defmodule Platform.Memory.Provider do
  @callback ingest(entries :: [map()]) :: :ok | {:error, term()}
  @callback search(query :: String.t(), opts :: keyword()) :: {:ok, [result()]} | {:error, term()}
  @callback delete(entry_ids :: [binary()]) :: :ok | {:error, term()}
end
```

- **`ingest/1`** — receives `[%{id, content, memory_type, date, workspace_id, metadata}]`
- **`search/2`** — opts include `:workspace_id`, `:memory_type`, `:date_from`, `:date_to`, `:limit`. Returns `[%{entry_id, score}]`. Main app hydrates full entries locally.
- **`delete/1`** — removes entries from the index

Configuration: `config :platform, memory_provider: Platform.Memory.Providers.StartupSuite` (or `Platform.Memory.Providers.Null` for no-op default).

### Ingest Pipeline

When an `org_memory_entry` is written, the existing telemetry event (`[:platform, :org, :memory_entry_written]`) fires a handler that HTTP POSTs the entry to the configured memory provider. Volume is low (~5–50 writes/day), so a synchronous HTTP call is appropriate.

For resilience, the memory service exposes a `GET /sync?since=<timestamp>` catchup endpoint so it can backfill missed entries on restart.

### Search Tool

A single `org_memory_search` tool in `federation/tool_surface.ex` proxies queries to the configured `MemoryProvider`. The tool accepts `query` (required), `memory_type`, `date_from`, `date_to`, and `limit`. Results are hydrated from `org_memory_entries` in the main DB before returning to the agent.

---

## Agent System Events

### Concept

Agents can be flagged for **system-triggered events** — scheduled tasks that fire automatically rather than via user attention. Two system events are defined in v1:

- **`daily_summary`** — generate a daily org memory entry summarizing the day's activity
- **`dreaming`** — consolidate accumulated daily memories into `ORG_MEMORY.md`

### Agent Flagging

A new `system_events` field (list of strings) on the `agents` table stores which system events an agent is opted into. Managed via the agent config UI. Example: `["daily_summary", "dreaming"]`.

### Scheduling

A `Platform.Agents.SystemEventScheduler` GenServer starts in the supervision tree and uses `:timer.send_interval/2` to fire on schedule:

- **Daily summary:** once per day (e.g. 23:00 UTC). The scheduler queries for agents with `"daily_summary"` in `system_events`, picks the designated agent, and sends it an attention event with instructions to summarize the day's activity across spaces it participates in. The agent writes the result via `org_memory_append`.
- **Dreaming:** once per day (e.g. 03:00 UTC). The scheduler sends the designated `"dreaming"` agent an attention event to read recent daily entries, synthesize patterns, and update `ORG_MEMORY.md` via `org_context_write`.

### Why Not Oban

At two jobs per day, Oban's persistence, uniqueness, and retry infrastructure is not justified as a new dependency. A GenServer + timer is sufficient. If scheduling needs grow, Oban can be introduced later without architectural changes.

---

## Space ↔ Project Linking

- Add `project_id` (nullable FK) to `chat_spaces`
- When a space has a project link, conversation agents receive project context in their preamble (not just task agents via ContextAssembler)

---

## New Tools

Registered via the channel plugin WebSocket interface:

| Tool                        | Purpose                                      | Phase |
|-----------------------------|----------------------------------------------|-------|
| `org_context_read`          | Read an org context file by key              | 1 ✅  |
| `org_context_write`         | Write/update an org context file             | 1 ✅  |
| `org_context_list`          | List available org context files             | 1 ✅  |
| `org_memory_append`         | Append a daily or long-term memory entry     | 1 ✅  |
| `org_memory_search`         | Semantic search over org memory entries      | 3     |

---

## Rejected Alternatives

| Alternative                              | Reason for Rejection                                                                 |
|------------------------------------------|--------------------------------------------------------------------------------------|
| pgvector in main Postgres                | Moved embedding + vector search to dedicated external service for hardware isolation and pluggability |
| Bumblebee (in-monolith embeddings)       | Embedding workload moved to dedicated hardware; keeps BEAM lean                      |
| Chat message search (hybrid vector+keyword) | Descoped — search over org memory entries is sufficient for v1; conversation search can be revisited later |
| Oban for scheduling                      | Two cron jobs/day doesn't justify the dependency; GenServer + timer is sufficient     |
| Full roster injection per message        | Too much token overhead; roster is injected at session start only                    |
| Per-message full org context injection   | Wasteful; tiered model with session-start injection is more efficient                 |
| ACLs on org context writes in v1         | Deferred — any agent/user can write; revisit when abuse or access-control needs arise |

---

## Implementation Phases

### Phase 1 — Org Context Core
- `org_context_files` + `org_memory_entries` tables and migrations
- `Platform.Org.Context` module (CRUD + version bumping)
- WebSocket tool registration
- Channel plugin tool handlers (`org_context_read/write/list`, `org_memory_append/search`)
- Basic UI for viewing/editing org context files

### Phase 2 — Context Injection Optimization
- Session-aware context injection (stop injecting full context every message)
- Org context delivery on session start via system prompt
- Prompt template updates for `dispatch.in_progress` and `dispatch.planning`

### Phase 3 — Org Memory Search & Agent System Events

**Branch:** `feat/org-context-phase-3` (core repo) + new external memory service repo

#### 3.1 — Agent system events infrastructure
- Add `system_events` field to `agents` table (list of strings, stored in migration)
- `Platform.Agents.SystemEventScheduler` GenServer with `:timer` for daily summary + dreaming cron
- Agent config UI: toggle system event flags per agent

#### 3.2 — Memory Provider plugin interface
- `Platform.Memory.Provider` behaviour (`ingest/1`, `search/2`, `delete/1`)
- `Platform.Memory.Providers.Null` no-op default
- `Platform.Memory.Providers.StartupSuite` HTTP client to external memory service
- Telemetry handler on `[:platform, :org, :memory_entry_written]` → ingest to provider

#### 3.3 — `org_memory_search` tool
- Register `org_memory_search` in `federation/tool_surface.ex`
- Calls configured `MemoryProvider.search/2`, hydrates results from `org_memory_entries`

#### 3.4 — External memory service (separate repo)
- Embedding model: `thenlper/gte-small` (384-dim) — Bumblebee + Nx.Serving or Python equivalent
- Vector storage: pgvector or purpose-built vector DB (implementation detail of the service)
- REST API: `POST /ingest`, `POST /search`, `DELETE /entries`, `GET /sync?since=<timestamp>`
- Deployed on dedicated hardware

### Phase 4 — Project Linking & Polish
- `project_id` FK on `chat_spaces` + project context in agent preamble
- UI polish for org memory feed and search
