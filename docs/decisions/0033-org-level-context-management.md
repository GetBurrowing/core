# ADR 0033 — Org-Level Context Management

**Status:** Accepted  
**Date:** 2026-04-08  
**Author:** Sloane Scott / Hal

---

## Context

Individual agents have persistent personal knowledge via SOUL.md, MEMORY.md, AGENTS.md, and similar workspace files. There is no equivalent shared organizational layer — agents cannot access org-wide knowledge, discover other agents/users, or search past conversations across spaces. This ADR covers two major components: (1) Org Context Files for shared persistent knowledge, and (2) Conversation Retrieval via hybrid vector+keyword search.

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
- `org_directory_search`

### Injection Location

The channel plugin currently injects full context on every message — this is a known inefficiency. Preferred approach: inject org context into the **system prompt** directly (not the first human message) to avoid polluting conversation history and to survive session resumption. Appending to the first human message is the fallback if system prompt injection is infeasible.

### Prompt Template Updates

Agent prompt templates (`dispatch.in_progress`, `dispatch.planning`) will be updated with guidance on when to write org memory entries: key decisions, completed milestones, important context shifts, notable events.

---

## Conversation Retrieval

### Embedding Infrastructure

- **pgvector** added to the existing Postgres instance — no new infrastructure
- HNSW index on the embedding column for approximate nearest neighbor performance

**`message_embeddings`** — separate table (keeps `chat_messages` hot table clean, allows reindexing and model swaps independently):

| Column      | Type                          | Notes                                 |
|-------------|-------------------------------|---------------------------------------|
| id          | uuid v7                       | PK                                    |
| message_id  | uuid (unique FK → chat_messages) | One embedding per message          |
| space_id    | uuid                          | Denormalized for efficient filtering  |
| embedding   | vector(dim TBD)               | Dimension depends on Gemma model      |
| model       | text                          | Embedding model identifier            |
| inserted_at | utc_datetime_usec             |                                       |

### Embedding Generation

- **Model:** Gemma via local Ollama endpoint — no API cost
- **Worker:** `Platform.Workers.MessageEmbeddingWorker` (Oban job)
- **Schedule:** Every 30 minutes, batches of 100 messages per run
- **Discovery:** LEFT JOIN on `chat_messages` to find unembedded messages

### Hybrid Search

`Platform.Chat.ConversationSearch` module combines two retrieval legs:

1. **Vector leg** — pgvector cosine similarity on `message_embeddings`
2. **Keyword leg** — existing `websearch_to_tsquery` on `chat_messages.search_vector`

Results are merged via **Reciprocal Rank Fusion (RRF)**.

### Access Control

Agents can only search spaces they are active participants in, enforced at query level via JOIN on `chat_participants`.

---

## Space ↔ Project Linking

- Add `project_id` (nullable FK) to `chat_spaces`
- When a space has a project link, conversation agents receive project context in their preamble (not just task agents via ContextAssembler)

---

## New Tools

Registered via the channel plugin WebSocket interface:

| Tool                        | Purpose                                      |
|-----------------------------|----------------------------------------------|
| `org_context_read`          | Read an org context file by key              |
| `org_context_write`         | Write/update an org context file             |
| `org_context_list`          | List available org context files             |
| `org_memory_append`         | Append a daily or long-term memory entry     |
| `org_memory_search`         | Search org memory entries                    |
| `org_directory_search`      | Search the org directory for users/agents    |
| `conversation_search`       | Cross-space conversation search (hybrid)     |
| `conversation_search_space` | Single-space conversation search (hybrid)    |

---

## Rejected Alternatives

| Alternative                              | Reason for Rejection                                                                 |
|------------------------------------------|--------------------------------------------------------------------------------------|
| Separate vector DB (Pinecone, Weaviate)  | Unnecessary infrastructure at current scale; pgvector keeps everything in Postgres    |
| Full roster injection per message        | Too much token overhead; use `org_directory_search` tool on demand instead            |
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

### Phase 3 — Conversation Search
- pgvector extension + `message_embeddings` table and HNSW index
- `Platform.Workers.MessageEmbeddingWorker` Oban job
- `Platform.Chat.ConversationSearch` hybrid search module
- `conversation_search` and `conversation_search_space` tools

### Phase 4 — Directory & Linking
- `org_directory_search` tool
- `project_id` FK on `chat_spaces` + project context in agent preamble
- UI polish
