# Agent Runtime Architecture — ADR 0007

GenServer-per-agent under DynamicSupervisor, context sharing protocol, provider behaviour with Vault-backed credential resolution.

```mermaid
graph TB
  subgraph Import["Import / Bootstrap"]
    DotOpenClaw[".openclaw folder<br/>SOUL.md · MEMORY.md<br/>config.json · workspace files"]
    ConfigParser["Platform.Agents.ConfigParser<br/>OpenClaw JSON → Agent struct"]
  end

  subgraph Supervision["Supervision Tree"]
    AppSup["Platform.Application<br/>OTP root supervisor"]
    AgentSup["Platform.Agents.Supervisor<br/>DynamicSupervisor — one per platform"]
    Registry["Registry :agents<br/>name → pid lookup"]
    ServerA["AgentServer :zip<br/>GenServer"]
    ServerB["AgentServer :other<br/>GenServer"]
  end

  subgraph AgentServer["AgentServer (per agent)"]
    State["State<br/>config · workspace · memory<br/>current session"]
    ExecPipeline["execute/2<br/>message → provider call → reply"]
  end

  subgraph Context["Context Sharing Protocol"]
    ContextBroker["Platform.Agents.ContextBroker<br/>GenServer — cross-agent handoff"]
    ContextScope["ContextScope<br/>what parent shares:<br/>full | memory_only | config_only | custom"]
    ContextDelta["ContextDelta<br/>what child returns on completion"]
  end

  subgraph Providers["Provider Layer"]
    Router["Platform.Agents.Router<br/>primary → fallback model chain"]
    Behaviour["Provider behaviour<br/>chat/3 · stream/3 · models/1 · validate_credentials/1"]
    Anthropic["Providers.Anthropic<br/>OAuth Bearer<br/>anthropics-beta headers"]
    OpenAI["Providers.OpenAI<br/>API key from Vault"]
  end

  subgraph Memory["Memory + Workspace"]
    MemCtx["Platform.Agents.MemoryContext<br/>long_term · daily · snapshot"]
    WorkspaceFiles["agent_workspace_files<br/>SOUL.md · MEMORY.md · AGENTS.md<br/>versioned, editable"]
    DB[("agents · agent_memories<br/>agent_sessions · agent_workspace_files<br/>agent_context_shares")]
  end

  Vault["Platform.Vault<br/>get/2 — credential resolution"]
  AuditStream["Platform.Audit<br/>Event Stream"]

  DotOpenClaw --> ConfigParser
  ConfigParser --> AgentSup
  AppSup --> AgentSup & ContextBroker
  AgentSup --> Registry & ServerA & ServerB
  ServerA & ServerB --> State & ExecPipeline
  ExecPipeline --> Router
  ServerA <--> ContextBroker
  ContextBroker --> ContextScope & ContextDelta
  Router --> Anthropic & OpenAI
  Anthropic --> Vault
  OpenAI --> Vault
  State --> MemCtx & WorkspaceFiles
  MemCtx --> DB
  WorkspaceFiles --> DB
  ExecPipeline --> AuditStream
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| GenServer per agent | Process isolation — one crash doesn't affect others |
| DynamicSupervisor | Agents start/stop at runtime without restarting app |
| Registry for lookup | O(1) pid resolution by agent slug |
| ContextBroker GenServer | Serializes cross-agent context handoffs, prevents races |
| Provider behaviour | Swap Anthropic/OpenAI without changing agent code |
| Vault for all credentials | No hardcoded keys; rotation without redeploy |
| `.openclaw` portability | Import/Export preserves agent identity across deployments |
