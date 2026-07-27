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
  — Onboard, recover, and offboard scoped external (SXI) chat users
  (Pocket-ID OIDC + pre-staged grants, admin recovery queue, archival).
- [`claude-channel-bridge-rollout.md`](claude-channel-bridge-rollout.md)
  — Roll the `system_event` envelope fix onto a `claude_channel` bridge, and
  read `mix platform.runtime_wake_report` (`proven` / `unproven` / `revoked`)
  without mistaking `unproven` for a defect count.
