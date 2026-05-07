# ADR 0033 — Org-Level Context Management

**Status:** Accepted (Phase 3 revised 2026-04-16)  
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

**`org_memory_entries`** — append-only log for short-lived notes:

| Column      | Type                | Notes                                       |
|-------------|---------------------|---------------------------------------------|
| id          | bigserial           | PK, monotonic ordering                      |
| workspace_id| uuid (nullable)     | Same multi-tenancy insurance                |
| date        | date                | Relevant date for the entry                 |
| content     | text                |                                             |
| authored_by | uuid                |                                             |
| metadata    | jsonb               |                                             |
| inserted_at | utc_datetime_usec   |                                             |

> **Update (2026-05): `memory_type` column dropped.** The original two-type
> design (`daily` + `long_term`) overlapped with `ORG_MEMORY.md`. The model
> is now: `org_memory_entries` for short-term notes, `ORG_MEMORY.md` as the
> sole canonical long-term store curated by the dreaming/historian agent.

### Default Seed Files

- **ORG_IDENTITY.md** — who the org is, mission, values, product summary
- **ORG_MEMORY.md** — curated long-term org knowledge — decisions, patterns, lessons (analogue to agent MEMORY.md)
- **ORG_AGENTS.md** — registered agents and their roles

### Memory Model

- `ORG_MEMORY.md` is the canonical long-term store: curated knowledge, manually written or maintained by the dreaming agent via `org_context_write`.
- `org_memory_entries` is append-only, short-lived: the last 2 days surface to agents as `ORG_NOTES-YYYY-MM-DD`. Older entries remain searchable via `org_memory_search`.

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
  @callback ingest(entry :: map()) :: :ok | {:error, term()}
  @callback search(query :: String.t(), opts :: keyword()) :: {:ok, [%{entry_id: binary(), score: float()}]} | {:error, term()}
  @callback delete(entry_id :: binary()) :: :ok | {:error, term()}
end
```

- **`ingest/1`** — receives a single entry map `%{id, content, memory_type, date, workspace_id, metadata}`. The provider wraps it in a list for the service's batch API (`POST /ingest` accepts `{entries: [...]}`).
- **`search/2`** — opts include `:workspace_id`, `:memory_type`, `:date_from`, `:date_to`, `:limit`. Returns `[%{entry_id, score}]`. Main app hydrates full entries locally.
- **`delete/1`** — removes a single entry from the index by ID.

Configuration: `config :platform, memory_provider: Platform.Memory.Providers.StartupSuite` (or `Platform.Memory.Providers.Null` for no-op default). Feature-gated via `MEMORY_SERVICE_URL` env var in `runtime.exs`; when unset the Null provider is used.

A `Platform.Memory.Provider.configured/0` helper resolves the active provider at runtime via `Application.get_env/3`.

### Ingest Pipeline

When an `org_memory_entry` is written, the existing telemetry event (`[:platform, :org, :memory_entry_written]`) fires `Platform.Memory.TelemetryHandler`, which loads the full entry from the database (telemetry metadata only carries the entry ID, not content), converts it to a plain map, and calls `Provider.ingest/1` on the configured provider. The handler is attached in `Application.start/2` alongside the Audit, Vault, and Chat telemetry handlers. Volume is low (~5–50 writes/day), so a synchronous HTTP call is appropriate.

The handler wraps execution in a rescue to prevent telemetry from detaching it on crash, and logs warnings on provider errors without raising.

For resilience, the memory service exposes a `GET /sync?since=<timestamp>` catchup endpoint so it can backfill missed entries on restart.

### Search Tool

A single `org_memory_search` tool in `federation/tool_surface.ex` routes queries through the configured `MemoryProvider`. The tool accepts `query` (optional), `memory_type`, `date_from`, `date_to`, and `limit`.

**Search flow:**
- **Null provider** (default): bypasses the provider entirely and falls back to the existing `OrgContext.search_memory_entries/1` ILIKE substring search against the database.
- **Real provider** (e.g. StartupSuite): calls `Provider.search/2` to get scored entry IDs, then hydrates full entries from `org_memory_entries` in the main DB. Results include a `score` field and are ordered by provider ranking. If the provider returns empty results or errors, the tool gracefully degrades to the DB fallback.

The `query` parameter is optional to support both semantic search (when a provider is active) and browsing/filtering by date and type (DB fallback).

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
| `org_memory_search`         | Semantic search over org memory entries (with DB fallback) | 3 ✅  |

---

## Rejected Alternatives

| Alternative                              | Reason for Rejection                                                                 |
|------------------------------------------|--------------------------------------------------------------------------------------|
| pgvector in main Postgres                | Moved embedding + vector search to dedicated external service (`memory-service`) for hardware isolation and pluggability. External service uses pgvector in its own Postgres. |
| Bumblebee (in-monolith embeddings)       | Embedding workload moved to dedicated Python service using SentenceTransformers + CUDA; keeps BEAM lean |
| Chat message search (hybrid vector+keyword) | Descoped — search over org memory entries is sufficient for v1; conversation search can be revisited later |
| Oban for scheduling                      | Two cron jobs/day doesn't justify the dependency; GenServer + timer is sufficient     |
| Full roster injection per message        | Too much token overhead; roster is injected at session start only                    |
| Per-message full org context injection   | Wasteful; tiered model with session-start injection is more efficient                 |
| ACLs on org context writes in v1         | Deferred — any agent/user can write; revisit when abuse or access-control needs arise |

---

## Implementation Phases

### Phase 1 — Org Context Core ✅
- `org_context_files` + `org_memory_entries` tables and migrations
- `Platform.Org.Context` module (CRUD + version bumping)
- WebSocket tool registration
- Channel plugin tool handlers (`org_context_read/write/list`, `org_memory_append/search`)
- Basic UI for viewing/editing org context files

### Phase 2 — Context Injection Optimization ✅
- Org context delivery on attention via `ContextPlane.build_context_bundle/1` and `ContextAssembler.build/2`
- Prompt template updates for `dispatch.in_progress` and `dispatch.planning` with "Writing to Org Memory" guidance

### Phase 3 — Org Memory Search & Agent System Events

**Branch:** `feat/org-context-phase-3` (core repo) + `memory-service` repo

#### 3.1 — Agent system events infrastructure ✅
- `system_events` field on `agents` table (list of strings, migration `20260416020000`)
- `Platform.Agents.SystemEventScheduler` GenServer with `:timer` for daily summary (23:00 UTC) + dreaming (03:00 UTC)
- Agent config UI: toggle system event flags per agent

#### 3.2 — Memory Provider plugin interface ✅
- `Platform.Memory.Provider` behaviour (`ingest/1`, `search/2`, `delete/1`) + `configured/0` helper
- `Platform.Memory.Providers.Null` no-op default
- `Platform.Memory.Providers.StartupSuite` HTTP client (Req) to external memory service
- `Platform.Memory.TelemetryHandler` on `[:platform, :org, :memory_entry_written]` → loads full entry from DB → `Provider.ingest/1`
- Config gated on `MEMORY_SERVICE_URL` env var in `runtime.exs`

#### 3.3 — `org_memory_search` tool upgrade ✅
- `org_memory_search` in `federation/tool_surface.ex` routes through configured provider
- Provider returns scored entry IDs → hydrated from `org_memory_entries` via `OrgContext.get_memory_entries_by_ids/1`
- Graceful degradation: Null provider or provider error falls back to DB ILIKE search

#### 3.4 — External memory service (separate repo: `memory-service`)
- FastAPI (Python) microservice with Pydantic request/response schemas
- Embedding model: `BAAI/bge-large-en-v1.5` (1024-dim) via SentenceTransformers, with BGE query prefix for asymmetric retrieval
- Vector storage: pgvector in dedicated Postgres (`embeddings` table with `vector(1024)` column, cosine distance)
- REST API: `POST /ingest`, `POST /search`, `DELETE /entries`, `GET /sync?since=<timestamp>`, `GET /health`
- Idempotent upsert on ingest (`INSERT ON CONFLICT DO UPDATE`)
- Deployed on dedicated hardware (GPU-capable for embedding)

### Phase 4 — Project Linking & Polish
- `project_id` FK on `chat_spaces` + project context in agent preamble
- UI polish for org memory feed and search
