# Install Manifest (schema v1)

This document is the field-by-field reference for the **install manifest** defined by
[ADR 0053](../../docs/decisions/0053-install-manifest-and-renderers.md). It sits next to
[`platform-target-contract.md`](platform-target-contract.md), which it extends: that contract
names the runtime values core-platform needs, and the manifest is what now produces them.

One manifest describes **one Burrow install for one customer**. It covers infrastructure only:
domain, TLS, service set, model endpoints, auth, backup, size, GPU and images. Per-install
behaviour (orgs, agents, prompts, feature settings) stays in the admin panel.

- Format: TOML. `tomllib` parses it with the Python standard library, so no pip step is needed.
- Validator: `PYTHONPATH=deployment/installer python3 -m burrow_install validate <manifest>`
- Service set: `PYTHONPATH=deployment/installer python3 -m burrow_install services <manifest>`
- Examples: [`single-host.install.toml`](../examples/single-host.install.toml)
  (target `single-host`), [`mac.install.toml`](../examples/mac.install.toml) and
  [`mac-lite.install.toml`](../examples/mac-lite.install.toml) (target `mac`, meetings on and off)

Every key the manifest may contain is listed below. Any other key, at any depth, is an error
(`unknown_key`, or `unknown_service` under `[services]`). This means a misspelled knob fails
validation instead of silently keeping its default.

---

## Top level

| Key | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | integer | yes | Must be `1`. Anything else, or a missing value, gives `unsupported_schema_version`, and nothing else is checked. |

## `[install]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | `[a-z][a-z0-9-]{0,62}`. Names the install; becomes `DEPLOY_TARGET`. |
| `size_tier` | `small` \| `medium` \| `large` | `small` | Sizing hint for renderers (VM size, pool sizes). |
| `target` | `single-host` \| `mac` | `single-host` | Which renderer the manifest is for (task 01a0d6ab). The validator applies that target's rules; `render --target`, if given, must match (`target_mismatch`). |
| `hosted` | bool | `false` | An install we provision. Requires a backup target; see `[backup]`. |
| `org_name` | string | none | The root org's display name (core task 01a10315). Rendered into core-platform's env as `ROOT_ORG_NAME`, a plain env line (not a secret). core reads it only at FIRST migrate (`seed_root_orgs`), so it names the org of a fresh install; without it the root org is "Root Org". 1-80 printable characters, no newline, no leading or trailing space and none of `"`, `$` or a backtick, else `invalid_org_name`. |
| `modules` | array of strings | `[]` | Build-time modules ([ADR 0055](../../docs/decisions/0055-extension-contract-and-build-time-modules.md)). Each entry must be a known module (`unknown_module`), listed once (`invalid_value`). Known modules: `play`. The set picks the core image flavour: `[]` runs `<registry>/core:core`, `["play"]` runs `<registry>/core:play` (legacy `image_namespace`: `suite-core:core` / `suite-core:play`). A module is compiled into the core image, so this changes nothing else in the render. See [`install-modules.md`](install-modules.md). |

## `[domain]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `primary` | string | required | Public FQDN of the install. Missing gives `missing_domain`. A value that is not a DNS name (IP literal, single label, trailing dot, bad label) gives `invalid_domain`. Auth is served at `auth.<primary>`. |
| `tls` | `acme` \| `internal` | `acme` | `acme` uses a public CA. `internal` uses a private root generated on the host, for throwaway or LAN installs. |
| `acme_email` | string | none | Required iff `tls = "acme"` (`acme_email_required`). Rejected with `tls = "internal"` (`field_not_applicable`). |
| `auth_host` | string | `auth.<primary>` | Where pocket-id is served. Must be a DNS name other than `primary`. Lets a non-apex primary use a flat name (Cloudflare Universal SSL covers one label below the zone). |
| `livekit_host` | string | `livekit.<primary>` | LiveKit signalling (meetings only). Same rules as `auth_host`. |

On `target = "mac"` TLS ends at the tunnel's or the tailnet's edge, so `tls` and `acme_email`
are `field_not_applicable` there and no `acme_email` is needed.

## `[host]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `gpu` | bool | `false` | The host has an NVIDIA GPU usable by containers. |
| `ssh_authorized_key` | string | none | One OpenSSH public key, emitted as top-level cloud-config `ssh_authorized_keys: [<key>]` for the cloud image's default user (core task 01a10315): the customer's optional power-user path. Must match `^(ssh-ed25519\|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+( [^\n]*)?$` (one key, optional comment), else `invalid_ssh_authorized_key`. `target = "single-host"` only (`field_not_applicable` on `mac`, which has no cloud-init). |

## `[services]`

core-platform, postgres and the Caddy edge are implicit and cannot be turned off. The five keys
below are the whole vocabulary. Any other key gives `unknown_service`. Each target runs a subset:
`single-host` runs `files`, `memory`, `voice`, `embeddings`; `mac` runs `files`, `memory`,
`meetings`.

| Key | Type | Default | Container | Notes |
|---|---|---|---|---|
| `files` | bool | `false` | `files-service` | File storage and extraction. |
| `memory` | bool | `false` | `memory-service` | Needs `embeddings = true` (`memory_requires_embeddings`). |
| `voice` | bool | `false` | `speaches` | Speech-to-text and text-to-speech. See `[voice]`. |
| `embeddings` | bool | `false` | `embeddings` (only in `mode = "local"`) | The embeddings capability. See `[embeddings]`. On `mac`: `mac_local_embeddings_unsupported`. |
| `meetings` | bool | `false` | `livekit` (+ `meeting-transcriber` with `[meetings] transcription`) | `mac` only in v1 (`field_not_applicable` on `single-host`). See `[meetings]`. |

On `mac`, `voice = true` is `mac_voice_unsupported` (no local speech model), and memory needs a
hosted embeddings endpoint (`hosted_embeddings_required`) instead of `services.embeddings`.

A table for a service that is off (`[voice]` while `voice = false`) is allowed and ignored. Its
internal consistency is still checked, so turning the service on later is a one-field change.

## `[voice]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `accelerator` | `cpu` \| `cuda` | `cpu` | `cuda` with `services.voice = true` needs `host.gpu = true` (`gpu_required`). |

## `[embeddings]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `mode` | `local` \| `endpoint` | `local` | `local` runs the embeddings container. `endpoint` uses a remote OpenAI-compatible embeddings API and runs no container. |
| `base_url` | string | none | http(s) URL. Required iff `mode = "endpoint"` (`embeddings_endpoint_required`). Otherwise `field_not_applicable`. |
| `api_key_ref` | string | none | Secret ref (see below). Only with `mode = "endpoint"`. Rendered as a 0600 file `secrets/<REF>` mounted into memory-service alone (`MEMORY_EMBEDDING_API_KEY_FILE`, memory-service 2ef3312f). |
| `model` | string | none | Only with `mode = "endpoint"`. `MEMORY_EMBEDDING_MODEL`; unset keeps the literal `embeddings`. Required on `mac`. |
| `query_prefix` | string | none | Only with `mode = "endpoint"`. Unset keeps memory-service's BGE query prefix; `""` sends queries unprefixed (hosted OpenAI). |

`base_url` for memory-service has no `/v1` suffix: memory-service appends `/v1/embeddings`.

## `[[models.endpoints]]`

An install has **no model endpoint unless its owner declares one**. There is no default endpoint
of ours. `local`, `hosted` and `byo` are equally first-class. Agent runtimes are not configured
here; they federate in through the admin panel and runtime registration.

| Key | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | `[a-z][a-z0-9-]{0,62}`, unique across endpoints (`duplicate_endpoint_name`). |
| `kind` | `local` \| `hosted` \| `byo` | yes | `local`: runs on the customer's hardware. `hosted`: a provider API. `byo`: any endpoint the customer brings. |
| `base_url` | string | yes | http(s) URL. |
| `api_key_ref` | string | no | Secret ref. |

## `[auth]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `mode` | `bundled-pocket-id` \| `external-oidc` | `bundled-pocket-id` | Bundled mode runs the `pocket-id` container at `auth.<primary>`. |
| `issuer` | string | none | https URL. For external mode. |
| `client_id` | string | none | For external mode. |
| `client_secret_ref` | string | none | Secret ref. For external mode. |

External mode needs all three of `issuer`, `client_id` and `client_secret_ref`. If any is missing, the result is one `external_oidc_incomplete` error listing them. In bundled mode, all three are `field_not_applicable`.

## `[backup]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `target` | `none` \| `local-path` \| `s3-compatible` | `none` | |
| `path` | string | none | Absolute path. Required for `local-path`. |
| `bucket`, `endpoint`, `access_key_ref`, `secret_key_ref` | string | none | Required for `s3-compatible`. `endpoint` is an http(s) URL. |
| `region` | string | none | Optional, `s3-compatible` only. |
| `keep` | int | `14` | Retention: the newest `keep` nightly snapshots survive. |
| `hosted_opt_out` | bool | `false` | Hosted installs only: run without backups on purpose. Contradicts any target but `none`. |

A target other than `none` makes the single-host renderer emit a nightly systemd timer (`burrow-backup.timer`) that runs `bin/burrow-backup`: a `pg_dump -Fc` of every database in `core-postgres`, a tar snapshot of each data volume (`core-data`, and `agent-homes` or the host `/home` when native agents run), and retention. `bin/burrow-restore-drill <backup dir>` restores the newest snapshot into a throwaway postgres and a temp dir and prints `restored <db> <rows>`. `s3-compatible` credentials are secret refs read from `customer-secrets.env`; no rendered file other than that one holds a value. The job writes `backup-status.json` (last success time, size) into the `core-data` volume for `admin_health`.

`install.hosted = true` marks an install we provision. With no `[backup] target` it defaults to `local-path` at `/var/backups/burrow`, and `target = "none"` is `backup_required_hosted` unless `hosted_opt_out = true`.

A missing required field gives one `backup_incomplete` error. A field the target does not use gives `field_not_applicable`.

## `[images]`

| Key | Type | Default | Notes |
|---|---|---|---|
| `registry` | string | **required** (or the legacy `image_namespace`), no default | The registry path the Burrow images come from, e.g. `ghcr.io/<owner>`: `<registry>/core` (tag = flavour, `core` or `play`), `<registry>/files-service:latest`, `<registry>/memory-service:latest`, `<registry>/meeting-transcriber:latest` and `<registry>/burrow-agent-host:latest`. A registry host (with a dot, or `localhost`; optional port) and at least one lowercase path component, no scheme, tag or trailing `/`, else `invalid_value`. A default would name one publisher. Set exactly one of `registry` and `image_namespace`: neither is `missing_required` at `images.registry`, both is `invalid_value` at `images.image_namespace`. **meeting-transcriber has no published build under a registry yet** (measured 2026-10-18: it publishes only on a `v*` tag and has no GHCR package), so a `registry` manifest that runs it (`services.meetings` with `[meetings] transcription = true`) must pin `refs.meeting-transcriber` (`missing_required` otherwise), or use the legacy key. GHCR packages are private: `images.source = "registry"` needs a credential with an `auths["ghcr.io"]` entry. |
| `image_namespace` | string | LEGACY, deprecated | The Docker Hub namespace of the images every install used before task 01a14dd8, rendered unchanged: `docker.io/<image_namespace>/suite-core`, `suite-files-service`, `suite-memory-service`, `suite-meeting-transcriber` and `suite-agent-host`. Still accepted; `validate` (and every command that reads a manifest) prints `warning deprecated at images.image_namespace: ...` on stderr. One that is not a Docker Hub namespace is `invalid_value`. Its credential is `auths["https://index.docker.io/v1/"]`. |
| `source` | `registry` \| `preloaded` | `registry` | `preloaded`: images are loaded onto the host out of band, and nothing is pulled. |
| `refs.<container>` | string | registry default | Per-container image override. The keys are container names: `caddy`, `cloudflared`, `core-platform`, `core-postgres`, `embeddings`, `files-service`, `livekit`, `meeting-transcriber`, `memory-service`, `pocket-id`, `speaches`, `agent-host`, `tailscale-auth`, `tailscale-livekit`, `tailscale-primary`. The `core-platform` default is the flavour `install.modules` selects; an override replaces it, so a pinned ref must be a build of the same flavour (for example `core:play-<sha>` with `modules = ["play"]`). |

## `[access]` (target `mac` only)

| Key | Type | Default | Notes |
|---|---|---|---|
| `mode` | `cloudflare-tunnel` \| `tailscale` | `cloudflare-tunnel` | How the public hostnames reach the Mac. TLS ends at that edge, whose certificate chains to a public root. |
| `tunnel_token_ref` | string | none | Secret ref of the remotely-managed tunnel's token (`TUNNEL_TOKEN` for `cloudflared`). Required with `cloudflare-tunnel` (`tunnel_token_ref_missing`). |
| `tailscale_authkey_ref` | string | none | Secret ref of a reusable Tailscale auth key, shared by the per-hostname sidecars. Required with `tailscale` (`tailscale_authkey_ref_missing`). With tailscale, `primary`, `auth_host` and `livekit_host` are ts.net names; each sidecar's `TS_HOSTNAME` is the first label. |

On `single-host` any `[access]` key is `field_not_applicable`.

## `[meetings]` (`services.meetings = true` only)

Ignored while `services.meetings` is off, so flipping meetings back off is a one-field change.

| Key | Type | Default | Notes |
|---|---|---|---|
| `media_reach` | `lan` \| `tailnet` \| `public` | none | Required (`meetings_media_reach_required`). Where LiveKit's single-port media listeners (7881/tcp, 7882/udp, the only host ports the `mac` target publishes) are reachable from. `lan`: `rtc.node_ip` is the machine's LAN address. `tailnet`: the host's Tailscale address. `public`: `use_external_ip` (STUN at boot; needs a router forward of both ports). |
| `node_ip` | string | detected | IPv4. Pins `rtc.node_ip` for `lan`/`tailnet`; detected at render time when unset (a failed detection is `media_ip_undetected`, never a silent fall-back to public). `field_not_applicable` with `public`. |
| `media_host` | string | none | `public` only, optional. A DNS-only (grey-cloud) A record, e.g. `media.example.com`, that the setup CLI's `ddns` job (task 01a0d6ab stage 4) keeps pointed at this machine's public IP. LiveKit itself needs no hostname for media (ICE uses the STUN-learned IP). |
| `transcription` | bool | `false` | Adds `meeting-transcriber`. |
| `stt_endpoint` | string | none | With `transcription`: the `name` of a `[[models.endpoints]]` entry speaking OpenAI-compatible `/audio/transcriptions` (`stt_endpoint_unknown` otherwise). Its `base_url` ends at `/v1`. |
| `stt_model` | string | `whisper-1` | The transcriber's `STT_MODEL`. |

TURN/TLS on 443 is not rendered (it needs its own hostname, certificate and a direct inbound 443).
Agent voice in meetings (burrow-voice-worker) is not part of the `mac` target in v1.

## `[day2]` (reserved)

These keys are validated but not yet acted on. ADR 0053 names the follow-up work that will use them.

| Key | Type | Default |
|---|---|---|
| `upgrade_channel` | `stable` \| `edge` \| `pinned` | `stable` |
| `phone_home` | bool | `false` |

## `[agents]` (native agents, target `single-host`)

The capability profile of the install's native agents (core task 01a10322). It is install
config, realised by packaging: core never branches on it, and only displays the profile the
agent host reports.

| Key | Type | Default | Notes |
|---|---|---|---|
| `profile` | `full_machine` \| `contained` \| `off` | `full_machine` when the table is present, `off` when it is absent | A manifest without `[agents]` renders exactly as it did before the table existed. On `target = "mac"` any profile other than `off` is `field_not_applicable`. |
| `login` | `api_key` \| `operator` | `api_key` | How native agents log in to Claude (core task 01a17b10). Rendered into core-platform's env as `NATIVE_AGENT_LOGIN` whenever the profile is not `off`. `operator`: core sends no API key and a person attaches to the agent's pane to log in to Claude Code there (services/agent-host/README.md, "Operator login"). |
| `full_root` | bool | `false` | Lets the `admin_restart`, `admin_deploy` and `admin_rollback` tools act (core task 01a17b10). Off: nothing is mounted and those tools return `requires_full_root` naming `agents.full_root`. On, `contained`: exactly one mount, the container runtime socket, into the agent-host container, plus `AGENT_HOST_FULL_ROOT=true`. On, `full_machine`: no mount (the host is already root); the host env file gets `AGENT_HOST_FULL_ROOT=true`. The host advertises `full_root` in its hello. Ignored when `profile = "off"`. Note: `admin_rpc` evaluates code in the running core release and is NOT gated by this key. |

- **`full_machine`** (the default for a VM we provision): the agent host is a root systemd
  service on the HOST. The render adds to `user-data` the tools (tmux, git, curl, cron; node,
  bun, Claude Code, Codex and suite-cli at the versions pinned in
  `services/agent-host/versions.env`; chromium as a snap), `burrow-agent-host.service`, the
  `burrow-agent@.service` template, a first-boot setup unit (`burrow-agent-host-setup.service`,
  `bin/burrow-agent-host-setup`) that copies the daemon out of the agent-host image,
  `/etc/burrow-agent-host.env` (0600 root) and `/etc/sudoers.d/burrow-agents`
  (`%burrow-agents ALL=(ALL) NOPASSWD:ALL`, mode 0440). Agents reach core at the install's public
  URL through Caddy; with `tls = "internal"` the install root is added to the system trust store.
- **`contained`** (shared hosts): the agent host is the `agent-host` container
  (`<registry>/burrow-agent-host`, systemd as PID 1) on a dedicated `agents` network.
  `core-platform` is the only service on both networks, so the agent host reaches core and the
  internet and not Postgres or any other service. It reads its own `agent-host.env` (0600, only
  `AGENT_HOST_TOKEN`), not `secrets.env`. Under DOCKER (this renderer) the container needs the
  host cgroup namespace for systemd, so it is network and filesystem containment, not a privilege
  boundary; under rootless podman (test-host, see core-ops) container root is not host root.
- Both: `AGENT_HOST_TOKEN` is generated and given to core-platform through `secrets.env`.

**Isolation limit (option A).** An install is one trust group. Per-agent OS users stop
accidental crossing, not malicious crossing. On `full_machine` an agent with sudo is root over
the whole install: other agents' homes, env files and tokens, and core-platform's `secrets.env`
and Postgres through docker. On `contained` an agent is root over the agent container (every
agent's home), not over the host or Postgres.

## `[push]` (Web Push)

| Key | Type | Default | Notes |
|---|---|---|---|
| `vapid` | `off` \| `generate-on-host` | `off` | `off` renders nothing. `generate-on-host` (core task 01a10315) adds `bin/burrow-vapid` (mode 0755) and an `ExecStartPre=/opt/burrow/bin/burrow-vapid` line to `burrow-stack.service`, before compose up, and adds `openssl` to the cloud-init packages. `target = "single-host"` only (`vapid_requires_single_host` on `mac`). |

`bin/burrow-vapid` is idempotent: if `secrets.env` already has a `VAPID_PUBLIC_KEY=` line it
exits 0. Otherwise it generates a P-256 key with `openssl ecparam -name prime256v1 -genkey
-noout` and appends `VAPID_PUBLIC_KEY=` (the 65-byte uncompressed point, leading `0x04`) and
`VAPID_PRIVATE_KEY=` (the 32-byte raw scalar), both base64url without padding, to `secrets.env`,
which stays mode 0600. core-platform reads both from its env (`Platform.Push`). The keys are made
on the host because Python's standard library cannot generate EC keys, and a key made there never
passes through whoever rendered the install: no render, golden or provisioner holds it.

---

## Secret refs

A field ending in `_ref` holds the **name** of a secret, never its value. The name is
`UPPER_SNAKE_CASE`, and a string that is not a name gives `invalid_value`. Customer-supplied values
are provided at render time, never in the manifest. Secrets the install generates itself
(`SECRET_KEY_BASE`, database password, service tokens) have no manifest field at all.

## Error codes

The CLI prints `error <code> at <toml.path>: <message>`, one line per problem, and exits `2`.
A valid manifest prints `ok` and exits `0`.

| Code | Raised when |
|---|---|
| `unsupported_schema_version` | `schema_version` is missing or not `1` |
| `unknown_key` | a key outside this schema, at any depth |
| `unknown_service` | a `[services]` key other than `files`, `memory`, `voice`, `embeddings` or `meetings` |
| `unknown_module` | an `install.modules` entry other than `play` |
| `invalid_type` | a value of the wrong TOML type |
| `invalid_enum` | an enum value outside its allowed set |
| `invalid_value` | a malformed name, URL, email, path, secret ref or empty image ref, or a module listed twice |
| `missing_required` | `install.name` or an endpoint's `name`/`kind`/`base_url` is missing |
| `missing_domain` | `domain.primary` is missing |
| `invalid_domain` | `domain.primary`, `auth_host` or `livekit_host` is not a DNS name |
| `acme_email_required` | `tls = "acme"` without `acme_email` |
| `field_not_applicable` | a field that the selected mode or target does not use |
| `gpu_required` | voice on with `accelerator = "cuda"` and `host.gpu = false` |
| `memory_requires_embeddings` | `services.memory = true` with `services.embeddings = false` |
| `embeddings_endpoint_required` | `embeddings.mode = "endpoint"` without `base_url` |
| `external_oidc_incomplete` | `auth.mode = "external-oidc"` missing issuer, client_id or client_secret_ref |
| `backup_incomplete` | the backup target is missing a field it requires |
| `backup_required_hosted` | `install.hosted` with `backup.target = "none"` and no `hosted_opt_out` |
| `duplicate_endpoint_name` | two `[[models.endpoints]]` entries share a `name` |
| `mac_voice_unsupported` | `target = "mac"` with `services.voice = true` |
| `mac_local_embeddings_unsupported` | `target = "mac"` with `services.embeddings = true`, or an explicit `embeddings.mode = "local"` |
| `hosted_embeddings_required` | `target = "mac"`, memory on, without `[embeddings] mode = "endpoint"` carrying `model` and `api_key_ref` |
| `tunnel_token_ref_missing` | `target = "mac"`, `access.mode = "cloudflare-tunnel"` without `tunnel_token_ref` |
| `tailscale_authkey_ref_missing` | `target = "mac"`, `access.mode = "tailscale"` without `tailscale_authkey_ref` |
| `meetings_media_reach_required` | meetings on without `meetings.media_reach` |
| `invalid_org_name` | `install.org_name` is empty, longer than 80, not printable, padded, or has `"`, `$` or a backtick |
| `invalid_ssh_authorized_key` | `host.ssh_authorized_key` is not one `ssh-ed25519` / `ecdsa-sha2-nistp256` public key |
| `vapid_requires_single_host` | `push.vapid = "generate-on-host"` with `target = "mac"` |
| `stt_endpoint_unknown` | transcription on and `meetings.stt_endpoint` names no `[[models.endpoints]]` entry |
| `invalid_toml` | the file does not parse as TOML (loader) |
| `unreadable_manifest` | the file cannot be read (loader) |

A value that fails a type or enum check is treated as absent by the cross-field rules, and it
does not raise a second error. So one wrong field produces exactly one error line.

---

## Mapping from the platform target contract (ADR 0003)

| ADR 0003 contract field | Produced from |
|---|---|
| `PHX_SERVER` | Constant `true` (renderer). |
| `PHX_HOST` | `domain.primary` |
| `PORT` | Constant `4000` (renderer; internal only). |
| `DNS_CLUSTER_QUERY` | Blank: a single-host install is one node. |
| `SECRET_KEY_BASE` | Generated at render time; no manifest field. |
| `DEPLOY_TARGET` | `install.name` |
| `PUBLIC_FQDN` | `domain.primary` |
| `PUBLIC_SCHEME` | Constant `https`; both `tls` modes terminate TLS at Caddy. |
| `UPSTREAM_SERVICE` | Constant `core-platform` (registry). |
| `UPSTREAM_PORT` | Constant `4000`. |
| `HEALTHCHECK_URL` | `https://<domain.primary>/health` |
| `PLATFORM_IMAGE` | `images.refs.core-platform`, else the flavour of `install.modules` (`<registry>/core:core` or `<registry>/core:play`). |
| `PROMOTION_CHANNEL` | `day2.upgrade_channel` (reserved; not yet acted on). |
| `PROMOTION_REF` | Not produced: promotion state is private instance state (ADR 0003 §4). |

The manifest also produces values that ADR 0003 predates, and that the renderer (stage 2 of task
01a0d69d) records against their consumers:

- `MEMORY_SERVICE_URL` and `FILES_SERVICE_URL`. Core treats an unset value as the feature being
  off: `apps/platform/config/runtime.exs`, around the `System.get_env("MEMORY_SERVICE_URL")` and
  `System.get_env("FILES_SERVICE_URL")` reads.
- The `OIDC_*` values.

## Rendering

`python3 -m burrow_install render <manifest> --out <dir>` writes one install. Run it with
`PYTHONPATH=deployment/installer`. The target is the manifest's `install.target`; `--target`, if
given, must match it (`target_mismatch`). The service semantics live in
`burrow_install/registry.py`, and each target adds its own output layer (`templates.py` for
`single-host`, `mac.py` for `mac`).

`single-host` writes these files to `--out`:

| File | Mode | Notes |
|---|---|---|
| `compose.yaml` | 0644 | No secret literal. Containers that need secrets read `secrets.env` through `env_file`. |
| `Caddyfile` | 0644 | One site per route. `tls = "internal"` signs with a root that the host generates at first boot. |
| `secrets.env` | 0600 | Holds the generated secrets and the customer secrets that a container reads. |
| `customer-secrets.env` | 0600 | Written only when a customer secret is supplied that no container reads yet. |
| `services.txt` | 0644 | Same as `burrow_install services`. |
| `postgres-init/*.sql` | 0644 | Init SQL declared by the enabled services. |
| `models.json` | 0644 | Written only when `[[models.endpoints]]` is declared. |
| `agent-host.env` | 0600 | `[agents] profile = "contained"` only: the agent-host container's `AGENT_HOST_TOKEN`, and nothing else. |
| `user-data` | 0600 | `#cloud-config` for Ubuntu 24.04. Carries every file above plus `burrow-stack.service` (the install lives under `/opt/burrow`), and with `[agents] profile = "full_machine"` the agent host's units, setup script, env file and sudoers file. |
| `meta-data` | 0644 | NoCloud instance id. |
| `registry-auth.json` | 0600 | Written only with `--registry-auth`. |

Options:

- `--reuse-secrets <secrets.env>` keeps the values an earlier render generated, and drops the
  secrets of services that are now off.
- `--customer-secrets <file>` supplies each `*_ref` value, one `NAME=value` per line.
- `--registry-auth <config.json>` is required when `images.source = "registry"` pulls a private
  default image.

`mac` writes `compose.yaml`, `Caddyfile` (`auto_https off`, one `http://<host>` site per
route, `trusted_proxies static private_ranges`, a 404 for any other Host, and with meetings an
internal-only `:4080` listener that sets `X-Forwarded-Proto: https`, because core's `force_ssl`
redirects a plain internal POST from LiveKit's webhook or the transcriber), `secrets.env`, `customer-secrets.env`,
`services.txt`, `postgres-init/*.sql`, `models.json` and `registry-auth.json` as above, plus
`livekit.yaml` (meetings; no secret, the key pair arrives as `LIVEKIT_KEYS`), `tailscale/*.json`
(tailscale serve configs) and `secrets/<REF>` (0600 key files mounted into one container). It
writes no `user-data`/`meta-data`, publishes no port on Caddy, and renders no auth-host alias and
no CA-bundle mount: core reaches `https://<auth_host>` through public DNS and the edge. pocket-id
runs on the bundled postgres (`20-pocket-id.sql`, `DB_CONNECTION_STRING`) with a generated
`STATIC_API_KEY` for first-run bootstrap.

The renderer refuses in these cases:

- `--out` is inside a git work tree (`output_inside_git_worktree`);
- `--out` is not empty (`output_not_empty`);
- a customer secret is missing (`customer_secret_missing`) or shadows a generated name
  (`customer_secret_conflict`);
- `--target` differs from `install.target` (`target_mismatch`);
- `media_reach` `lan`/`tailnet` without `node_ip` and the address cannot be detected
  (`media_ip_undetected`).

To compare two renders without printing a secret, run `burrow_install redact <dir> --out <dir>` on
each and diff the copies. Do not diff the raw directories: `user-data` carries `secrets.env`.

## First admin: `bootstrap-admin`

```
python3 -m burrow_install bootstrap-admin --base https://<auth host> \
  --api-key-file <0600 file holding STATIC_API_KEY> --email <addr> [--username <u>] \
  --link-file <path> [--primary <host> --oidc-secret-file <0600 file>]
```

The non-interactive pocket-id bootstrap for an install provisioned by someone else (a droplet),
where the Mac `setup` CLI does not apply (core task 01a10315; `burrow_install/bootstrap.py`). It
finds or creates the first admin (`setup/pocketid.py` `ensure_admin`), mints a one-time sign-in
code valid for `LOGIN_TTL` (30 minutes), and writes
`https://<auth host>/lc/<code>?redirect=%2Fsettings%2Faccount` to `--link-file` with mode 0600.
stdout is one JSON document, `{"ok": true, "admin": "created"|"exists", "link_file": ...}`; the
link and the API key are never printed. A re-run mints a fresh link. Exit codes: `0` ok, `1`
pocket-id unreachable or erroring (`{"ok": false, "error": ..., "kind": ...}`, `kind` being the
connection class such as `connection_refused`, or `http`), `2` usage (including an API key file
readable by anyone but its owner). With `--primary` and `--oidc-secret-file` (both or neither) it also
registers core's OIDC client (`suite-core`, callback `https://<primary>/auth/oidc/callback`,
PKCE) and the render's `OIDC_CLIENT_SECRET` as its only secret, as the Mac setup CLI's pocket-id
step does: nothing else registers the client on a `single-host` install. The JSON then carries
`"oidc_client": "created"|"exists"`; a re-run registers nothing new.
