# Control Center Module Architecture

Module dependency diagram for the modularized `ControlCenterLive` (ADR 0016).

## Module Dependency Graph

```mermaid
graph TD
    subgraph "LiveView Shell"
        CCL[ControlCenterLive<br/><i>719 lines</i><br/>mount · handle_params · render<br/>panel assignment · runtime events]
    end

    subgraph "Function Components"
        AC[AgentCard<br/><i>60 lines</i><br/>sidebar entry]
        AD[AgentDetail<br/><i>890 lines</i><br/>header · stats · config_form<br/>workspace_editor · memory_browser<br/>runtime_monitor · vault_panel<br/>federation_panels]
        OB[Onboarding<br/><i>491 lines</i><br/>overlay · chooser · template flow<br/>federate flow · import flow · create form]
        RP[RuntimePanel<br/><i>177 lines</i><br/>stat_card · credential_row<br/>federation_connection_panel]
    end

    subgraph "Event Handlers"
        OBE[OnboardingEvents<br/><i>348 lines</i><br/>template · federate · import]
        RE[RuntimeEvents<br/><i>93 lines</i><br/>suspend · revoke · regenerate]
        ACE[AgentCrudEvents<br/><i>150 lines</i><br/>create · delete]
        WE[WorkspaceEvents<br/><i>127 lines</i><br/>select · save · new file]
        ME[MemoryEvents<br/><i>64 lines</i><br/>filter · append]
    end

    subgraph "Data Layer"
        AData[AgentData<br/><i>475 lines</i><br/>list_agents · runtime_snapshot<br/>form builders · config parsing<br/>memory/session queries · delete]
    end

    subgraph "Shared"
        H[Helpers<br/><i>156 lines</i><br/>badge classes · humanize · format<br/>normalize · slugify · error summary]
    end

    %% LiveView calls components
    CCL -->|"renders"| AC
    CCL -->|"renders"| AD
    CCL -->|"renders"| OB
    CCL -->|"delegates events"| OBE
    CCL -->|"delegates events"| RE
    CCL -->|"delegates events"| ACE
    CCL -->|"delegates events"| WE
    CCL -->|"delegates events"| ME
    CCL -->|"queries"| AData

    %% Component dependencies
    AD -->|"uses"| RP
    AD -->|"imports"| H
    AC -->|"imports"| H
    OB -->|"imports"| H
    RP -->|"imports"| H

    %% Event handler dependencies
    OBE -->|"imports"| H
    ACE -->|"queries"| AData
    ACE -->|"calls reload"| CCL
    WE -->|"calls reload"| CCL
    ME -->|"calls reload"| CCL
    RE -->|"calls reload"| CCL

    %% Data layer dependencies
    AData -->|"imports"| H

    %% Styling
    classDef shell fill:#4F46E5,stroke:#3730A3,color:#fff
    classDef component fill:#0D9488,stroke:#0F766E,color:#fff
    classDef handler fill:#D97706,stroke:#B45309,color:#fff
    classDef data fill:#7C3AED,stroke:#6D28D9,color:#fff
    classDef shared fill:#6B7280,stroke:#4B5563,color:#fff

    class CCL shell
    class AC,AD,OB,RP component
    class OBE,RE,ACE,WE,ME handler
    class AData data
    class H shared
```

## Layer Responsibilities

| Layer | Modules | Role |
|-------|---------|------|
| **Shell** | `ControlCenterLive` | LiveView lifecycle, socket assigns, URL routing, `render/1` composition |
| **Components** | `AgentCard`, `AgentDetail`, `Onboarding`, `RuntimePanel` | Pure HEEx rendering via `Phoenix.Component`. No state, no side effects. |
| **Event Handlers** | `OnboardingEvents`, `RuntimeEvents`, `AgentCrudEvents`, `WorkspaceEvents`, `MemoryEvents` | Grouped `handle_event` clauses. Return `{:noreply, socket}`. May call back to shell for reload. |
| **Data** | `AgentData` | Queries, form builders, config parsing, deletion. No socket access. |
| **Shared** | `Helpers` | Badge classes, formatting, normalization. Imported by all layers. |

## Data Flow

```mermaid
sequenceDiagram
    participant Browser
    participant CCL as ControlCenterLive
    participant Handler as Event Handler
    participant AData as AgentData
    participant Component as Function Component
    participant DB as Ecto/Repo

    Browser->>CCL: phx-click event
    CCL->>Handler: delegate(event, params, socket)
    Handler->>AData: query / build form
    AData->>DB: Repo query
    DB-->>AData: data
    AData-->>Handler: result
    Handler->>CCL: reload_selected_agent(socket)
    CCL->>AData: list_agents(), runtime_snapshot(), etc.
    AData->>DB: queries
    DB-->>AData: data
    AData-->>CCL: assign data
    CCL->>Component: render with assigns
    Component-->>CCL: HEEx markup
    CCL-->>Browser: DOM patch
```
