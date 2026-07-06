# LiveKit API Key + Secret Rotation

How to rotate `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` in production
without a webhook-auth outage.

## Context

`POST /api/webhooks/livekit` is guarded by
`PlatformWeb.Plugs.VerifyLivekitSignature`, which verifies an HS256 JWT
signed with `LIVEKIT_API_SECRET` and asserts a `sha256(body)` claim
(see `apps/platform/lib/platform_web/plugs/verify_livekit_signature.ex`
and `Platform.Meetings.verify_livekit_jwt/2`).

Because signing is single-secret, if we rotate `LIVEKIT_API_SECRET` in
the LiveKit dashboard and deploy the new value in one shot, there is a
narrow window where:

- LiveKit is signing webhooks with the **new** secret; but
- The BEAM is still running with the **old** secret loaded into
  `Application` env (until the deploy container swaps).

During that window, `verify_livekit_jwt/2` returns `{:error, ...}` and
the plug returns `401`. LiveKit retries on 5xx but not indefinitely on
4xx, so events (participant_joined, participant_left,
recording_finished, etc.) can be dropped.

The right long-term fix is `LIVEKIT_API_SECRET_SECONDARY` support —
verify with either primary or secondary during rotation — but that is
**out of scope for this task** (see Follow-up below).

Until that lands, use the flag-off interim path documented here.

## Sequence (interim path — this task's shipped version)

### 1. Generate the new key/secret in LiveKit Cloud

- Dashboard → project → Settings → API Keys → **New**
- Copy the new `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` into the
  ops vault (1Password: `Suite / LiveKit / prod`) as
  `LIVEKIT_API_KEY_PENDING` / `LIVEKIT_API_SECRET_PENDING`. Do **not**
  delete the old key yet.

### 2. Disable webhook signature enforcement on Suite prod

The flag lives in `apps/platform/config/config.exs`
(`:livekit_webhook_signature_required, true`) and is read at runtime via
`Application.get_env/3`. Override it by writing a small runtime override
into the running BEAM. On moon:

```bash
# Confirm the container is running with the pre-rotation secret.
ssh hive podman exec core-platform \
  /app/bin/platform rpc 'IO.puts(Application.get_env(:platform, :livekit_webhook_signature_required))'
# expected: true

# Flip the flag off (in-BEAM, no restart).
ssh hive podman exec core-platform \
  /app/bin/platform rpc \
  'Application.put_env(:platform, :livekit_webhook_signature_required, false)'

# Confirm the override took.
ssh hive podman exec core-platform \
  /app/bin/platform rpc 'IO.puts(Application.get_env(:platform, :livekit_webhook_signature_required))'
# expected: false
```

During the flag-off window, `verify_livekit_signature` logs at
`Logger.warning` level and passes the request through unauthenticated:

```
[LiveKit] Signature verification failed (reason=…) — passing through
because :livekit_webhook_signature_required is false
```

That log line is the visibility signal that the flag is off — grep
Grafana Loki (`{app="core-platform"} |= "passing through"`) to confirm
the override is live.

### 3. Deploy the new key/secret

Update the ops vault entries to promote `LIVEKIT_API_KEY_PENDING` /
`LIVEKIT_API_SECRET_PENDING` to `LIVEKIT_API_KEY` /
`LIVEKIT_API_SECRET`. Rotate the podman env file on moon, then bounce
the container:

```bash
ssh hive systemctl --user restart core-platform
```

Wait for the container to be healthy (`podman ps` shows `healthy` in
the STATUS column, ~10s):

```bash
ssh hive podman ps --filter name=core-platform \
  --format '{{.Names}} {{.Status}}'
```

At this point LiveKit signs with the new secret **and** the BEAM has
the new secret loaded — signatures match.

### 4. Re-enable the flag

```bash
ssh hive podman exec core-platform \
  /app/bin/platform rpc \
  'Application.put_env(:platform, :livekit_webhook_signature_required, true)'

# Confirm.
ssh hive podman exec core-platform \
  /app/bin/platform rpc 'IO.puts(Application.get_env(:platform, :livekit_webhook_signature_required))'
# expected: true
```

The `passing through` log line should stop appearing in Loki within a
few seconds.

### 5. Verify signed traffic

From any host with the new secret, send a signed test webhook. The
helper `Platform.Test.LivekitHelpers.sign_livekit_payload/2` (in
`apps/platform/test/support/livekit_test_helpers.ex`) is the reference
signer; for an ops-side verification, mirror its logic with a shell
one-liner:

```bash
NEW_SECRET='<from vault>'
BODY='{"event":"ping"}'
SHA=$(printf '%s' "$BODY" | openssl dgst -sha256 -binary | base64)
# JWT header/payload per Meetings.verify_livekit_jwt/2:
#   { "alg": "HS256", "typ": "JWT" } . { "sha256": "<SHA>" }
# Use joken / a scratch mix task if you don't want to hand-roll it.
# For a full working script, see:
#   apps/platform/test/support/livekit_test_helpers.ex
```

Then:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://suite.example.com/api/webhooks/livekit \
  -H 'Content-Type: application/webhook+json' \
  -H "Authorization: $JWT" \
  -d "$BODY"
# expected: 200
```

Also confirm a **wrong-secret** call now returns 401 (proving the flag
is back on):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://suite.example.com/api/webhooks/livekit \
  -H 'Content-Type: application/webhook+json' \
  -H "Authorization: Bearer bogus" \
  -d '{}'
# expected: 401
```

### 6. Delete the old key from LiveKit

Only after several minutes of successful signed webhook traffic
(watch the `passing through` log absence in Loki + at least one real
`participant_joined` or `participant_left` handled without a 401 in the
Traefik access log), delete the old key from the LiveKit dashboard.

## Rollback

If the new secret misconfigures (e.g. wrong value pasted, wrong key
selected, dashboard rotation half-completed):

```bash
# 1. Flip the flag off (buys quiet during rollback).
ssh hive podman exec core-platform \
  /app/bin/platform rpc \
  'Application.put_env(:platform, :livekit_webhook_signature_required, false)'

# 2. Restore the OLD LIVEKIT_API_KEY / LIVEKIT_API_SECRET from the vault
#    into the podman env file. (The pre-rotation values you promoted
#    "OUT" to `_PREVIOUS` before step 3 above.)

# 3. Bounce.
ssh hive systemctl --user restart core-platform

# 4. Confirm healthy, then re-enable the flag.
ssh hive podman exec core-platform \
  /app/bin/platform rpc \
  'Application.put_env(:platform, :livekit_webhook_signature_required, true)'
```

**Vault hygiene:** during step 3 of the main sequence, promote the old
values to `LIVEKIT_API_KEY_PREVIOUS` / `LIVEKIT_API_SECRET_PREVIOUS`
before overwriting. Keep them for 24h so rollback is one paste, not a
LiveKit-dashboard round-trip.

## Follow-up (out of scope for this task)

The interim flag-off window is small but not zero. File a task to add
`LIVEKIT_API_SECRET_SECONDARY` support to
`Platform.Meetings.verify_livekit_jwt/2`:

- Read both `LIVEKIT_API_SECRET` and `LIVEKIT_API_SECRET_SECONDARY`
  from runtime env.
- In `verify_livekit_jwt/2`, try the primary first, then the secondary
  on `{:error, :signature_error}`. Return `:ok` on either match.
- Rotation becomes: deploy secondary → LiveKit rotates dashboard key →
  promote secondary to primary → drop secondary. No flag-off window.

Once that lands, this runbook can be shortened to the primary/secondary
swap and the flag-off interim path deleted.

## Related

- `apps/platform/lib/platform_web/plugs/verify_livekit_signature.ex` —
  the plug this rotation targets.
- `apps/platform/lib/platform/meetings.ex` — `verify_livekit_jwt/2`.
- `apps/platform/test/support/livekit_test_helpers.ex` —
  `sign_livekit_payload/1,2` reference signer, importable in tests and
  usable as a template for ops-side signed curl.
- `apps/platform/config/config.exs` — flag default
  (`:livekit_webhook_signature_required, true`).
- [`livekit_webhook_lan_whitelist.md`](livekit_webhook_lan_whitelist.md)
  — Traefik LAN allowlist that runs in front of the JWT plug; leave it
  in place during rotation.
