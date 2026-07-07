# Guest meetings — enabling the feature

Guest join links land on a distinct public hostname (default `meet.example.com`,
override via `MEETING_GUEST_HOST` env var). Requirements:

- **DNS**: `<your-guest-host>` resolves to your Suite server's public IP
- **TLS**: your certificate covers `<your-guest-host>`
- **Reverse proxy**: routes `<your-guest-host>` to Suite's port 4000 WITHOUT auth middleware —
  guest ingress authenticates via HMAC-signed invite tokens, not OIDC/session

The exact reverse-proxy config depends on your platform (Traefik, nginx, Caddy, HAProxy).
Consult your platform's routing docs for host-based virtual-host setup.

## How guests join

1. Meeting host clicks "Copy guest link" in the meeting controls (host-gated UI)
2. Host optionally pre-fills a display name (skips guest name-entry gate)
3. Host copies + shares the resulting `https://<your-guest-host>/<slug>/<signed-token>` link
4. Guest opens link — either lands directly in the meeting (pre-provisioned name) or fills
   in a name form (self-entry). Token is minted on click, not at invite generation, so
   LiveKit key rotations don't invalidate outstanding invites
5. Guest appears in the participant rail with "(guest)" suffix + "via guest link" sub-line

## Security notes

- Invites expire after 24 hours by default (per-invite override possible)
- Guest tokens have 30-minute TTL — join session but not lingering credentials
- Guests can type any display name (no impersonation guard beyond the "(guest)" suffix)
- Each invite spawns an isolated per-invite chat space; guest chat/history stays out of the
  host's chat_space
