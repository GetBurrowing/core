# YouTube publication-list work

`SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED` controls only the external YouTube
publication-list worker and its list client. It is disabled by default.
Only `true` (trimmed, case-insensitive) enables it; missing, blank, false
or invalid values disable it at Social application startup. Invalid values
produce a fixed warning without printing the supplied value.

Existing post analytics, follower analytics, shared pacing and installation-wide
Retry-After remain active under their existing configuration. This switch does
not clear cached observations, scan progress, allowance/rotation or binding
invalidation. Enabled work retains the shared one-reserved-request-per-org-per-60-
seconds allowance for discovery, pagination, backfill and refresh. Skipped or
busy reservations are not refunded.

## Operator procedure (requires separate activation authority)

The installation environment file is the source of truth. To enable an
authorized installation, persist `SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED=true`
in that installation's environment, perform the planned restart, and read
the effective value inside the running release:

```sh
bin/platform rpc 'IO.inspect(Platform.Social.PublicationSync.enabled?())'
```

For a rapid stop, these are separate operations, not an atomic pair:

1. Set the application value off by RPC in each running container that can
   perform this work, then read back its effective value:

```sh
bin/platform rpc 'Application.put_env(:social, :youtube_publications_enabled, false); IO.inspect(Platform.Social.PublicationSync.enabled?())'
```

2. Persist `SOCIAL_YOUTUBE_PUBLICATIONS_ENABLED=false` in the installation
   environment and verify that saved value.

Report each operation's outcome. If persistence fails after RPC succeeds,
report that the running process is off but a restart may re-enable it. If
the file is off but RPC fails, the running process may still be enabled.
If effective-value verification fails, report the runtime state as unverified;
neither a saved file nor an RPC response alone proves the complete stop.
Likewise, report partial enable states when persistence, restart or read-back
fails. Do not describe a partial result as enabled or stopped successfully.

RPC-only state does not survive a restart. Account for every container that
reads the installation file, including experimental containers. Do not put
an installation-specific opt-in into configuration consumed by other installs.

Before a later activation, enumerate every container inheriting the value,
its application role and whether it runs the analytics worker. Establish
those roles by read-only inspection; do not infer that an experimental
container cannot request data. Effective-setting read-back and the rapid-stop
procedure must cover every request-capable process, not just the primary
container. A container count alone is not evidence of worker coverage.
Check every configured recipient on each enable/stop, including currently
inactive units that could start later. If a running request-capable process
cannot be reached or its effective value cannot be verified, the stop is
incomplete. Persist false so a later start reads the disabled value.

The durable allowance is shared per org in the installation database, not
per container. Multiple workers do not create separate publication quotas.
This procedure neither disables units nor adds cluster-control machinery.

Disabling blocks new worker admission and is checked again after pacing and
at publication-list dispatch. An HTTP request already past its final check
can finish and persist its response; this is not cancellation. A reservation
already committed before the stop is retained, without refund. Re-enabling
resumes valid progress under existing allowance, binding and backoff checks.

## Cached display

Authorized viewers can still see retained observations while disabled,
labelled **YouTube updates are off**. Cached native-video links, views, coverage
limits, vendor last-sync time and local fetch provenance remain visible.
Unknown metrics remain unknown. Empty caches do not trigger a request, and
repair history does not promise an active scan while disabled. Existing pages
pick up the setting on their next state-changing render (or reload); the switch does not broadcast
a page refresh. Other analytics display is unchanged.

This document authorizes no activation, measurement request, cache import,
posting action or whole-image rollback. The existing whole-analytics switch
remains an emergency option rather than this feature's normal stop procedure.
