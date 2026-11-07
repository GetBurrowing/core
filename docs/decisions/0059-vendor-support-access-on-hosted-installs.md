# ADR 0059: Vendor Support Access on Hosted Installs

- **Status:** Proposed
- **Date:** 2026-11-06
- **Owners:** Team
- **Task:** 01a1b362-6ef5-7000-9bdd-cbe40bf2378c (stage 1 of 4: core; stage 2 the owner's Support
  card; stage 3 the installer and host files; stage 4 the vendor's support system)
- **Amends:** [ADR 0056](0056-supporting-customer-installs.md) for installs whose owner has vendor
  support access on. 0056 is not edited.
- **Related:** [ADR 0053](0053-install-manifest-and-renderers.md), [ADR 0054](0054-install-to-install-federation.md)

## Context

A hosted install is one the vendor provisions for a customer. When it breaks, vendor support has
no supported way in. ADR 0056 designs a narrow, consented support channel (federation tools, a
diagnostics bundle, a host-side doctor) and rejects vendor SSH outright. None of 0056's slices
has shipped: on origin/main `913287c6`, `git grep support_inbound|support_diagnostics -- apps`
returns nothing, and tasks 01a11722 and 01a11723-* are in the backlog.

This ADR records a deliberate departure for hosted installs: while the install owner has a switch
on, vendor support may open a time-boxed admin session in the app, or a time-boxed root shell on
the host. While the switch is off, neither is possible, and the mechanism that makes that true
runs on the install, not at the vendor.

**Not experimentable.** This is a security and consent control (who may enter a customer's
install, and whether the owner can stop it), not a tunable outcome. There is no variant population
to measure, and an A/B test on whether a vendor can get in would itself break the disclosure
promise.

## Decision

### 1. The switch

`install_support_access_settings` is a singleton (one row, a DB CHECK plus a unique index, the
`install_link_unfurl_settings` shape) with `enabled`, `updated_by_user_id` and `updated_at`.
`Platform.SupportAccess.Settings.get/0` reads it fresh; `update/2` re-checks
`Platform.Access.authorize_install/1` and refuses a vendor support user even while it holds admin,
because the switch is the owner's.

**Defaults.** The migration seeds `enabled` from the environment variable
`SUPPORT_ACCESS_DEFAULT`: exactly `on` seeds true; any other value, or none, seeds false. Nothing
in code defaults it on.

- The installer renders `on` for **new hosted installs** (stage 3), so they start on.
- An **existing install** that later receives this code starts **off** until its owner turns it
  on. This is a recommendation awaiting a human decision (Open questions).

Every toggle writes `support.access_changed` (actor, from, to).

### 2. Off means off, on the install

- **Admin path:** the grant endpoint refuses with 403 `support_access_off`.
- **Existing admin sessions** end in the same transaction as the toggle-off. The browser checks
  (`PlatformWeb.LiveAuth.on_mount`, every `handle_event`, a timer at `not_after`, and the
  `:require_auth` / `:require_auth_api` plugs) treat a vendor support user as signed out unless
  its support session is active, on every mount and request, not only at sign-in. Ended sessions'
  sockets are disconnected by a broadcast on their `live_socket_id`.
- **Repair path:** refused at the host's sshd by stage 3's principals command, which reads the
  state file (section 6). The toggle-off rewrites it to `enabled: false` with no repair sessions
  before `Settings.update/2` returns.
- The vendor's support system hiding its buttons is cosmetic. It is **not** the control.

### 3. Grant requests

`POST /api/support-access/v1/grants`, host-agnostic and sessionless (server to server). The body
is canonical JSON, signed as raw bytes:

```json
{"install_id": "...", "kind": "admin" | "repair",
 "operator": {"name": "...", "email": "..."},
 "duration_s": 3600, "nonce": "...",
 "issued_at": 1794000000, "expires_at": 1794000120, "kid": "..."}
```

`issued_at` and `expires_at` are unix seconds. The header `x-burrow-support-signature` carries the
base64url Ed25519 signature over `"burrow-support-grant/1\n"` plus the raw body, verified against
the public key `kid` names in `SUPPORT_VENDOR_KEYS`. The shape follows
`Platform.Federation.Peers.Envelope.verify/3`.

Refusals, in order, each with its own reason and status:

| # | Condition | Reason | Status |
|---|---|---|---|
| 1 | no vendor key configured | (route absent) | 404 |
| 2 | bad signature or unknown kid | `bad_signature` | 401 |
| 3 | `install_id` is not this install's `INSTALL_ID` | `wrong_install` | 421 |
| 4 | `expires_at` past, or more than 300 s after `issued_at` | `grant_expired` | 410 |
| 5 | nonce already used | `replayed_nonce` | 409 |
| 6 | `duration_s` over 14400 (4 h, in config) | `duration_too_long` | 422 |
| 7 | switch off | `support_access_off` | 403 |

A validly signed body that is not a grant is `malformed_grant` (400). Used nonces are persisted in
`support_grant_nonces` until the grant's `expires_at`, so a replay is refused across restarts.

Every validly signed request, granted or refused, writes `support.grant_requested` and then
`support.grant_issued` or `support.grant_refused` (with the reason). Requests that fail the
signature are only logged and rate-limited per client IP; they are not audited, so unsigned junk
cannot fill the audit log.

### 4. Admin sessions

An admin grant inserts a `support_sessions` row (UUIDv7 id, kind, operator name and email,
`not_before`, `not_after`, `ended_at`, `end_reason`), finds or creates **one** support user per
operator email (`users.support_vendor = true`; unarchived if it was archived; a real user who
already holds that email is never taken over), and gives it the install admin role for this
session only. It mints a single-use sign-in code (32 random bytes, stored only as a sha256 hash,
valid 60 s) and returns `{session_id, sign_in_url, not_after}`, where the URL is
`https://<primary host>/auth/support?code=...`.

`GET /auth/support` redeems the code as `AuthController.app_handoff/2` redeems a handoff code:
it renews the session and writes `:current_user_id`, `:support_session_id` and the
`live_socket_id`. Every refusal looks identical. Support users are excluded from
`Accounts.install_admins/0`, so a support user is never the install owner.

### 5. Ending sessions

A session ends when it passes `not_after` (`expired`), when the owner ends it (`ended_by_owner`,
`SupportAccess.end_session/2`, stage 2's button), or when the switch goes off
(`access_turned_off`). Ending sets `ended_at` and `end_reason`, revokes the admin role, archives
the support user (`support_session_ended`) unless another of its admin sessions is still active,
disconnects the session's sockets, and writes `support.session_ended`. A supervised sweeper
(`Process.send_after` ticks, every 60 s; core has no Oban) ends expired sessions, rewrites the
state file, ingests shell events and prunes nonces and codes. A browser that stays connected does
not outlive `not_after`: the LiveView hook checks on every event and on a timer, independently of
the sweeper.

### 6. Repair sessions and the host state file

A repair grant inserts a `support_sessions` row of kind `repair` and returns
`{session_id, principal: "support-" <> INSTALL_ID, not_after}`, which the vendor's support system
puts into the operator's short-lived SSH certificate.

Core rewrites the JSON at `SUPPORT_ACCESS_STATE_PATH` (default
`/var/lib/burrow-support/state.json`, bind-mounted from the host by stage 3) atomically (write a
temp file, then rename) on every toggle, grant, end and sweep:

```json
{"version": 1, "enabled": true, "principal": "support-<INSTALL_ID>",
 "repair_sessions": [{"id": "...", "not_after": "2026-11-07T01:00:00Z"}]}
```

It holds no secret. `repair_sessions` lists only active sessions and is empty while the switch is
off. If a write fails, the toggle-off still commits, the error is kept on the settings row for the
owner's Support card (`state_file_error`) rather than reported as success, and the sweeper retries
every tick. Stage 3's host script fails closed: it checks each session's `not_after` itself, so a
stale `enabled: true` cannot extend a session, and it refuses on a missing or unparsable file.

### 7. What a repair session is

**A repair session is root on the host.** It can read every file core can, including the Vault
master key, agent env files and login state, and it can change core's code, its database and its
audit log. Nothing in this ADR narrows that. The owner's protections are the switch, the 4 h cap,
the record below, and ending the session.

### 8. Audit

Every support row goes through `Platform.SupportAccess.audit/2` into the append-only
`audit_events` table: the grant rows above, `support.access_changed`, `support.session_ended`,
and:

- **Shell events.** Core tails the host-written JSONL at `SUPPORT_SHELL_EVENTS_PATH` (default
  `/var/lib/burrow-support/events.jsonl`, written by stage 3's wrapper; one line per event,
  `{"event": "shell_opened" | "shell_command" | "shell_closed", "session_id", "command", "ts"}`)
  and writes `support.shell_opened`, `support.shell_command` (command text truncated to 500
  characters) and `support.shell_closed`, each with the session id. The read offset is persisted.
  A line whose session id is unknown is recorded as `support.shell_unmatched`, without its
  content.
- **Admin actions.** A plug and a LiveView hook write `support.action` for every non-GET request
  and every `handle_event` a support user makes: route or LiveView module, event name, and the
  sha256 of the params. Never the param values, never a response body.

No audit row or log line carries a sign-in code, a sign-in URL or key material.

**The audit is tamper-evident, not tamper-proof against root.** `support.*` rows are hash-chained
(`metadata.chain`: the previous row's digest and this row's digest), and
`SupportAccess.verify_audit_chain/0` re-walks the chain, so an edited or deleted row is evident to
anyone who kept an earlier chain head. A repair session is root: it can rewrite the whole chain,
and it can edit the shell event file before core reads it. The shell record is what the host
reported, not proof of what ran. Detection of a full rewrite needs a chain head kept off the host
(stage 4 may record it with each grant); this ADR does not provide one.

### 9. Key custody

- **Support grant-signing key** (Ed25519). The private half is held **only** by the vendor's
  support system, in its production secret store (stage 4 names the exact store). The install holds
  only public halves, in `SUPPORT_VENDOR_KEYS` (`kid:base64` pairs, more than one allowed), which
  the installer renders from the manifest (stage 3).
- **Rotation:** the vendor's support system adds a new kid, renders it alongside the old one, and
  removes the old kid once every install has re-rendered.
- **Repair access** uses short-lived SSH certificates issued by the vendor's support system to the
  operator's own key; the install trusts only the CA's public key (stage 3, stage 4). Operators keep
  their own SSH private keys.
- Core generates no production key. Tests generate throwaway keypairs in process. No key, code or
  sign-in URL is committed, logged or posted in chat.

The display name in copy comes from `SUPPORT_VENDOR_NAME`, rendered by the vendor's support system.
Core code, tests and copy say "vendor support" and never spell the vendor's name (the install
identity guard enforces this).

### 10. What this changes in ADR 0056

- **Supersedes, only while the switch is on:** 0056's "Considered and rejected: SSH or VPN access
  for the vendor" and C.5 ("the vendor places no SSH key in cloud-init"). While the switch is on, a
  repair session is a sanctioned vendor shell, and stage 3 places the vendor's SSH user CA public
  key on the host. While it is off, 0056's position holds: the principals command admits no vendor
  certificate.
- **Unchanged:** B.1, telemetry and heartbeat stay opt-in. This ADR adds no telemetry.
- **Not decided here:** C.4 ("support never performs a Claude login"). Whether a repair session,
  which as root can reach the login flow, may be used during a customer's Claude login is an open
  human decision (below). This ADR builds no Claude-login tooling.
- 0056's federation support relationship, diagnostics bundle, doctor and rescue page are
  unaffected and still to be built (tasks 01a11722, 01a11723-*).

## Open questions (human decisions; not gates)

1. **On by default for new hosted installs.** The product owner confirms this. It changes the "your data, your
   server" model: a new hosted customer's install admits vendor support until the owner turns it
   off.
2. **Existing installs.** The product owner decides whether an existing install that receives this code
   defaults off (this plan's recommendation, and what the migration does unless
   `SUPPORT_ACCESS_DEFAULT=on` is rendered) or on.
3. **Disclosure wording.** The owner-facing wording on the Support card (stage 2) is checked
   against the customer terms.
4. **Claude login during a repair session.** Whether a repair session may be used while a
   customer is performing a Claude login, given 0056 C.4.

## Consequences

- A hosted customer can be helped when the app is down (repair) or misconfigured (admin), within
  four hours per session and only while the owner allows it.
- The owner's switch is enforced on the install three ways (grant endpoint, per-request session
  checks, host state file), so a compromised or careless vendor system cannot reach an install whose
  owner has turned support off.
- A repair session is a full root shell. The record of it is tamper-evident only up to root; an
  owner who cannot accept that keeps the switch off.
- `INSTALL_ID` is a new environment variable core reads; stage 3 renders it.
