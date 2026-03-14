# Platform Target Contract

This document defines the reusable deployment contract for the Phoenix platform application in the public **Core** repository.

It describes the **shape** of a deploy target, not a real target instance.

Real target instances belong in the private **Core Ops** repository.

---

## Deployable artifact

Current application artifact:

- OCI image: `ghcr.io/startup-suite/core`
- container port: `4000`
- startup command: Phoenix release `bin/server`

The image is produced by Core CI.

---

## Required runtime contract

### Non-secret runtime values

These describe the target instance and may be stored in the private target repo if they are not sensitive:

- `PHX_SERVER` — must be `true` for release startup
- `PHX_HOST` — public hostname for endpoint URL generation
- `PORT` — internal container port (default `4000`)
- `DNS_CLUSTER_QUERY` — cluster DNS query value; blank is acceptable for single-node startup

### Secret runtime values

These must not be committed to the public repo:

- `SECRET_KEY_BASE` — required for Phoenix production boot

---

## Route metadata contract

A target instance should record route metadata for the live deployment:

- `DEPLOY_TARGET`
- `PUBLIC_FQDN`
- `PUBLIC_SCHEME`
- `UPSTREAM_SERVICE`
- `UPSTREAM_PORT`
- `HEALTHCHECK_URL`

---

## Promotion contract

A target instance should record the currently promoted artifact:

- `PLATFORM_IMAGE`
- `PROMOTION_CHANNEL`
- `PROMOTION_REF`

This lives in the private ops repo because it describes a real target instance.

---

## Expected private target layout

A real target instance should look like:

```text
targets/<target>/
├─ compose/
├─ env/
├─ overrides/
├─ releases/
└─ runbooks/
```

And the corresponding private secrets are expected at:

```text
secrets/<target>/
```

---

## LiveView-first posture

Core prefers Phoenix LiveView wherever possible.

That means the first deployment model should stay simple:

- Phoenix release in one container
- Traefik handles TLS and routing
- no separate SPA hosting layer required for first ship
- add more complex frontend delivery only when a surface truly needs it
