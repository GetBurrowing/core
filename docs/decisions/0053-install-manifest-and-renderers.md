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
  full Burrow install is the set of live quadlets on one machine.

That cannot scale to customer installs, and the product decision below means every customer
gets one.

**Product decision (Rowan, 2026-09-25).** Every customer gets their own owned Burrow install.
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

- Until moon is rendered from a manifest, there are two descriptions of a Burrow install: the
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

## Proof (Mac)

Task 01a0d6ab stage 5. The proof ran on **2026-10-05 between 04:50Z and 05:23Z**, on **rock**,
from branch `task/01a0d6ab-6ea3-7001-8976-86dd066069ca`. The installer code on rock was the
branch at `ef321ef0` plus three fixes this run found. Those fixes are committed in the same
commit as this section (see "Found by the proof and fixed").

The core image was pinned to `docker.io/example/suite-core:feat-01a0d6ab-multiarch`: index
`sha256:7b39215b...`, revision `17a3df5d`. `/health` reported exactly that commit.

### Where it ran, and why rock

- **The machine.** rock is the team's own Apple Silicon Mac mini: arm64, 8 GB RAM, macOS 26.3,
  OrbStack 29.4.0, and a 4 GiB VM limit. hive reaches it as `ssh rock`.
- **Why not Harper's Mac mini.** The plan targeted Harper's Mac mini through Octavius, because
  hive has no route there (measured 2026-09-25 and recorded in this section's first draft). On
  2026-10-05 Rowan moved the proof to rock: *"run it on rock yes, but please tear it down once
  its up"*. That meant the executor could run every step over ssh, so no relay to Harper or
  Octavius was needed.
- **Rock is shared and live.** Brosnan's agent runtime runs there, working the iOS app
  (Xcode/TestFlight). The run therefore waited for a quiet window. The first check, at 04:02Z,
  measured memory-pressure level 2 (warn): 4.2 of 5.1 GB swap used and 133 MB unused. The
  executor polled every 10 minutes. It started only after two consecutive level-1 (normal)
  readings, at 04:40Z and 04:50Z, with no booted simulator and no Xcode build. During the run a
  30-second monitor took 65 samples: 42 at level 1, 23 at level 2, none critical. The lowest
  `memory_pressure` free reading was 31%. The run touched none of Brosnan's processes, tmux
  sessions, `~/.claude.json`, ports, Xcode state or `~/private_keys`.
- **OrbStack was already running**, and was left running. Its licence line, as preflight printed
  it: "OrbStack is free for personal non-commercial use; commercial use needs a paid licence."

### Deviations from the customer path (and why)

- **No OpenAI key.** At Rowan's request, embeddings used moon's LAN llama-server (model
  `embeddings`, Qwen3, **1024-dim**), and speech-to-text used moon's LAN speaches (model
  `Systran/faster-distil-whisper-large-v3`). The width the proof expects is therefore 1024, not
  1536. `api_key_ref` pointed at a 0600 dummy key file, because neither server checks a bearer.
  A customer Mac uses the hosted endpoints, which is the default of `proof.sh init`. The
  `--embed-url/--embed-model/--stt-url/--stt-model` flags exist for runs like this one.
- **OrbStack containers could not reach the LAN.** From inside the VM, `192.0.2.200:8188`
  and `:8000` timed out, while rock itself reached both. The likely cause is macOS's Local
  Network privacy permission for OrbStack; it was not checked, because that is a System
  Settings change on a shared desktop. The run worked around it with a throwaway loopback TCP
  forwarder on rock (`lanfwd-01a0d6ab`, 127.0.0.1:18188 and :18001). Containers reached it
  through `host.docker.internal`. The hosted-endpoint customer path does not hit this.
- **The installer was driven by the executor over ssh,** not by a headless `claude -p` with
  SKILL.md loaded. Every CLI command and its full output went to a transcript (113 JSONL lines).
  Its first line is the planted marker. That is the file the hygiene grep read.
- **The agent-connect session ran on hive, not rock.** A fresh `CLAUDE_CONFIG_DIR` on rock reports
  "Not logged in". Logging it in would have meant copying Brosnan's credentials, which the run
  must not touch. The session was a separate `claude -p` on hive with `--strict-mcp-config` and
  its own MCP config: a 0600 file holding the new instance's `/mcp` URL and a throwaway runtime
  token.
- **The passkey was enrolled from hive's headless Chrome over CDP,** in an isolated browser
  context with a WebAuthn virtual authenticator. The `open location` call was shimmed on rock,
  so no browser window opened on the shared desktop. On pocket-id's `/login/alternative/code`
  page the **Submit button stayed disabled** with the code prefilled (pocket-id 2.18.0, which the
  `:v2` tag now resolves to; stage 4 measured 2.16.0). The page made no request. The script
  therefore made the same call the page makes,
  `POST /api/one-time-access-token/<code>` from the page's origin, which returned 200. This
  was not re-tested in a real desktop browser. It is follow-up 9.

### Measurements

| # | Check | Expected | Measured |
|---|---|---|---|
| 2 | Preflight | 7881/tcp and 7882/udp free; no container-name clash | PASS. 21 TCP and 11 UDP listeners recorded; both media ports free; no name collision; 47 GiB free disk (29 GiB needed); runtime OrbStack, VM 3.9 GiB (advisory: give it 4 GiB) |
| 3 | `setup status` after `verify` | `complete: true` | `complete: true`; only `keepalive` (advisory) not done. Its human steps: `sudo pmset`, OrbStack start-at-login. FileVault and automatic login were already off. |
| 4 | From hive: `/health` | 200, `commit` = `17a3df5d...` | 200, `status ok`, commit `17a3df5d020b91c88bf8ccd92a72f0d111b4e51b`. Public TLS with no `-k` (`ssl_verify_result` 0); the edge certificate is issued by Google Trust Services WE1. |
| 4 | From hive: `/auth/login` | 302 to `https://auth-01a0d6ab.<zone>/`, and that page 200 text/html | 302 to `https://auth-01a0d6ab.example.com/authorize?client_id=suite-core&...` (PKCE S256). Following it gives 200 text/html at `/interaction`; the auth host root is 200 text/html. |
| 4b | First user signs in | Lands in Suite | Passkey (virtual authenticator) at pocket-id, then `https://suite-01a0d6ab.example.com/chat`, title "Chat" |
| 5 | `proof.sh memory --expect-dim 1024` | width 1024; opposite orderings | PASS. `atttypmod` 1024. Cat query: canary rank 1 (fused and semantic), control rank 2. VAT query: control rank 1 (semantic 1, lexical 1), canary rank 2. Ingest wait 6 s. memory-service logged `Dimension: 1024`, `api_key=set`, with no mismatch. |
| 5 | `proof.sh files` | sha256 equal, `cmp` identical, unauthenticated GET denied, runtime revoked, token 401, file deleted | PASS. 1 MiB up and down, sha256 `8e190dfe...` on both sides and the server's content hash; `cmp` identical; unauthenticated GET 302; runtime revoked (token hash cleared); the same token then got 401; token file deleted |
| 6 | `proof.sh arch` | every image arm64; `uname -m` aarch64 | PASS. All 7 running images arm64; `uname -m` aarch64 in core-platform, files-service and memory-service |
| 8 | Meetings on (`media_reach = "lan"`, transcription on) | 2 publishers with tracks; livekit host 200 from hive | Both media ports re-checked free. `lk room participants list proof-01a0d6ab` showed `pub_0 (ACTIVE) tracks: 1` and `pub_1 (JOINED) tracks: 1`; LiveKit logged connectionType udp twice. From hive, `https://livekit-01a0d6ab.example.com/` returned 200 after fix (b) below; before it, 404. meeting-transcriber registered as a worker; RestartCount 0 for both. core carried 4 `LIVEKIT_*` names. |
| 8 | Meetings back off | livekit absent; `LIVEKIT_*` count 0; health 200 | PASS. Running services: caddy, cloudflared, core-platform, core-postgres, files-service, memory-service, pocket-id. `LIVEKIT_*` count 0. `/health` 200 from hive. The 18 shared `secrets.env` names had equal sha256 prefixes across the flip. The only core `[error]` was the known `prompt_template_missing meetings.summarize`. |
| 9 | A separate agent session | one message posted; one memory search | Runtime `agent-01a0d6ab` (bundles memory and messaging, in its own channel). The `claude -p` session's `memory_search` returned the canary (`01a10a78-ca6b...`, source journal). `send_media` posted message `01a10a7b-abe0...` into the agent's channel; rpc confirmed its space. `send_media` reads `file_path` on the server, so the file was placed in the core-platform container. It is the only messaging tool reachable over MCP; plain text posts go through the channel socket. Afterwards the runtime was revoked, and `tools/list` with its token returned 401. |
| 10 | `setup run backup` | a dump passes `pg_restore --list` | LaunchAgent installed (daily 03:15). Entry counts: core_platform 694, memory 13, pocketid 179. A re-run of `pg_restore --list` on the newest core dump exited 0. |
| 11 | Transcript hygiene | every secret 0; marker 1 | PASS. 30 secret values checked, 0 found: every `secrets.env` name, the Cloudflare token, the dummy key, the registry auth and its tokens, and the agent token. Marker count 1. The hive-side `claude -p` output and the CDP log also had 0 occurrences of the agent token; the positive control, the MCP config file, had 1. |

RAM. Readings are `docker stats --no-stream`; "VM" is OrbStack's VM limit; "free" is
`memory_pressure` free percentage. Total host RAM is 8 GiB.

| Reading | before install | idle after install | after data plane |
|---|---|---|---|
| OrbStack VM limit | 3.89 GiB | 3.89 GiB | 3.89 GiB |
| `memory_pressure` free | 44% | 46% | 46% |
| core-platform | n/a | 345 MiB | 347 MiB |
| core-postgres | n/a | 92 MiB | 99 MiB |
| memory-service (http backend) | n/a | 101 MiB | 108 MiB |
| files-service | n/a | 42 MiB | 75 MiB |
| pocket-id | n/a | 62 MiB | 67 MiB |
| caddy + cloudflared | n/a | 62 MiB | 89 MiB |
| **Burrow total** | n/a | **703 MiB** | **785 MiB** |
| Pre-existing (nexus-neo4j, suite-dev-postgres) | 1038 MiB | 688 MiB | 691 MiB |

### Found by the proof and fixed

- **(a) `up` lost `docker compose` on OrbStack.** The install's own `DOCKER_CONFIG`, which holds
  the registry credential, also moves Docker's per-user plugin dir. OrbStack installs
  `docker-compose` only in `~/.docker/cli-plugins`, so `up` failed with "unknown flag:
  --project-directory". The install's `config.json` now carries `cliPluginsExtraDirs`: the
  user's plugin dir plus Docker Desktop's and Homebrew's.
- **(b) A re-render did not reach running containers.** A single-file bind mount pins the
  replaced inode, and `docker compose up -d` leaves an unchanged service running. After the
  meetings flip, caddy still served its first Caddyfile; the in-container path read "No such
  file". The livekit host therefore returned 404 through the tunnel. `up` now compares each
  mounted config (Caddyfile, livekit.yaml) with what the container reads, and force-recreates a
  service whose copy differs.
- **(c) First boot of postgres was marked unhealthy.** initdb, the init scripts and the restart
  checkpoint took longer than 5 x 10 s of healthchecks on a loaded 8 GB Mac; the checkpoint's
  fsync alone took 22 s. `up` failed with "dependency failed to start". The mac render now gives
  the bundled postgres a 180 s `start_period`.
- **(d) The livekit DNS record outlived the meetings flip and teardown.** Both only looked at
  the hostnames the current knobs route. The `tunnel` step now deletes its own CNAME for a
  configured host that is no longer routed, and teardown covers every configured host. On rock,
  the stale `livekit-01a0d6ab` CNAME was deleted by hand during teardown, through the API with a
  name-plus-target match.

### Teardown (Rowan: "please tear it down once its up")

Each item was listed before teardown, using the same filter or path, and shown gone after it.
Every filter was shown matching the live resources first.

- `setup teardown --confirm suite-01a0d6ab`:
  - it ran `docker compose down -v`. Before: 7 containers, 5 volumes and 1 network under compose
    project `suite-01a0d6ab`. After: none.
  - it deleted the tunnel `suite-suite-01a0d6ab` and the `suite-` and `auth-01a0d6ab` CNAMEs.
    The `livekit-01a0d6ab` CNAME was deleted by hand (fix (d)).
  - it removed the backup LaunchAgent: 1 plist and 1 loaded before, 0 and 0 after.
- **Cloudflare, from the account:**
  - tunnels matching 01a0d6ab: 1, then 0 (account total back to 2);
  - DNS records matching 01a0d6ab: 3, then 0 (zone total back to 33);
  - API token `suite-proof-01a0d6ab`: present and active (id `f0dfce2d...`), then deleted. The
    account's token total is back to 1.
- **Directories:** `~/suite/suite-01a0d6ab`, `~/SuiteBackups/suite-01a0d6ab`, the inputs dir and
  the source dir were present, then gone. The empty `~/suite` and `~/SuiteBackups` were removed.
- **The copied registry credential:** all three copies were present, then gone. They were the
  0600 input file, the install's `.docker/config.json` and its `registry-auth.json`.
- **The throwaway agent runtime** on the new instance was revoked (token then 401), and then
  removed with the instance's volumes.
- **The forwarder:** `lanfwd-01a0d6ab` was killed; listeners on 18188/18001 went from 2 to 0.
- **The pulled images were removed:** suite-core feat tag, files-service, memory-service,
  meeting-transcriber, pocket-id, livekit-server and cloudflared.
  `pgvector/pgvector:pg16` was on rock before the run and was kept. `caddy:2` was kept because
  whether it pre-dated the run is unknown.
- **OrbStack:** it was running before and was left running.

### Human prerequisites (not the CLI's to solve), as found on rock

- **(a) A container runtime.** OrbStack was already installed and running.
- **(b) A Docker Hub read credential for the private `example` images.** moon's
  `auth.json` was copied as a 0600 file. **The open decision is still Rowan's:** make the
  images public, or build a pull-token flow.
- **(c) A Cloudflare zone and a scoped token.** This run minted a 24-hour token from the
  account's legacy global key, scoped to the zone (Zone:Read, DNS:Edit) and the account
  (Cloudflare Tunnel:Edit). It was deleted at teardown.
- **(d) The core repository is private.** The run avoided cloning it on rock: it copied only
  `deployment/` with `git archive`, because the installer needs nothing else.

### Day-2 note: embedding width varies per install

memory-service creates `embeddings.embedding` at whatever width the configured model returns
on its first boot. That is 1536 for `text-embedding-3-small`, and 1024 for moon's Qwen3 (and
for this proof). Since memory-service `2ef3312f` it refuses to start if a table already exists
at a different width. So changing `[embeddings] model` on a live install is a migration, not a
knob: re-embed, or drop and re-create the tables. The width is part of an install's state and
must be read from the install (`atttypmod`), never assumed.

### Follow-ups named by this proof

1. An arm64 build of `suite-voice-worker`, for agent voice in meetings. It is amd64-only today.
2. TURN/TLS for remote meeting participants without a router port-forward.
3. LiveKit Cloud as an alternative to running LiveKit on the Mac.
4. A slim memory-service image without torch for the `http` embedding backend, if the measured
   arm64 image size warrants it.
5. files-service speech-to-text through the same hosted OpenAI endpoint.
6. Public images or a pull-token flow, to remove prerequisite (b). This is Rowan's decision.
7. Per-install container names, so that two installs, or an install and an unrelated
   `caddy`, can share a host.
8. An arm64 build of the `play` flavour. Since the main merge, CI builds `core` for amd64 and
   arm64, and `play` for amd64 only. A Mac install with `modules = ["play"]` would run under
   emulation.
9. ~~Re-check pocket-id's one-time-code page.~~ Root-caused and fixed in stage 6: it was the
   code length, not a browser quirk (see "Stage 6" below). pocket-id is now pinned to v2.18.0.
10. OrbStack's LAN reach from containers (likely macOS Local Network permission). This matters
    only for a Mac that uses LAN-hosted model endpoints.
11. A text-message tool on the MCP surface for remote agents. `send_media` needs a file on the
    server.

### Stage 6: the sign-in code length, and the skill-driven transcript clause

**What the behavioural gate found.** A real person following the installer's sign-in link
reached pocket-id's code page with the code prefilled and **Submit disabled**. pocket-id v2.18.0
`backend/internal/onetimeaccess/service.go:271-274` mints a 6-character code when
`ttl <= 15m` and a 12-character one otherwise. Its frontend
(`routes/login/alternative/code/+page.svelte:24-29`) expects 12 characters whenever
`emailOneTimeAccessAsUnauthenticatedEnabled` is false, which is the default. The installer
asked for `ttl = "15m"`, exactly on the boundary. The earlier proof reached `/chat` only
because its script made the page's POST itself.

**Fix.**

- `LOGIN_TTL` is now `"30m"` (`setup/pocketid.py`). It is the smallest round value clearly
  above the boundary, and it keeps the link, which is a credential until used, short-lived.
  `EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED` is left off.
- `LoginTtlTest` parses the TTL the way Go does and requires 15 min < TTL <= 60 min. The
  pocket-id fake now follows the same length rule, so the shared real/fake case asserts a
  12-character code. With `"15m"` (and with `"900s"` and `"0.25h"`), the TTL test and the
  12-character assertion fail against the fake and against a real v2.18.0 container.
- pocket-id is pinned to `ghcr.io/pocket-id/pocket-id:v2.18.0`. On 2026-10-05 that was the same
  image digest as `:v2`, so the pin changes nothing today. It does stop the boundary, or the
  frontend's expectation, from moving under an install without a deliberate change.
- **Found while re-proving against v2.18.0:** pocket-id 2.17.0 and later
  (`AUTO_CREATE_OIDC_CLIENT_SECRET`, default true) generate an active secret along with the
  client. That left `suite-core` with two live secrets, one of which nobody holds. `oidc-client`
  now deletes that secret, using the id from the create response (`createdSecret.id`), so a
  secret an admin added later is never touched. Against v2.16.0, no `createdSecret` is
  returned, so nothing is deleted.

**Live re-proof (hive, docker, throwaway `pocketid-01a0d6ab-<pid>` at v2.18.0).** The link was
minted with the installer's own `ensure_admin` + `login_link` and opened in an isolated
headless-Chrome context. Nothing was injected; only network events were observed.

| TTL | Code length | `POST /api/one-time-access-token` from the page | Final page |
|---|---|---|---|
| `30m` (installer) | 12 | 1 request, 200 | `/signup/add-passkey`, title "Add Passkey", heading "Set up your passkey" |
| `15m` (control) | 6 | none | `/login/alternative/code?code=<redacted>&redirect=...`, title "Login Code", Submit `disabled: true` |

The container was removed afterwards. `docker ps -a --filter name=pocket` then listed only
hive's production `pocket-id`, which shows the filter matches.

**The skill-driven transcript clause is still UNMEASURED.** The clause says the only human
inputs are the domain, the Cloudflare token path, the OpenAI key path and the passkey. Measuring
it needs Claude logged in on the Mac. rock's fresh config is not logged in, and Brosnan's
credentials are off limits. Procedure for a human on a logged-in Mac:

1. Copy `deployment/` onto the Mac (`git archive HEAD deployment | tar -x -C ~/suite-src`) and
   put `deployment/installer/mac` on `PATH`. Have the domain, a 0600 Cloudflare token file and
   a 0600 OpenAI key file ready.
2. Make an empty directory and install the skill there as a project skill:
   `mkdir -p .claude/skills/suite-install-mac && cp ~/suite-src/deployment/installer/skill/SKILL.md .claude/skills/suite-install-mac/`.
   Start `claude` in that directory. Type `MARKER-01a0d6ab-transcript` as the first message,
   then `Install Burrow on this Mac.` Answer only what the agent asks. Add the passkey in the
   browser window it opens, then say so.
3. When `verify` passes, exit. The transcript is the session file
   `~/.claude/projects/<cwd with / replaced by ->/<session-id>.jsonl` (newest file there).
   A scripted alternative records the same shape:
   `claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages`,
   with each human message fed as one `{"type":"user","message":{"role":"user","content":"..."}}`
   line on stdin, and stdout teed to a file.
4. Run `proof.sh --grep-transcript --transcript <file> --marker MARKER-01a0d6ab-transcript
   --key-file <cf token file> --key-file <openai key file> --human-turns`. Every secret count
   must be 0. Each `transcript.human_turn <n> "<text>"` line is one turn a human typed. The
   clause holds when, apart from the marker and the opening request, those lines carry only
   the domain, the two paths and the passkey confirmation. Re-run with
   `--expect-human-turns <n>` to record the count as a PASS/FAIL.

`human_turns()` counts user records with text content. It drops tool results, subagent prompts
(`parent_tool_use_id`, `isSidechain`), `isMeta`/`isCompactSummary`/`isSynthetic` records,
records whose `origin.kind` is not `human`, and harness text (`<task-notification`,
`<local-command-`, `<system-reminder`). It is tested on synthetic fixtures of both shapes that
plant exactly four inputs among every excluded kind, with a negative control that adds a fifth.
On a real `claude -p` stream-json run on hive, it listed exactly the one message fed in and
dropped the tool result.
