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
