# Runbooks

Ops-facing procedures for platform components. Each runbook is a
self-contained "how do I do X in production" doc — prereqs, commands,
rollback, verification.

## Index

- [`livekit_webhook_lan_whitelist.md`](livekit_webhook_lan_whitelist.md)
  — Traefik LAN allowlist middleware for `/api/webhooks/livekit`
  (defence-in-depth atop the JWT signature plug).
- [`livekit_key_rotation.md`](livekit_key_rotation.md)
  — Rotate `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` in production
  without a webhook-auth outage (flag-off interim path).
- [`github_webhook_secret.md`](github_webhook_secret.md)
  — Cutover, verification, and zero-gap rotation of the HMAC secret behind
  `/api/webhooks/github` (fail-closed as of task `019f9b11`).
- [`external_users.md`](external_users.md)
  — Onboard, recover, and offboard scoped external (Globex) chat users
  (Pocket-ID OIDC + pre-staged grants, admin recovery queue, archival).
- [`onboard_tenant_org.md`](onboard_tenant_org.md)
  — Add a new client org: the `/admin/orgs` form for the row, memberships,
  and the code change its scope-rail chip and colour ramp still need
  (task `019ffe9d`). Notes that the branch creates **no** org itself.
- [`claude-channel-bridge-rollout.md`](claude-channel-bridge-rollout.md)
  — Roll the `system_event` envelope fix onto a `claude_channel` bridge, and
  read `mix platform.runtime_wake_report` (`proven` / `unproven` / `revoked`)
  without mistaking `unproven` for a defect count.
- [`code-mode-experiment-rollout.md`](code-mode-experiment-rollout.md)
  — After the task `01a114a8` deploy: grant `code_mode`, create and start the
  `dispatch.code_mode` experiment for five agents, install the usage hook per
  host, the dsh and Oddjob follow-ups, and how to read `code_mode_report`.
- [`burrow-rename-deferred.md`](burrow-rename-deferred.md)
  — The ledger of `suite`-named identifiers the Burrow rename (task
  `01a14ba9`) keeps on purpose, each with its reason and removal condition.
