# LIVEKIT env vars in dev-platform containers

The dev BEAM containers spawned by `spawn-dev-on-test-host.sh` now inherit
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, and `LIVEKIT_URL` from the
production secrets files on test-host.

This allows `Platform.Meetings.generate_token/2` to succeed inside dev
containers, which is required for any e2e exercise of a real LiveKit
join (camera, second-window, screen share, etc.).

## Where the change lives

- Source-of-truth: build-host repo (`example/build-host`), commit `6feeaa4`,
  file `stacks/apps/dev-on-test-host/spawn-dev-on-test-host.sh`.
- Production cron mirror: `~/cron/spawn-dev-on-test-host.sh`
  (hand-synced from the build-host source; not under git).

## Source files on test-host

- `~/core-ops/secrets/test-host-production/platform.secrets.env` —
  `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
- `~/core-ops/targets/test-host-production/env/platform.shared.env` —
  `LIVEKIT_URL`.

## Verifying

```
~/cron/spawn-dev-on-test-host.sh <slug>
ssh deploy@test-host "podman exec dev-platform-<slug> printenv | grep '^LIVEKIT_'"
# expect three non-empty lines
```
