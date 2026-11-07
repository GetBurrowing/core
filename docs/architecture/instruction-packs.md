# Signed instruction packs

Task 01a1b6e1-4995-7000-b918-fb305d219275, stage 1.

## Scope and wire contract

An immutable release is data, never a code update. Allowed entries are
`role_prompt`, `skill_markdown`, `prompt_template`, and `setup_dialogue`.
Setup “scripts” are dialogue text. A target is a logical slug, never a path.
Entries carry only type, target and content. There are no attachments, archives,
executable bundles, hooks, tools, permissions, secrets, responsibility or role
membership fields, template evaluation, network destinations or sharing settings.
Markdown may discuss code; it is stored as text and must never be executed by
an importer. Later application stages must resolve targets only through existing
prompt/skill stores, preserve local edits, and perform server-side authorization.

The manifest has exactly pack_id, version (positive integer), schema_version (1),
minimum_client_version (SemVer), published_at (UTC ISO8601), previous_digest,
changelog, and entries. Version 1 has a null previous_digest; later versions
must increment by one and bind the preceding canonical manifest SHA-256.
No release can be updated/deleted through the database. The manifest module
pins counts, individual text sizes, and a 1 MiB canonical manifest limit.
An envelope has exactly manifest, key_id and a base64 Ed25519 signature.
Canonical UTF-8 bytes are compact JSON of the array:
`["burrow-instruction-pack-v1", [pack_id, version, schema_version,
minimum_client_version, published_at, previous_digest, changelog],
[[type, target, content], ...]]`.
No whitespace normalization occurs. Order of entries is signed. The independent
OpenSSL fixture pins these bytes; map iteration cannot alter the signature.
An install must reject unsupported schemas/minimum client versions before applying.

## Publisher operation and trust bootstrap

Publishing runs only as a local operator Mix command on the broker host:
`mix instruction_packs.publish MANIFEST.json`. Both broker mode and
`:instruction_pack_publisher` `enabled: true` are required. That config also
contains `key_id`, the raw 32-byte Ed25519 `private_key`, and `trusted_keys`, a
map from key id to raw 32-byte public key. The command verifies its signed output
against that map before storing it. No HTTP upload endpoint or agent tool exists.
Release transactions serialize per pack and validate the previous digest.

Generate the first Ed25519 key in the publisher's secret manager/HSM workflow
(e.g. `openssl genpkey -algorithm ED25519 -out /secure/operator-only/key.pem`).
Load raw key bytes through the broker's secret-storage configuration adapter;
do not copy PEM headers or DER encodings into the raw key config. Restrict that
storage and command access to operators. Never print keys, put private keys in
source control, manifests, logs, install images, or customer configuration.
The architecture deliberately has no default production private key.
Provision only the public key and its id in trusted installer/owner configuration
on each install; do not bootstrap trust from a fetched pack. Missing, malformed
or unknown roots fail closed. The example test key is exclusively a fixture.

Rotation in this first protocol requires explicit owner/installer public-key
configuration. Configure the new public key before publishing with its id;
retain the old public key while old/pinned releases are needed. A pack cannot
rotate its own key or mutate trust roots. An automated successor must authenticate
a rotation with an already trusted root, with its own versioned verified format;
this release does not accept unsigned rotation instructions from pack text.

## Existing channel and security boundary

GET `/api/feedback-broker/v1/instruction-packs/:pack_id/:version` returns the
stored envelope bytes, behind FeedbackBrokerGate's broker-enabled/rate limits.
There is no new host: Download uses Feedback.GithubPublisher.Broker.base_url/0.
The download client requires HTTPS, default TLS peer verification, no redirects,
no decompression, finite connection/response timeouts and a streaming byte cap.
Manifest text cannot supply a URL or request options. It verifies against only
the separately configured trust roots before returning a manifest.

Signatures authenticate the vendor as publisher; they do not prove prompt semantics
safe. Text can contain malicious instructions. Tools and egress must continue to
be authorized server-side, independently of prompt text and pack opt-in.
A pack never changes sharing consent. Subsequent stages must use the sharing
registry from 01a1b678, Habits aggregation from 01a1b6a1 and setup-guide stores
from 01a1b6de when those interfaces land; do not create duplicate registries or
silently disable missing dependencies. Hosted updater 01a1b35d is image/code
updates and remains separate. Stage 1 does not yet auto-pull/apply or send metrics.

## Install-side application and ownership

The application path retains verified signed envelopes separately from broker
publication. An install's State records selected version, high-water mark, pin,
checked/applied times and append-only selection history. Entry records each
vendor baseline/hash, last value actually applied, effective version and
base/local/incoming conflict. A conflicted release's selected version therefore
is not a claim that every target runs that version.

Existing content is local, even if it is byte-identical to a seeded default.
Owners explicitly accept incoming conflicts before those targets become
vendor-owned. Subsequent updates compare the live bytes with the last value
actually applied on the same physical row; edits and deletions stay local. A recreated row remains local even when its slug and text match the deleted vendor row. Null legacy row provenance is conservative and requires owner adoption. Missing/ambiguous mappings
reject a whole release. Retired vendor targets clear only their text in place,
preserving skill ids and attachments; locally edited targets are never cleared.
Text templates continue to use the existing Mustache renderer, never EEx.

Fetch happens outside the content transaction. The final transaction locks the
actual install_sharing singleton and checks the consent value, stop switch and
snapshot timestamp again. Pin, conflict resolution and application serialize on
the install-state advisory lock. Every content/store write, provenance update,
retained release and history/audit event commits together. Network failure,
untrusted signatures, unsupported minimum versions, old/out-of-order versions,
missing target mappings or consent changes leave the last good content active.

Rollback requires owner authorization and a retained, previously applied release,
re-verifies its signature against current trust roots, preserves edits since
application and pins the rolled-back version. Unpinning allows sequential
advancement again. Conflict resolution is owner-only, audited and refuses a
stale row/text/version snapshot rather than overwriting edits made after review. Owner UI obtains fresh snapshots through Installer.conflicts/2; the token includes physical row identity as well as base/local/incoming text and incoming version.

The BEAM poller requests the next sequential version of each trusted-config pack
id through the existing broker. It does not follow a pack-supplied URL or change
stable/edge image tracking. Tests disable background polling unless explicitly
started. Existing installs must receive this code through the normal code updater
before they can pull instruction packs; this feature adds no release promotion,
SSH update path, systemd timer or new remote host.

Trusted owner/installer runtime settings are `INSTRUCTION_PACKS` (comma-separated
pack ids), `INSTRUCTION_PACK_TRUST_ROOTS` (JSON object of key id to base64 32-byte
public key) and `INSTRUCTION_PACK_POLLER=false` to disable scheduling. Public keys
are provisioned through the trusted installer/owner channel; no pack supplies or
changes them. A missing trust root rejects the download. Publisher private keys
remain exclusively in publisher secret storage.

With no explicit pack-id allowlist, the poller discovers at most 100 unique
slug ids at GET `/instruction-packs` on that same broker scope. This catalog is
untrusted discovery metadata only: it carries no text, URL, key, version choice
or authority to apply. Every requested version still passes signature/schema/
compatibility/chain verification. Catalog changes cannot grant tools or replace
local data. A consent snapshot spans discovery and download, so an off/on toggle
cancels work queued by the old cycle. An explicit INSTRUCTION_PACKS setting
restricts discovery to those trusted-config ids instead.

## Consumed role and setup-guide targets

`role_prompt` target `burrow` resolves `agents.burrow.role.v1` and
`setup_dialogue` target `burrow` resolves `agents.burrow.setup.v1` in the existing
PromptTemplates store. Generic prompt_template entries cannot alias those rows;
unknown typed targets reject the entire release. Their insert-only seed derives
from the actual Burrow.identity_template/2 role/setup text, the consumer extended
by the setup-guide task. It does not duplicate a second role registry or grant.

NativeAgents originally seeds an instructions file once, so changing that seed
alone would leave existing agents stale. AttentionDispatch now reads these saved
text values for the existing install-managed Burrow agent on its next eligible
attention. Prompt-bearing signals receive supplemental guidance before the
original work; chat context retains its existing org map and adds an explicitly
labelled instruction-guidance/burrow source. Human message content/identity and
existing wiki entries remain unchanged. A deliberate absent/no-work prompt stays
absent. Other agents do not receive the guide's identity. This uses the channel
runtime's existing prompt/context rendering; no runtime restart, filesystem write,
permission change or new client executable is performed by applying a pack.
Local instructions retain precedence over supplemental guidance. Removing a
saved guidance row is a local deletion, and pack application will not recreate it.


## Owner status and pinned availability

Settings → Sharing with Burrow uses the existing Sharing singleton for every consent choice. The separate `instruction_pack_checks` singleton stores only pending/check/error timestamps, so a catalog outage is visible before the first pack exists. A missing next immutable version is a successful no-update check, not a transport failure.

The same gated broker exposes `/instruction-packs/:pack_id/latest`, returning pre-signed release bytes with `Cache-Control: no-store`. Clients verify this head with the configured trust roots and compatibility checks. Availability is fetched while pinned, but it never applies content or appends applied history. Consent is checked again under the install lock before caching. Replayed older heads cannot lower the highest retained verified version.

`instruction_pack_downloads` therefore includes verified **unapplied** availability releases. Running-version feedback must use `State.version` and entry effective provenance, never the largest downloaded version. Rollback and the owner version selector admit only versions in applied history; a cached future release is not rollback eligible. Owners can resume updates to advance through the signed chain, and local edits remain protected.

## Anonymous current inventory and learned outcomes

The existing hourly `Sharing.UsageBatcher` request to the existing broker `/usage`
route optionally carries `instruction_outcomes`; there is no pack-specific
background uploader or endpoint. The receiver validates the same literal contract
and stores one replacement row per random sharing install id and window start.
Retries replace that window, not increment it. Only pack id, selected applied
version, effective vendor versions, bounded vendor/mixed status and explicit
Habits provenance availability are accepted. Target ids, local text and diffs,
changelogs, names, raw outcomes and arbitrary error messages are not fields.
Receiver payload validation is independent of the sender. These records describe
current state, not a historic attribution or a causal experiment result.

Both the usage-counts consent and the install-wide instruction stop are checked
at the last broker send boundary. Download consent never enables uploads. Turning
off does not send a farewell request. A current effective version requires the
same saved target identity and applied hash; replacing a row with identical bytes
or editing content makes it local. An unapplied cached release is never running.

`Platform.Habits.Shapes.aggregate/0` is the sole allowable source for anonymous
learned-default rates, with its five-user suppression and bucketed rates. Its
current contract aggregates historic signals without observation-time instruction
pack provenance. Pack-attributed rates therefore remain **unavailable**, never
zero and never labelled with today's pack version. A future provenance-aware
contract must capture it when observations happen and preserve unknown historical
observations. Shape transport remains the common-batch task 01a1b6a5; instruction
updates do not create another raw-signal query or a duplicate shape sender.

A signed adversarial instruction can ask for export or a grant; it remains text.
The protected sharing, feedback and role-grant APIs enforce their existing owner,
consent, redaction and scope checks independently of pack contents. Signatures
prove publisher identity, not that the prose is safe. External runtimes with
unrestricted shell or network retain those existing capabilities and their tool
sandbox; this channel grants none and does not claim to prevent arbitrary shell
exfiltration by a runtime already authorized to perform it.
