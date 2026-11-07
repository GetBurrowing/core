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

## Runtime setup (Dalton / Ryan-owned operators)

Use a dedicated native play-host runtime credential, provisioned through existing federation
onboarding. Keep its token in the ordinary `token_file`. Native `serve -config` example:

```json
{
  "burrow_url": "wss://BURROW/runtime/ws",
  "runtime_id": "moon-native",
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

Only Dalton changes moon container/UDP/DNS/firewall setup, on a separate port pool from stream
WebRTC. Record actual mapping and demonstrate ENet from a second network; DNS alone is not
reachability evidence. Existing public Voltron 24972 must remain untouched. Stage 1 proved
DO :24973 plus Windows LEFT and moon RIGHT; that is not proof of this provider's container.
Stage 2 deployment/test evidence must identify its own image digest and native host revision.

## Build publisher identity

`GAME_NATIVE_PUBLISHERS_FILE` points to 0600 JSON mapping project UUID to SHA256 of its CI
publisher credential. CI stores the raw credential in its repository secret, sends it only
as Authorization bearer to POST `/api/ext/play/builds/:project_id`. It cannot publish another
project. Manifests bind id/repo/engine/protocol/capacity/server-image digest. Existing IDs are
immutable and conflicting content is rejected. Native build packaging is stage 3, Godot first;
Unreal will reuse the shared play-host runner rather than a second packager.
