# LiveKit Webhook LAN Allowlist (Traefik)

Defence-in-depth network-layer allowlist for `POST /api/webhooks/livekit`.
Runs at the edge (Traefik) so untrusted sources never reach the BEAM.

## Context

The `/api/webhooks/livekit` endpoint is guarded by
`PlatformWeb.Plugs.VerifyLivekitSignature` (HS256 JWT + `sha256(body)`
claim, feature-flagged by `:livekit_webhook_signature_required`). That
plug is the source-of-truth guard.

This runbook adds a second gate at Traefik: only source IPs that are
plausibly LiveKit (or on the internal LAN, if self-hosted) can hit the
endpoint at all. If the JWT plug is ever mis-flagged (`false` in an env
where it should be `true`), the network allowlist keeps the blast radius
to trusted networks.

Phantom-fix v4 bug 3: prevents replay/probing traffic from
budget-untrusted networks from reaching webhook processing at all.

## Prereqs

You need the source CIDR to allow:

- **LiveKit Cloud**: log in to the LiveKit Cloud dashboard, open your
  project → Settings → Network → Egress IPs. Copy the listed
  `/32`s (or the region CIDR they publish).
- **Self-hosted on LAN**: use the internal CIDR the LiveKit server sits
  on. On the moon host this is typically the podman default bridge
  (`10.88.0.0/16`) plus the LAN (`192.168.1.0/24`).

Also note: Traefik on moon lives at `~/docker/traefik3/` and watches the
`rules/` directory for dynamic-config reloads.

## Traefik v3 Middleware

Add a new file `~/docker/traefik3/rules/livekit-webhook-allowlist.toml`:

```toml
# LAN + LiveKit Cloud egress allowlist for /api/webhooks/livekit.
# Attaches to the platform router; JWT plug remains as source-of-truth.

[http.middlewares]

  [http.middlewares.livekit-webhook-allowlist.ipAllowList]
    sourceRange = [
      # LiveKit Cloud egress IPs (replace with values from dashboard)
      "203.0.113.10/32",
      "203.0.113.11/32",

      # Self-hosted / LAN
      "10.88.0.0/16",
      "192.168.1.0/24",
    ]

    # Behind Cloudflare: trust the client-IP chain far enough back to
    # reach the real client, but exclude Cloudflare's own edges from
    # the allowlist calculation. See:
    # https://doc.traefik.io/traefik/middlewares/http/ipallowlist/
    [http.middlewares.livekit-webhook-allowlist.ipAllowList.ipStrategy]
      depth = 1
      # excludedIPs = ["173.245.48.0/20", "103.21.244.0/22", ...]

[http.routers]

  [http.routers.platform-livekit-webhook]
    entryPoints = ["websecure"]
    rule = "Host(`suite.example.com`) && PathPrefix(`/api/webhooks/livekit`)"
    service = "platform"
    middlewares = ["livekit-webhook-allowlist"]
    [http.routers.platform-livekit-webhook.tls]
      certResolver = "letsencrypt"
```

Notes:

- `depth = 1` means "trust the last hop of `X-Forwarded-For`". If
  Cloudflare fronts Traefik, either raise `depth` to reach past
  Cloudflare, or list Cloudflare's edge ranges in `excludedIPs` so
  they're skipped when picking the client IP.
- Keep this router **more specific** than the catch-all platform router
  so Traefik matches it first (`PathPrefix` beats the bare `Host` rule).
- The middleware name must match between `[http.middlewares]` and the
  `middlewares = [...]` array on the router.

## Reload

Traefik v3 dynamic config is file-watched. No restart required:

```bash
# Sanity-check Traefik is healthy before touching config.
podman exec traefik traefik healthcheck

# Drop the file in the watched rules dir.
cp livekit-webhook-allowlist.toml ~/docker/traefik3/rules/

# Confirm Traefik picked it up (no error in the last few log lines).
podman logs --tail=50 traefik | grep -iE 'livekit|error'
```

If Traefik rejects the config it logs an error and keeps the previous
snapshot live — the old routing stays in place, no downtime.

## Rollback

The JWT plug is the source-of-truth guard, so the network allowlist can
be removed without opening a hole:

```bash
# Option A: remove the middleware attachment, keep the middleware defined.
# Edit ~/docker/traefik3/rules/livekit-webhook-allowlist.toml and delete
# the `middlewares = ["livekit-webhook-allowlist"]` line from the router.

# Option B: nuke the file entirely.
rm ~/docker/traefik3/rules/livekit-webhook-allowlist.toml
```

Traefik reloads live. Requests immediately fall back to only the JWT
plug (still returns 401 for anything without a valid signature).

## Verification

From an off-LAN host (not in `sourceRange`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://suite.example.com/api/webhooks/livekit \
  -H 'Content-Type: application/webhook+json' \
  -d '{}'
# expected: 403   (Traefik denied at the edge)
```

From an on-LAN host (in `sourceRange`, no valid signature):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://suite.example.com/api/webhooks/livekit \
  -H 'Content-Type: application/webhook+json' \
  -d '{}'
# expected: 401   (Traefik allowed; JWT plug rejected)
```

Both 403 and 401 are correct outcomes. 403 proves the network layer is
enforcing; 401 proves the JWT plug is enforcing behind it.

## Related

- `apps/platform/lib/platform_web/plugs/verify_livekit_signature.ex` —
  the JWT plug this runbook layers on top of.
- `apps/platform/config/config.exs` —
  `:livekit_webhook_signature_required` feature flag.
- Traefik docs: <https://doc.traefik.io/traefik/middlewares/http/ipallowlist/>
