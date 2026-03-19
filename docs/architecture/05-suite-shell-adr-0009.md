# Suite Shell Architecture — ADR 0009

Persistent navigation shell wrapping all LiveView surfaces. Auth-gated live_session, sidebar nav, top bar, slot-based content rendering.

```mermaid
graph TB
  subgraph External["External"]
    Browser["Browser"]
    OAuthProxy["oauth2-proxy<br/>Injects X-Auth-Request-Email<br/>X-Auth-Request-User headers"]
    OIDCProvider["OIDC Provider"]
  end

  subgraph Phoenix["Phoenix Router"]
    RequireAuth["RequireAuth plug<br/>reads oauth2-proxy headers"]
    LiveSession["live_session :authenticated<br/>on_mount: ShellLive"]
    RootRoute["GET /<br/>→ redirect /chat"]
    ChatRoute["/chat<br/>ChatLive"]
    ControlRoute["/control<br/>ControlCenterLive"]
    HealthRoute["GET /health<br/>200 — no auth, for healthcheck"]
  end

  subgraph ShellLayout["Suite Shell Layout"]
    ShellHeex["shell.html.heex"]
    TopBar["Top bar<br/>workspace name · user pill<br/>agent status indicators"]
    Sidebar["Sidebar nav<br/>Chat · Control Center<br/>(future: Tasks, Experiments)"]
    ContentSlot["@inner_content slot<br/>surface renders here"]
  end

  subgraph Surfaces["Surfaces (in slot)"]
    ChatLive["ChatLive<br/>real-time work chat"]
    ControlCenter["ControlCenterLive<br/>agent config · vault · system health"]
  end

  Browser --> OAuthProxy
  OAuthProxy <--> OIDCProvider
  OAuthProxy --> RequireAuth
  RequireAuth --> LiveSession
  LiveSession --> RootRoute & ChatRoute & ControlRoute
  ChatRoute --> ChatLive
  ControlRoute --> ControlCenter
  ChatLive & ControlCenter --> ShellHeex
  ShellHeex --> TopBar & Sidebar & ContentSlot
```

## Route Table

| Path | Module | Auth | Notes |
|------|--------|------|-------|
| `/` | — | ✅ | Redirects to `/chat` |
| `/chat` | `ChatLive` | ✅ | Main work chat surface |
| `/control` | `ControlCenterLive` | ✅ | Agent/vault/system config |
| `/health` | controller | ❌ | Healthcheck endpoint |
| `/auth/*` | `AuthController` | ❌ | OIDC callback routes |

## Auth Flow

```mermaid
sequenceDiagram
  participant B as Browser
  participant T as Traefik
  participant O as oauth2-proxy
  participant P as OIDC Provider
  participant A as Phoenix App

  B->>T: GET /chat
  T->>O: forward (chain-oauth2)
  O->>B: 302 → OIDC Provider /authorize
  B->>P: GET /authorize
  P->>B: login page
  B->>P: credentials
  P->>O: callback with code
  O->>P: token exchange
  O->>A: forward with X-Auth-Request-* headers
  A->>A: RequireAuth reads headers
  A->>B: 200 ChatLive
```

## Shell Extension Pattern

New surfaces slot into the shell by:
1. Adding a route inside `live_session :authenticated`
2. Adding a nav entry in `shell.html.heex` sidebar
3. Using the shell layout (inherited automatically from live_session)

No shell modifications needed for the surface itself — the `@inner_content` slot handles rendering.
