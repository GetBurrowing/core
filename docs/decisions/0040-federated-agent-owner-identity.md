# ADR 0040: Federated Agent Owner Identity

**Status:** Proposed (revised after architect + security review 2026-05-01 — see "Amendments")
**Date:** 2026-05-01 (initial); 2026-05-01 (revised post-review)
**Deciders:** Marlowe (drafting + revised path); Rowan + org-admin + legal review needed before "Accepted" — specifically D4 GDPR classification and the disclosure-flow threat model
**Related:** BACKLOG #18 (this work item), BACKLOG #9 (privacy leak that surfaced the gap), BACKLOG #17 (thinking-stream PubSub split — depends on this), ADR 0034 (MCP endpoint + capability bundles), ADR 0038 (membership author snapshots — precedent for owner snapshotting)

---

## Amendments (post architect + security review, 2026-05-01)

This ADR was reviewed by independent architect and security agents on the day of authoring. Both blocked Stage 1 as originally written. The amendments below are the synthesized recommended path. The original deliberation that follows is preserved as decision history; **read this section as the current source of truth where it conflicts with what's below**.

### Schema-shape amendments (Stage 1 scope expanded)

1. **Idempotency key must include `invoked_by_user_id`.** `runtime_events.idempotency_key` is currently globally unique with key shape `"#{runtime_id}:#{task_id}:#{phase}:#{event_type}:#{timestamp}"` (`runtime_supervision.ex:165-168`). Once owner identity starts being populated under multi-user-per-runtime federation, two users invoking the same `(runtime, task, phase)` at the same microsecond collapse to one row — a correctness bug. **Fix at Stage 1**, before owner columns are populated: extend the key generator in `normalize_attrs/1` to mix in `invoked_by_user_id` (or NULL-safe sentinel). One-line change; tests required.

2. **Audit-events strategy is NOT dual-key replication.** `audit_events` already models actor identity via `actor_id` + `actor_type` (per `20260314060000_create_audit_events.exs:8-9`). Stage 1 **extends `actor_type` enum** to add `"federated_user"` and adds a single `actor_org_id` column. Do *not* add `invoked_by_user_id` + `owner_org_id` to `audit_events` — that duplicates the existing actor model. Each table uses its existing actor pattern; the dual-key columns live on `runtime_events` and `execution_leases` only.

3. **`owner_attribution_status` enum in initial migration.** Add to `runtime_events` and `execution_leases` alongside the owner columns. Values: `legacy_pre_migration`, `attributed`, `attribution_failed`, `pseudonymous`. Populated at write time. Removes the auditor footgun of "NULL means either pre-migration or post-migration bug." Cheap; observability win for Stage 2's NOT NULL transition.

4. **Reserve `invocation_visibility_grants` table at Stage 1.** Empty schema, no callers. Sets the slot for delegation grants (the deferred D2 sub-question on cross-org delegated visibility). Without reservation, Stage 2's visibility filter has to be re-architected when delegation lands; with reservation, the filter shape is `WHERE (user_id, org_id) = subscriber OR EXISTS (visibility_grant)` from day one, even if the grants table is always empty in Stage 1.

### `OwnerHandle` module signature change (D4)

Original: `OwnerHandle.for(user_id, peer_org_id, server_secret)`.

**Revised: `OwnerHandle.for(user_id, user_salt, peer_org_id, key_version)`.**

Rationale (security finding D4-1, D4-2):
- **Per-user salt** stored alongside the user record. Defends against enumeration if `server_secret` leaks (UUIDv7 timestamp-prefix narrows the search space; without a salt, an attacker with the secret can recompute every user's handle for every peer). Salt rotation = handle revocation, achievable per-user without breaking the global system.
- **Versioned secret** (`server_secret_v1`, `server_secret_v2`). Each handle records `key_version`; rotation re-issues handles with the new version; old handles continue to verify until expiry. Without versioning, secret leak = total compromise of all historic and future handles.
- **HMAC** primitive: `HMAC(key=server_secret_v<n>, msg=user_salt || peer_org_id)`. Constant-time comparison required for verification.

This signature must ship in Stage 1 module — the cryptographic contract bakes itself into tests, callers, and reviewer mental models, so retrofitting in Stage 3 is high-cost. The Stage 1 module ships unused; correctness of the contract matters now.

### D1 framing change

Drop the "forward-compatible from dual-key to single-key" claim. Dual-key is a **permanent decision**. Real precedent: OAuth 2.0 `(client_id, user_id)` on access tokens; Stripe Connect `(account, customer)`; Matrix federation `(server, user)` MXIDs. None tried to collapse to single-key.

The actual reason to denormalize `owner_org_id` even when it's derivable from `runtime_id → runtime → org`: **survivability under runtime deletion.** Runtimes get retired; the owner-org attribution must survive that. Add this to the rationale.

### D2 substantive revision

The original rights table had two assignments wrong and three rights missing.

**Revised rights table:**

| Right | Recommended | Rationale |
|---|---|---|
| **Visibility of own invocation's thinking stream** | Invoking user (scoped by tuple `(user, org)` per security D1-1) | BACKLOG #9 privacy fix |
| **Read agent configuration** (system prompt, allowed tools) | **Invoking user** (NEW — was missing) | Consent. Users sending data to a black box is unacceptable. |
| **Write agent configuration** (definition-level: prompts, tool list) | Hosting org | The agent definition is the org's; configuration affects all the org's invocations |
| **Set invocation-time parameters** (temperature, tool subset toggles) | Invoking user (NEW row — was conflated with config) | Per-call params are user-scoped; precedent in `chat_participants.attention_config` |
| **Audit log readability — operational metadata** (timing, runtime_id, event_type, success/failure, byte counts) | Both | Operational accountability |
| **Audit log readability — content payload** (args, descriptions, free text in `runtime_events.payload`) | **Invoking user's org only** (was "both" — privacy footgun) | `runtime_events.payload :map` is freeform and contains user-supplied content per `tool_surface.ex:2361-2366`. "Both" leaks user prompts to hosting org. Schema split: separate `runtime_events_metadata` columns vs `runtime_events_content` row, or inline split with row-level filtering at read time. |
| **Billing attribution** | Invoking user | Track which @-mention triggered which cost |
| **Rate limiting** | Hosting org (per-runtime, per-`owner_org_id` for federation peers) AND per-`(user, org)` pair-wise | Pair-wise rate limits are the actually useful unit for cross-org abuse |
| **Revocation — in-flight kill** (NEW row, was ambiguous) | Hosting org any-time; invoking user can kill **their own** in-flight invocation with bounded SLA (≤5s) | "Graceful UX cancel" was insufficient — agent reading sensitive doc must be killable mid-stream |
| **Revocation — post-fact** | Hosting org any; invoking user own | Unchanged from original |
| **Cross-org peering / federation enable-disable** | Hosting org | Unchanged |
| **Delete invocation history** (NEW — GDPR Art 17) | Invoking user (own); hosting org (operational) | Required by GDPR. Stage 3 includes cross-org deletion propagation protocol. |
| **Claim an unowned (legacy NULL) invocation** (NEW) | Default deny | Pre-migration rows are anonymous forever. Status enum makes this explicit. |
| **Share / transfer invocation visibility** to a third party (NEW) | Default deny; explicit grant via `invocation_visibility_grants` table | Reserves the schema slot. Filter shape accommodates from day one. |
| **Sanitized vs raw error visibility** (NEW per security D2-5) | Invoking user sees sanitized; hosting org sees raw | Stack traces leak hostnames, file paths, code excerpts. Default to sanitized cross-org. |

### D3 strengthening

- Acknowledge: `tasks.created_by_user_id` does NOT exist (only `reported_by :string` and `assignee_id`). Best-effort backfill via `tasks` join is more lossy than the original draft claimed. NULL-for-existing is the only viable option.
- **Soak-exit criterion explicit:** transition to NOT NULL (or check constraint) only when `runtime_event_owner_unknown` breadcrumb count drops below 5/day for 7 consecutive days in production.
- **Note: only one writer to `runtime_events` was identified** (`runtime_supervision.ex:48` via `RuntimeEvent.changeset`). The Risk #2 hidden-direct-Repo.insert mitigation is largely already true; document this affirmatively.
- Use **check constraint** at Stage 2, not NOT NULL, so partial rollback is possible.

### D4 additional clarifications

- **Federation handshake is currently device-keyed, not user-keyed** (`node_identity.ex:38-41`). Threading `OwnerHandle` through federation requires a protocol bump — extending the `node.invoke.request` payload schema to carry the handle. Stage 3 work, but document the protocol-bump implication explicitly so Stage 3 isn't surprised.
- **Right-to-be-forgotten:** salt rotation = handle revocation. When a user requests deletion, the originating org rotates that user's salt; existing peer-stored handles become unverifiable. **This is technical, not just legal.** Per-user salt is what makes RTBF mechanically achievable.
- **Cross-peer collusion is a known limitation, not a defense-in-depth gap.** Document explicitly: pseudonymization protects against passive peers, not active collusion. Active anti-correlation requires batching, traffic shaping, or contractual non-collusion — out of scope for this ADR; tracked as a separate followup.
- **Disclosure flow (Stage 3) requires** cryptographic non-repudiation (user signs consent with session-tied key); two-party approval inside originating org (user + admin); per-(handle, requestor) one-shot semantics; mandatory user notification on every disclosure; per-handshake opt-out; rate-limit on disclosure requests per peer per time window. Bake these into the Stage 3 threat model before any code lands.

### Revised Stage 1 estimate

**~2 developer-days under TDD** (was 1 dev-day). The expansion is:
- New audit_events extension (actor_type enum + actor_org_id) — separate from runtime_events/execution_leases dual-key
- `owner_attribution_status` enum schema + tests
- `invocation_visibility_grants` empty table reservation
- `OwnerHandle` revised signature with salt + versioned secret + HMAC + property tests for stability/opaqueness/rotation
- Idempotency key change in `normalize_attrs/1` + tests covering multi-user-same-runtime collision
- D2 schema split (metadata vs content read-side filtering)

### Stage 2 prerequisites (governance-blocked, must resolve before Stage 2)

- **D2-1 audit content/metadata split** — formally accepted by Marlowe + Rowan
- **D1-1 untrusted-user-id-from-peer enforcement** — design and acceptance of mint-by-originating-org constraint
- **D2 in-flight kill SLA** — operational signoff on ≤5s kill propagation requirement
- **Federation peer authentication primitive cited** — the trust root for everything in this ADR; if `node_identity.ex` Ed25519 device key isn't sufficient, that's a hard prerequisite

### Stage 3 prerequisites (governance + legal-blocked)

- **D4-5 GDPR classification of pseudonymous handle** — legal review
- **Disclosure flow threat model** (above) — written, reviewed, signed off before any disclosure code lands
- **Cross-org deletion propagation protocol** — design and federation handshake bump

---

## Context

Federated agent invocations today are scoped entirely by `space_id`. There is no field on `runtime_events`, `execution_leases`, or any tool-call audit row that identifies *which user* owns a given invocation. BACKLOG #9 surfaced this when investigating a thinking-stream privacy leak: with no owner identifier, federated invocations can leak reasoning across organizational boundaries because the visibility filter has nothing to filter *by*.

The runtime_events schema (`apps/platform/priv/repo/migrations/20260325013000_create_execution_leases_and_runtime_events.exs`):

```
runtime_events:
  id, task_id, lease_id, phase, runtime_id, event_type,
  occurred_at, idempotency_key, payload
```

```
execution_leases:
  id, task_id, phase, runtime_id, runtime_worker_ref,
  status, started_at, last_heartbeat_at, last_progress_at,
  expires_at, block_reason, metadata
```

Neither carries a `user_id` field. `Platform.Federation.ToolSurface` (`apps/platform/lib/platform/federation/tool_surface.ex`) exposes a unified tool surface to federated runtimes; tool calls today land in audit/event rows attributed to the `runtime_id` only.

This is fine when "runtime" and "user" map 1:1 (a single user driving a single runtime). It breaks for federation, where:

- A runtime can be hosted by **another organization** entirely
- A single hosted runtime can serve invocations from **multiple users** across orgs
- A single user can invoke through **multiple runtimes** (e.g., a Claude Code session and a hosted agent)

Without owner identity, three concrete failure modes are open:

1. **Privacy across the federation boundary** — federated invocations risk leaking thinking back across org boundaries (BACKLOG #9, second bullet).
2. **Audit accountability** — owner-visible audit log of thinking is desirable even when it's not surfaced to space participants. Without owner identifiers, "who triggered this" is unanswerable post-hoc.
3. **Cross-org abuse** — without an owner, no clear party to apply rate limits or revoke against. Any abuse mitigation today is at the runtime granularity, which is too coarse.

This ADR proposes the schema + plumbing changes to thread owner identity through federated invocations. It also surfaces the governance questions that must be resolved before scoping work (BACKLOG #17 thinking-stream split, BACKLOG #18 visibility filtering) can land.

---

## Open decisions (governance — resolve before "Accepted")

These questions cannot be answered from the codebase alone. They are product / governance / legal calls. Each is named here with options and a recommended default; the recommended default is what the **non-blocking technical groundwork** in this ADR assumes, with the understanding that decisions can be flipped before enforcement code lands.

### D1. Who is the owner of a federated invocation?

**Options:**

- **(a) Invoking user only.** The user who @-mentioned the agent (or otherwise initiated the invocation) is the sole owner.
- **(b) Hosting org only.** The org that operates the runtime is the sole owner. Users who invoke have access governed by their org membership.
- **(c) Both (dual-key).** Invocation is owned jointly: the invoking user gets visibility / configuration / billing-attribution rights; the hosting org gets operational accountability (rate limits, abuse handling, federation peering).

**Recommended default: (c) dual-key.** Both pieces are load-bearing. Invoking user is who answers "did I ask for this," who pays attention to the result, who has billing-relevant claim. Hosting org is the only party that can revoke / rate-limit / handle abuse, and is the federation peer. Picking only one collapses to a worse design quickly: (a) makes cross-org abuse handling impossible because there's no operational party to talk to; (b) makes per-user privacy filtering impossible because we can't tell whose thinking is whose.

**Schema implication:** add **two** fields, `invoked_by_user_id` and `owner_org_id`. (a) and (b) collapse to one field each but are migratable to (c) later. (c) is forward-compatible.

### D2. What scope does ownership confer?

The literature on this question fragments into multiple sub-rights. Each can be granted to invoking-user, hosting-org, both, or neither.

| Right | Recommended | Rationale |
|---|---|---|
| **Visibility** of own invocation's thinking stream | Invoking user | This is the BACKLOG #9 privacy fix. The invoking user is the only participant in a federated invocation who has unambiguous claim to see what the agent reasoned about *for them*. |
| **Configuration** of agent (system prompts, allowed tools) | Hosting org | The runtime is the org's; configuration affects all the org's invocations, not just one user's. |
| **Billing attribution** | Invoking user | Track which user's @-mention triggered which invocation for cost-allocation / chargeback. |
| **Rate limiting** | Hosting org | Per-runtime rate limits are operational; per-user rate limits are billing/quota. Both should exist; abuse-mitigation rate limits live with the host. |
| **Audit log readability** | Both | Hosting org sees its runtime's full audit; invoking user sees their own invocations across runtimes (joined view). |
| **Revocation / kill** | Hosting org primary, invoking user secondary | The hosting org can kill any of its runtime's invocations. The invoking user can kill *their own* invocation (graceful UX cancel) but not anyone else's. |
| **Cross-org peering / federation enable-disable** | Hosting org | Out of scope for invoking users. |

**Open sub-question:** can a hosting org *delegate* "see thinking" rights for an invocation back to an invoking user from a *different* org? Today's BACKLOG #9 fix would say no by default; future federated workflows (e.g., a guest collaborator from another org running an agent in our space) might say yes via explicit consent. Defer; recommend default-deny with a note that a future ADR can refine.

### D3. How are existing invocations migrated?

Existing `runtime_events` and `execution_leases` rows have no owner data. Three options for backfill:

- **(a) Leave NULL.** Existing rows are owner-unknown forever. New rows always have owner. Cheap; loses some retroactive accountability.
- **(b) Best-effort backfill** by joining `runtime_events.task_id` → `tasks` table → infer owner from `tasks.created_by_user_id` or whatever field exists.
- **(c) Hard requirement.** Block deploy of the migration until backfill completes; fail any read that finds NULL owner.

**Recommended default: (a) NULL for existing, NOT NULL for new.** Best-effort backfill (b) is tempting but the join is lossy (federation-arrived invocations won't have a clean `tasks.created_by_user_id`), and partial backfill creates the worst of both worlds: looks accountable but isn't. (c) is operationally hostile — blocks deploys for backfill jobs that may take hours on production data. (a) draws a clear line between "before owner identity" and "after"; auditors can use the timestamp to know which records to trust for accountability claims.

### D4. How does cross-org invocation handle owner identity?

When user X in org A @-mentions agent Y hosted by org B, the invocation flows through federation to org B's runtime. Two options:

- **(a) Pass-through.** Org A sends `invoked_by_user_id=X, owner_org_id=A` to org B. Org B records both. User X's identity becomes known to org B.
- **(b) Pseudonymization.** Org A sends a stable opaque token to org B (e.g., `owner_user_handle="usr_abc123"` derivable per-org). Org B can rate-limit per-handle and audit per-handle but doesn't learn user X's real identity in org A.

**Recommended default: (b) pseudonymization at the federation boundary.** Real user IDs do not cross org boundaries by default. The handle is stable enough for rate-limiting and audit, opaque enough that org B doesn't learn the user's identity in org A. Real-identity disclosure (for billing reconciliation, abuse investigation) goes through a separate consent-gated flow.

**This is the question most likely to need legal review.** GDPR / CCPA implications around cross-border data identification.

---

## Decision (proposed pending governance review)

Adopt a **dual-key ownership model** for federated agent invocations:

- `invoked_by_user_id` — the user who initiated the invocation. References `users.id` when invocation is intra-org. Stores a **stable pseudonymous handle** when the invocation arrived via federation from another org (per D4).
- `owner_org_id` — the org operating the runtime that produced the events. References `orgs.id`.

Apply across the runtime / federation event surface:

1. Add columns to `runtime_events` and `execution_leases` (NULL for existing, NOT NULL for new — see D3).
2. Add columns to any tool-call audit rows (TBD — investigate during implementation).
3. Thread owner through `Platform.Federation.ToolSurface` so tool calls record both fields at write time.
4. Audit log enrichment: log lines that reference an actor now include both fields.
5. Visibility filtering — gate thinking-stream visibility by `invoked_by_user_id` (BACKLOG #17 / Option C work). **This is enforcement and is governance-blocked until D1 + D2 are accepted.**

Pseudonymization at the federation boundary is achieved by a server-side handle generator: `Platform.Federation.OwnerHandle.for(user_id, peer_org_id)` returns a stable token computed from `(user_id, peer_org_id, server_secret)`, deterministic per (user, peer-org) pair. The peer org gets the handle; the user's real id stays in the originating org.

---

## Implementation plan

### Stage 1 — Non-blocking technical groundwork (can ship before governance decision)

These changes are **additive** and **non-enforcing**. They prepare the ground without committing to any specific governance interpretation. Schema columns default to NULL; plumbing populates them when known and gracefully degrades when not. No existing code path is altered to *require* owner identity.

1. **Migration** — add `invoked_by_user_id :uuid, null: true` and `owner_org_id :uuid, null: true` to `runtime_events` and `execution_leases`. No FK constraints initially (avoid blocking on owner-row presence; FKs added in Stage 2 once enforcement starts). Indexes on both columns scoped to NOT NULL (`where: "invoked_by_user_id IS NOT NULL"`).
2. **Schema modules** — update `Platform.Orchestration.RuntimeEvent` and the corresponding ExecutionLease module to declare the new fields; changesets accept them.
3. **ToolSurface threading** — add an `:owner` keyword arg to the internal tool-call dispatch helpers in `tool_surface.ex`. When supplied, populate the owner fields on resulting event/audit rows. When omitted, leave NULL and log a single info-level breadcrumb (`runtime_event_owner_unknown`) to make the gap discoverable in production telemetry without flooding logs.
4. **Audit log enrichment plumbing** — wherever log lines reference an actor (greppable by `Logger.metadata([actor:` or similar), add `:owner_user` and `:owner_org` metadata keys when known. Existing log shape preserved when not known.
5. **OwnerHandle module** — `Platform.Federation.OwnerHandle.for(user_id, peer_org_id, server_secret)` deterministic handle generator. Stage 1 ships the module; nothing yet calls it. Includes property-based tests for: stability across calls, divergence across peer orgs, opaqueness (handle reveals nothing about user_id without the secret).
6. **Tests** — full TDD coverage of all of the above. Migration up/down. Changeset accept/reject. ToolSurface threading happy + missing-owner. Audit log enrichment when known. OwnerHandle property tests.

**Estimate:** 1 developer-day. Non-controversial because it changes nothing observable — preparation only.

**Deliverables:** one migration file, two schema edits, ToolSurface dispatch helper update, audit log metadata, OwnerHandle module, ~20-40 tests. Single PR; reviewable independently.

### Stage 2 — Enforcement plumbing (governance-gated, ships after D1+D2 accepted)

After D1 and D2 are decided, the actual enforcement lands:

1. **NOT NULL** the new columns on the migration (separate migration, runs after a soak window where new writes are confirmed populated).
2. **FK constraints** — `invoked_by_user_id` references the appropriate user surface (real `users.id` when intra-org, the OwnerHandle table when federated — schema TBD per D4).
3. **ToolSurface caller-required** — surfaces stop dispatching when owner is unknown and the call is over federation (intra-org legacy code paths can keep degrading gracefully during a transition window).
4. **Visibility filter** for thinking streams (BACKLOG #17 dependency). The `thinking:<space_id>` topic gets scoped by owner; subscribers receive only the events whose `invoked_by_user_id` matches their own user_id (or matches a delegated-access grant per D2 sub-question).
5. **Rate limit hooks** — per `owner_org_id` rate limits at the federation boundary; per `invoked_by_user_id` quota tracking.
6. **Audit log readability** — joined view exposing per-user audit across runtimes.

**Estimate:** 2-3 developer-days. Cannot start until D1+D2 are signed off.

### Stage 3 — Cross-org pseudonymization (governance-gated, ships after D4 accepted)

After D4 is decided:

1. Federation handshake passes pseudonymous handle when the originating user's org differs from the peer org.
2. Peer org records handle in `invoked_by_user_id`; flag `owner_handle_is_pseudonymous = true` on the row.
3. Real-identity disclosure flow (consent-gated, audit-logged) for the cases where billing reconciliation or abuse investigation requires it.

**Estimate:** 2-4 developer-days, gated on legal review of pseudonymization.

---

## Stage 1 file-by-file

| File | Change |
|---|---|
| `apps/platform/priv/repo/migrations/<timestamp>_add_owner_identity_to_runtime_tables.exs` | NEW — adds columns + indexes (NULL-permissive) |
| `apps/platform/lib/platform/orchestration/runtime_event.ex` | Add fields to schema + changeset |
| `apps/platform/lib/platform/orchestration/execution_lease.ex` *(or wherever the lease schema lives — investigate during impl)* | Same pattern |
| `apps/platform/lib/platform/federation/tool_surface.ex` | Add `:owner` keyword arg threading; populate when supplied |
| `apps/platform/lib/platform/federation/owner_handle.ex` | NEW — pseudonymous handle generator |
| `apps/platform/test/platform/orchestration/runtime_event_test.exs` | Cover new field accept/reject |
| `apps/platform/test/platform/federation/owner_handle_test.exs` | NEW — property tests for handle stability/opaqueness |
| `apps/platform/test/platform/federation/tool_surface_test.exs` | Cover threading happy + missing-owner |

Out-of-scope for Stage 1: visibility filtering (Stage 2 / BACKLOG #17), rate limit hooks (Stage 2), federation handshake pseudonymization (Stage 3), audit log UI surfaces.

---

## Risks

1. **Premature schema commitment.** Stage 1 commits to dual-key columns. If governance flips D1 to single-key, the migration is a partial waste (one column unused). Mitigation: D1's recommended default is dual-key precisely because it's forward-compatible with single-key interpretations (just leave one column NULL). The reverse migration risk is real but small.
2. **Soak-window assumption (Stage 2).** Going NOT NULL requires confidence that all writes populate the columns. Hidden code paths that bypass `ToolSurface` and write directly to `runtime_events` would be a problem. Mitigation: grep for direct `Repo.insert` calls into these tables during Stage 1 implementation; ensure they all flow through dispatch helpers.
3. **Breakdown of the OwnerHandle abstraction under future federation flows.** If a use case emerges requiring real-identity disclosure across orgs (e.g., a bilateral support arrangement between Burrow-on-Burrow federation peers), the handle abstraction may need to be extended with disclosure tokens. Mitigation: ship handle generation Stage 1 *without* a peer-side resolution path; add resolution Stage 3 only after D4.
4. **Conflict with BACKLOG #17 timing.** Item #17 (thinking-stream PubSub topic split — Option C) depends on owner identity for per-user scoping. If #17 ships before this ADR's Stage 2, #17 will scope-by-runtime instead of by-user, which is the wrong granularity and would need rework. Mitigation: coordinate sequencing — #17's Option C lands *after* this ADR's Stage 2.

---

## Why this ADR exists, not just BACKLOG #18

The BACKLOG entry frames the work as schema + plumbing — implementation. This ADR distinguishes:

- The **governance decisions** (D1-D4), which are not implementation choices and should be reviewed by Rowan / org-admin / legal independently of the schema work.
- The **non-blocking technical groundwork** (Stage 1), which can ship now and unblocks Stage 2 the moment governance lands.
- The **enforcement work** (Stages 2-3), which is governance-gated and not safe to start until decisions are accepted.

Encoding this split in an ADR rather than a BACKLOG line ensures the decisions don't get silently re-litigated during implementation review and that the prerequisite chain (this ADR's Stage 2 ↔ BACKLOG #17 Option C) is documented for cross-PR coordination.

---

## What the implementer should do next

1. **Get D1-D4 reviewed.** Even with recommended defaults, these need explicit signoff from Rowan + org-admin + legal before Stage 2 starts. Stage 1 can begin in parallel — none of Stage 1 commits to a specific D1-D4 interpretation.
2. **Ship Stage 1 in one PR.** Single commit chain, full test coverage, no observable behavior change. Mark the PR as "follow-up to ADR 0040."
3. **Open BACKLOG entries** for Stage 2 and Stage 3 referencing this ADR.
4. **Coordinate sequencing with BACKLOG #17.** If both ADRs are in flight, the maintainer should ensure #17's Option C lands after this ADR's Stage 2 (otherwise #17 has to ship with runtime-id scoping and migrate later).
