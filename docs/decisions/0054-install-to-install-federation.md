# ADR 0054: Install-to-Install Federation

- **Status:** Proposed
- **Date:** 2026-09-25
- **Owners:** Team
- **Task:** 01a0d90f-3e5a-7001-9bf8-c266127c5186
- **Extends:** [ADR 0014](0014-agent-federation-and-external-runtimes.md) (runtime federation), [ADR 0040](0040-federated-agent-owner-identity.md) (federated agent owner identity); neither is superseded
- **Related:** [ADR 0053](0053-install-manifest-and-renderers.md) (install manifest; records the owned-instance decision)

## Context

On 2026-09-25 Rowan decided that every customer gets their own owned Suite install. Multi-org
inside one install is not a customer isolation boundary (ADR 0053 records this). Owned
installs still need to collaborate: two businesses, or a family and a contractor, each on their
own install, want one shared space.

Nothing in core does this today. Measured at origin/main `571aaae2`:

- No ADR in `docs/decisions/` covers peer installs. "Federation" in ADR 0014 means external
  agent runtimes connecting to one install. The "federation peer" in ADR 0040 is a hosting
  org or runtime inside one install, not another install.
- The only `.well-known` URL in `apps/platform/lib` is the OIDC client's discovery URI
  (`oidc.ex:125`). Core serves no `.well-known` route of its own.
- The only Ed25519 keypair is `Platform.Federation.NodeIdentity`. Its moduledoc calls it the
  "device identity for the OpenClaw node connection": core acting as a client of an OpenClaw
  gateway. It is a file on disk and is not a trust root between installs.

This ADR picks up a proposal from 2026-09-25. Installs are never federated over Erlang
distribution. The boundary between installs is an ordinary signed protocol over HTTPS, and
the BEAM's job is on each side of that boundary.

**Not experimentable.** This is protocol plumbing with no variant population. v1 has one
relationship between two installs, so there is nothing to assign variants to. Its tunables
(replay window, backoff, breaker threshold, queue cap) are reliability config. Its one
model-facing choice, how remote text is wrapped, belongs to `Platform.Security.ExternalContent`
and is reused unchanged; any wrapper experiment belongs to that module.

## Decision

### 1. Trust model

**Install identity.** Each install has an `install_id` (UUIDv7) and one or more Ed25519
signing keys. Each key has a `kid`. The Ed25519 primitives are hoisted out of `NodeIdentity`
into one shared module (`Platform.Federation.Ed25519`), and NodeIdentity delegates to it with
its on-disk format unchanged. There is no second keypair implementation.

**Private key custody.** The install's private key lives in `Platform.Vault` (slug
`peer-federation-key-<kid>`) and is read at call time. It is never written to a file and never
logged. Only public keys and fingerprints (sha256 of the public key) leave the Vault.

**Descriptor.** `GET /.well-known/suite-federation` returns:

```json
{
  "protocol": "suite-federation/1",
  "install_id": "<uuidv7>",
  "display_name": "...",
  "base_url": "https://suite.example.com",
  "inbox": "https://suite.example.com/federation/v1/inbox",
  "keys": [{"kid": "...", "alg": "ed25519", "public_key": "<b64url>"}]
}
```

It returns 404 while the feature flag (`PEER_FEDERATION_ENABLED`) is off, which is the default.
Discovery is opt-in: an install is found because an admin types its URL. There is no central
directory.

**Establishment: propose, then accept.**

1. An admin on install A proposes a relationship with install B's base URL. A fetches B's
   descriptor and sends B a `relationship.propose` envelope, signed with A's key and carrying
   A's `install_id`, `kid`, public key and base URL.
2. B verifies the envelope against the key in its payload. B then **re-fetches A's
   `.well-known` from the payload's base URL** and requires the same `install_id` and `kid`.
   This binds the key to a domain the proposer controls. B records a `pending_inbound` row.
   Unknown installs may send only `relationship.propose`, and those are rate-limited.
3. An admin on B compares the key fingerprint with A's admin **out of band** (a call, a
   message on another channel) and accepts. B sends `relationship.accept`, and both rows
   become `active`.

The re-fetch in step 2 makes B issue a GET to a URL that an unauthenticated sender chose. That
is a server-side request forgery surface. Before the fetch the implementation must require
https, resolve the host and refuse loopback, private (RFC 1918, ULA), link-local and
cloud-metadata ranges, follow no redirects, and cap the response size. The only exception is
`PEER_FEDERATION_ALLOW_HTTP`, which permits plain http, is honoured only outside `:prod`, and
exists for the two-install rig on moon's podman network.

**Revocation is unilateral.** Revoking sets the local row to `revoked`, persists that first,
and only then sends a best-effort `relationship.revoke` notice. From that moment the revoking
install refuses every inbound envelope from the peer and sends nothing outbound. The revoking
install enforces the revocation itself, so it holds whether or not the peer receives the
notice or cooperates.

**Key rotation.** A `key.rotate` envelope announces a new `kid` and public key and is signed
by a key that is current at the receiver. The old `kid` stays valid for an overlap window
(7 days). Each peer-key entry the receiver stores carries its own `status` and `valid_until`,
and verification checks them. This lets the receiver end the overlap, or retire one
compromised peer `kid`, without dropping the relationship.

**Trust is per relationship and never global.** Accepting B grants B nothing towards any other
peer, and there is no transitive trust. Every authorisation decision reads one relationship
row.

**Why signatures and not runtime bearer tokens.** Runtime tokens (`AgentRuntime.hash_token`)
are not reused for peers. A bearer secret one install issues to another can be replayed by
whoever receives it. A signature is bound to one message and one key, and gives per-message
non-repudiation.

### 2. Protocol

**Transport (v1).** HTTPS `POST` of one signed envelope to `/federation/v1/inbox`, with one
transaction per envelope, as in Matrix's server-to-server `/send`. A WebSocket transport is the
follow-up, for presence and typing, which v1 does not carry.

POST is chosen for three reasons:
- each envelope carries its own signature, so the connection carries no trust;
- retries are idempotent (see below);
- it can be exercised with curl.

**Envelope.**

| Field | Meaning |
|---|---|
| `v` | protocol version, `1` |
| `id` | UUIDv7; the idempotency key |
| `from` | sender `install_id` |
| `to` | recipient `install_id` |
| `kid` | signing key id |
| `ts` | unix milliseconds |
| `nonce` | 16 random bytes, base64url |
| `type` | e.g. `relationship.propose`, `message.replicate` |
| `payload` | type-specific object |

**Signature.** Ed25519 over the domain-separation prefix `"suite-federation/1\n"` followed by
the **raw request body bytes**. It travels in the `suite-federation-signature` header. The
verifier works on the cached raw body (`CacheBodyReader`), the same verdict/transport split as
`Platform.Webhooks.GithubSignature`. It never re-encodes JSON.

**Verification order.** Size cap (256 KB), JSON decode, `v`, `to` equals self, `from` resolves
to a peer row that is `active` (or `pending` for handshake types only), `kid` is valid for that
peer, signature, timestamp window, nonce unseen. Each check has its own reason atom. The HTTP
response carries only that atom and never echoes the input.

**Replay protection.** Two layers:
- `ts` must be within plus or minus 300 s of the receiver's clock;
- an ephemeral nonce cache (ETS) keyed on peer and nonce holds for the same window.

The nonce cache is lost on restart, and it is per node. **Durability comes from idempotency,
not from the cache.** Envelope `id`s and message links (`(peer_id, remote_message_id)` unique)
make a replayed or duplicated delivery a no-op that still returns 200. A multi-node install
would need a shared nonce store or would get a per-node replay window; v1 installs are single
node.

**Ordering.** The owner of a shared space orders it by its own UUIDv7 message ids. Each side
keeps a per-space cursor (the last message it delivered successfully) and resyncs from that
cursor after reconnecting or after its queue overflows.

### 3. Owner-authoritative shared space

This follows the Matrix room model, with one install authoritative per space.

- **The owner** (the install that shared the space) assigns canonical message ids and order.
  The owner's copy is the truth.
- **A replica** submits (`message.submit`). The owner accepts it, stores it under its own id
  and replicates it (`message.replicate`) to the replica, which links the two ids.
- **Conflicts resolve as owner-wins.** A replica never overrules the owner.

**Replicated in v1:** message creation only.

**Replicated later:** edits, deletes, reactions, participant changes and attachments. Each is
a new envelope type with owner-wins semantics.

v1 allows one peer per shared space; `federation_shared_spaces.local_space_id` is unique for
that reason. That uniqueness is a v1 limit, not a design invariant. Multi-peer spaces require
dropping that index.

Loop prevention: a message that arrived through federation (`metadata["source"] ==
"federation_inbound"`) is never sent onward.

### 4. Per-peer supervision

Each active peer gets its own process (`PeerConnection`), registered by peer id. It owns:

- a **bounded outbound queue** (cap 1000, configurable). On overflow it drops the oldest
  entries and marks the peer `resync_needed`. The chat table is the durable source and the
  cursor resync refills the gap, so there is no outbox table;
- **exponential backoff with jitter** (base 1 s, max 60 s);
- a **circuit breaker**: closed; open after 5 consecutive failures; half-open probe after the
  backoff.

Timeouts, non-2xx responses and garbage bodies are handled as values and never raise inside
the process. A slow or hostile peer only ever occupies its own process.

**Restart intensity must be scoped per peer.** A `DynamicSupervisor`'s restart intensity
defaults to 3 restarts in 5 s (measured: `DynamicSupervisor.init([])` returns `intensity: 3,
period: 5`), and it is counted **across the whole supervisor**. One crash-looping peer could
exhaust it and take down every sibling. Each peer is therefore wrapped in its own small
`Supervisor` with its own intensity, and that wrapper is started under the DynamicSupervisor
with `restart: :temporary`. A peer whose wrapper gives up stays offline until a periodic boot
scan (every 60 s) restarts it, and that event is logged with the peer id. The isolation claim
is bounded by one measurement: after peer X's wrapper gives up, peer Y's pid and the
DynamicSupervisor's pid are unchanged.

Telemetry for sends and breaker changes carries the peer id and outcome only, never payloads.

Backpressure through GenStage or Broadway is not needed for v1. The inbox is one bounded POST
per transaction; see Out of scope.

### 5. Remote agents

A remote agent joins a shared space the same way any external runtime joins an install today
(ADR 0014): the owner install mints an `AgentRuntime` row, and the agent connects through the
existing `/runtime/ws` socket (`PlatformWeb.RuntimeSocket`) with the `allowed_bundles` the owner
grants. The owner can revoke that runtime as it would any other.

There is no new token system and no new bundle system. Brokered provisioning, where the peer
protocol carries the runtime invitation instead of an admin handing the token over, is a
**follow-up** and is not in this slice.

### 6. Untrusted content

Remote content is untrusted outside text, like inbound email. The ingest mirrors
`Platform.Mail.Inbound`:

- The author is a **local system participant**, one per (peer, remote author). Its display
  name is the sanitised remote name plus `(via <peer>)`, with mention tokens escaped.
- The body is wrapped with `ExternalContent.wrap/2` (a `federation: "Suite peer"` source
  label is added), capped at 32 KB, and then passed through `ExternalContent.escape_mentions/1`.
  That rewrites every at-sign followed by an opening square bracket to a fullwidth at-sign.
- Metadata carries `"source" => "federation_inbound"` and `"skip_mention_scan" => true`.
- AttentionRouter gives `federation_inbound` messages no agent decision. Its existing
  `email_inbound?/1` clause (`attention_router.ex:377`, also consulted at
  `responsibilities/router.ex:878`) is generalised into `untrusted_inbound?/1` covering both
  sources. No parallel clause is added.

**The mention-summon gate.** `Chat.reinvite_and_pin_mentioned/1` runs after the commit of every
message in a non-DM space. It adds any non-archived agent whose slug or name appears in a
mention token, if `mention_summon_authorized?/2` passes. That check is keyed on the message's
`author_user_id`: the author must be an admin user participant of the space, or the sponsor of
the execution space's task.

**`author_user_id` is safe only because the ingest never copies it.** `Chat.post_message`
does not protect that field. `put_author_snapshot/3` keeps any author snapshot fields the
caller supplies (`Map.merge(snapshot, attrs)`, and `already_snapshotted?/2` skips the snapshot
entirely when a display name is present), and `Message.changeset` casts `author_user_id`. So
the guarantee is a rule about the ingest, not something the platform enforces:

> The ingest builds `post_message` attrs from a fixed literal: the local system participant's
> id, the rendered content, and fixed metadata. It never merges payload fields into attrs.
> The payload's `author_user_id`, `author_agent_id` and display name are never copied.

A system participant snapshots `author_user_id` as nil, so the summon gate refuses. The
falsifier is a test that sends an envelope whose payload claims a local admin's id as
`author_user_id` and then checks that the stored row has nil and that no participant was added.

That gives three independent layers against a remote mention, plus the author-field rule:
1. every mention token is escaped;
2. `skip_mention_scan` is set;
3. `untrusted_inbound?/1` returns no agent decision, which still holds when an agent already
   holds the space's active mutex.

No remote content can dispatch an agent in v1. If that is ever wanted, it must be a deliberate
new branch in AttentionRouter, not a fall-through.

### 7. Out of scope for v1

- Remote agents joining over the peer protocol (brokered provisioning); the manual
  `AgentRuntime` path in section 5 already works.
- Edits, deletes, reactions, participant and attachment replication.
- Presence and typing (Phoenix.Tracker or delta CRDTs over the signed protocol) and the
  WebSocket transport that would carry them.
- GenStage or Broadway backpressure on inbound events.
- Spaces shared with more than one peer.
- Sharing canvases or tasks.
- DNS-based discovery.
- An admin UI; v1 is driven from the console and mix tasks.

## 8. Rejected alternatives

- **Erlang distribution.** Distribution trusts everything. The cookie is effectively root on
  every connected node, and nodes form a full mesh by default. It is right for clustering nodes
  inside one install and wrong between installs owned by different people.
- **Matrix itself.** It would mean operating a second homeserver next to every install, and
  Suite's task, stage and agent model does not map onto Matrix rooms and events. The room
  model's owner-authoritative idea is borrowed; the system is not.
- **ActivityPub.** It is built for public social push. HTTP-signature profiles vary loosely
  between implementations, and it has no notion of owner-authoritative private state.
- **mTLS.** On real installs TLS terminates at the reverse proxy, so the application never sees
  the client certificate. Per-envelope signatures survive the proxy and can be verified by the
  application itself.

## Consequences

- One new trust root per install (the Vault-held key) and one new public route family
  (`/.well-known/suite-federation`, `/federation/v1/inbox`), both off by default behind
  `PEER_FEDERATION_ENABLED`.
- Relationship, key and shared-space state lives in new `federation_*` tables. The chat table
  stays the source of truth for messages.
- The untrusted-inbound predicate becomes shared between email and federation. Any future
  untrusted source joins that predicate instead of adding a clause.
- The author-field rule in section 6 is the one guarantee that no module enforces; the ingest
  is responsible for it. Its test is the regression guard for it.
