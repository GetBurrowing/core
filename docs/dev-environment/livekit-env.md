# LIVEKIT env vars in dev-platform containers

The dev BEAM containers spawned by `spawn-dev-on-moon.sh` now inherit
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, and `LIVEKIT_URL` from the
production secrets files on moon.

This allows `Platform.Meetings.generate_token/2` to succeed inside dev
containers, which is required for any e2e exercise of a real LiveKit
join (camera, second-window, screen share, etc.).

## Where the change lives

- Source-of-truth: hive repo (`rowanellis/hive`), commit `6feeaa4`,
  file `stacks/apps/dev-on-moon/spawn-dev-on-moon.sh`.
- Production cron mirror: `/home/dev/cron/spawn-dev-on-moon.sh`
  (hand-synced from the hive source; not under git).

## Source files on moon

- `/srv/dev/core-ops/secrets/moon-production/platform.secrets.env` —
  `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
- `/srv/dev/core-ops/targets/moon-production/env/platform.shared.env` —
  `LIVEKIT_URL`.

## Verifying

```
~/cron/spawn-dev-on-moon.sh <slug>
ssh dev@build-host.local "podman exec dev-platform-<slug> printenv | grep '^LIVEKIT_'"
# expect three non-empty lines
```
