# ADR 0004: Authentication Strategy

- **Status:** Accepted
- **Date:** 2026-03-13
- **Owners:** Team

## Context

Startup Suite Core needs an authentication model from the beginning. Several options exist:

- roll a custom username/password system
- delegate entirely to infrastructure-level authentication (reverse proxy auth headers)
- delegate identity to an external OIDC provider and own only the session and user record

The platform has explicit product goals that affect this choice:

- multi-user from day one — authentication is not a single-user afterthought
- personal domains and operator infrastructure must not bleed into the public codebase
- the system should feel professional and explicit, not cobbled together
- experiments, variants, and human review depend on knowing who the current user is
- the Accounts platform domain is a first-class concern, not a wrapper around a library

We also have an early-stage constraint: the platform is a Phoenix scaffold without a database yet. Auth introduces the first real persistence requirement.

## Decision

We will use **OIDC delegation** for authentication.

The application delegates identity verification to an operator-supplied OIDC provider and owns only:

- the user record (persisted in Postgres)
- the session (server-side, cookie-backed)
- route protection via a plug

### Why not custom auth

Rolling a username/password system requires:

- password hashing and storage
- email verification
- password reset flows
- brute force protection
- potential MFA support

None of this is core product value. It is undifferentiated infrastructure that introduces real security risk if done carelessly. Delegating to an OIDC provider eliminates these concerns.

### Why not infrastructure-level auth only

Relying purely on reverse proxy authentication headers (where the proxy asserts identity via headers before the app sees the request) is a useful interim posture but not a durable architecture:

- the app cannot reason about the current user without reading external headers
- user persistence and profile data require app-level handling regardless
- the app cannot own session expiry, logout, or token refresh
- it couples the application's auth model to a specific infrastructure topology

Infrastructure-level auth may be used as a **temporary protective layer** during early deployment before app-level OIDC is wired up. Once the app owns auth, the infrastructure layer should be removed so the app is the single auth authority.

### OIDC client library

We will use **assent** as the Elixir OIDC client library.

Assent handles:

- OIDC discovery (fetching provider metadata from the well-known endpoint)
- authorization URL construction
- authorization code exchange
- ID token parsing and claim extraction
- userinfo endpoint requests
- PKCE support

Assent is provider-agnostic. Any OIDC-compliant provider can be configured without code changes.

### Configuration model

All OIDC provider configuration is supplied via environment variables:

| Variable | Purpose |
|---|---|
| `OIDC_ISSUER` | OIDC issuer base URL (used for discovery) |
| `OIDC_CLIENT_ID` | OAuth2 client identifier |
| `OIDC_CLIENT_SECRET` | OAuth2 client secret |
| `APP_URL` | Application base URL (used to construct the callback URI) |

No provider-specific URLs, client IDs, or secrets appear in the public codebase. Operators supply their own OIDC provider and credentials via the runtime environment. This is consistent with the Core/Core Ops boundary established in ADR 0001.

### User persistence

The app maintains a `users` table with the following shape:

- `id` — UUID primary key
- `email` — from the OIDC `email` claim
- `name` — from the OIDC `name` claim
- `oidc_sub` — the OIDC `sub` claim (stable provider-assigned identifier)
- timestamps

On successful authentication, the app performs a **find-or-create** against `oidc_sub`. This means:

- first login creates the user record
- subsequent logins update the session without duplicating the record
- the user record is the application's source of truth; the OIDC provider is trusted only for identity assertion

### Auth flow

```
User → /auth/login
         ↓
     Build OIDC authorize URL (assent)
     Store state/verifier in session
         ↓
     Redirect to OIDC provider
         ↓
     User authenticates at provider
         ↓
     Provider redirects to /auth/oidc/callback
         ↓
     Validate state
     Exchange code for tokens (assent)
     Extract claims from ID token
     Find or create user in DB
     Set :current_user_id in session
         ↓
     Redirect to /
```

### Logout flow

```
User → /auth/logout
         ↓
     Read ID token from session
     Clear application session
         ↓
     Redirect to provider end-session endpoint
     (with id_token_hint and post_logout_redirect_uri)
         ↓
     Provider ends SSO session
     Provider redirects back to app
```

Clearing only the application session without redirecting to the provider end-session endpoint would leave the SSO session active. The user would be silently re-authenticated on next visit. Full logout requires both.

### Route protection

A `RequireAuth` plug sits in front of protected routes:

- checks `:current_user_id` in the plug session
- if present: loads the user from DB, assigns to `conn.assigns.current_user`
- if absent: redirects to `/auth/login` and halts

LiveView mounts should additionally verify `current_user` in `on_mount` to protect socket connections.

### Phased rollout

**Phase 1 (infrastructure layer):** Deploy behind infrastructure-level auth as a protective guard. The app does not yet own auth; the infrastructure layer rejects unauthenticated requests before they reach the app.

**Phase 2 (app-level OIDC):** Wire the OIDC flow, Accounts context, and RequireAuth plug. Once verified in production, remove the infrastructure-level auth guard so the app is the single auth authority.

This phasing allows the app to be deployed and tested before auth is fully implemented, without exposing it publicly.

## Consequences

### Positive

- no password storage or credential management in the app
- any OIDC-compliant provider works without code changes
- user records are owned by the app and can carry app-specific attributes
- session and logout are fully under app control
- env-var configuration keeps the public repo free of operator specifics
- consistent with the Core/Core Ops boundary model

### Tradeoffs

- requires an OIDC provider to be running and accessible at deploy time
- first-login latency includes a DB write
- logout requires a round-trip to the provider's end-session endpoint

### Guardrails

To preserve this decision:

- do not hardcode any OIDC provider URLs, client IDs, or secrets in the Core repo
- do not bypass the `RequireAuth` plug for authenticated surfaces without an explicit reason
- do not store the full ID token in the database — the `oidc_sub` claim is sufficient for identity linkage
- do not add provider-specific logic to the auth controller — keep it generic via assent configuration
- do not remove infrastructure-level auth before app-level OIDC is verified in production

## Follow-up

Near-term follow-up work should:

1. implement the Accounts context with the User schema and migration
2. implement the AuthController with login, callback, and logout actions
3. implement the RequireAuth plug
4. add LiveView `on_mount` auth verification
5. verify the full login and logout cycle in production
6. remove the infrastructure-level auth guard once app-level auth is confirmed stable
