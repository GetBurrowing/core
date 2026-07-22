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
- [`external_users.md`](external_users.md)
  — Onboard, recover, and offboard scoped external (SXI) chat users
  (Pocket-ID OIDC + pre-staged grants, admin recovery queue, archival).
