# Native Play provider

Streamed review builds and packaged native sessions are distinct supported modes of Play.
`ReviewBuild.resolve` remains task-branch-only. Native Play never clones or builds on click.

The `Platform.GameStream.Provider` contract is `start(session_id, immutable_build, limits)`,
`status(handle)`, `stop(handle, reason)` and `reconcile(session_id)`. Native dispatch uses the
existing federation runtime socket. `game_native_host` hosts declare only that capability;
stream hosts retain their existing capabilities and lifecycle. A channel stays kind `channel`.

`GameChannels.configure(user, channel, project)` requires channel write and verified project
access including membership in the repository's org. It does not grant cross-org access.
`NativeSessions.play` locks the channel and persists a session before dispatch; the partial
unique index is an additional guard. Repeated starts use the same session/container name.
`NativeSessions.mint` returns an opaque 60-second reservation only to the authenticated user.
The caller must not post the response or URL to messages/canvases/logs. Hosts validate it by
HTTPS POST `/api/ext/play/admit/:session_id`, Authorization bearer credential, JSON claims:
`token`, `user_id`, `channel_id`, `build_id`, `generation`. Atomic consumption returns an
`admission_id` and slot. Never construct a body or seat before success. The host credential
is unrelated to any player token and scoped to one session; only its digest reaches core.

## Runtime setup (designated infrastructure operators)

Use a dedicated native play-host runtime credential, provisioned through existing federation
onboarding. Keep its token in the ordinary `token_file`. Native `serve -config` example:

```json
{
  "burrow_url": "wss://BURROW/runtime/ws",
  "runtime_id": "native-host",
  "token_file": "/private/runtime-token",
  "logs_dir": "/var/log/burrow-native",
  "native": {
    "enabled": true,
    "podman": "podman",
    "state_dir": "/var/lib/burrow-native",
    "public_host": "native.EXAMPLE",
    "admission_url": "https://BURROW/api/ext/play/admit",
    "images": ["REGISTRY/GAME@sha256:DIGEST"],
    "ports": [24973]
  }
}
```

Use real complete lowercase SHA256 digests. Operator pre-pulls these images; `--pull=never`
and the exact allowlist reject mutable or unapproved images. Each image's entrypoint launches
the packaged dedicated game, reading `GAME_NATIVE_CONFIG_FILE`, writing admission IDs at
`/run/native-state/roster.json` atomically every second. No graphics or encoder is initialized.
Run rootless Podman; config files are 0600, state directories 0700, mounted under keep-id.
The native host emits heartbeats every 10 seconds, recovers session handles from disk and
matches owner/session/generation labels before stopping. Its orphan sweep is limited to its
own runtime's label. During core outage, existing gameplay continues at most 120 seconds;
new admission fails closed. A missing game roster kills the session after 60 seconds.

Core starts time out after 90 seconds; host heartbeat becomes stale after 30 seconds for
admission and is stopped at 90 seconds. Idle teardown uses a session-pinned 300/600/900-second
experiment value (control 600) only with no connected players or unexpired reservations.
Late publishing never changes the running build. Restart reconciliation never grants slots.

Only the designated infrastructure operator changes container/UDP/DNS/firewall setup, on a separate port pool from stream
WebRTC. Record actual mapping and demonstrate ENet from a second network; DNS alone is not
reachability evidence. Existing public Voltron 24972 must remain untouched. Stage 1 proved
a remote :24973 server plus native clients on two independent networks; that is not proof of this provider's container.
Stage 2 deployment/test evidence must identify its own image digest and native host revision.

## Immutable package publication (task 01a1b287 stage 3)

`deployment/game-build/godot.sh` exports Windows x86_64, Linux x86_64, macOS Universal 2
(arm64 and x86_64), and Linux dedicated-server packages using exactly Godot 4.7.2 and its
checksum-pinned matching templates. Export presets add the `native` feature, selecting the
native lobby without changing the streamed default. Server images execute the exported
runtime, not an editor. Clean Actions player VMs execute the archives without installing
an engine; macOS checks both Mach-O slices. Archive entries retain PCK/resources and mode.

The engine-neutral `publish.py` builds nothing. It validates archives, hashes, sizes,
relative executable paths and the complete matrix, then verifies GitHub provenance with
`gh attestation verify` bound to repository, source SHA and the immutable reusable workflow.
Main pushes only register after every clean-player test and attestation succeeds. Immutable
`native-<source SHA>` releases are never overwritten, and are retained indefinitely in this
version (including installed rollback versions and active-session artifacts). CI reruns
that conflict fail rather than replacing an archive. A failed partial release is never latest.

`GAME_NATIVE_PUBLISHERS_FILE` now contains project UUID -> identity policy (NOT a secret):
`repository`, numeric-string `repository_id`, full caller `workflow_ref` at
`refs/heads/main`, and `job_workflow_ref` at a reviewed 40-character reusable workflow SHA.
Core verifies RS256 against the fixed GitHub issuer's HTTPS JWKS, audience
`burrow-native-builds`, validity, repo id, main push, caller/reusable identity, source SHA,
and run number. A caller's repo string is never proof. GitHub rotates signing keys; the
trust anchor is the fixed issuer/JWKS origin plus the pinned workload policy. Old static
publisher credentials are refused. This is a publisher-auth replacement, not a parallel UI.
The publisher obtains short-lived OIDC only in memory and sends it in Authorization.

Latest is selected atomically among fully validated immutable rows by signed workflow run
number, not finish time. Older finishing runs cannot overwrite a newer main build. Running
sessions retain their original stored manifest. Rollback installers can fetch an older build
by its immutable id without rewinding latest. A workflow replacement must preserve this
sequence or be explicitly migrated; do not silently reset its counter.

Private artifacts: authenticated channel readers with current repository access request
`GET /api/ext/play/browser/channels/:channel/builds/:build` and CSRF-protected
`POST .../assets/:artifact_index`. Core exchanges its repository-scoped asset credential
for GitHub's short-lived HTTPS asset URL and returns it with no-store/no-referrer headers.
`GAME_NATIVE_ASSET_CREDENTIALS_FILE` is a 0600 JSON map of repository -> read-only GitHub
App token/fine-grained credential; rotate it through the existing operator secret path.
No repository PAT is returned to a launcher/browser. The signed asset URL is a bearer
secret: do not put it in chat, logs or telemetry, and verify the manifest checksum after
fetch. GitHub controls actual URL expiry (the response's 60 seconds is the client reuse
limit, not a promise that GitHub revokes at exactly 60 seconds).

Unreal integration boundary: task 01a17b51 stage 3 owns play-host's BuildCookRun runner,
LFS handling, DDC cache and archive-and-launch. There are no Unreal scripts, fixture or
workflow jobs here. After that runner lands, a follow-up can pass its archive metadata
through `publish.py`: source SHA, engine identifier, platform/architecture/role, bytes,
SHA256, executable-relative path, immutable asset id, protocol/capacity and server image
digest. An open engine field proves metadata extensibility, not Unreal packaging/execution.

macOS packages use ad-hoc signing provided by Godot, with no generated signing key.
Public distribution without Gatekeeper friction requires the existing organization's
Developer ID Application identity and notarization credentials, held by its Apple Developer
account custodian (the organization must identify the custodian); no agent creates a signing key.

The reusable workflow source checkout is resolved from GitHub's `job_workflow_sha` claim,
not a caller-supplied tools branch. Attestation verification separately pins signer workflow
path AND signer commit digest and rejects self-hosted attestations; archives also require
nonempty PCK resources. The publisher does not accept traversal paths or symbolic links.

GitHub's attestation *index* rejects user-owned private repositories. The workflow therefore
uses the official `@actions/attest` library with `skipWrite: true`, signs using GitHub's
private Sigstore service, and retains `provenance.json` beside the private archives. It does
not make the repository public or skip signature verification. `gh attestation verify`
checks that bundle against the versioned `trusted_root.jsonl` (SHA256
`65ca537f6ed8a47fd0e560c421baa1f6c1efb8b25fc200d8c5c02c0e92eb2b9c`), retrieved with the
official CLI's TUF verification on 2026-11-07. Root rotation requires an explicit reviewed
update. The library and transitive security patch overrides are integrity-locked; no install
scripts run. Signing is ephemeral GitHub workload identity, not a new launcher signing key.

Before enabling main publication, the deployment operator configures repository variables
`BURROW_GAME_PROJECT_ID` and `BURROW_GAME_URL`, the corresponding core workload policy,
read-only private asset credentials, and host registry access for immutable server digests.
An unset destination fails publication; validation branches export and test but never alter
latest. This task does not infer a game project's cross-organization permission from the
Burrow task's project UUID or reuse a throwaway test project in production.
