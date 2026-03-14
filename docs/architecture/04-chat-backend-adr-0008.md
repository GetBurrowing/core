# Chat Backend Architecture — ADR 0008

Real-time work chat with native AI agent participation, three-tier attention routing for cost control, and live canvas components.

```mermaid
graph TB
  subgraph LiveView["Phoenix LiveView"]
    ChatLive["ChatLive<br/>assign: space, messages, participants<br/>presence tracking"]
  end

  subgraph ChatContext["Platform.Chat — Context"]
    CreateSpace["create_space/1"]
    AddParticipant["add_participant/2<br/>type: user | agent"]
    PostMessage["post_message/1<br/>content_type: text | system | agent_action | canvas"]
    ListMessages["list_messages/2<br/>keyset pagination by bigserial id"]
    Search["search/2<br/>tsvector full-text query"]
    ManageThread["create_thread/2<br/>pin_message/2<br/>add_reaction/3"]
  end

  subgraph Realtime["Real-time Layer"]
    PubSub["Phoenix.PubSub<br/>topic: chat:space:<id>"]
    Presence["Phoenix.Presence<br/>online participants per space"]
  end

  subgraph AttentionRouter["AttentionRouter — Cost Control Gate (per agent-space pair)"]
    Tier1["Tier 1: Mention-only<br/>@agent trigger<br/>zero cost for non-matching msgs"]
    Tier2["Tier 2: Heartbeat digest<br/>periodic batch review<br/>cheap model triage"]
    Tier3["Tier 3: Active watcher<br/>rules/embedding pre-filter<br/>before LLM call"]
  end

  subgraph Canvas["Live Canvas System"]
    CanvasLive["Canvas LiveView components<br/>agent-managed, state in DB"]
    Types["Types: table · form · code<br/>diagram · dashboard · custom"]
  end

  subgraph DB["Database (8 tables)"]
    Spaces[("chat_spaces<br/>UUID PK<br/>kind: channel|dm|group")]
    Participants[("chat_participants<br/>type: user|agent<br/>attention_mode")]
    Messages[("chat_messages<br/>bigserial PK<br/>tsvector search_vector (GIN)<br/>no updated_at")]
    Threads[("chat_threads")]
    Canvases[("chat_canvases<br/>state :map JSONB")]
    Reactions[("chat_reactions")]
    Pins[("chat_pins")]
    Attachments[("chat_attachments<br/>storage_key ref")]
  end

  AgentRuntime["Platform.Agents<br/>Runtime — responds via post_message"]
  AuditStream["Platform.Audit<br/>Event Stream"]

  ChatLive --> PostMessage & ListMessages & Search
  ChatLive --> Presence
  PostMessage --> PubSub
  PubSub --> ChatLive
  PubSub --> AttentionRouter
  AttentionRouter --> Tier1 & Tier2 & Tier3
  Tier1 & Tier2 & Tier3 --> AgentRuntime
  AgentRuntime --> PostMessage
  PostMessage --> Messages
  Messages --> Spaces & Participants & Threads
  ChatLive --> Canvas
  Canvas --> CanvasLive & Types
  CanvasLive --> Canvases
  PostMessage --> AuditStream
```

## Message Flow

```mermaid
sequenceDiagram
  participant U as User
  participant LV as ChatLive
  participant Ctx as Platform.Chat
  participant DB as PostgreSQL
  participant PS as PubSub
  participant AR as AttentionRouter
  participant Ag as AgentServer

  U->>LV: send message
  LV->>Ctx: post_message/1
  Ctx->>DB: INSERT chat_messages
  Ctx->>PS: broadcast "new_message"
  PS->>LV: push update → re-render
  PS->>AR: route to attention tier
  AR->>AR: evaluate: mention? heartbeat? active?
  AR->>Ag: execute/2 (if attention triggered)
  Ag->>Ctx: post_message/1 (agent reply)
  Ctx->>PS: broadcast agent reply
  PS->>LV: push update → re-render
```

## Attention Tier Decision

| Tier | Trigger | Cost | v1 |
|------|---------|------|----|
| 1: Mention-only | `@agent` in content | zero for non-matches | ✅ |
| 2: Heartbeat digest | periodic interval | cheap model triage | planned |
| 3: Active watcher | all messages | pre-filter + LLM | future |
