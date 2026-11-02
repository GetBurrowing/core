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

The well-known path discrepancy between the proof ticket and 0054 is recorded under `## Open questions` below.

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

### 5. Trust and authorisation

- **Pairing keys reuse 0054.** A hub and a spoke pair with the Ed25519 install keys, the
  propose/accept exchange and the out-of-band fingerprint check of
  `0054-install-to-install-federation.md § 1. Trust model`. No new key type exists. In the
  default model a spoke pairs to exactly one hub; a second `hub_spoke` relationship in the
  `spoke` role is refused. A hub pairs to many spokes.
- **Per-direction scopes on the relationship.** The scopes are `upstream:journal`,
  `downstream:canon`, `upstream:files` and `downstream:files`. A relationship holds the subset
  both admins accepted at pairing, so a spoke can be paired read-only (`downstream:canon` and
  `downstream:files` only). Scope is read from the relationship row on every envelope, as in
  section 3.
- **Spoke policy is enforced at the spoke, before send.** The hub is never trusted to filter
  what it receives. The check in section 1 runs on the spoke when an entry or file is queued
  upstream, so data the policy excludes never reaches the wire. The default is that nothing
  goes up. The hub-side scope check is a second, independent refusal and never a substitute.
- **Hub-side ACL for downstream.** The hub holds, per spoke, which canon pages and files that
  spoke receives. Where the scopes of
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants` apply to the pages in
  question, the ACL honours them; a spoke is not sent a page its relationship has no grant for.
  `canon.publish` and `file.offer` are generated per spoke from that ACL.
- **Inbound upstream text and files are untrusted to the hub.** Journal entries and files from
  a spoke are external content. The hub wraps them with `Platform.Security.ExternalContent`
  and applies `0054-install-to-install-federation.md § 6. Untrusted content`, including before
  the Historian reads them. A spoke entry cannot dispatch an agent on the hub, cannot carry an
  instruction the Historian is obliged to follow, and files are verified against their content
  hash and stored as data, not executed or rendered as trusted markup.
- **Revocation and key rotation.** Revoking a relationship stops the hub sending anything to
  that spoke and stops it accepting anything from it, through 0054's existing revocation.
  Rotating a key follows 0054's trust model; envelopes signed by the old key are refused once
  the new key is accepted. Canon already delivered to a revoked spoke stays on that spoke,
  because it is data now held by an install the hub does not control and the protocol cannot
  recall it. Journal entries the spoke already pushed stay on the hub as the hub's data, unless
  the spoke's admin asks the hub's admin to remove them. Neither side's data is deleted by the
  protocol on revocation. A `hub/` copy left on a revoked spoke is marked detached and stops
  receiving updates.
- **Agent capping on the hub.** A Historian run on the hub is an agent whose effective
  permissions are capped per `0058-rbac-v2-roles-scopes-and-agent-capping.md § Agents`. It reads
  the per-spoke journal namespaces it has been granted and writes hub canon pages, and cannot
  read beyond that scope: not another install's content, not memory outside its grants.
  Per-spoke namespacing means a run curating from one spoke's feed holds no read on another
  spoke's namespace unless the run is explicitly granted both.

### 6. Open and proprietary boundary

Core is Apache-2.0 and lives in `GetBurrowing/core`. The proprietary repo is working-named
`GetBurrowing/burrow-cloud`. That repository exists today, so the name is not only an
assumption; what is assumed is that fleet and curation code belongs there rather than in a new
repository, because it must be able to depend on core's public protocol and not the reverse.

| Piece | Where it lives | Repo | Licence | Notes |
|---|---|---|---|---|
| Hub/spoke protocol and envelopes (section 3) | core | GetBurrowing/core | Apache-2.0 | built on 0054 |
| Relationship roles and per-direction scopes | core | GetBurrowing/core | Apache-2.0 | |
| Per-spoke upstream policy engine, default nothing up | core | GetBurrowing/core | Apache-2.0 | enforced at the spoke |
| `hub/` and `org/` namespaces | core | GetBurrowing/core | Apache-2.0 | |
| File offer and fetch by content hash | core | GetBurrowing/core | Apache-2.0 | |
| Version reporting in peer status, refusal on major mismatch | core | GetBurrowing/core | Apache-2.0 | reports only; never forces upgrades |
| Minimal console or mix-task way to pair a hub and a spoke by hand | core | GetBurrowing/core | Apache-2.0 | self-hosting stays fully free and functional |
| Historian curation hook on the hub | core | GetBurrowing/core | Apache-2.0 | the hook only |
| One-click add-a-location provisioning and pairing | fleet layer | GetBurrowing/burrow-cloud | Proprietary | drives the core pairing path |
| Lockstep upgrades | fleet layer | GetBurrowing/burrow-cloud | Proprietary | |
| Fleet health and backups | fleet layer | GetBurrowing/burrow-cloud | Proprietary | |
| Key rotation tooling | fleet layer | GetBurrowing/burrow-cloud | Proprietary | uses core's rotation rules |
| Hub-curation layer: Historian and agent configuration, cross-location reporting | curation layer | GetBurrowing/burrow-cloud | Proprietary | configuration, not mechanism |
| Enterprise extras: SSO, audit export, SLA, support via 0056 | enterprise | GetBurrowing/burrow-cloud | Proprietary | support follows [ADR 0056](0056-supporting-customer-installs.md) |

**Nothing in core is a licence check, an entitlement gate or a feature flag keyed to payment.**
Every row marked core works without any vendor service, account or key.

**Commercial context, not a core mechanism.** The pricing sketch is a hub platform fee plus a
per-location managed-service fee; self-hosting is free. This describes what the vendor may charge for
the proprietary layer and has no representation in core code.

### 7. What the vendor can and cannot see

- **Where installs run.** The hub and each spoke run in the customer's cloud account, or as
  hosted installs billed to the customer.
- **Fleet operations see lifecycle, never content.** The fleet layer sees that an install
  exists, its version, its health, its backup status and its key-rotation events.
  Checkable: the status data core reports to a peer or operator carries versions and health
  (section 4), and no envelope or status field in section 3 or section 4 carries journal
  bodies, page bodies or file bytes to anything other than the paired peer.
- **Content only through granted support access.** The vendor sees content only through support access
  the customer grants under [ADR 0056](0056-supporting-customer-installs.md)
  (`0056-supporting-customer-installs.md § A.5 What the support agent can never do` bounds it).
  Checkable: that access is a separate `support` relationship the customer's admin accepts, and
  it can be revoked; nothing in `hub_spoke` creates or implies it.
- **The vendor is never in the data path.** Hub and spokes talk directly, using the descriptor and
  signed envelopes of 0054. There is no vendor relay or broker. Checkable: a `hub_spoke`
  relationship is addressed to a peer install's own URL and key, the protocol has no relay
  envelope or forwarding hop, and trust is never transitive
  (`0054-install-to-install-federation.md § 1. Trust model`), so a third party cannot be inserted.
- **What would let the vendor see content, and its absence.** The vendor would need (a) a key trusted by
  the hub or a spoke, (b) a relay hop, or (c) a field carrying content in a status or telemetry
  report. The protocol has none of these: keys are the customer's own pairing keys, there is no
  relay type, and `policy.report` and version reporting carry policy and versions only. A review
  that finds any of the three has found a defect against this ADR.

## Rejected alternatives

- **(a) A licence or entitlement check inside core. Rejected.** Core is Apache-2.0, so any
  in-core check is removable by a one-line fork. It protects nothing and taxes honest
  self-hosters.
- **(b) A single multi-tenant hub install holding every franchisee as an org. Rejected.** It
  contradicts the owned-install decision in
  `0053-install-manifest-and-renderers.md § 1. One declarative install manifest per install` and
  customer isolation: one database would hold every franchisee's data.
- **(c) Full mesh between all locations. Rejected.** It needs pairings that grow with the
  square of the number of locations and leaves no single canon authority.
- **(d) A vendor-operated relay or broker between hub and spokes. Rejected.** It puts the vendor in the
  data path, which section 7 rules out.
- **(e) A closed-source protocol. Rejected.** The sponsor judges forks inevitable, and a closed
  protocol loses the aim of being the best option to make this easy.
- **(f) Whole-memory two-way sync. Rejected.** It is conflict-heavy and leaks customer data
  that the spoke never chose to share.
- **(g) Letting the hub filter upstream data after receipt. Rejected.** The data has already
  left the spoke; enforcement belongs before send.
- **(h) Spokes writing hub canon directly. Rejected.** It breaks the Historian as sole page
  writer and makes canon quality depend on every spoke.

## Staged build order

1. **Dependency: the 1:1 proof.** Task 01a199b2-b20c-7000-a5b5-f55e7ecfdf5d. At the time of
   writing it is in progress and has landed no findings, so this is unlanded and the plan rests
   on [ADR 0054](0054-install-to-install-federation.md) as written. Exit condition: two real
   installs paired and replicating a message.
2. **Many-peer relationships and roles.** `kind = "hub_spoke"`, `role`, complementary-role
   check, one hub per spoke. Exit: a hub holds relationships with two spokes, each with its own
   key and revocation, and a second hub for a spoke is refused.
3. **Upstream journal feed with spoke policy.** `journal.push`, idempotency, tombstones, the
   default-nothing-up policy and `policy.report`. Exit: with the default policy a spoke sends
   nothing; after an admin allows one namespace, only that namespace arrives, and a replay is a
   no-op.
4. **Historian curation hook on the hub.** The hook is in core; the curation configuration is
   proprietary. Exit: the hub's Historian reads a spoke's pushed journal as external content and
   writes a canon page, and a spoke entry cannot dispatch an agent.
5. **Downstream canon under `hub/page/...`.** `canon.publish`, `canon.retract`, sequence
   numbers and resync. Exit: a spoke shows a hub page read-only, a retraction removes it, and a
   spoke returning after downtime catches up in order.
6. **Files.** `file.offer` and fetch by hash under `hub/file/...`, plus the upstream file scope.
   Exit: a spoke fetches a hub file, a corrupted transfer is detected by hash, and nothing
   uploads without `upstream:files`.
7. **Version reporting and refusal on major mismatch.** Exit: pairing across majors is refused
   with a reason both admins see, and peer status shows negotiated and advertised versions.
8. **Outside core, tracked in burrow-cloud: fleet provisioning and pairing.** One-click
   add-a-location, lockstep upgrades, fleet health, backups and key rotation. Exit: a new
   location is provisioned and paired to a hub without hand-run commands, using only core's
   public pairing path.

## Consequences

- Self-hosters get hub and spoke fully functional in core; the commercial layer is convenience
  and operation, not capability.
- Spoke customer data stays on the spoke unless its admin opts in per policy; the default is
  safe and a misconfigured hub cannot pull more.
- The hub's Historian becomes the quality gate for canon, so canon is only as good as the
  curation, and the hub carries the curation workload.
- Revocation cannot recall delivered canon or pushed journal entries; operators need to know
  that data already delivered stays where it landed.
- More relationship state (kind, role, scopes, canon sequence per spoke) must be stored and
  tested on top of an unproven 1:1 slice, which is why step 1 gates the rest.
- Version drift across a network is reported by core and fixed by the proprietary fleet layer;
  a self-hoster must upgrade by hand.

## Open questions

- **The well-known path.** The proof ticket (01a199b2-b20c-7000-a5b5-f55e7ecfdf5d) probes
  `/.well-known/burrow-federation`, while 0054 specifies `/.well-known/suite-federation` for the
  descriptor and keeps the client fetching that path
  (`0054-install-to-install-federation.md § Protocol versions`). Both paths are served, so the
  probe may be correct, but this ADR does not resolve it. Wherever this ADR says "the
  descriptor" it means whichever path 0054 serves, and the proof ticket decides which one an
  operator should probe.
- **Whether the proof ticket's findings change the design.** Until it reports, nothing here is
  proven end to end.
- **Hub-wide shared spaces.** Whether a later ADR should lift the one-peer-per-space index.
- **Where `ExternalContent` wrapping applies to files.** It is an existing module for text; the
  treatment of file bytes needs confirming when step 6 is built.
