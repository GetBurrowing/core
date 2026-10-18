# Burrow on a Mac: the setup CLI, and the same steps by hand

This directory installs Burrow, self-hosted, on a Mac running Docker
Desktop or OrbStack, reached from the internet through a Cloudflare tunnel.
The tunnel means no port-forward and no public IP. It was built in task
01a0d6ab stage 4, on top of the `mac` render target (ADR 0053, stage 3).

There are three layers, and each one uses only the layer below it:

1. **`burrow-install setup ...`** is a deterministic CLI. It never prompts on
   the terminal, prints one JSON document per command, and is the only thing
   that changes install state. Its code is in `../burrow_install/setup/`.
2. **`../skill/SKILL.md`** is a harness-agnostic Agent Skill. It offers to do
   the install, then loops on `setup status --json`, asks the human only for
   what a step needs, and explains failures. It contains no infra logic; a
   test checks that every command it cites exists and every step is cited.
3. **This README** is the human fallback: the same steps, by hand, in order.

## Why `burrow-install` and not `burrow`

`burrow` is already taken. It is the separate **Burrow CLI** (repo
`Startup-Suite/suite-cli`, TypeScript on bun; `suite` is its old name and still
works as an alias), which wires a Claude Code runtime to Burrow (`burrow init`,
`burrow claude`, `burrow doctor`, `burrow status`). That tool connects an
*agent* to an existing Burrow install. This one *installs* Burrow, and it is
Python in core because it drives core's install renderer. The two are
siblings; neither replaces the other. If the `burrow` CLI later grows
`burrow install`, it should exec `deployment/installer/mac/burrow-install` and
pass its JSON through unchanged, not re-implement the steps.

This CLI was called `suite-install` (Python package `suite_install`) until
task 01a14dd8. Both old names still work: `mac/suite-install` and
`python3 -m suite_install` print one deprecation line on stderr and run
`burrow-install` with the same arguments, stdout and exit code.

A desktop app (task 01a0d6b9) will wrap this CLI. The JSON contract below is
the stable surface for it.

## Before you start (human prerequisites)

- **Docker Desktop or OrbStack**, installed and running. Installing either
  needs the Mac owner's admin password.
- **The registry path** Burrow's images are published under, and a read
  credential for its private images (`<registry>/core`, `files-service`,
  `memory-service`). The path is the manifest's required `[images] registry`,
  e.g. `ghcr.io/<owner>` (`setup init --registry`); there is no default.
  Anonymous pulls return 401. You supply the credential as a docker
  `config.json` with an inline `auths["ghcr.io"].auth` (base64 of
  `<user>:<token with read:packages>`). Whether these images become public is
  an open product decision, not something this CLI decides.
  - `meeting-transcriber` has no build under the registry yet, so an install
    with `[meetings] transcription = true` must pin
    `[images.refs] meeting-transcriber`, or stay on the legacy input below.
  - **Legacy:** `[images] image_namespace` (`setup init --image-namespace`)
    still renders the old Docker Hub images (`docker.io/<namespace>/...`) and
    `validate` prints a deprecation warning. Its credential is
    `auths["https://index.docker.io/v1/"].auth`. Set exactly one of the two.
- **A domain in a Cloudflare account you control**, and an API token with
  **Zone:Read, DNS:Edit and Account: Cloudflare Tunnel:Edit**.
- **An OpenAI API key.** Memory search uses `text-embedding-3-small`, and
  meeting transcription uses `whisper-1` when meetings are on.

### Licences (the runtime, not Burrow)

Docker Desktop is free for personal use, education, non-commercial open source
and small businesses (fewer than 250 employees AND under $10M annual revenue).
Larger commercial use needs a paid subscription. OrbStack is free for personal
non-commercial use; commercial use needs a paid licence. The rendered
`compose.yaml` is runtime-agnostic. Colima (MIT) also runs it, but that has
not been tested. `setup run preflight` prints the same text.

## Quick start with an agent

Load `deployment/installer/skill/SKILL.md` into your agent (Claude Code or
any harness that reads Agent Skills) and ask it to set up Burrow on this Mac.

## The steps, by hand

Run everything from a clone of core. `burrow-install` finds a Python 3.11 or
later, or installs `uv` to `~/.local/bin` without sudo and uses Python 3.12.
Stock macOS python3 is 3.9, which has no `tomllib`.

```sh
S=deployment/installer/mac/burrow-install
$S setup init --from deployment/examples/mac-lite.install.toml \
   --name myburrow --domain burrow.example.com --auth-host auth-burrow.example.com \
   --registry ghcr.io/<owner>
$S setup status --json
```

Keep every hostname exactly one label below the zone. Cloudflare Universal SSL
covers only one level, so `auth.burrow.example.com` would get no edge
certificate; use `auth-burrow.example.com`.

Supply secrets by **reference**, never as values:

```sh
$S setup secret CLOUDFLARE_API_TOKEN   # macOS dialog with hidden input -> login Keychain
$S setup secret OPENAI_API_KEY
$S setup secret REGISTRY_AUTH          # paste the config.json
# or: chmod 600 ~/key && $S setup run render --input OPENAI_API_KEY=@$HOME/key
# or: $S setup run render --input OPENAI_API_KEY=env:OPENAI_API_KEY
```

Then run the steps in this order. Re-running any of them is safe.

| # | Command | What it does | Needs sudo? |
|---|---|---|---|
| 1 | `setup run preflight` | Read-only checks: runtime running, compose, Python, free disk (compressed arm64 image total x3 + 10 GiB, about 29 GiB for mac-lite), listening ports (7881/tcp and 7882/udp with meetings), RAM, runtime VM memory, and whether REGISTRY_AUTH can pull. | no |
| 2 | `setup run domain` | Finds the zone, enforces the one-label rule (`hostname_too_deep`), verifies the token. | no |
| 3 | `setup run tunnel` | Finds or creates tunnel `suite-<name>` (remotely managed). Sets its ingress (each host to `http://caddy:80`, then 404), creates proxied CNAMEs, and writes `TUNNEL_TOKEN` into `secrets.env`. It never overwrites a DNS record it did not create. | no |
| 4 | `setup run ddns` | Only for meetings with `media_reach = "public"`. Installs a LaunchAgent that runs `ip-watch.sh` every 5 minutes. On a public-IP change it restarts LiveKit, and it updates the optional grey-cloud A record `[meetings] media_host`. **You** forward 7882/udp and 7881/tcp on the router. Tailscale (`media_reach = "tailnet"`) needs neither. | no |
| 5 | `setup run render` | Renders the install into the install dir with `--reuse-secrets`. A re-render never rotates a secret. | no |
| 6 | `setup run up` | Runs `docker compose up -d --remove-orphans` with the install's own `DOCKER_CONFIG` and waits for every service to be running and healthy. It then creates the pocket-id admin (ADMIN_EMAIL) at once, which closes pocket-id's public `/setup` page. | no |
| 7 | `setup run pocket-id` | Finds the admin (or creates it), then opens a one-time sign-in link in your browser. Add a passkey on the Account page, then re-run. The step is done once a passkey exists. | no |
| 8 | `setup run oidc-client` | Creates client `suite-core` (callback `https://<primary>/auth/oidc/callback`, PKCE on) and registers the `OIDC_CLIENT_SECRET` that core already reads. core needs no restart. | no |
| 9 | `setup run keepalive` | Advisory; it never gates `verify`. Reports `pmset`, FileVault, automatic login and start-at-login. It turns on Docker Desktop's start-at-login when that key already exists in its settings file. | the printed `sudo pmset -a sleep 0 disksleep 0 autorestart 1` does |
| 10 | `setup run backup` | Installs a LaunchAgent (03:15 daily) that runs `backup.sh`: `pg_dump -Fc` of every database (core, memory and pocket-id) to `~/BurrowBackups/<name>/`, keeping 14. It runs once and checks each dump with `pg_restore --list`. | no |
| 11 | `setup run verify` | Checks `https://<primary>/health` returns 200, `/auth/login` returns a 302 to `https://<auth_host>/`, and that page returns 200 text/html. It uses normal public TLS verification and never `-k`. | no |

Installing Docker Desktop, `sudo pmset`, and FileVault or automatic login in
System Settings are the only steps that need the owner's password.

### The power-failure truth

With FileVault **on**, a Mac that restarts after a power cut waits at the
FileVault unlock screen. There is no user session, so no Docker Desktop or
OrbStack and no Burrow, whatever `autorestart` says. Unattended recovery needs
FileVault **off** plus automatic login (System Settings, admin password). That
is the owner's security trade-off. The CLI reports it and never makes it.

### Restoring a backup

```sh
cd ~/burrow/<name>
docker compose exec -T core-postgres pg_restore -U core_platform -d <db> --clean --if-exists \
  < ~/BurrowBackups/<name>/<db>-<utc>.dump
```

Time Machine picks up `~/BurrowBackups`. Those are consistent dump files, not a
live database inside the runtime's VM disk image.

### Teardown

`setup teardown --confirm <name>` runs `docker compose down -v`, removes the
two LaunchAgents, and deletes the tunnel and only the DNS records that point
at it. It leaves the install dir and `~/BurrowBackups` for you to delete.

### Moving an install made before the rename

An install made before task 01a14dd8 lives under the legacy root and runs its
jobs under the legacy LaunchAgent labels. Every command still finds it there.
`setup run migrate` moves it. It runs `docker compose down` there (no `-v`),
moves the directory to `~/burrow/<name>`, runs `docker compose up -d` from the
new directory, and rewrites each legacy LaunchAgent under the new label. The
compose project name comes from compose.yaml, which is unchanged, so the
volumes are the same. Backups taken before the move stay in the old backup
directory, recorded in state.json as `ids.legacy_backup_dir`. Running it again
moves nothing, and it refuses (exit 2) when both directories exist.
`docs/runbooks/burrow-rename-deferred.md` lists every name kept for old installs.

## Secrets: what travels where

- **Inputs are references.** They take one of three forms: `@/path` (a file,
  refused unless mode 0600 or tighter), `env:VAR`, or `keychain:ITEM`.
  `state.json` stores the reference, never the value.
- **`secret_in_argv`.** A secret input given as a literal (`--input
  OPENAI_API_KEY=sk-...`) is refused and not stored, and the refusal does not
  repeat it. The refusal cannot unsend it, though: the value is already in the
  shell history and in the agent's transcript. The remediation says to rotate
  it. The skill's rules exist so that the literal is never typed in the first
  place.
- **Keychain.** `setup secret NAME` shows a hidden-input `osascript` dialog.
  Its script goes on stdin, and the typed value comes back on its stdout. The
  value is stored with `security -i`, with the command on stdin and the value
  hex-encoded (`-X`). That keeps it out of every process's argv, which `ps`
  shows to any local user. It is read back with `security
  find-generic-password -s suite-install.<name> -a ITEM -w` into the CLI's
  memory only. The item is in your login Keychain under service
  `suite-install.<install name>`. That prefix is KEPT on purpose: renaming it
  would orphan every secret an install already stored.
- **Output.** No step prints a secret value. As a second layer, the CLI
  replaces every secret value it knows of (secrets.env, customer-secrets.env,
  `secrets/*`, and every input it resolved) with `<secret:NAME>` before
  printing. The transcript-hygiene test runs every step with the scrubber on
  and with it off.
- **The pocket-id sign-in link** is a credential until it is used or expires
  (30 minutes; see `LOGIN_TTL` in `setup/pocketid.py` for why it must stay
  above 15 minutes). The CLI opens it through `osascript` on stdin and saves it to
  `.setup/login-link` (0600) as a fallback. It is never printed.
- **Background jobs** read the Cloudflare token from its 0600 file or from the
  Keychain, and send it to `curl -K -` on stdin.

## pocket-id automation surface

pocket-id is pinned to `ghcr.io/pocket-id/pocket-id:v2.18.0` (the image `:v2`
resolved to on 2026-10-05, same digest). It was a floating `:v2` until task
01a0d6ab stage 6: pocket-id decides the sign-in code's length from its TTL
(6 characters at 15 minutes or less, 12 above), and its frontend's
expectation of that length can move between releases, so the version is
pinned and moving it is a deliberate change that re-runs the sign-in probe. Setup uses `STATIC_API_KEY`, which pocket-id documents as
granting admin access and being "useful for declarative installations". It
makes no database writes. The endpoints are `GET/POST /api/users`, `GET
/api/users/:id/webauthn-credentials`, `POST
/api/users/:id/one-time-access-token`, `GET/POST/PUT /api/oidc/clients[/:id]`
and `GET/POST /api/oidc/clients/:id/secrets` (POST takes a caller-supplied
`secret`). Creating the admin also closes pocket-id's public `/setup` page
(measured on a real v2.16.0 container: `GET /api/signup/setup` then returns 404
`setup_not_available`). That page lets whoever reaches it first become admin,
so `up` creates the admin (ADMIN_EMAIL) as soon as pocket-id answers. The open
window lasts from pocket-id's first answer to that call, not until a later step
runs. If the call cannot be made within 120 s, `up` fails with
`admin_not_created` and says so.

Burrow core calls pocket-id's admin API too, for its Users page
(`/admin/sign-in-users`, Burrow admins only; task 01a113ea). On every
bundled-pocket-id install the renderer gives core-platform three env vars:
`POCKET_ID_ADMIN_ENABLED="true"` (the page's switch; only the exact string
`true` turns it on), `POCKET_ID_ADMIN_URL=http://pocket-id:1411` (the same
upstream Caddy proxies the auth host to) and `POCKET_ID_API_KEY`, which is
`STATIC_API_KEY` under a second name. The key is an admin-grade pocket-id
credential. It lives in `secrets.env` (0600), never in `compose.yaml`, and
core reads it server-side only: it is sent as the `X-API-Key` header and is
never logged or shown in the browser. Core's endpoints are `GET/POST
/api/users`, `GET/PUT/DELETE /api/users/:id`, `GET
/api/users/:id/webauthn-credentials` and `POST
/api/users/:id/one-time-access-token`. The sign-in links it mints use a 30
minute TTL for the same reason as `LOGIN_TTL`: at 15 minutes or less pocket-id
mints a 6-character code that never auto-submits from `/lc/<code>`. With
`[auth] mode = "external-oidc"` there is no bundled pocket-id, and none of the
three vars is written. To keep the key but ship with the page off, delete
`POCKET_ID_ADMIN_ENABLED` from core-platform's environment.

The bundled pocket-id runs with `LOG_LEVEL=error` in its compose environment
(task 01a114c1). Its request log records the full URL path, and every
one-time sign-in code travels in one: `GET /lc/<code>` and `POST
/api/one-time-access-token/<code>`. pocket-id logs every response below 500 at
info, except a rate-limited 429 at warn, so `warn` would still print a code.
At `error`, only 5xx request lines are written. The residual is that a 5xx on
either path still logs that path, code included. `docker compose logs
pocket-id` still shows errors, including the failures the setup steps point
you to. Never set `debug`: it also logs SQL queries.

## JSON contract (version 1)

The desktop app (task 01a0d6b9) and the skill depend on this contract. Any
change that is not additive bumps `contract_version`.

Every command prints one JSON object that has `contract_version` and `ok`.

`setup status --json`:

```json
{
  "contract_version": 1, "ok": true,
  "install_dir": "...", "install_name": "...", "target": "mac", "primary": "...",
  "next_step": "domain" | null,
  "complete": false,
  "keychain_service": "suite-install.<name>",
  "inputs": {"NAME": {"secret": true, "optional": false, "provided": true,
                      "kind": "file|env|keychain|literal|null", "description": "..."}},
  "steps": [{"name": "preflight", "summary": "...", "advisory": false,
             "state": "done|pending|blocked", "needs": ["INPUT", ...],
             "blocked_reason": "waiting for render | awaiting_passkey | ...",
             "skipped": true, "note": "not applicable: ...",
             "last_run": "...Z", "last_error": "error_code"}]
}
```

`setup run <step>` on success:

```json
{"contract_version": 1, "ok": true, "step": "tunnel", "outputs": {...non-secret...},
 "human_steps": [{"why": "...", "command": "sudo ...", "steps": "...", "needs_sudo": true}],
 "advisory": true}
```

And on failure:

```json
{"contract_version": 1, "ok": false, "step": "domain", "error_code": "hostname_too_deep",
 "error": "...", "remediation": "...", "outputs": {...}}
```

Exit codes:

- 0: ok.
- 1: the step failed; read `error_code` and `remediation`.
- 2: refused (`usage`, `secret_in_argv`, `step_order`, `unknown_input`, ...).
- 3: blocked on a human (`input_missing`, `awaiting_passkey`).

## Files

- `burrow-install`: wrapper that picks a Python.
- `suite-install`: the old name, a three-line wrapper that prints one deprecation
  line and execs `burrow-install`, so a desktop app or a script holding the old
  path keeps working.
- `backup.sh`: the dump, verify and rotate job.
- `ip-watch.sh`: the public-IP watcher.
- `proof.sh`: the data-plane proof, run on the Mac after `verify`. It checks memory ranks, a
  file round trip, arm64, RAM, meetings on and off, and the transcript's secret counts. Its
  logic is in `../burrow_install/proof_mac.py`, and the results are recorded in ADR 0053 under
  "Proof (Mac)".
- `../burrow_install/setup/`: the CLI.
- `../skill/SKILL.md`: the skill.
- `../tests/test_setup_*.py`, `../tests/test_mac_proof.py`: the tests.

The two LaunchAgent plists are generated by `burrow_install/setup/macos.py`
(`plistlib`), so no template file can drift from the code. Install
directory layout: `install.toml`, `state.json` (0600, non-secret), the render
(`compose.yaml`, `Caddyfile`, `secrets.env` 0600, ...), `bin/` (copies of the
two scripts) and `.setup/` (0700).
