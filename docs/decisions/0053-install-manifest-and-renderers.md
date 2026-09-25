# ADR 0053: Install Manifest and Per-Target Renderers

- **Status:** Accepted
- **Date:** 2026-09-25
- **Owners:** Team
- **Task:** 01a0d69d-8469-7001-bc2c-8d6e3de56dff
- **Extends:** [ADR 0003](0003-deployment-contract-shape.md) (deployment contract shape; not superseded)
- **Related:** [ADR 0001](0001-repository-shape-and-boundary.md), [ADR 0042](0042-org-project-topology-and-context-inheritance.md)

## Context

ADR 0003 defines the contract for **one application**. It covers core-platform's runtime values
(`PHX_*`, `SECRET_KEY_BASE`), its route metadata and its promotion state. It says nothing about
the **install** around that application: which services run beside core, how they find each
other, where models come from, how sign-in works, or where backups go.

In practice, that knowledge lives in hand-kept host files. Measured on 2026-09-25:

- core-ops `targets/` holds only `hive-production` and `moon-production`. Both are
  host-specific, so there is no parametric target to stamp a new install from.
- **The core-ops moon target does not describe moon.** core-ops `origin/main` tracks
  `core-platform`, `core-postgres`, `memory-service`, `embeddings` and `suite.network`. Live
  moon also runs `files-service`, `speaches` (cuda, on the host's NVIDIA GPU), `meeting-voice`
  and `wyoming-openai`, none of which core-ops tracks. The live core-platform quadlet sets
  `FILES_SERVICE_URL`; the tracked one has no such line. The only accurate description of a
  full Suite install is the set of live quadlets on one machine.

That cannot scale to customer installs, and the product decision below means every customer
gets one.

**Product decision (Rowan, 2026-09-25).** Every customer gets their own owned Suite install.
Hosting several customers as orgs inside one install is not an option, because multi-org
isolation is not strong enough to sell across customers. ADR 0042's org hierarchy (one root
org, tenant children) organises clients *within* an install. It is not a boundary between
customers, and this ADR does not ask it to be one.

**Positioning.** The positioning is data sovereignty: the customer is not locked into a
provider, a platform or an agent harness. They bring any agents (OpenClaw, Claude Code,
DeepSeek, Hermes; many or one) and any models.

## Decision

### 1. One declarative install manifest per install

One TOML **install manifest** is the single source, for an install rendered from it, of:

- the domain and TLS mode;
- the service set: core-platform and postgres always, with files-service, memory-service,
  speaches/voice and embeddings optional;
- model endpoints, each local, hosted or bring-your-own;
- auth, either bundled pocket-id or an external OIDC provider;
- the backup target;
- the size tier;
- the GPU flag.

A manifest describes exactly one install for one customer. The hosted offering runs one
install per customer (target 2 below) from the same manifest format.

The schema is `schema_version = 1`. It is documented field by field in
[`deployment/schema/install-manifest.md`](../../deployment/schema/install-manifest.md), and
its validator lives in `deployment/installer/suite_install/`.

**Scope note.** "Single source" holds for installs rendered from a manifest. It does **not**
yet hold for moon or hive: their quadlets stay hand-maintained until the follow-ups below move
moon onto a manifest.

### 2. The manifest owns infrastructure only

The manifest owns domain, TLS, services, endpoints, auth, backup, size, GPU and images.
Per-install **behaviour** stays in the admin panel: orgs, agents, prompts, feature settings
and runtime registration. Orgs are clients, not deployments. An org is never a manifest
field, and a manifest never configures an org.

### 3. Agents and models are pluggable and customer-owned

- The manifest has **no default model endpoint of ours**. `[[models.endpoints]]` entries carry
  `kind = "local" | "hosted" | "byo"`, and `hosted` and `byo` are equally first-class.
- Agent runtimes are **not configured by the manifest at all**. They federate in through the
  admin panel and runtime registration. So no agent-harness env (for example moon's
  `OPENCLAW_GATEWAY_URL`) is ever rendered by default.
- A renderer emits a model endpoint, agent setting or host literal only when the manifest
  declares it.

### 4. Renderers per target

The same manifest renders to each target:

1. **Single host:** docker compose + Caddy + cloud-init. Built by task 01a0d69d and proven on
   a throwaway KVM guest.
2. **Hyperscaler:** a thin OpenTofu module per cloud whose only job is to boot target (1) on a
   VM. CloudFormation is used only for an AWS Marketplace listing.
3. **Mac:** OrbStack or Docker Desktop plus Caddy, or a Cloudflare Tunnel for public reach.

Renderers compose output only from the manifest plus a single service registry
(`suite_install/registry.py`). The registry declares each service's container, env, injected
env, secrets, init SQL, volumes, routes and dependencies. Turning a service off removes
everything that service declares.

**What core trusts under `tls = "internal"`.** `apps/platform/config/runtime.exs:3-10` points
Erlang's `:ssl` defaults and `:public_key.cacerts_get/0` at CAStore's bundle. That does not
cover every client in core. Core's OIDC client is Assent's `Assent.HTTPAdapter.Httpc`
(`config/config.exs:394`), and when it is given no trust store it verifies against
`:certifi.cacerts()`, a list compiled into certifi.beam that no file can extend. Measured on
the throwaway VM (task 01a0d69d stage 3): the install root was in the mounted CAStore file and
in `:public_key.cacerts_get()`, was absent from `:certifi.cacerts()`, and `/auth/login`
answered 500 with an Unknown CA alert. `Platform.OIDC.http_adapter/1` now resolves the bare
Httpc adapter to `ssl: [cacertfile: CAStore.file_path()]`, so sign-in trusts the same file as
the rest of core. Only the trust store is supplied, so Assent still adds `verify_peer` and
hostname checking. For installs with public certificates the change is a superset: all 143 of
certifi's roots are in CAStore's bundle (same measurement).

### 5. Validation is a tool, not a convention

`python3 -m suite_install validate <manifest>` prints `ok` and exits 0 for a valid manifest.
Otherwise it prints one `error <code> at <toml.path>: <message>` line per problem and exits 2.
Every key outside the schema, at any depth, is an error, so a misspelled knob cannot silently
keep its default.

The load-bearing rules are cross-field:

- `voice.accelerator = "cuda"` needs `host.gpu`;
- memory needs embeddings;
- each auth mode and backup target needs its own fields.

So the validator is code, not a JSON Schema file. `python3 -m suite_install services <manifest>`
prints the enabled container set and is the ground truth that a rendered install is checked
against.

The tooling is **Python 3.11+ standard library only** (`tomllib`), because it must run on a
bare customer host or a Mac with no pip step.

### 6. Day-2 requirements are reserved, not built

A sellable install also needs:

- upgrade channels with unattended migrations;
- tested backup **and** restore;
- first-run bootstrap: admin user, OIDC client, secrets and outbound mail;
- health phone-home.

The schema reserves `[day2]` keys (`upgrade_channel`, `phone_home`) that validate but are not
acted on, so adding these later does not need a schema version bump.

### 7. Where it lives

Per ADR 0001 (Core owns "reusable deployment contracts, generic deployment templates and
examples"), the schema, validator, renderers and safe examples live in **Core** under
`deployment/`. Per ADR 0003's guardrails, Core Ops does not become the home for reusable
deployment logic. Core Ops holds real instances only, such as a future moon manifest.

## Consequences

### Positive

- A new customer install is one reviewed file, not a copy of a live host.
- A manifest either validates or names the exact field that is wrong. A typo fails; it does
  not silently disable a knob.
- The service set a manifest implies is printable, so a rendered install can be checked
  against it mechanically.
- Customers keep control of their models and agents, with no endpoint of ours baked in.

### Tradeoffs

- Until moon is rendered from a manifest, there are two descriptions of a Suite install: the
  manifest format, and moon's hand-kept quadlets. The quadlets have already drifted from
  core-ops.
- `registry.py` restates part of core's env contract (`MEMORY_SERVICE_URL`,
  `FILES_SERVICE_URL`, the prod-required secrets, the `OIDC_*` keys) in Python. It can drift
  when core adds a required env var until the follow-up check below exists.
- Core now carries a small Python toolchain under `deployment/installer/`. That is acceptable
  because it is deployment tooling with no dependencies, not product runtime.

## Guardrails

- Examples in Core stay non-personal (ADR 0003): no real hostnames, LAN addresses or secrets.
- A manifest holds secret **refs** (names), never secret values.
- Never add a default model endpoint, agent-harness variable or host literal of ours to the
  registry or a renderer.
- A new manifest key needs a schema entry, a doc row and a validator test. An unknown key must
  keep failing.
- A breaking schema change bumps `schema_version`. The validator refuses versions it does not
  read.

## Follow-up

Named here; not yet created as tickets:

1. OpenTofu renderer (target 2), one thin module per cloud that boots the single-host render.
2. CloudFormation template for an AWS Marketplace listing.
3. Mac renderer (target 3): OrbStack/Docker Desktop + Caddy, or a Cloudflare Tunnel.
4. Upgrade channels and unattended migrations (`day2.upgrade_channel`).
5. Tested backup **and** restore for each `backup.target`.
6. First-run bootstrap: admin user, OIDC client, generated secrets, outbound mail.
7. Health phone-home (`day2.phone_home`).
8. A podman-quadlet renderer target. Migrating moon onto a core-ops manifest needs it, because
   moon runs quadlets, not compose.
9. Migrate moon onto a core-ops manifest, and fix the core-ops moon target drift recorded in
   Context.
10. A core env var for extra CA certificates, so that `tls = "internal"` installs do not need
    to bind-mount a combined bundle over the CAStore file inside the core image. Prioritise
    it: that mount stops working when CAStore's path moves in an image bump (the path carries
    the castore version). The single-host renderer makes that failure loud: the stack refuses to
    start and names the path. Since `Platform.OIDC.http_adapter/1` reads the same CAStore
    file, one env var covering that file covers sign-in too.
11. A CI check that the env names `apps/platform/config/runtime.exs` requires in prod are all
    produced by the registry for the default service set.
12. A JSON Schema for the manifest, for editor completion only. The validator stays
    authoritative.
13. Per-service secret scoping on single host. Every container that reads `secrets.env` through
    `env_file` sees every line in it, not only its own. The renderer keeps customer-supplied
    secrets that no container reads out of `secrets.env` for that reason (files-service would
    otherwise take an `OPENAI_API_KEY` there as its STT credential), but generated secrets are
    still visible across containers.
14. GPU hosts: the single-host render emits the compose GPU reservation, but its cloud-init
    does not install the NVIDIA driver or container toolkit.
15. Turning memory on for an install whose postgres volume is already initialised. The memory
    init SQL runs only on an empty data volume, so this needs a migration step.
16. memory-service declares `MEMORY_API_KEY` but did not enforce it at memory-service
    `a24876a`. The renderer generates and wires it on both sides anyway.

## Proof

Recorded 2026-09-25 by task 01a0d69d. Stage 3 ran the first boot. Stage 4 ran the memory-knob
flip on branch `task/01a0d69d-8469-7001-bc2c-8d6e3de56dff` at `48f8de5`, from a clone on moon.
The proof scripts are in `deployment/installer/proof/` and are described in its README. No
secret value is quoted here. The redacted copies come from `suite_install redact`, which
replaces every value with `<secret:NAME>`. Secret values are compared only as sha256
digests.

### VM host method

moon is Bluefin 42 (bootc) with rootless podman 5.6.2. It has no qemu, virsh or virt-install,
and `sudo -n` needs a password. `/dev/kvm` is `crw-rw-rw- root kvm`, and a rootless
`podman run --device /dev/kvm` container ran `KVM_GET_API_VERSION` (12) and `KVM_CREATE_VM`.
So the guest is a real QEMU/KVM VM, with its own kernel (Ubuntu 24.04, `6.8.0-139-generic`),
its own cloud-init and its own docker. QEMU is the main process of the rootless container
`vm-01a0d69d`, started as `qemu-system-x86_64 -accel kvm -cpu host -smp 4 -m 16G` with
`--cpus 4`. Ports are published on `127.0.0.1` only (18443 to guest 443, 18022 to guest 22).
The Ubuntu cloud image is checked against Ubuntu's `SHA256SUMS` before use.

### What stage 3 found, and fixed or corrected

- **OIDC trust store, root cause and fix.** With image `suite-core:latest`, `/auth/login`
  answered 500, and core logged an Unknown CA alert against `https://auth.<primary>`. The
  install root was present in the mounted CAStore file and in `:public_key.cacerts_get()`,
  but absent from `:certifi.cacerts()`. Assent's Httpc adapter, given no trust store, verifies
  against `:certifi.cacerts()`, a list compiled into certifi.beam that no file can extend.
  Commit `a5c2e83` makes `Platform.OIDC.http_adapter/1` pass
  `ssl: [cacertfile: CAStore.file_path()]`. A mutation that removed the clause failed 2 of
  22 tests in `oidc_test.exs`.
- **Trust-store claim, corrected.** This task's plan (stage 2) claimed that
  `runtime.exs:3-10` replaces Erlang's trust store with `CAStore.file_path()`, so a combined
  bundle mounted over that file would be enough for sign-in. That held for `:ssl` defaults
  and for `:public_key.cacerts_get/0`, but not for Assent. Decision section 4 ("What core
  trusts under `tls = "internal"`") now states the corrected claim: sign-in trusts the root
  only after the fix above. All 143 certifi roots are also in CAStore's bundle, so installs
  with public certificates lose nothing.
- **Embeddings healthcheck port.** The llama.cpp image's own HEALTHCHECK probes port 8080,
  but the rendered server listens on 8188, so embeddings reported unhealthy while it was
  serving. The registry now declares a healthcheck on 8188. In both stage 4 runs,
  embeddings shows `healthy`.
- **Images absent from moon.** `docker.io/library/caddy:2` and
  `ghcr.io/pocket-id/pocket-id:v2` are not in moon's podman store. The guest pulls them
  anonymously (`preload.sh --pull-missing-public`). The other five refs are streamed from
  moon's store (`podman save | docker load`), and their layer diff ids match the host. No
  registry credential enters the guest.
- **Image under test.** The tag is `docker.io/example/suite-core:feat-01a0d69d-oidc-ca`.
  Its `org.opencontainers.image.revision` is `a5c2e83`, and its digest is
  `sha256:279b457d09a2...`. The only change since `a5c2e83` is a README. The manifests below
  pin it with `[images] refs.core-platform`, which is the one line that differs from
  `deployment/examples/moon-equivalent.install.toml`.

### Step 1: memory on

```text
$ diff moon-equivalent.install.toml memory-on.toml
> refs.core-platform = "docker.io/example/suite-core:feat-01a0d69d-oidc-ca"
$ suite_install validate memory-on.toml         -> ok
$ suite_install render memory-on.toml --out render-on
  11 generated secrets (names only printed); postgres-init/10-memory.sql present
$ vm-up.sh --name 01a0d69d ... --https-port 18443 --ssh-port 18022   04:52:26Z-04:53:11Z
  cloud-init status: done, errors: []
$ preload.sh ... --pull-missing-public --file <Qwen3-Embedding-0.6B-f16.gguf>=models/...
  5 refs streamed (layers match host), 2 pulled anonymously in the guest, model sha256 421a27e58d16 matches
  suite-stack.service active; 7 containers running                      04:53:17Z-04:55:28Z
```

Every curl ran from moon with `--cacert <guest root.crt>` and
`--connect-to <name>:443:127.0.0.1:18443`. None used `-k`. The root is
`CN=suite-01a0d69d internal root`, SHA-256 fingerprint `E5:71:69:C2:...:18:35:92`. Its key
never left the guest.

```text
(a) GET https://suite-01a0d69d.test/health      -> 200
(b) GET https://suite-01a0d69d.test/auth/login  -> 302  Location https://auth.suite-01a0d69d.test/authorize?client_id=suite-core&...
(c) hop 1 /authorize                            -> 302  ssl_verify_result 0
    hop 2 /interaction/error ("The requested OAuth 2.0 Client does not exist.") -> 200 text/html, ssl_verify_result 0
    control: /health without --cacert           -> curl: (60) unable to get local issuer certificate
guest: docker ps -a --filter name=memory-service -> memory-service Up 21 seconds
guest: docker exec core-platform env | cut -d= -f1 | grep -c '^MEMORY_' -> 5
guest: docker compose ps --services --status running | sort
       == suite_install services memory-on.toml ->
       caddy core-platform core-postgres embeddings files-service memory-service pocket-id  (EQUAL)
```

Check (c) passes because the chain ends at a 200 text/html pocket-id page over verified TLS.
That page is pocket-id's unknown-client page, not a sign-in form. Creating the `suite-core`
client in pocket-id is first-run bootstrap (Follow-up 6).

### Steps 2-3: render memory off, then diff

`memory-off.toml` is `memory-on.toml` with `memory = true` changed to `memory = false`, and
nothing else. It validates `ok`, and it was rendered with `--reuse-secrets render-on/secrets.env`.

```text
$ diff -r <redact render-on> <redact render-off>
  compose.yaml : - MEMORY_SERVICE_URL (core-platform env)
                 - core-platform depends_on memory-service
                 - the memory-service service block (image, env_file, 5 MEMORY_* env, depends_on core-postgres + embeddings)
  postgres-init: Only in render-on (10-memory.sql: role memory, database memory, CREATE EXTENSION vector)
  secrets.env  : - MEMORY_API_KEY, MEMORY_DATABASE_URL, MEMORY_DB_PASSWORD, MEMORY_SERVICE_API_KEY
  services.txt : - memory-service
  user-data    : the same removals, in the embedded compose.yaml, write_files entry for
                 10-memory.sql, secrets.env and services.txt
  Caddyfile, meta-data: identical
  added lines (^>): 0   removed lines (^<): 64
```

The added-line count can fire: the same diff with its arguments reversed reports 64 added
lines. Re-rendering after the flip did not reorder anything; the diff shows no `>` lines at all.

```text
secrets.env names: on 14, off 10
  dropped: MEMORY_API_KEY MEMORY_DATABASE_URL MEMORY_DB_PASSWORD MEMORY_SERVICE_API_KEY
  added:   (none)
  the 10 shared names have the same sha256 digest on and off:
  ATTACHMENT_SIGNING_KEY DATABASE_URL ENCRYPTION_KEY FILES_SERVICE_TOKEN MEETING_CALENDAR_SIGNING_KEY
  MEETING_GUEST_SIGNING_KEY OIDC_CLIENT_SECRET POSTGRES_PASSWORD SECRET_KEY_BASE VAULT_MASTER_KEY
```

### Step 4: redeploy memory off in the running guest

`compose.yaml`, `Caddyfile`, `services.txt` and `secrets.env` (mode 0600) from `render-off`
were written to `/opt/suite`. The guest's sha256 of each matched the render. `10-memory.sql`
was removed, and then `docker compose up -d --remove-orphans` ran (04:56:39Z-04:57:02Z).

```text
(a) /health     -> 200
(b) /auth/login -> 302  Location https://auth.suite-01a0d69d.test/authorize?client_id=suite-core&...
(c) same two hops, ending at 200 text/html, ssl_verify_result 0
guest: docker ps -a --filter name=memory-service -> (empty)
guest: docker exec core-platform env | cut -d= -f1 | grep -c '^MEMORY_' -> 0
guest: running set == suite_install services memory-off.toml ->
       caddy core-platform core-postgres embeddings files-service pocket-id  (EQUAL; files-service healthy)
```

Two findings from the flip:

- **Memory secrets reached containers that do not own them.** Before the flip,
  core-platform's environment held all five memory names, including `MEMORY_DB_PASSWORD`,
  which is memory-service's own database password. Five containers read the whole
  `secrets.env` through `env_file`: core-platform, core-postgres, files-service,
  memory-service and pocket-id. Caddy and embeddings do not (Follow-up 13). This also
  explains which containers the flip recreated: exactly the four `env_file` readers that
  remained (core-platform, core-postgres, files-service, pocket-id), because their
  `secrets.env` content changed even though their own settings did not. Caddy and
  embeddings stayed `Running`.
- **The postgres-init mount stays with memory off.** The memory-off `compose.yaml` still
  mounts `./postgres-init` into core-postgres, but the render no longer ships that
  directory, so compose starts it as an empty directory. This is harmless, because the init
  scripts run only on an empty volume. It is also a mount with nothing behind it, so a later
  renderer revision should drop it when no service declares init SQL.

### Step 5: teardown

`vm-down.sh --name 01a0d69d --workdir /srv/dev/01a0d69d-vm` ran at 04:57:23Z. Its
before-block hit 6 of 6 checks, which is the positive control: the container
`vm-01a0d69d`, the image `localhost/vmhost-01a0d69d`, the workdir, listeners on 18443 and
18022, and the conmon and qemu processes. Afterwards, only the image check still hit: the
pulled `suite-core:feat-01a0d69d-oidc-ca`, which vm-down.sh does not own. vm-down.sh exited 2
for that reason. After `podman rmi` on that image:

```text
podman ps -a --filter name=01a0d69d                -> (empty)
podman images --filter reference='*01a0d69d*'      -> (empty)
ls -d /srv/dev/01a0d69d-vm                   -> absent
ss -ltnH 'sport = :18443' / 'sport = :18022'        -> (empty)
pgrep -af 01a0d69d                                  -> (empty)
podman volume ls / podman network ls | grep 01a0d69d -> 0 / 0
```

Prod units, `systemctl --user is-active core-platform core-postgres memory-service
files-service embeddings` on moon, read `active active active active active` at 04:51:49Z,
before the run, and at 04:57:31Z, after teardown. The run started, stopped and removed no unit,
container, volume or network without `01a0d69d` in its name. The only image pulled onto moon
was the `feat-01a0d69d-oidc-ca` tag, and it was removed again.
