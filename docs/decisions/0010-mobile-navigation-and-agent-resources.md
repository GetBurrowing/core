# ADR 0010: Mobile Navigation Model and Agent Resources Naming

**Status:** Accepted  
**Date:** 2026-03-15  
**Deciders:** Team

---

## Context

ADR 0009 established a persistent suite shell with shared navigation across Chat and Control Center. That shell works conceptually on desktop, but mobile usage reveals a deeper problem: the shell is only one layer of navigation, while each module also contains its own browser/detail structure.

On mobile, simply collapsing the shell sidebar is not enough. The content inside Chat and Control Center is still compacted because desktop split-pane layouts are being squeezed into a phone viewport.

At the same time, mobile navigation must avoid stacking multiple hamburger-driven drawers. A shell-level drawer for modules plus a second module-level drawer for channels/resources would be confusing and wasteful.

We need a coherent rule for how navigation behaves across desktop and mobile without overloading the shell drawer.

---

## Decision

Adopt a **two-level navigation model**:

1. **Shell drawer = top-level module navigation only**
2. **Each module uses its own browser/detail pattern**

For mobile, use **Option A** for browser/detail presentation:

- open directly into the current **detail view**
- access the module's **browser** from the title/header area or another module-specific affordance
- selecting a browser item returns the user to the detail view

This means:

- the shell drawer is only for switching between modules like Chat, Agent Resources, Tasks, and future modules
- the shell drawer must **not** become a container for channels, conversations, agent lists, or other module-local structures
- module-local navigation must **not** use a second hamburger drawer

We also rename the user-facing surface name **Control Center** to **Agent Resources**.

---

## Navigation Model

### App-Level Navigation

The shell owns the global module switcher.

Examples:
- Chat
- Agent Resources
- Tasks
- future suite modules

This is the only drawer/hamburger-driven navigation on mobile.

### Module-Level Navigation

Each module defines its own browser and detail views.

Examples:

- **Chat**
  - Browser: conversations / channels / DMs
  - Detail: active conversation thread
- **Agent Resources**
  - Browser: agents, vault, sessions, memories, resource lists
  - Detail: selected agent/resource screen

The browser is not placed in the shell drawer.

---

## Responsive Behavior

### Desktop

Desktop may continue to use split-pane layouts where appropriate:

- browser pane + detail pane side by side
- richer persistent navigation within a module

### Mobile

Mobile shows **one primary pane at a time**:

- either browser
- or detail
- never both persistently side by side

The mobile default for browser/detail modules is:

- land in the current detail view
- use the title/header affordance to access the browser
- select an item and return to detail

This preserves the same information architecture across screen sizes while changing the presentation model appropriately.

---

## Shell Implications

The mobile shell task should remain narrowly scoped to:

- module-level drawer for top-level destinations only
- active module name in the mobile header
- full-width content area on mobile
- rename visible navigation copy from **Control Center** to **Agent Resources**

The shell task should **not** attempt to solve Chat channel browsing or Agent Resources internal information architecture.

---

## Naming Decision

Rename the user-facing surface **Control Center** to **Agent Resources**.

Rationale:
- clearer than "Control Center"
- more specific to the domain
- evokes the idea of managing agent concerns in the same way Human Resources manages human organizational concerns
- scales naturally to include config, memory, sessions, vault, tools, health, and import/export concerns

Short-term implementation note:
- visible UI copy should change now
- internal file/module/route names may remain stable temporarily if that reduces churn

---

## Consequences

### Positive

- avoids the anti-pattern of multiple competing mobile drawers
- keeps shell responsibilities clean and bounded
- gives a reusable pattern for all future modules
- supports desktop richness without forcing desktop IA onto mobile
- clarifies that mobile requires a first-class design model, not just responsive CSS compression

### Negative

- module behavior will intentionally differ between desktop and mobile presentation
- Chat and Agent Resources each need their own follow-up mobile IA work
- some route/header/title patterns may need to change to support browser → detail transitions cleanly

---

## Non-Goals

This ADR does **not** define:

- the exact mobile browser affordance for Chat (title tap, sheet, pushed route, segmented control, etc.)
- the full information architecture for Agent Resources
- all future module-level mobile interaction details

Those are follow-up design and implementation tasks.

---

## Follow-Up Work

1. Finish the mobile shell drawer/full-width content task with the shell drawer scoped to modules only
2. Complete an **Agent Resources** design pass for mobile-first browser/detail IA
3. Define Chat mobile browser/detail behavior using Option A
4. Apply the same pattern to future modules rather than inventing one-off navigation models
