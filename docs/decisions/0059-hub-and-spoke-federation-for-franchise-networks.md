# ADR 0059: Hub-and-Spoke Federation for Franchise Networks

- **Status:** Proposed
- **Date:** 2026-11-01
- **Owners:** Team
- **Task:** 01a199b2-e7df-7000-b6a9-99ba1746bd79
- **Extends:** [ADR 0054](0054-install-to-install-federation.md) (a hub/spoke relationship kind and new envelope types on its trust model and protocol; not superseded, and its v1 behaviour is unchanged)
- **Related:** [ADR 0056](0056-supporting-customer-installs.md) (the `support` relationship kind, the precedent for adding a kind), ADR 0058 ([RBAC v2](0058-rbac-v2-roles-scopes-and-agent-capping.md))

## Context

A franchise network is many locations that share a brand and a body of know-how. The use case
this ADR designs for:

- Each location runs its own owned install (ADR 0053 records the owned-install decision).
- One install is the **hub**. It holds the master org memory and the master files: the
  playbooks, the standard operating procedures, the brand assets.
- Every other install is a **spoke**. A spoke reads the hub's canon and feeds back what it
  chooses to share: what worked, what broke, local variations.
- A spoke's customer data is its own. It does not go to the hub unless the spoke's own policy
  says so.
- Hub and spokes run in the customer's cloud account, or as hosted installs billed to the
  customer. Core does not assume the vendor operates any of them.

**What 0054 covers and does not cover.** Measured at origin/main `17feb5560`, where 0054 is
still `Proposed`:

- It specifies one relationship between two installs. A shared space has at most one peer:
  `federation_shared_spaces.local_space_id` is unique, and
  `0054-install-to-install-federation.md § 7. Out of scope for v1` lists "Spaces shared with
  more than one peer" and "Sharing canvases or tasks".
- It replicates one thing, message creation (`message.replicate`), per
  `0054-install-to-install-federation.md § 3. Owner-authoritative shared space`. Edits, deletes,
  reactions and attachments are listed as later work there.
- It has no hub role and no notion of one install holding many peers with different standing.
  Its trust is per relationship and never transitive
  (`0054-install-to-install-federation.md § 1. Trust model`), which this ADR keeps.
- It has no memory sync and no file sync. Org memory pages and journals, and stored files, are
  not envelope payloads.
- ADRs 0055 to 0058 do not cover any of this. The `support` kind described in
  0056-supporting-customer-installs.md § A.1 The `support` relationship kind
  shows that a new relationship kind can be added over 0054 without editing it, and this ADR follows that route.

The memory model this ADR syncs is the one in
`0041-org-memory-v2-wiki-system.md § Historian as sole page writer`: agents append to journals,
and only the Historian writes wiki pages. Hub-and-spoke keeps that rule on both sides of the
link. A grant model for who may read or write memory on an install is
[ADR 0058](0058-rbac-v2-roles-scopes-and-agent-capping.md) (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`), and this ADR does not change it.

**Licence.** Core is Apache-2.0. Everything here is protocol and per-install behaviour that
belongs in core. Fleet-level operation across many installs (rolling upgrades, a network-wide
dashboard, billing) is not specified here and is not core's job; section 4 says where the line
falls.

**Dependency: the proof ticket.** Task 01a199b2-b20c-7000-a5b5-f55e7ecfdf5d ("Prove
install-to-install federation end to end: two dev installs pair and share one channel") is
meant to show that 0054's one-to-one slice works between two real installs. When this ADR was
drafted that ticket had landed no findings, so this design rests on 0054 as written and on unit
and controller tests only, not on an end-to-end run. Nothing below should be treated as proven
until that ticket reports.

**Open question, owned by the proof ticket: the well-known path.** That ticket probes
`/.well-known/burrow-federation`, while 0054 specifies `/.well-known/suite-federation` for the
descriptor and keeps the client fetching that path
(`0054-install-to-install-federation.md § Protocol versions`). Both paths are served, so the probe
may be correct, but this ADR does not resolve it. Wherever this ADR says "the descriptor" it
means whichever path 0054 serves, and the proof ticket decides which one an operator should
probe.

**Not experimentable.** This is a decision record. It introduces no model, prompt, threshold
or generator.

## Decision

Hub-and-spoke is a new **relationship kind** over 0054, in the way `support` is in 0056. It adds
a role to the relationship, a small set of envelope types and a per-direction scope. It does not
change how a `kind = "peer"` relationship behaves, and it does not alter 0054's v1 limit of one
peer per shared space.

### 1. Data-flow model

Bullets here are the checkable commitments.

- **One install holds many peers (the hub role).** A hub install has one relationship row per
  spoke. Each is an ordinary 0054 relationship (own key, own `PeerConnection`, own revocation)
  with `kind = "hub_spoke"` and a `role`. A spoke has one such relationship, to its hub, and may
  also hold ordinary 0054 peer relationships. Nothing about the hub's many peers is transitive:
  a spoke gains no standing towards another spoke.
- **The one-peer-per-space limit is lifted only where needed.** `hub_spoke` sync does not use
  shared chat spaces. It uses the journal and canon feeds below, so the unique index on
  `federation_shared_spaces.local_space_id` stays and 0054's v1 behaviour is unchanged. If a
  later ADR wants a hub-wide shared space, that is the point at which the index is revisited.
- **Upstream: spokes send chosen journal entries; the hub's Historian curates.** A spoke pushes
  selected journal entries (`org/journal/...` and, where the policy allows, project or space
  journals) to the hub as an append-only feed. The hub stores them as journal entries in a
  per-spoke namespace. The hub's Historian reads them like any other journal and decides what
  becomes canon, following the sole-page-writer rule in
  `0041-org-memory-v2-wiki-system.md § Historian as sole page writer`. **A spoke never writes
  hub canon**, directly or by any envelope.
- **Downstream: the hub publishes canon read-only under `hub/page/...`.** Each hub canon page
  appears on every spoke under the namespace `hub/page/<path>`. Spoke users and agents can read,
  search and link to it, and cannot edit it. The spoke keeps its own `org/page/...` tree,
  untouched by the sync.
- **Files follow the same split.** Hub files appear on a spoke as `hub/file/...`, read-only. The
  spoke's own files stay in its own namespace. Downstream file blobs are fetched by content hash
  (see `file.offer` in section 3), so a spoke fetches only what it does not hold and a
  corrupted transfer is detectable.
- **A per-spoke upstream policy decides what may go up.** Each spoke holds a policy that lists
  what may be sent: which journal namespaces, which file collections, which tags. Every upstream
  envelope is checked against it at the spoke before it is queued. **The default policy is that
  nothing goes up.** A spoke's customer data does not leave the spoke unless an admin of that
  spoke has changed the policy. The hub cannot change a spoke's policy; it can only see what the
  spoke reports (`policy.report`).
- **Where they run.** The hub and each spoke run in the customer's cloud account, or as hosted
  installs billed to the customer. Core makes no assumption that one party operates the whole
  network.

### 2. Conflict rules

- **Hub canon wins downstream.** Where the hub and a spoke disagree about a `hub/` page or file,
  the hub's version is the one the spoke shows. A spoke's local state never overrules canon.
- **A spoke's `org/` content is never overwritten by hub content.** The two live in different
  namespaces. A hub page whose path would collide with a spoke `org/` path does not collide:
  it is under `hub/`. The sync code has no operation that writes into a spoke's `org/`
  namespace.
- **Upstream entries are append-only, with an idempotency key.** The key is the spoke's
  `install_id` plus the entry id. A replayed or duplicated `journal.push` is a no-op that still
  returns success, the same durability-by-idempotency rule 0054 uses
  (`0054-install-to-install-federation.md § 2. Protocol`). The hub never edits a pushed entry in
  place.
- **A spoke edits or deletes an entry it already sent.** The spoke sends a tombstone for that
  entry id in a later `journal.push`. The tombstone is appended; the original is not removed.
  The hub's Historian decides what a tombstone means for any canon page already derived from
  the entry. The protocol does not retract canon on its own authority.
- **The hub retracts canon.** The hub sends `canon.retract`. Each spoke drops its `hub/` copy of
  that page or file. Spoke-side pages that linked to it keep the link text and lose the
  target, the way any link to a missing page behaves.
- **Ordering and replay after downtime.** Upstream, each spoke keeps a cursor over its own
  journal feed and resends from the last entry the hub acknowledged, so the hub's view is the
  spoke's journal order for that spoke. Downstream, the hub orders canon by a per-spoke canon
  sequence number and a spoke that comes back asks for everything after its last applied
  sequence. Entries are applied in sequence order; a gap triggers a resync request rather than
  guessing. There is no ordering between two different spokes' feeds, and the hub does not
  invent one.

### 3. Protocol additions over ADR 0054

Everything here rides on 0054 unchanged: the envelope fields, the Ed25519 signature over the raw
body, the verification order, the plus or minus 300 s replay window with the nonce cache, and the
per-peer `PeerConnection` with its bounded queue, backoff and circuit breaker
(`0054-install-to-install-federation.md § 2. Protocol`,
`0054-install-to-install-federation.md § 4. Per-peer supervision`). None of those rules is
loosened for the new types.

**Relationship kind and role.** `relationship.propose` and `relationship.accept` gain
`kind = "hub_spoke"` and a `role` of `hub` or `spoke`, set by the proposer and confirmed by the
accepter. The pair must be complementary (one `hub`, one `spoke`); anything else is refused. The
unknown-install rule in 0054 still holds: an unknown sender may send only `relationship.propose`.
As with 0056's `support` kind, an admin on each side still confirms the key fingerprint out of
band before accepting.

**Per-direction scope.** The relationship row carries a scope for each direction: what the
sender may send, and what the receiver will accept. An envelope outside the receiver's accepted
scope is rejected with its own reason atom. A hub's scope for a spoke is read-only downstream
(`canon.publish`, `canon.retract`, `file.offer`) and journal-append-only upstream (`journal.push`,
`policy.report`). Scope is stored on the relationship and read on every authorisation decision, as
0054 requires of trust generally.

**New envelope types.**

| Type | Direction | Payload |
|---|---|---|
| `journal.push` | spoke to hub | entries, each with the spoke's `install_id`, entry id, namespace, body, timestamp and a `tombstone` flag; the idempotency key is install id plus entry id |
| `canon.publish` | hub to spoke | a canon page (path under `hub/page/`, body, canon sequence number) or a file manifest reference |
| `canon.retract` | hub to spoke | the path to drop and the sequence number of the retraction |
| `file.offer` | hub to spoke | a file path under `hub/file/`, its size, media type and content hash; the spoke fetches the blob by hash over the same signed channel and verifies the hash |
| `policy.report` | spoke to hub | the spoke's current upstream policy, so the hub can see what it will and will not receive; informational, never a request to change policy |

Remote text from either side is still untrusted. Journal entries and canon pages are stored as
data and rendered through the same wrapping and mention-escaping that 0054 specifies for remote
content (`0054-install-to-install-federation.md § 6. Untrusted content`), and no envelope of any
of these types can dispatch an agent on the receiving install.

### 4. Version strategy

- **Negotiated at pairing.** Each side's descriptor lists the protocol versions it speaks, which
  builds on `0054-install-to-install-federation.md § Protocol versions` and the
  `suite-federation/1` descriptor. At `relationship.propose` and `relationship.accept` the two
  installs agree the highest version both support.
- **Major mismatch refuses pairing.** If the two sides share no major version, the relationship
  is not created, and both admins see the reason.
- **Minor versions are additive.** A minor version may add envelope types or optional payload
  fields and may never change the meaning of an existing one. A receiver that gets an envelope
  type it does not know ignores it, returns success so the sender does not retry forever, and
  increments a logged count per type and peer.
- **The protocol only reports versions.** The peer's negotiated and advertised versions are
  visible in peer status. Core does not push, schedule or force an upgrade on a peer.
- **Lockstep upgrades are not core's job.** Rolling a whole network to a new version together is
  an operational concern of the proprietary fleet layer, not of core. Core's contract is that
  adjacent minors interoperate and that a mismatch is reported rather than silently degraded.
