# ADR 0015: Agent Onboarding and Role Templates

**Status:** Accepted  
**Date:** 2026-03-19  
**Deciders:** the product owner, Zip  
**Related:** ADR 0014 (Agent Federation), ADR 0007 (Agent Runtime)  

---

## Context

The current Agent Resources UI exposes a single "Create" flow with a full
form (name, slug, model, status, sandbox, max concurrent). This is
intimidating for new users and positions agent creation as a technical
exercise rather than a simple decision.

With federation (ADR 0014), there are now multiple ways an agent can arrive
in Burrow: created locally, federated from an external runtime, imported
from a workspace, or instantiated from a role template. The UI needs to
surface these paths in order of ease, not technical complexity.

The current create form should be the last resort, not the first thing
users see.

---

## Decision

We will restructure agent onboarding into four paths, ordered from
easiest to most complex, with a mobile-first UI that presents simple
choices before extensive data entry.

---

## Decision Details

### 1. Four onboarding paths

| Path | Steps | Who it's for |
|------|-------|-------------|
| **Role Template** | Pick role, name it, done | Users who want a working agent fast |
| **Federate** | Enter connection, confirm, done | Users running their own OpenClaw |
| **Import** | Select agents from workspace, confirm | Users with existing OpenClaw config |
| **Create Custom** | Full manual form | Power users, edge cases |

### 2. Role Templates

Pre-built agent configurations that map to common job roles. Each template
includes: name suggestion, system prompt, recommended model tier, tool
profile, and default attention behavior.

Initial templates:

| Template | Description | Tool profile | Default model tier |
|----------|-------------|-------------|-------------------|
| Designer | Visual design, UI/UX, branding | canvas, image, web_search | mid (Sonnet-class) |
| Researcher | Deep research, analysis, synthesis | web_search, web_fetch, pdf | high (Opus-class) |
| Architect | System design, ADRs, code review | fs, exec, web_search | high (Opus-class) |
| Writer | Content, docs, copywriting | fs, web_search | mid (Sonnet-class) |
| Analyst | Data analysis, reporting, dashboards | canvas, web_fetch, exec | mid (Sonnet-class) |
| DevOps | Infrastructure, CI/CD, monitoring | exec, fs, web_search | mid (Sonnet-class) |
| PM | Project management, planning, tracking | canvas, web_search | mid (Sonnet-class) |
| Sales | Outreach, proposals, CRM | web_search, web_fetch, canvas | mid (Sonnet-class) |

Templates are not frozen — users can edit any field after creation. The
template just provides a smart starting point.

### 3. Federate flow

1. User enters Burrow WebSocket URL (pre-filled with current Burrow instance)
2. User enters runtime_id and receives a pairing token
3. Token is shown once with copy button and OpenClaw config snippet
4. Connection instructions displayed
5. Agent appears in list when the external runtime connects

### 4. Import flow

1. Burrow reads the mounted OpenClaw workspace config (agents.list)
2. Shows available agents with checkboxes
3. User selects which to import
4. Agents are created in Burrow's database from the workspace definitions

### 5. Mobile-first UI

The entry point is a single "Add Agent" action. Tapping it shows a clean
selection screen with four large cards — one per path. No form fields
visible until the user has chosen their path.

Agent list on the main screen: cards with name, role badge, status
indicator. Tap to expand/edit. No sidebar on mobile — full-screen list
with tap-to-detail navigation.

### 6. Create Custom (existing form)

Preserved as-is but positioned as the expert option. Reached only through
explicit selection from the onboarding chooser, not as the default view.

---

## Consequences

### Positive

- New users can have a working agent in 2 taps (template path)
- Federation is a first-class onboarding path, not hidden in settings
- Mobile experience is clean and focused
- Power users still have full control via Create Custom

### Negative

- Role templates need maintenance as capabilities evolve
- Template defaults may not suit every deployment

---

## References

- ADR 0014: Agent Federation and External Runtimes
- ADR 0007: Agent Runtime Architecture
