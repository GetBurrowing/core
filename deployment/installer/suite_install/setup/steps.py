"""The step registry and the steps that are not Cloudflare or pocket-id.

Every step is idempotent and resumable: a re-run detects what exists and
skips it, never rotates a secret under a live volume (render always reuses
secrets.env), and records its outcome in state.json.

Target split (architect note, task 01a0d6ab): ``render``, ``up``,
``pocket-id``, ``oidc-client``, ``backup``'s dump logic and ``verify`` read
only the rendered install; ``domain``, ``tunnel``, ``ddns`` and ``keepalive``
are Mac-specific and say so in ``applies``.
"""

import base64
import json
import os
import shutil
import sys

from .. import registry
from .. import render as render_mod
from ..secrets import SecretsError, parse_env_file
from . import cloudflare, inputs, macos, pocketid, web
from .state import SetupError

INSTALLER_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MAC_DIR = os.path.join(INSTALLER_DIR, "mac")

# Compressed linux/arm64 sizes in MiB, measured 2026-09-25 with
# `docker buildx imagetools inspect --raw` (sum of layer sizes) for the images
# the mac target pulls. suite-memory-service carries torch and dominates.
IMAGE_MIB = {
    "core-platform": 276,
    "memory-service": 5851,
    "files-service": 151,
    "core-postgres": 146,
    "pocket-id": 30,
    "caddy": 21,
    "cloudflared": 26,
    "livekit": 37,
    "meeting-transcriber": 318,
}
# ESTIMATE, not measured: Docker Desktop's containerd store keeps the
# compressed blob AND the unpacked snapshot; an unpack ratio of ~2 gives 3x.
DISK_FACTOR = 3
DISK_HEADROOM_GIB = 10
MIN_VM_MEMORY_GIB = 4

LICENCES = (
    "Docker Desktop is free for personal use, education, non-commercial open source and "
    "small businesses (fewer than 250 employees AND under $10M annual revenue); larger "
    "commercial use needs a paid subscription. OrbStack is free for personal non-commercial "
    "use; commercial use needs a paid licence. The compose files are runtime-agnostic; "
    "Colima (MIT) also runs them but is not tested."
)
FILEVAULT_TRUTH = (
    "With FileVault ON, a Mac that restarts after a power cut waits at the FileVault unlock "
    "screen: no user session, so no Docker Desktop or OrbStack and no Suite, whatever "
    "autorestart says. Unattended recovery needs FileVault OFF plus automatic login (System "
    "Settings, admin password). That is the owner's security trade-off; this CLI reports it "
    "and never changes it."
)


class Ctx:
    """What a step may touch. Tests build one with fakes."""

    def __init__(self, install, state, host, keychain, environ=None):
        self.install = install
        self.state = state
        self.host = host
        self.keychain = keychain
        self.environ = dict(os.environ if environ is None else environ)
        self._manifest = None
        self.cloudflare_api = cloudflare.API
        self.pocketid_url = None  # default https://<auth_host>
        self.docker_auth_url = "https://auth.docker.io/token"
        self.docker_registry_url = "https://registry-1.docker.io"
        self.url_for = lambda host, path: f"https://{host}{path}"
        self.backup_root = None  # default ~/SuiteBackups
        self.log_root = None  # default ~/Library/Logs
        self.disk_free_bytes = lambda path: shutil.disk_usage(path).free
        self.health_wait_seconds = 600
        self.seen_secrets = {}

    @property
    def manifest(self):
        if self._manifest is None:
            self._manifest = self.install.manifest()
        return self._manifest

    @property
    def install_name(self):
        return self.manifest["install"]["name"]

    def value(self, name, required=True):
        value = inputs.resolve(self, name, required=required)
        if value is not None and inputs.declared(self.manifest)[name].secret:
            self.seen_secrets[name] = value
        return value

    def rendered_secret(self, name):
        value = self.install.read_secret(name)
        if value:
            self.seen_secrets[name] = value
        return value

    def compose_argv(self, *args):
        return [
            "docker",
            "compose",
            "--project-directory",
            self.install.path,
            "-f",
            self.install.file("compose.yaml"),
            *args,
        ]

    def compose(self, *args, env=None, timeout=600):
        return self.host.run(self.compose_argv(*args), env=env, timeout=timeout)

    def secret_values(self):
        """Every secret value this process knows of, for the output scrubber."""
        values = dict(self.seen_secrets)
        for rel in ("secrets.env", "customer-secrets.env"):
            path = self.install.file(rel)
            if os.path.exists(path):
                try:
                    for k, v in parse_env_file(path).items():
                        values.setdefault(f"{rel}:{k}", v)
                except SecretsError:
                    pass
        secret_dir = self.install.file("secrets")
        if os.path.isdir(secret_dir):
            for name in os.listdir(secret_dir):
                try:
                    with open(os.path.join(secret_dir, name), encoding="utf-8") as handle:
                        values.setdefault(f"secrets/{name}", handle.read().strip())
                except OSError:
                    pass
        return {k: v for k, v in values.items() if v and len(v) >= 8}


class Step:
    def __init__(self, name, run, summary, needs=None, after=(), applies=None, advisory=False):
        self.name = name
        self.run = run
        self.summary = summary
        self._needs = needs or (lambda m: [])
        self.after = tuple(after)
        self._applies = applies or (lambda m: (True, None))
        self.advisory = advisory

    def needs(self, manifest):
        return list(self._needs(manifest))

    def applies(self, manifest):
        return self._applies(manifest)


def _mac(m):
    if m["install"]["target"] != "mac":
        return False, "target is not mac"
    return True, None


def _tunnel_mode(m):
    ok, why = _mac(m)
    if not ok:
        return ok, why
    if m["access"]["mode"] != "cloudflare-tunnel":
        return False, f"access mode is {m['access']['mode']}"
    return True, None


def _ddns_applies(m):
    ok, why = _mac(m)
    if not ok:
        return ok, why
    if not m["services"].get("meetings"):
        return False, "meetings are off"
    if m["meetings"]["media_reach"] != "public":
        return False, f"media_reach is {m['meetings']['media_reach']} (no port-forward or DDNS)"
    return True, None


def _pocket(m):
    if m["auth"]["mode"] != "bundled-pocket-id":
        return False, f"auth mode is {m['auth']['mode']}"
    return True, None


def _need_registry(m):
    return [inputs.REGISTRY_AUTH] if inputs.private_images(m) else []


# ---------------------------------------------------------------------------
# preflight (read-only)
# ---------------------------------------------------------------------------


def _docker_hub_repo(image):
    ref = image
    for prefix in ("docker.io/", "index.docker.io/"):
        ref = ref.removeprefix(prefix)
    name, _, tag = ref.partition(":")
    return name, tag or "latest"


def check_registry_auth(ctx, auth_text, image):
    """Prove the credential can pull ``image`` (manifest HEAD); never prints it."""
    try:
        config = json.loads(auth_text)
    except ValueError as exc:
        raise SetupError(
            "registry_auth_invalid", "REGISTRY_AUTH is not JSON", "supply a docker config.json"
        ) from exc
    entry = None
    for key in (
        "https://index.docker.io/v1/",
        "index.docker.io",
        "docker.io",
        "registry-1.docker.io",
    ):
        entry = (config.get("auths") or {}).get(key)
        if entry:
            break
    if not entry or not entry.get("auth"):
        raise SetupError(
            "registry_auth_unusable",
            "REGISTRY_AUTH has no inline Docker Hub `auth` (a credsStore reference cannot be "
            "used from the install's own DOCKER_CONFIG)",
            'write {"auths": {"https://index.docker.io/v1/": {"auth": "<base64 of '
            'user:read-token>"}}} to a 0600 file and re-supply REGISTRY_AUTH',
        )
    repo, tag = _docker_hub_repo(image)
    basic = entry["auth"]
    ctx.seen_secrets["registry-auth"] = basic
    try:
        base64.b64decode(basic, validate=True)
    except ValueError as exc:
        raise SetupError("registry_auth_invalid", "REGISTRY_AUTH auth is not base64", None) from exc
    try:
        resp = web.request(
            "GET",
            f"{ctx.docker_auth_url}?service=registry.docker.io&scope=repository:{repo}:pull",
            headers={"Authorization": f"Basic {basic}"},
        )
        token = (resp.json() or {}).get("token") if resp.status == 200 else None
        if not token:
            raise SetupError(
                "registry_auth_rejected",
                f"Docker Hub refused the credential (HTTP {resp.status})",
                "check the user and read token in REGISTRY_AUTH",
            )
        ctx.seen_secrets["registry-token"] = token
        head = web.request(
            "HEAD",
            f"{ctx.docker_registry_url}/v2/{repo}/manifests/{tag}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.oci.image.index.v1+json, "
                "application/vnd.docker.distribution.manifest.list.v2+json",
            },
        )
    except web.WebError as exc:
        raise SetupError(
            "registry_unreachable", f"{exc.kind}: {exc.detail}", "check the internet connection"
        ) from exc
    if head.status != 200:
        raise SetupError(
            "registry_auth_rejected",
            f"the credential cannot pull {repo}:{tag} (HTTP {head.status})",
            "the Docker Hub user needs read access to the example repositories",
        )
    return f"{repo}:{tag} pullable"


def _lsof_lines(ctx, argv):
    result = ctx.host.run(argv, timeout=30)
    rows = []
    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 9:
            rows.append(f"{parts[0]} {parts[8]}")
    return sorted(set(rows))


def preflight(ctx):
    m = ctx.manifest
    outputs, blockers, advisories = {}, [], []

    info = ctx.host.run(["docker", "info", "--format", "{{json .}}"], timeout=60)
    if not info.ok:
        blockers.append(
            (
                "runtime_not_running",
                "docker info failed: no container runtime is running",
                (
                    "start Docker Desktop or OrbStack (installing either needs the Mac owner's "
                    "admin password), then re-run preflight"
                ),
            )
        )
    else:
        try:
            doc = json.loads(info.stdout)
        except ValueError:
            doc = {}
        os_name = doc.get("OperatingSystem", "")
        runtime = (
            "Docker Desktop"
            if "Docker Desktop" in os_name
            else "OrbStack"
            if "OrbStack" in os_name
            else os_name or "unknown"
        )
        vm_gib = round(int(doc.get("MemTotal") or 0) / 2**30, 1)
        outputs["runtime"] = runtime
        outputs["runtime_server_version"] = doc.get("ServerVersion")
        outputs["runtime_vm_memory_gib"] = vm_gib
        outputs["runtime_arch"] = doc.get("Architecture")
        if vm_gib and vm_gib < MIN_VM_MEMORY_GIB:
            advisories.append(
                f"the runtime VM has {vm_gib} GiB; give it at least {MIN_VM_MEMORY_GIB} GiB "
                "(Docker Desktop: Settings > Resources)"
            )
        compose = ctx.host.run(["docker", "compose", "version", "--short"], timeout=60)
        if not compose.ok:
            blockers.append(
                (
                    "compose_missing",
                    "docker compose is not available",
                    "Docker Desktop and OrbStack ship it; update the runtime",
                )
            )
        else:
            outputs["compose_version"] = compose.stdout.strip()

    outputs["python"] = ".".join(str(p) for p in sys.version_info[:3])

    containers = registry.enabled_containers(m)
    image_mib = sum(IMAGE_MIB.get(c, 0) for c in containers)
    need_gib = round(image_mib * DISK_FACTOR / 1024 + DISK_HEADROOM_GIB, 1)
    free_gib = round(ctx.disk_free_bytes(ctx.host.home()) / 2**30, 1)
    outputs["disk_free_gib"] = free_gib
    outputs["disk_required_gib"] = need_gib
    if free_gib < need_gib:
        blockers.append(
            (
                "disk_low",
                (
                    f"{free_gib} GiB free; this install needs about {need_gib} GiB "
                    f"({image_mib} MiB compressed images x{DISK_FACTOR} + {DISK_HEADROOM_GIB} GiB)"
                ),
                "free disk space (a full disk stops the runtime VM), then re-run preflight",
            )
        )

    if ctx.host.platform == "darwin":
        mem = ctx.host.run(["sysctl", "-n", "hw.memsize"], timeout=10)
        if mem.ok and mem.stdout.strip().isdigit():
            outputs["ram_gib"] = round(int(mem.stdout.strip()) / 2**30, 1)
    outputs["listeners_tcp_before"] = _lsof_lines(ctx, ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"])
    if m["services"].get("meetings"):
        busy = _lsof_lines(
            ctx, ["lsof", "-nP", f"-iTCP:{registry.LIVEKIT_TCP_PORT}", "-sTCP:LISTEN"]
        ) + _lsof_lines(ctx, ["lsof", "-nP", f"-iUDP:{registry.LIVEKIT_UDP_PORT}"])
        outputs["meetings_ports"] = (
            f"{registry.LIVEKIT_TCP_PORT}/tcp, {registry.LIVEKIT_UDP_PORT}/udp"
        )
        if busy:
            blockers.append(
                (
                    "port_in_use",
                    "LiveKit's media ports are taken: " + "; ".join(busy),
                    "stop that process or turn meetings off (setup init --meetings off)",
                )
            )

    private = inputs.private_images(m)
    if private:
        auth_text = ctx.value(inputs.REGISTRY_AUTH)
        image = render_mod.plan(m).services[private[0]].image
        outputs["registry_auth"] = check_registry_auth(ctx, auth_text, image)
    outputs["licences"] = LICENCES
    if advisories:
        outputs["advisories"] = advisories
    if blockers:
        code, message, remediation = blockers[0]
        outputs["blockers"] = [c for c, _m, _r in blockers]
        raise SetupError(code, message, remediation, outputs=outputs)
    return outputs


# ---------------------------------------------------------------------------
# render / up
# ---------------------------------------------------------------------------


def _write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)


def render_step(ctx):
    m = ctx.manifest
    install = ctx.install
    customer = {}
    for ref in inputs.customer_refs(m):
        customer[ref] = ctx.value(ref)
    if m["install"]["target"] == "mac" and m["access"]["mode"] == "cloudflare-tunnel":
        ref = m["access"]["tunnel_token_ref"]
        token = ctx.rendered_secret(ref)
        if not token:
            raise SetupError(
                "step_order",
                f"{ref} is not in secrets.env yet",
                "run `setup run tunnel` first",
                exit_code=2,
            )
        customer[ref] = token
    auth_text = ctx.value(inputs.REGISTRY_AUTH) if inputs.private_images(m) else None

    before = {}
    if os.path.exists(install.secrets_path):
        before = parse_env_file(install.secrets_path)

    work = os.path.join(install.setup_dir(), f"render-{os.getpid()}")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, mode=0o700)
    try:
        customer_path = os.path.join(work, "customer.env")
        _write_private(customer_path, "".join(f"{k}={v}\n" for k, v in customer.items()))
        auth_path = None
        if auth_text is not None:
            auth_path = os.path.join(work, "registry-auth.json")
            _write_private(auth_path, auth_text)
        out = os.path.join(work, "out")
        try:
            rendered = render_mod.render(
                m,
                out,
                reuse_secrets=install.secrets_path if before else None,
                customer_secrets=customer_path,
                registry_auth=auth_path,
            )
        except render_mod.RenderError as exc:
            raise SetupError(exc.code, exc.line(), "fix the manifest with `setup init`") from exc
        new_files = sorted(rendered.files)
        for rel in new_files:
            dest = install.file(rel)
            os.makedirs(os.path.dirname(dest), mode=0o755, exist_ok=True)
            os.replace(os.path.join(out, rel), dest)
        removed = []
        for rel in ctx.state.get("rendered_files", []):
            if rel not in new_files and os.path.exists(install.file(rel)):
                os.unlink(install.file(rel))
                removed.append(rel)
        ctx.state["rendered_files"] = new_files
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if auth_text is not None:
        docker_dir = install.file(".docker")
        os.makedirs(docker_dir, mode=0o700, exist_ok=True)
        _write_private(
            os.path.join(docker_dir, "config.json"),
            install_docker_config(auth_text, ctx.host.home()),
        )

    after = parse_env_file(install.secrets_path)
    return {
        "files": new_files,
        "removed": removed,
        "services": registry.enabled_containers(m),
        "secrets_reused": sorted(k for k in after if before.get(k) == after[k]),
        "secrets_new": sorted(k for k in after if k not in before),
        "secrets_changed": sorted(k for k in after if k in before and before[k] != after[k]),
    }


# Where docker CLI plugins (compose) live. DOCKER_CONFIG moves the per-user
# plugin dir along with the credential: OrbStack installs `docker-compose`
# only into ~/.docker/cli-plugins, so with the install's DOCKER_CONFIG the
# `compose` subcommand vanished and `up` failed with "unknown flag:
# --project-directory" (measured on rock, 2026-10-05). Docker Desktop's
# system dirs are listed too; docker skips a listed dir that does not exist.
PLUGIN_DIRS = (
    "{home}/.docker/cli-plugins",
    "/usr/local/lib/docker/cli-plugins",
    "/opt/homebrew/lib/docker/cli-plugins",
    "/Applications/Docker.app/Contents/Resources/cli-plugins",
)


def install_docker_config(auth_text, home):
    """The install's docker config.json: the registry credential plus the
    user's CLI plugin dirs (``cliPluginsExtraDirs``), so ``docker compose``
    still resolves under the install's own DOCKER_CONFIG."""
    doc = json.loads(auth_text)
    doc["cliPluginsExtraDirs"] = [d.format(home=home) for d in PLUGIN_DIRS]
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def _docker_env(ctx):
    """Point docker at the install's registry credential without losing the runtime.

    DOCKER_CONFIG swaps the whole config dir (and with it the current
    context), so the active context's endpoint is pinned as DOCKER_HOST first.
    """
    config = ctx.install.file(".docker", "config.json")
    if not os.path.exists(config):
        return None
    env = {"DOCKER_CONFIG": ctx.install.file(".docker")}
    host = ctx.host.run(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout=30
    )
    if host.ok and host.stdout.strip():
        env["DOCKER_HOST"] = host.stdout.strip()
    return env


def compose_ps(ctx):
    result = ctx.compose("ps", "--all", "--format", "json", timeout=60)
    if not result.ok:
        return None
    text = result.stdout.strip()
    if not text:
        return []
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


# Rendered config files bind-mounted into a running container, as
# {install-relative file: (service, path inside the container)}. A re-render
# replaces the file, but a single-file bind mount keeps pointing at the old
# inode, and `docker compose up -d` sees an unchanged service and leaves it
# running. Measured on rock, 2026-10-05: after the meetings flip added the
# livekit host block, caddy still served its first Caddyfile (the in-container
# path read "No such file") and https://livekit-<tag>.<zone>/ returned 404.
MOUNTED_CONFIGS = {
    "Caddyfile": ("caddy", "/etc/caddy/Caddyfile"),
    "livekit.yaml": ("livekit", "/etc/livekit.yaml"),
}


def _recreate_stale_mounts(ctx):
    """Force-recreate each service whose mounted config differs from the render.

    Compares the file on disk with what the container reads at the mount path
    (a stale mount reads as missing). Only services that are running are
    checked; a just-created container already has the new file.
    """
    import hashlib

    recreated = []
    for rel, (service, path) in MOUNTED_CONFIGS.items():
        host_path = ctx.install.file(rel)
        if not os.path.exists(host_path):
            continue
        with open(host_path, "rb") as handle:
            want = hashlib.sha256(handle.read()).hexdigest()
        seen = ctx.compose("exec", "-T", service, "cat", path, timeout=60)
        if seen.ok and hashlib.sha256((seen.stdout or "").encode()).hexdigest() == want:
            continue
        if not seen.ok and "is not running" in (seen.stderr or ""):
            continue
        result = ctx.compose(
            "up", "-d", "--no-deps", "--force-recreate", service, env=_docker_env(ctx), timeout=600
        )
        if not result.ok:
            raise SetupError(
                "compose_up_failed",
                f"recreating {service} for its changed {rel} exited {result.returncode}",
                f"see `docker compose logs {service}`",
            )
        recreated.append(service)
    return recreated


def up(ctx, poll=5):
    import time

    wait_seconds = ctx.health_wait_seconds

    if not os.path.exists(ctx.install.file("compose.yaml")):
        raise SetupError("step_order", "no compose.yaml", "run `setup run render`", exit_code=2)
    result = ctx.compose("up", "-d", "--remove-orphans", env=_docker_env(ctx), timeout=3600)
    if not result.ok:
        tail = "\n".join((result.stderr or "").strip().splitlines()[-8:])
        code = (
            "registry_pull_denied"
            if "denied" in tail or "unauthorized" in tail
            else "compose_up_failed"
        )
        raise SetupError(
            code,
            f"docker compose up exited {result.returncode}: {tail}",
            "re-check REGISTRY_AUTH (preflight) if a pull was denied; otherwise see "
            "`docker compose logs`",
        )
    recreated = _recreate_stale_mounts(ctx)
    deadline = time.monotonic() + wait_seconds
    services = {}
    while True:
        rows = compose_ps(ctx) or []
        services = {r.get("Service"): (r.get("State", ""), r.get("Health", "") or "") for r in rows}
        ready = services and all(
            state == "running" and health in ("", "healthy") for state, health in services.values()
        )
        if ready or time.monotonic() >= deadline:
            break
        time.sleep(poll)
    outputs = {
        "services": {s: (f"{st}/{h}" if h else st) for s, (st, h) in sorted(services.items())}
    }
    if recreated:
        outputs["recreated_for_config"] = recreated
    if not ready:
        bad = [s for s, (st, h) in services.items() if st != "running" or h not in ("", "healthy")]
        raise SetupError(
            "services_unhealthy",
            f"not ready after {wait_seconds}s: {', '.join(sorted(bad)) or 'no services'}",
            "see `docker compose logs <service>`; re-run `setup run up` once fixed",
            outputs=outputs,
        )
    if _pocket(ctx.manifest)[0]:
        # pocket-id offers its public /setup page (first admin, no auth) until a
        # user exists. Create the admin now, so that window lasts only as long
        # as pocket-id takes to answer, not until someone runs the next step.
        outputs["pocketid_admin"] = _close_setup_window(ctx, deadline=time.monotonic() + 120)
    return outputs


def _close_setup_window(ctx, deadline, poll=3):
    import time

    client = _pocket_client(ctx)
    email = ctx.value(inputs.ADMIN_EMAIL)
    username = ctx.value(inputs.ADMIN_USERNAME, required=False) or pocketid.default_username(email)
    while True:
        try:
            user, action = pocketid.ensure_admin(client, email, username)
        except SetupError as exc:
            if exc.code != "pocketid_unreachable" or time.monotonic() >= deadline:
                raise SetupError(
                    "admin_not_created",
                    f"pocket-id admin could not be created yet ({exc.code}): {exc.message}",
                    "run `setup run pocket-id` as soon as the auth hostname answers: until an "
                    "admin exists, pocket-id's /setup page lets anyone who reaches it first "
                    "become admin",
                ) from exc
            time.sleep(poll)
            continue
        ctx.state["ids"]["pocketid_admin_id"] = user["id"]
        return action


# ---------------------------------------------------------------------------
# pocket-id / oidc-client (target-agnostic; see pocketid.py)
# ---------------------------------------------------------------------------


def _pocket_client(ctx):
    key = ctx.rendered_secret("STATIC_API_KEY")
    if not key:
        raise SetupError(
            "step_order",
            "STATIC_API_KEY is not in secrets.env",
            "run `setup run render` and `setup run up` first",
            exit_code=2,
        )
    base = ctx.pocketid_url or f"https://{registry.Ctx(ctx.manifest).auth_host}"
    return pocketid.Client(base, key)


def pocket_id(ctx):
    client = _pocket_client(ctx)
    email = ctx.value(inputs.ADMIN_EMAIL)
    username = ctx.value(inputs.ADMIN_USERNAME, required=False) or pocketid.default_username(email)
    user, action = pocketid.ensure_admin(client, email, username)
    ctx.state["ids"]["pocketid_admin_id"] = user["id"]
    outputs = {"admin_username": username, "admin": action}
    count = pocketid.passkey_count(client, user["id"])
    outputs["passkeys"] = count
    if count:
        link_file = os.path.join(ctx.install.file(".setup"), "login-link")
        if os.path.exists(link_file):
            os.unlink(link_file)
        return outputs
    auth_host = registry.Ctx(ctx.manifest).auth_host
    link = pocketid.login_link(client, user["id"], auth_host)
    ctx.seen_secrets["login-link"] = link
    link_file = os.path.join(ctx.install.setup_dir(), "login-link")
    _write_private(link_file, link + "\n")
    opened = ctx.host.open_url(link)
    outputs.update(
        {
            "browser_opened": opened.ok,
            "login_link_file": link_file,
            "login_link_expires_in": pocketid.LOGIN_TTL,
        }
    )
    expiry = (
        f" The sign-in link works once and expires {pocketid.LOGIN_TTL} after it was made; "
        "if it has expired, re-running `setup run pocket-id` makes a new one."
    )
    raise SetupError(
        "awaiting_passkey",
        f"pocket-id admin {username} has no passkey yet",
        (
            "In the browser window that opened you are signed in to pocket-id as the admin; "
            "on the Account page choose Add passkey and follow your device's prompt. "
            "Then re-run `setup run pocket-id`." + expiry
            if opened.ok
            else f"Open the one-time sign-in link stored in {link_file} (mode 0600; do not "
            "paste it into chat), add a passkey on the Account page, then re-run "
            "`setup run pocket-id`." + expiry
        ),
        exit_code=3,
        outputs=outputs,
    )


def oidc_client(ctx):
    client = _pocket_client(ctx)
    secret = ctx.rendered_secret("OIDC_CLIENT_SECRET")
    if not secret:
        raise SetupError("step_order", "OIDC_CLIENT_SECRET missing", "run `setup run render`", 2)
    primary = ctx.manifest["domain"]["primary"]
    record, action = pocketid.ensure_client(client, primary)
    dropped = pocketid.drop_created_secret(client, record) if action == "created" else None
    secret_id, secret_action = pocketid.ensure_secret(
        client, secret, ctx.state["ids"].get("oidc_secret_id")
    )
    ctx.state["ids"]["oidc_secret_id"] = secret_id
    return {
        "client_id": pocketid.CLIENT_ID,
        "client": action,
        "callback_url": pocketid.callback_url(primary),
        "pkce": bool((record or {}).get("pkceEnabled", True)),
        "secret": secret_action,
        "generated_secret_deleted": bool(dropped),
        "secret_source": "secrets.env OIDC_CLIENT_SECRET (already read by core-platform)",
        "core_restarted": False,
    }


# ---------------------------------------------------------------------------
# keepalive (advisory)
# ---------------------------------------------------------------------------


def keepalive(ctx):
    outputs = {"power_failure_truth": FILEVAULT_TRUTH}
    human = []
    if ctx.host.platform != "darwin":
        outputs["note"] = "not macOS: nothing checked"
        return outputs, human
    pm = macos.parse_pmset(ctx.host.run(["pmset", "-g"], timeout=30).stdout)
    outputs["pmset"] = pm
    if pm.get("sleep") != "0" or pm.get("disksleep") != "0" or pm.get("autorestart") != "1":
        human.append(
            {
                "why": "keep the Mac awake and restart it after a power cut",
                "command": "sudo pmset -a sleep 0 disksleep 0 autorestart 1",
                "needs_sudo": True,
            }
        )
    fv = macos.filevault_on(ctx.host.run(["fdesetup", "status"], timeout=30).stdout)
    outputs["filevault"] = {True: "on", False: "off", None: "unknown"}[fv]
    auto = ctx.host.run(
        ["defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"],
        timeout=30,
    )
    outputs["automatic_login"] = "on" if auto.ok and auto.stdout.strip() else "off"
    if fv is not False or outputs["automatic_login"] != "on":
        human.append(
            {
                "why": "unattended recovery after a power cut (optional; a security trade-off "
                "only the owner makes)",
                "command": None,
                "steps": "System Settings > Privacy & Security > FileVault: Turn Off; then "
                "Users & Groups > Automatically log in as: <this user>",
                "needs_sudo": True,
            }
        )
    dd = macos.docker_desktop_autostart(ctx.host.home())
    if dd is not None:
        path, key, value = dd
        if value is True:
            outputs["runtime_start_at_login"] = "on (Docker Desktop)"
        else:
            macos.set_json_key(path, key, True)
            outputs["runtime_start_at_login"] = f"set on (Docker Desktop {key})"
    elif ctx.host.which("orbctl") or os.path.isdir("/Applications/OrbStack.app"):
        outputs["runtime_start_at_login"] = "not changed (OrbStack)"
        human.append(
            {
                "why": "start the runtime when the user logs in",
                "command": None,
                "steps": "OrbStack > Settings > General > Start at login",
                "needs_sudo": False,
            }
        )
    else:
        outputs["runtime_start_at_login"] = "unknown runtime"
        human.append(
            {
                "why": "start the runtime when the user logs in",
                "command": None,
                "steps": "enable start-at-login in your container runtime's settings",
                "needs_sudo": False,
            }
        )
    return outputs, human


# ---------------------------------------------------------------------------
# backup / ddns (LaunchAgents)
# ---------------------------------------------------------------------------


def _copy_script(ctx, name):
    bin_dir = ctx.install.file("bin")
    os.makedirs(bin_dir, mode=0o755, exist_ok=True)
    dest = os.path.join(bin_dir, name)
    shutil.copyfile(os.path.join(MAC_DIR, name), dest)
    os.chmod(dest, 0o755)
    return dest


def backup(ctx):
    name = ctx.install_name
    root = ctx.backup_root or os.path.join(ctx.host.home(), "SuiteBackups")
    backup_dir = os.path.join(root, name)
    logs = ctx.log_root or os.path.join(ctx.host.home(), "Library", "Logs")
    os.makedirs(backup_dir, mode=0o700, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    log = os.path.join(logs, f"suite-install-{name}-backup.log")
    script = _copy_script(ctx, "backup.sh")
    args = ["/bin/bash", script, ctx.install.path, backup_dir, "14", registry.POSTGRES_USER]
    outputs = {"backup_dir": backup_dir, "log": log, "keep": 14, "schedule": "daily 03:15"}
    if ctx.host.platform == "darwin":
        label = macos.agent_label(name, "backup")
        plist = macos.agent_plist(label, args, log, calendar={"Hour": 3, "Minute": 15})
        outputs["launch_agent"] = macos.install_agent(ctx.host, label, plist)
    else:
        outputs["launch_agent"] = "not installed (not macOS); schedule the same command with cron"
    result = ctx.host.run(args, timeout=3600)
    dumps, verified = {}, {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "dump":
            dumps[parts[1]] = parts[2]
        elif len(parts) >= 3 and parts[0] == "verified":
            verified[parts[1]] = int(parts[2])
    outputs["dumps"] = dumps
    outputs["pg_restore_list_entries"] = verified
    if not result.ok or not dumps or set(dumps) != set(verified):
        tail = "\n".join((result.stderr or "").strip().splitlines()[-5:])
        raise SetupError(
            "backup_failed",
            f"backup.sh exited {result.returncode}: {tail}",
            f"see {log}; the core-postgres container must be running",
            outputs=outputs,
        )
    return outputs


def ddns(ctx):
    m = ctx.manifest
    name = ctx.install_name
    media_host = m["meetings"].get("media_host")
    token_arg, zone_arg = "-", "-"
    if media_host:
        ref = ctx.state["inputs"].get(inputs.CLOUDFLARE_API_TOKEN, "")
        k = inputs.kind(ref) if ref else None
        if k == "file":
            token_arg = "file:" + ref[1:]
        elif k == "keychain":
            token_arg = f"keychain:{macos.keychain_service(name)}:{ref[9:]}"
        else:
            raise SetupError(
                "ddns_token_ref_unusable",
                "the background job cannot read CLOUDFLARE_API_TOKEN from this process's env",
                "re-supply it with `setup secret CLOUDFLARE_API_TOKEN` or as a 0600 file",
            )
        zone_arg = ctx.state["ids"].get("zone_id") or "-"
        if zone_arg == "-":
            raise SetupError("step_order", "no zone id", "run `setup run domain`", exit_code=2)
    logs = ctx.log_root or os.path.join(ctx.host.home(), "Library", "Logs")
    os.makedirs(logs, exist_ok=True)
    log = os.path.join(logs, f"suite-install-{name}-ip-watch.log")
    script = _copy_script(ctx, "ip-watch.sh")
    args = ["/bin/bash", script, ctx.install.path, zone_arg, media_host or "-", token_arg]
    outputs = {"interval_seconds": 300, "log": log, "media_host": media_host or None}
    if ctx.host.platform == "darwin":
        label = macos.agent_label(name, "ip-watch")
        plist = macos.agent_plist(label, args, log, interval=300)
        outputs["launch_agent"] = macos.install_agent(ctx.host, label, plist)
    human = [
        {
            "why": "LiveKit media from the internet (media_reach = public)",
            "command": None,
            "steps": f"on your router, forward {registry.LIVEKIT_UDP_PORT}/udp and "
            f"{registry.LIVEKIT_TCP_PORT}/tcp to this Mac's LAN address. Tailscale "
            '(media_reach = "tailnet") needs no forward and no DDNS.',
            "needs_sudo": False,
        }
    ]
    return outputs, human


# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

CORE_LOG_TLS = ("certificate verify failed", "CERTIFICATE_VERIFY_FAILED", "unknown ca", "bad_cert")
CORE_LOG_UNREACHABLE = ("nxdomain", "econnrefused", "ehostunreach", "timeout", ":closed")


def _get(ctx, url, what, follow=True):
    try:
        return web.request("GET", url, follow_redirects=follow, headers={"Accept": "*/*"})
    except web.WebError as exc:
        remediation = {
            "tls_verify_failed": "the certificate at the edge did not verify: check the "
            "hostname is proxied (orange cloud) and one label below the zone",
            "dns_unresolved": "the hostname does not resolve: re-run `setup run tunnel` and "
            "allow a minute for DNS",
            "connection_refused": "nothing answered: check `docker compose ps cloudflared`",
        }.get(exc.kind, "check `docker compose ps` and `docker compose logs cloudflared`")
        raise SetupError(exc.kind, f"{what}: {exc.detail}", remediation) from exc


def _diagnose_login_error(ctx, auth_host, status):
    """/auth/login failed: tell an issuer TLS problem from an unreachable issuer."""
    discovery = ctx.url_for(auth_host, "/.well-known/openid-configuration")
    try:
        resp = web.request("GET", discovery)
        host_view = f"HTTP {resp.status} from this machine"
    except web.WebError as exc:
        return (
            f"issuer_{exc.kind}",
            (
                f"/auth/login returned {status}; the issuer {discovery} fails from this machine "
                f"too ({exc.kind}: {exc.detail})"
            ),
            "fix the auth hostname first (pocket-id container, tunnel ingress, DNS)",
        )
    logs = ctx.compose("logs", "--since", "15m", "core-platform", timeout=60)
    text = (logs.stdout + logs.stderr).lower() if logs.ok else ""
    if any(p.lower() in text for p in CORE_LOG_TLS):
        return (
            "core_issuer_tls_error",
            (
                f"/auth/login returned {status}; the issuer answers ({host_view}) but core's "
                "logs show a certificate-verify failure reaching it"
            ),
            (
                "core must see the edge's public certificate, not an internal one: check that "
                "no compose alias or CA mount redirects the auth host"
            ),
        )
    if any(p in text for p in CORE_LOG_UNREACHABLE):
        return (
            "core_issuer_unreachable",
            (
                f"/auth/login returned {status}; the issuer answers ({host_view}) but core's "
                "logs show it could not connect (DNS, refused or timeout)"
            ),
            (
                "check the runtime's DNS from inside the container: "
                "docker compose exec core-platform getent hosts <auth host>"
            ),
        )
    return (
        "auth_login_error",
        (
            f"/auth/login returned {status}; the issuer answers ({host_view}); core's logs did "
            "not match a TLS or connection pattern"
        ),
        "see `docker compose logs core-platform`",
    )


def verify(ctx):
    rctx = registry.Ctx(ctx.manifest)
    primary, auth_host = rctx.primary, rctx.auth_host
    outputs = {}
    health = _get(ctx, ctx.url_for(primary, "/health"), "health")
    outputs["health_status"] = health.status
    try:
        body = health.json() or {}
        if isinstance(body, dict):
            for key in ("commit", "status", "version"):
                if key in body:
                    outputs[f"health_body_{key}"] = body[key]
    except ValueError:
        pass
    if health.status != 200:
        raise SetupError(
            "health_not_ok",
            f"/health returned {health.status}",
            "see `docker compose logs core-platform`",
            outputs=outputs,
        )
    login = _get(ctx, ctx.url_for(primary, "/auth/login"), "auth/login", follow=False)
    outputs["auth_login_status"] = login.status
    location = login.header("Location") or login.header("location") or ""
    expected = ctx.url_for(auth_host, "/")
    if login.status not in (302, 303) or not location.startswith(expected):
        if login.status >= 500:
            code, message, remediation = _diagnose_login_error(ctx, auth_host, login.status)
        else:
            code, message, remediation = (
                "auth_login_unexpected",
                (
                    f"/auth/login returned {login.status} to {location.split('?')[0] or 'nowhere'}; "
                    f"expected a redirect to {expected}"
                ),
                "check OIDC_ISSUER in compose.yaml and run `setup run oidc-client`",
            )
        raise SetupError(code, message, remediation, outputs=outputs)
    outputs["auth_login_location"] = location.split("?")[0]
    page = _get(ctx, location, "issuer page")
    outputs["issuer_page_status"] = page.status
    outputs["issuer_page_type"] = (page.header("Content-Type") or "").split(";")[0]
    if page.status != 200 or outputs["issuer_page_type"] != "text/html":
        raise SetupError(
            "issuer_page_not_ok",
            f"{outputs['auth_login_location']} returned {page.status} "
            f"{outputs['issuer_page_type']}",
            "see `docker compose logs pocket-id`",
            outputs=outputs,
        )
    return outputs


# ---------------------------------------------------------------------------
# The registry, in run order.
# ---------------------------------------------------------------------------


def _cf(fn):
    def run(ctx):
        return fn(ctx, ctx.value(inputs.CLOUDFLARE_API_TOKEN))

    return run


STEPS = [
    Step(
        "preflight",
        preflight,
        "read-only checks: runtime, compose, python, disk, ports, RAM, registry credential",
        needs=_need_registry,
    ),
    Step(
        "domain",
        _cf(cloudflare.domain),
        "find the Cloudflare zone, enforce one label below it, verify the token",
        needs=lambda m: [inputs.CLOUDFLARE_API_TOKEN],
        applies=_tunnel_mode,
    ),
    Step(
        "tunnel",
        _cf(cloudflare.tunnel),
        "find or create the remotely-managed tunnel, its ingress, proxied CNAMEs and token",
        needs=lambda m: [inputs.CLOUDFLARE_API_TOKEN],
        after=("domain",),
        applies=_tunnel_mode,
    ),
    Step(
        "ddns",
        ddns,
        "public-IP watcher that restarts LiveKit (meetings, media_reach = public)",
        after=("domain",),
        applies=_ddns_applies,
    ),
    Step(
        "render",
        render_step,
        "render the install files (reusing secrets.env)",
        needs=lambda m: list(inputs.customer_refs(m)) + _need_registry(m),
        after=("preflight", "tunnel"),
    ),
    Step(
        "up",
        up,
        "docker compose up -d, wait for health, create the pocket-id admin at once",
        needs=lambda m: [inputs.ADMIN_EMAIL] if _pocket(m)[0] else [],
        after=("render",),
    ),
    Step(
        "pocket-id",
        pocket_id,
        "create the first admin and open a one-time sign-in to enrol a passkey",
        needs=lambda m: [inputs.ADMIN_EMAIL],
        after=("up",),
        applies=_pocket,
    ),
    Step(
        "oidc-client",
        oidc_client,
        "register core's OIDC client (callback, PKCE) and its secret in pocket-id",
        after=("up",),
        applies=_pocket,
    ),
    Step(
        "keepalive",
        keepalive,
        "report sleep, FileVault and start-at-login; print the sudo commands",
        applies=_mac,
        advisory=True,
    ),
    Step(
        "backup", backup, "daily pg_dump LaunchAgent, run once and pg_restore --list", after=("up",)
    ),
    Step(
        "verify",
        verify,
        "public /health 200, /auth/login 302 to the issuer, issuer page 200",
        after=("up", "pocket-id", "oidc-client"),
    ),
]
BY_NAME = {s.name: s for s in STEPS}
