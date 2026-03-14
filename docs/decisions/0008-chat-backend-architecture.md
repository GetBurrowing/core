# ADR 0008: Chat Backend Architecture

## Status

Accepted

## Context

Chat is the first product surface to ship (ADR 0002). It needs to be a
genuinely good work chat experience — on par with Slack and Discord for daily
use — while also being the primary interface through which AI agents collaborate
with humans on the platform.

The distinguishing feature is not the chat itself but the agent integration
model: an agent is a native participant in conversations, not a bot bolted on
via webhooks. The agent can read discussion context, create tasks, record
decisions, connect dots across conversations, and render live interactive
artifacts — all through the same conversational interface humans use.

### Design constraints

1. **Exceptional chat fundamentals**. Rich text (markdown), code blocks with
   syntax highlighting, attachments (files, images), threads, reactions, pins,
   mentions, Unicode/emoji, typing indicators, presence, unread tracking. The
   basics must be excellent before the agent features matter.

2. **Agent as native participant**. Agents join spaces as participants alongside
   humans. They use the same message system, appear in the same participant
   list, and their messages are indistinguishable from human messages in the
   transport layer.

3. **Cost-conscious agent attention**. Processing every message through an LLM
   in an active chat would be prohibitively expensive. The agent's attention
   must be tiered — from explicit mention (cheapest) to periodic digest to
   filtered real-time monitoring — with the tier configurable per space.

4. **Live canvas**. Inspired by OpenClaw's canvas feature, agents should be able
   to render interactive LiveView components inline in chat. Tables, forms,
   diagrams, dashboards — server-rendered, real-time, collaborative.

5. **Cross-module awareness**. The agent in chat can act across the platform:
   create tasks in Execution, record decisions in Audit, query Vault for
   credentials, search past messages for context. Chat is the shared
   collaborative interface for the entire suite.

6. **Phoenix-native realtime**. PubSub for broadcast, Presence for online
   status, LiveView for the UI, Channels for WebSocket transport. No external
   realtime infrastructure needed.

## Decision

### New domain: `Platform.Chat`

Chat is already defined as a platform domain in ADR 0002. This ADR specifies
the internal architecture of that domain.

```
Platform.Chat
├── Space         — space/channel CRUD, membership, archival
├── Thread        — thread lifecycle, parent message linking
├── Message       — CRUD, rich content, soft delete, ordering
├── Participant   — user/agent membership, roles, read receipts
├── Attachment    — file upload, storage, serving
├── Reaction      — emoji reactions
├── Pin           — message pinning
├── Canvas        — live canvas CRUD, state management, component rendering
├── Presence      — online/typing via Phoenix.Presence
├── Search        — full-text search (PostgreSQL tsvector)
├── Agent         — attention routing, message-to-agent bridging
│   └── AttentionRouter — per-agent-space GenServer managing attention tier
└── PubSub        — topic management, broadcast helpers
```

### Message model

Messages are stored as **markdown with a structured metadata sidecar**. Markdown
is pragmatic: it is what humans type, what agents produce, and what LLMs
understand natively. The structured sidecar handles mentions, inline
attachments, and format hints without requiring a complex document model.

```json
{
  "content": "Let's go with approach B for the auth flow. @zip can you create a task?",
  "structured_content": {
    "mentions": [
      {"type": "agent", "id": "zip", "offset": 49, "length": 4}
    ],
    "code_blocks": [],
    "format_hints": []
  }
}
```

### Content types

| Type | Description |
|------|-------------|
| `text` | Rich text with markdown (normal messages, code blocks, links) |
| `system` | Platform-generated events (join, leave, decision recorded) |
| `agent_action` | Agent performed a platform action (task created, decision logged) |
| `canvas` | Reference to a live canvas component |

### Agent attention tiers

The cost of agent participation must be controllable. Three tiers, escalating
from cheapest to most resource-intensive:

**Tier 1 — Direct Mention** (default, ship first)

The agent activates only when explicitly mentioned via `@agent_slug`. The
attention router performs a string match on the message content — O(1), zero
API cost for non-matching messages. On match: load recent context (configurable
window), send to the agent's GenServer for processing.

This is the v1 implementation. It gives full control to users, costs nothing
when the agent isn't summoned, and establishes the interaction pattern.

**Tier 2 — Heartbeat Digest** (future)

The agent periodically reviews a batch of recent messages (configurable
interval: 15 minutes to several hours). A cheaper model (Haiku-class) can
perform the initial triage: summarize activity, identify decisions, surface
action items. Only findings that warrant a response escalate to the agent's
primary model.

Cost scales with the heartbeat interval, not message volume.

**Tier 3 — Active Watcher** (future)

The agent monitors messages in real-time but applies a pre-filter before
engaging the LLM. Filter strategies (configurable per space):

- **Rule-based**: keyword patterns ("decision", "action item", "we should",
  directed questions)
- **Embedding similarity**: compare message embedding against the agent's
  responsibility vector (cheap vector comparison, no LLM call)
- **Local model**: Ollama or similar for binary "should I engage?"
  classification — zero API cost
- **Cheap model**: Haiku-class triage when local inference is unavailable

Only messages that pass the filter get full LLM processing. Cost scales with
relevance, not volume.

### Attention routing architecture

An `AttentionRouter` GenServer sits between PubSub and the agent process.
One router per agent-space pair.

```
Message → PubSub → AttentionRouter → (filter by tier) → Agent GenServer
                         ↓
                    (drop if not relevant)
```

For Tier 1: string match for `@slug` — trivial.
For Tier 2: buffer messages, deliver batch on heartbeat tick.
For Tier 3: run configured pre-filter, forward only matches.

The router is the cost control gate. The agent GenServer never sees messages
that didn't pass the router's filter.

### Live canvas

A canvas is a LiveView component embedded in the chat, managed by an agent.
Phoenix LiveView provides real-time updates, collaborative state, and
server-rendered interactivity without additional infrastructure.

**Built-in canvas types:**

| Type | Description |
|------|-------------|
| `table` | Interactive data table (sortable, filterable) |
| `form` | Structured input form (agent collects information) |
| `code` | Syntax-highlighted code editor |
| `diagram` | Mermaid-rendered flowcharts and architecture diagrams |
| `dashboard` | Metrics, charts, project health |
| `custom` | Agent specifies a LiveView component module + initial state |

**Canvas lifecycle:**

1. Agent calls `Platform.Chat.Canvas.create/2` with type + initial state
2. A `chat_canvases` record is created with the component module and state
3. A `canvas`-type message is inserted in the space, referencing the canvas
4. The chat UI renders the canvas component inline (or in a side panel)
5. Users interact with the canvas via standard LiveView events
6. Agent can update canvas state via `Canvas.update_state/2`
7. State persists in PostgreSQL — survives page refreshes, can be referenced
   later

**State synchronization:** Canvas state updates broadcast on
`chat:canvas:{canvas_id}` via PubSub. All connected clients (users and agent)
see updates in real-time.

### Realtime architecture

All realtime features use Phoenix's built-in primitives:

**PubSub topics:**
- `chat:space:{id}` — messages, reactions, pins in a space
- `chat:thread:{id}` — messages in a thread
- `chat:typing:{space_id}` — typing indicators
- `chat:canvas:{canvas_id}` — canvas state updates
- `chat:presence:{space_id}` — presence updates

**Message flow:**
1. User sends message via LiveView form
2. Message persisted to `chat_messages` (bigserial ID for ordering)
3. PubSub broadcasts to `chat:space:{space_id}`
4. All connected LiveView clients receive the update and re-render
5. AttentionRouter (subscribed to the topic) evaluates the message
6. If the attention tier passes: forward to agent GenServer
7. Agent processes, optionally responds via the same message path
8. Agent's response is indistinguishable from a user message in transport

**Presence:** `Phoenix.Presence` tracks online participants per space.
Agents register presence when their GenServer is running. Typing indicators
use a dedicated topic with short TTL broadcasts.

### Search

PostgreSQL full-text search via `tsvector` for v1:

```sql
ALTER TABLE chat_messages ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(content, ''))
  ) STORED;

CREATE INDEX idx_chat_messages_search ON chat_messages USING gin(search_vector);
```

Query with `websearch_to_tsquery` for natural search syntax. Filter by space,
participant, date range, content type. Good enough for production use without
external search infrastructure. Upgrade path to Meilisearch or Typesense if
scale demands it.

### Data model

```sql
-- Spaces (channels, DMs, groups)
CREATE TABLE chat_spaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID,
  name VARCHAR NOT NULL,
  slug VARCHAR NOT NULL,
  description TEXT,
  kind VARCHAR NOT NULL DEFAULT 'channel',  -- channel|dm|group
  topic TEXT,
  metadata JSONB DEFAULT '{}',
  archived_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT unique_space_slug UNIQUE (workspace_id, slug)
);

-- Threads
CREATE TABLE chat_threads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  parent_message_id BIGINT,  -- FK added after chat_messages exists
  title VARCHAR,
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

-- Messages (bigserial for monotonic ordering)
CREATE TABLE chat_messages (
  id BIGSERIAL PRIMARY KEY,
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  thread_id UUID REFERENCES chat_threads(id) ON DELETE SET NULL,
  participant_id UUID NOT NULL REFERENCES chat_participants(id),
  content_type VARCHAR NOT NULL DEFAULT 'text',
  content TEXT,
  structured_content JSONB DEFAULT '{}',
  metadata JSONB DEFAULT '{}',
  edited_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL,

  search_vector TSVECTOR GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(content, ''))
  ) STORED
);

CREATE INDEX idx_chat_messages_space ON chat_messages (space_id, id DESC);
CREATE INDEX idx_chat_messages_thread ON chat_messages (thread_id, id DESC);
CREATE INDEX idx_chat_messages_participant ON chat_messages (participant_id);
CREATE INDEX idx_chat_messages_search ON chat_messages USING gin(search_vector);

-- Participants (users AND agents in a space)
CREATE TABLE chat_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  participant_type VARCHAR NOT NULL,  -- user|agent
  participant_id UUID NOT NULL,       -- references users.id or agents.id
  role VARCHAR NOT NULL DEFAULT 'member',  -- member|admin|observer
  display_name VARCHAR,
  avatar_url VARCHAR,
  last_read_message_id BIGINT,
  -- Agent attention config (only relevant when participant_type = 'agent')
  attention_mode VARCHAR DEFAULT 'mention',  -- mention|heartbeat|active
  attention_config JSONB DEFAULT '{}',
  joined_at TIMESTAMPTZ NOT NULL,
  left_at TIMESTAMPTZ,
  CONSTRAINT unique_participant UNIQUE (space_id, participant_type, participant_id)
);

-- Attachments
CREATE TABLE chat_attachments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  filename VARCHAR NOT NULL,
  content_type VARCHAR NOT NULL,
  byte_size BIGINT NOT NULL,
  storage_key VARCHAR NOT NULL,
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

-- Reactions
CREATE TABLE chat_reactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  participant_id UUID NOT NULL REFERENCES chat_participants(id) ON DELETE CASCADE,
  emoji VARCHAR NOT NULL,
  inserted_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT unique_reaction UNIQUE (message_id, participant_id, emoji)
);

-- Pins
CREATE TABLE chat_pins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  message_id BIGINT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  pinned_by UUID NOT NULL REFERENCES chat_participants(id),
  inserted_at TIMESTAMPTZ NOT NULL
);

-- Canvases (agent-managed live surfaces)
CREATE TABLE chat_canvases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  message_id BIGINT REFERENCES chat_messages(id),
  created_by UUID NOT NULL REFERENCES chat_participants(id),
  title VARCHAR,
  canvas_type VARCHAR NOT NULL,  -- table|form|code|diagram|dashboard|custom
  state JSONB DEFAULT '{}',
  component_module VARCHAR,      -- LiveView component module name
  metadata JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

### Telemetry events

```
[:platform, :chat, :message_sent]
[:platform, :chat, :message_edited]
[:platform, :chat, :message_deleted]
[:platform, :chat, :space_created]
[:platform, :chat, :space_archived]
[:platform, :chat, :participant_joined]
[:platform, :chat, :participant_left]
[:platform, :chat, :reaction_added]
[:platform, :chat, :reaction_removed]
[:platform, :chat, :canvas_created]
[:platform, :chat, :canvas_updated]
[:platform, :chat, :agent_activated]      -- attention router forwarded a message
[:platform, :chat, :agent_responded]
[:platform, :chat, :agent_action_taken]   -- agent created task, recorded decision, etc.
```

## Consequences

- Chat is a fully featured work chat — markdown, threads, reactions, pins,
  attachments, search, presence. The fundamentals must be good before agent
  features matter.
- Agents are native participants, not bot integrations. They join spaces, send
  messages, and appear in the participant list alongside humans.
- Agent attention is cost-controlled via a three-tier model. Tier 1 (mention
  only) ships first and costs nothing when the agent isn't summoned. Tiers 2
  and 3 add progressive automation with configurable cost profiles.
- The AttentionRouter is the cost control gate. No message reaches the agent's
  LLM without passing through the router's filter.
- Live canvases leverage Phoenix LiveView for real-time interactive content.
  The agent can render tables, forms, diagrams, and dashboards inline in chat
  without client-side JavaScript frameworks.
- PubSub, Presence, and LiveView provide the full realtime stack. No external
  infrastructure (Redis, WebSocket servers) is required.
- Full-text search uses PostgreSQL tsvector. No external search engine needed
  for v1.
- All chat operations emit telemetry events, feeding into the Audit event
  stream (ADR 0005).

## Follow-up

1. Write migrations for all 8 chat tables
2. Implement Space, Message, Participant context modules
3. Build PubSub + Presence foundation
4. Replace ChatLive scaffold with real LiveView UI
5. Implement Agent.AttentionRouter (Tier 1: mention-only)
6. Add threads, reactions, pins
7. Implement attachment upload and storage
8. Build canvas system (built-in types + agent API)
9. Add full-text search
10. Implement agent cross-module actions (task creation, decision recording)
