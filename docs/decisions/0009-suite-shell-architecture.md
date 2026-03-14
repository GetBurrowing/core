# ADR 0009: Suite Shell Architecture

**Status:** Accepted  
**Date:** 2026-03-14  
**Deciders:** Platform team

---

## Context

Chat is the first surface of the platform. The Control Center — where agents are configured, credentials managed, memory browsed, and pipelines observed — is the second. Additional surfaces (Execution, Analytics) follow.

Without a shell, each surface is a standalone page with no shared navigation, identity, or context. Users would need full-page navigations between surfaces. Agent status and system health would be invisible between surfaces.

The shell is the frame that holds the suite together.

---

## Decision

Build a **persistent navigation shell** as a Phoenix LiveView root layout that wraps all platform surfaces. The shell renders once and stays alive across soft navigations. Surfaces mount inside it via `live_session`.

---

## Shell Structure

### Navigation Model

```
┌─────────────────────────────────────────────────────┐
│  ⚡ Suite          [status indicators]    [user]    │  ← top bar
├──────┬──────────────────────────────────────────────┤
│      │                                              │
│  Nav │   Surface (Chat / Control Center / ...)      │
│      │                                              │
│  💬  │                                              │
│  ⚙️  │                                              │
│      │                                              │
│  ... │                                              │
└──────┴──────────────────────────────────────────────┘
```

- **Left sidebar**: icon-only nav with labels on hover; collapsible on mobile
- **Top bar**: suite wordmark, active agent status pills, user avatar + logout
- **Surface area**: full remaining viewport, independently scrollable
- **No full-page reloads**: LiveView `navigate` between surfaces

### Surfaces (v1)

| Surface | Route | Icon | Description |
|---------|-------|------|-------------|
| Chat | `/chat` | 💬 | Real-time chat with agent participation |
| Control Center | `/control` | ⚙️ | Agent management, vault, system health |

### Routes (v1 scope)

```
/ → redirect to /chat

/chat         → ChatLive (existing, moved from /)
/control      → ControlCenterLive
/control/agents        → agent list + status
/control/agents/:id    → agent detail + config editor
/control/vault         → credential list (names/scopes only, no values)
/control/system        → telemetry, audit log tail, health
```

---

## Shell LiveView Layout

The shell is a new root layout (`shell_layout.html.heex`) and a `ShellLive` module that:

1. Assigns current user from session
2. Tracks active route for nav highlighting
3. Broadcasts/receives agent status updates via PubSub
4. Renders the sidebar + topbar + `@inner_content`

All authenticated surfaces share a `live_session :authenticated` with the shell layout. The existing `ChatLive` and `PageController` redirect pattern will be replaced by this unified session.

```elixir
# router.ex
live_session :authenticated,
  on_mount: [PlatformWeb.Auth.LiveSessionHooks],
  layout: {PlatformWeb.Layouts, :shell} do
  live "/chat", ChatLive, :index
  live "/control", ControlCenterLive, :index
  live "/control/agents", ControlCenterLive, :agents
  live "/control/agents/:id", ControlCenterLive, :agent_detail
  live "/control/vault", ControlCenterLive, :vault
  live "/control/system", ControlCenterLive, :system
end
```

---

## Control Center (v1 scope)

The Control Center is a multi-tab LiveView (`ControlCenterLive`) using LiveView's `handle_params` for tab routing. v1 scope:

### Agents tab (`/control/agents`)
- List of configured agents with live status (online / offline / error)
- Agent name, model, last active timestamp
- Link to detail view

### Agent detail (`/control/agents/:id`)
- Agent config viewer (read-only in v1 — editable in v2 after Agent Runtime ships)
- Workspace file browser (SOUL.md, IDENTITY.md, USER.md contents)
- Recent activity (last N audit events for this agent)
- Memory snapshot (MEMORY.md preview)

### Vault tab (`/control/vault`)
- Credential list: name, type, scope, created/updated timestamps
- No values shown (ever) — display only
- Add / revoke credential buttons (v1: add is a simple form for `api_key` type)

### System tab (`/control/system`)
- Live audit event tail (Phoenix PubSub → LiveView update)
- Agent process health (from Registry/Supervisor — or QuickAgent status in v1)
- Recent errors from telemetry

---

## Shell Status Indicators (top bar)

Small status pills in the top bar showing live state without navigating away:

- **Agent dot**: green/yellow/red based on last QuickAgent response time
- **DB**: green if Repo can ping, red otherwise
- **Background jobs**: count of in-flight async tasks

Status driven by a `Platform.Health` module that polls on a `Process.send_after` timer inside the shell LiveView.

---

## Mobile / Responsive

- Sidebar collapses to a bottom tab bar on narrow viewports (< 768px)
- Top bar condenses (wordmark hidden, icons only)
- Surface content scrolls independently within its container

---

## Non-Goals (v1)

- No workspace picker / multi-workspace — single workspace for now
- No theme switcher — DaisyUI default
- No keyboard shortcuts — add in v2
- No notifications panel — handled by surface-level toasts for now

---

## Consequences

- Chat route moves from `/` to `/chat`; `/` redirects
- All new surfaces added to the router get the shell for free
- Control Center gives immediate visibility into agent state before full ADR 0007 runtime ships
- Shell layout is the natural home for global PubSub subscriptions (agent status, system health)
- Prepares the frame for Execution and Analytics surfaces without further layout work
