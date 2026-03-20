# ADR 0016: Control Center LiveView Modularization

**Status:** Accepted  
**Date:** 2026-03-20  
**Related:** ADR 0010 (Mobile Navigation and Agent Resources), ADR 0015 (Agent Onboarding and Role Templates)  
**Deciders:** Rowan Ellis  

## Context

`ControlCenterLive` had grown to 3,219 lines — a single LiveView module containing 168 functions, 45 `handle_event` clauses, and ~1,400 lines of inline HEEx template. It served as the entire Agent Resources surface: agent directory, detail views, config forms, workspace file editor, memory browser, runtime monitoring, vault visibility, onboarding flows (4 paths), federation management, and CRUD operations.

This scale made the file difficult to navigate, review, and modify safely. Adding a feature to any section required understanding the entire module. The blast radius of any change was the whole file.

The chat surface (`ChatLive`, 2,982 lines) has similar issues but was deliberately excluded from this effort to limit scope and risk.

## Decision

Decompose `ControlCenterLive` into focused modules using three Phoenix-idiomatic patterns:

### 1. Function Components (stateless render extraction)

Extract inline HEEx sections into `Phoenix.Component` modules with `attr` declarations. Components are pure functions — they receive assigns and return markup. No socket access, no side effects.

### 2. Event Handler Modules (behavioral extraction)

Group related `handle_event` clauses into dedicated modules. The main LiveView retains one-liner delegation clauses that route by event name:

```elixir
def handle_event("choose_onboarding", params, socket),
  do: OnboardingEvents.handle("choose_onboarding", params, socket)
```

Handler modules return standard `{:noreply, socket}` tuples. They may call back into the main LiveView's public `reload_selected_agent/2` for state refresh.

### 3. Data Module (query and logic extraction)

Pure data functions — agent directory listing, runtime snapshots, form builders, config parsing, memory queries, agent deletion — move to a dedicated module. No socket or assign access; all functions take and return plain data.

### What stays in the main LiveView

- `mount/3` — initial socket setup
- `handle_params/3` — URL-driven state loading
- `render/1` — thin shell calling components
- `assign_agent_panel/3` and `assign_empty_panel/1` — socket assign orchestration
- Runtime start/stop/refresh and config save — tightly coupled to socket state, short enough to not warrant extraction
- Sandbox and lifecycle helpers

## Module Structure

```
control_center_live.ex          (719 lines)  — Shell: lifecycle, render, panel assignment
control_center/
├── agent_card.ex               ( 60 lines)  — Sidebar directory entry component
├── agent_detail.ex             (890 lines)  — 8 detail panel components
├── agent_data.ex               (475 lines)  — Data queries, form builders, helpers
├── onboarding.ex               (491 lines)  — Onboarding overlay component
├── onboarding_events.ex        (348 lines)  — Onboarding event handlers + templates
├── helpers.ex                  (156 lines)  — Shared badge/format/normalize functions
├── agent_crud_events.ex        (150 lines)  — Create/delete event handlers
├── runtime_panel.ex            (177 lines)  — Stat card + credential row components
├── workspace_events.ex         (127 lines)  — File select/save event handlers
├── runtime_events.ex           ( 93 lines)  — Federation runtime management handlers
└── memory_events.ex            ( 64 lines)  — Memory filter/append handlers
```

**Total: 3,750 lines across 12 files** (vs 3,219 in one file). The ~16% growth is structural overhead (module declarations, `attr` specs, imports) — a worthwhile trade for navigability.

## AgentDetail Components

The largest extraction. Eight function components, each rendering one section of the agent detail panel:

| Component | Purpose |
|-----------|---------|
| `header/1` | Agent name, status badges, runtime state, action buttons, delete confirm |
| `stats/1` | Stat cards — federation (connection, trust, spaces) or built-in (runtime, sessions, files, memories, vault) |
| `federation_panels/1` | Identity form + spaces list (external agents only) |
| `config_form/1` | Model config, status, sandbox, thinking, resolved chain |
| `workspace_editor/1` | File list, editor textarea, file key input |
| `memory_browser/1` | Filter form, memory list, add-memory form |
| `runtime_monitor/1` | Runtime status, PID, active sessions, session history |
| `vault_panel/1` | Agent-scoped and platform credential visibility |

## Helpers Consolidation

`slugify/1`, `changeset_error_summary/1`, `normalize_map/1`, `blank_to_nil/1`, `blank_fallback/2`, `primary_model_label/1`, and `workspace_hint/2` were duplicated across the main module and event handler modules. All now live in `Helpers` and are imported where needed.

## Test Strategy

The refactor was driven by a test-first approach:

1. **Baseline:** 14 existing tests, all passing
2. **Coverage expansion:** 21 new tests added before any refactoring, covering onboarding flows, federation UI, runtime management, agent deletion, memory filtering, workspace files, and template creation
3. **Validation gate:** Full test suite (35 control center + 28 other LiveView tests = 63 total) run after every extraction step
4. **Why this works:** Tests use `Phoenix.LiveViewTest` — they mount the page, interact via events, and assert on rendered HTML. Internal module boundaries are invisible to them. A component extraction that preserves HTML output cannot break a test.

## Consequences

### Positive

- **Navigability:** Finding "where does the memory browser render?" → `agent_detail.ex`, `memory_browser/1`. Previously: scroll through 3,219 lines.
- **Blast radius:** Changing onboarding UI touches `onboarding.ex` + `onboarding_events.ex`. The main LiveView, agent detail, and data layer are untouched.
- **Reviewability:** PRs that modify one concern show diffs in one or two focused files.
- **Reusability:** Components like `RuntimePanel.stat_card` and `AgentCard.card` can be used from other LiveViews if needed.
- **Attr documentation:** `attr` declarations serve as component API documentation — explicit inputs, no guessing which assigns a template chunk needs.

### Negative

- **Indirection:** Understanding the full event flow requires following delegation from the main module to handler modules. Mitigated by consistent naming (event name matches handler module).
- **Total line count grew ~16%:** Module boilerplate (defmodule, use, import, attr declarations). This is structural investment, not complexity growth.
- **Handler modules call back to main LiveView:** `RuntimeEvents` calls `PlatformWeb.ControlCenterLive.reload_selected_agent/2` — a circular reference. Acceptable for now; could be resolved with a behaviour or callback module if it becomes problematic.

### Not addressed

- `ChatLive` (2,982 lines) — same patterns apply but deferred to a separate effort
- LiveComponent migration — deliberately avoided; function components are simpler and sufficient for stateless rendering
- Separate `.heex` template files — kept inline for co-location with `attr` declarations

## Alternatives Considered

1. **LiveComponent extraction** — rejected because the panels are stateless renderers, not interactive widgets with their own lifecycle. `Phoenix.Component` is the correct abstraction.
2. **Single mega-component module** — would reduce file count but not improve navigability within the component file.
3. **Separate `.heex` files** — valid but loses co-location of `attr` declarations with their templates. Inline HEEx is the Phoenix 1.7+ convention for function components.
4. **Full page split** (separate LiveViews for agent detail vs directory) — too invasive; the current single-page design with URL-driven panels works well for the UX.
