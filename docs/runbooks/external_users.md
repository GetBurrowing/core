# External Users (scoped chat guests)

How an operator brings a **scoped external user** online — the SXI tenant
is the first — and how an admin recovers, and later offboards, one.

## Context

An external user is a **real OIDC account in Pocket-ID**, not a Burrow-native
login and not a magic-link guest. Their surface is deliberately narrow: the
chat module only, scoped to an allowlist of spaces plus a per-org DM
allowlist. Everything else in Burrow is off-limits, and that scoping is
enforced per-surface (see [What's enforced](#whats-enforced-pointer-to-the-security-suite)).

The load-bearing invariant, honoring
[ADR-0004](../decisions/0004-authentication-strategy.md): **Burrow makes
ZERO outbound calls to Pocket-ID.** Burrow is a pure OIDC *token consumer* —
it reads the external group claim on login and nothing else. No account is
created, mutated, or queried in the IdP by Burrow. ADR-0004 is honored with
no amendment.

The `chat.` external surface ships **dark**: the router carries the host-match
code but no infrastructure declares a `chat.` host until the subdomain
go-live, a separate deferred operator step (see
[Go-live](#go-live-turning-the-chat-subdomain-on)). Until then the flow below
still works on the default host — `/welcome` and the admin queue are not
host-constrained.

## Prereqs

- Admin access to the **Pocket-ID** admin UI (to create the account and stamp
  the external group).
- Burrow admin access (to pre-stage the grant and to use the recovery queue at
  `/admin/external-logins`).
- The value of `OIDC_EXTERNAL_GROUP` for this deployment — the Pocket-ID group
  whose members Burrow treats as external. Default: `"sxi-external"`.
  - Config default lives in `apps/platform/config/config.exs`
    (`external_group: "sxi-external"`); prod threads it via
    `OIDC_EXTERNAL_GROUP` in `apps/platform/config/runtime.exs`.
- The `target_org`, the space IDs the user may see, and the org IDs whose
  members they may DM.

---

## Stage 1 — Onboarding

### 1. Provision the account in Pocket-ID (external, ADR-0004)

Create the account **in Pocket-ID** — through the admin UI or a signup-token
link — and stamp the external **group claim** on it (the group whose value
matches `OIDC_EXTERNAL_GROUP`, default `"sxi-external"`).

This is the only step performed against the IdP, and Burrow is not involved in
it. **Burrow makes ZERO outbound calls to Pocket-ID.** On login, Burrow reads
the group claim exactly once via `Platform.OIDC.external_claim?/1` (which
compares the login's groups against `OIDC.external_group/0`) and decides
admission from that. There is no code path in the auth stack that calls back
out to Pocket-ID, pushes data to it, or provisions anything there.

### 2. Pre-stage the grant (Burrow-side state only)

Before — or independently of — the user's first login, pre-stage a
`pending_external_grant` row so admission has something to apply. This is
Burrow-side state; it never touches Pocket-ID.

Create it via `Platform.Tenancy.ExternalGrants.create_grant/1`
(`apps/platform/lib/platform/tenancy/external_grants.ex`). The grant
(`Platform.Tenancy.PendingExternalGrant`,
`apps/platform/lib/platform/tenancy/pending_external_grant.ex`) is:

- **Keyed on `email` OR `oidc_sub`** — at least one must be present; on login
  it matches whichever identity the OIDC claim carries.
- **`target_org_id`** — required; the org the external user is admitted into
  (`belongs_to :target_org`).
- **`space_grants`** — a list of `%{"space_id" => ..., "role" => ...}` maps;
  each becomes a `chat_participants` row on apply (the channels the user may
  see).
- **`dm_allowlist_org_ids`** — a list of org-id strings; each seeds a per-org
  DM allowlist entry on apply (the org(s) whose members the user may DM).

```elixir
Platform.Tenancy.ExternalGrants.create_grant(%{
  email: "guest@sxi.example",
  target_org_id: sxi_org_id,
  space_grants: [%{"space_id" => shared_space_id, "role" => "member"}],
  dm_allowlist_org_ids: [our_org_id]
})
```

An unapplied grant is stamped with `applied_at` once consumed, so it applies
at most once (idempotent).

### 3. What happens on first login

On every OIDC login the admission policy provisions optimistically
(`Platform.Accounts.ExternalAdmission.admit/2`,
`apps/platform/lib/platform/accounts/external_admission.ex`):

1. The auth controller reads `OIDC.external_claim?/1` and hands `admit/2` the
   login plus the `external_claim?` flag.
2. `admit/2` resolves the user via `Accounts.find_or_create_from_oidc/1`, then
   looks up the matching `pending_external_grant`.

Two operator-visible outcomes:

- **Full grant** — a matching grant exists: its `space_grants` and
  `dm_allowlist_org_ids` are applied and the user lands in chat with their
  scoped space list (`Result` state `:full`).
- **Holding** — the login is flagged external (`external_claim?`) but no grant
  is staged yet: admission establishes **zero scoped rows** and parks the user
  on the `/welcome` holding landing (`Result` state `:holding`, reason
  `:awaiting_grant`). This is **never a hard refuse** — the user waits, and an
  admin can grant them live (Stage 2).

## Verification

- **Full grant:** the user reaches their scoped space list in chat and can DM
  only members of the allowlisted org(s).
- **Shortfall:** the user reaches `/welcome` (the zero-access holding page,
  `ExternalHoldingLive`) and sees no spaces — confirming fail-closed scoping.
- **No outbound IdP call:** confirm by inspection — there is no Pocket-ID
  client call in the auth path; admission reads the claim and consults only
  Burrow-side state (`ExternalGrants` / `pending_external_grants`).

---

## Stage 2 — Admin operations & recovery

### The recovery queue at `/admin/external-logins`

The admin-only route `/admin/external-logins`
(`ExternalRecoveryLive`, in the `:admin` `live_session` behind the
`:ensure_admin` gate — an external user cannot reach it) lists external logins
and their grant status, including the holding shortfalls the admin
notification flagged.

Its **one-click Grant** action calls
`Platform.Accounts.ExternalAdmission.recover/3`. Recovery **live-applies to the
waiting session over a LiveView push — no re-login required**: it never calls
back into `find_or_create_from_oidc/1`, so an operator can walk a first-time
user through it in real time and watch their spaces appear.

### Admin notification

Admins do not have to poll the queue. When a login hits the holding shortfall,
`Platform.Accounts.ExternalAdmissionNotifier` consumes the admission telemetry
and (a) broadcasts the new row so any open recovery surface live-appends it and
increments its badge, and (b) push-notifies root-org admins via the existing
`Notifications.fan_out_to_humans/3` seam, naming the waiting email + reason and
linking to `/admin/external-logins`.

### Unknown logins are fail-closed, not a hole

A truly-unknown login — a valid Pocket-ID account with no `sxi-external`
intent — gets the **same** zero-access holding state (reason `:missing_claim`)
and is just a row in the recovery queue to **ignore**. The security property
(no grant → no scoped access) is achieved by the holding state, not by a hard
refuse: there is nothing to leak because zero scoped rows were established.

### What's enforced (pointer to the security suite)

That a scoped external user cannot reach off-limits content is guaranteed by
the adversarial security suite under `apps/platform/test/security/` — one case
per surface: presence/typing, search/memory (historian), DM scope, federation
MCP, signed-file/attachment URLs, push previews, and the cross-surface
`external_user_scope_test.exs`. Treat that suite as the source of truth for
per-surface leakage; recovery and grant work never needs to re-reason about
leakage surface-by-surface. See
`apps/platform/test/security/external_user_scope_test.exs`.

---

## Stage 3 — Offboarding & go-live

### Offboarding (reuse the existing archival flow — nothing new to build)

Revoking an external user is the **existing user-archival flow**, not anything
built for external users. Set `users.archived_at` via `/admin/users`
(`UserAccessLive` already exposes archive/unarchive). After that, the OIDC
login seam refuses the account: `Platform.Accounts.find_or_create_from_oidc/1`
returns `{:error, :user_archived}`, which propagates straight through admission
to the auth controller.

There is nothing new to build or configure for offboarding. The grant simply
stops applying because the account can no longer log in. (Un-archiving via the
same UI restores login, and the grant applies again on next login.)

### Go-live: turning the `chat.` subdomain on (separate, deferred)

The `chat.` host-match code ships **inert/dark** — the router defines the
`chat.` host scope, but no infrastructure declares that host yet. Actually
turning on `chat.example.com` (DNS + Cloudflare/edge routing + TLS
cert, pointing the host at the app) is **operator infrastructure for a specific
deployment, NOT a repo change**, and was **deferred out of this stack** (it was
the router/subdomain member). Do **not** perform it as part of this change.

When the subdomain is flipped on later, follow the analogous shape already
documented for the guest-meeting host in
[`docs/features/guest-meetings.md`](../features/guest-meetings.md) — the `meet.`
DNS / TLS / reverse-proxy pattern is the template for the `chat.` host. Treat
this as a future go-live checklist item, not a step to perform now.
