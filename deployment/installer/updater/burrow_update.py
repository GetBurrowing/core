#!/usr/bin/env python3
"""burrow-update: the core updater of a single-host install (stdlib only).

Rendered byte for byte to /opt/burrow/bin/burrow-update (root 0755) by
burrow_install templates.updater_entries (an install that predates it gets
it from updater/bootstrap.sh, stage 4); run by burrow-updater.service from
its .timer (hourly) and .path (core's inbox). Moves core-platform between
digests of `<CORE_REPO>:<FLAVOUR>-<CHANNEL>` (updater.env only), holds while a
meeting is live, records the previous digest before it switches and rolls
back when /health does not come up. Migrations run on container start (the
image's CMD); an update is a recreate, nothing more.

TRUST BOUNDARY. The core CONTAINER gets no root, no docker.sock or
podman.sock, no privileged, no `user: root`, no pid: host, no cap_add. Its
only new mounts are its inbox dir (rw) and this updater's status dir (ro).
Core writes only request.json {action, request_id, requested_at} and
settings.json {auto_update}, staging -> inbox. No request can name an image:
the forward target is updater.env's, the rollback target only
state/previous_digest. Out of scope: on full_machine installs the agent host
runs as root and each native agent has sudo, so a core admin already reaches
the host through an agent; this does not widen that.

Test-only env: BURROW_UPDATE_ROOT (prefix of every path), BURROW_UPDATE_DOCKER,
BURROW_UPDATE_SYSTEMCTL, BURROW_UPDATE_REGISTRY_URL, BURROW_UPDATE_NOW (epoch s).
"""

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENV_FILE = "/etc/burrow-updater/updater.env"
INSTALL_ROOT = "/opt/burrow"
OVERRIDE = INSTALL_ROOT + "/compose.override.yaml"
BASE = "/var/lib/burrow-updater"
STATE = BASE + "/state"
CONSUMED = STATE + "/consumed"
CORE_DIR = BASE + "/core"
STAGING = CORE_DIR + "/staging"
INBOX = CORE_DIR + "/inbox"
OUTBOX = BASE + "/outbox"
STATUS = OUTBOX + "/status.json"
LOCK = "/run/burrow-updater.lock"
DUMP = STATE + "/pre-update.dump"

CORE_MOUNT = CORE_DIR + ":/run/burrow/updater/core:rw"
STATUS_MOUNT = OUTBOX + ":/run/burrow/updater/status:ro"
CORE_SERVICE = "core-platform"
PG_CONTAINER = "core-postgres"
PG_USER = "core_platform"
PG_DB = "core_platform"
CORE_UID = 1000
PATH_UNIT = "burrow-updater.path"
IRREVERSIBLE_LIST = "/app/release/irreversible-migrations.txt"
REVISION_LABEL = "org.opencontainers.image.revision"

MAX_BYTES = 4096
RATE_LIMIT_S = 60
CONSUMED_KEEP = 20
POLL_S = 5

FLAVOURS = ("core", "play")
CHANNELS = ("stable", "edge", "pinned")
ACTIONS = ("check", "update", "rollback")
REQUEST_KEYS = {"action", "request_id", "requested_at"}
SETTINGS_KEYS = {"auto_update"}
RESULTS = (
    "never_run",
    "ok",
    "up_to_date",
    "skipped_bad_digest",
    "no_release_on_channel",
    "deferred_meeting_live",
    "held_irreversible",
    "rolled_back",
    "rollback_failed",
    "failed_rollback_blocked",
    "pinned",
    "not_pinnable",
    "refused",
    "checked",
)
# A repository, as validate.py's [images] registry rule: a registry host
# (with a dot, or localhost; optional port) and lowercase path components.
REPO_RE = re.compile(
    r"^(?:localhost|[a-z0-9-]+(?:\.[a-z0-9-]+)+)(?::[0-9]{1,5})?"
    r"(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)+$"
)
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
MANIFEST_TYPES = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json, "
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)


class Refused(Exception):
    """A file in the inbox, or a request, that is not acted on."""


class ConfigError(Exception):
    pass


class RegistryError(Exception):
    pass


# ---------------------------------------------------------------------------
# Paths, clock, files.
# ---------------------------------------------------------------------------


def P(path):
    return os.environ.get("BURROW_UPDATE_ROOT", "") + path


def now():
    fixed = os.environ.get("BURROW_UPDATE_NOW")
    return float(fixed) if fixed else time.time()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def write_atomic(path, text, mode):
    """Write ``text`` beside ``path``, fsync, rename over it, fsync the directory."""
    tmp = f"{path}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        os.fchmod(fd, mode)
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    dfd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def read_json(path, default):
    text = read_text(path)
    if text is None:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return default


def ensure_dirs():
    """The render creates these (runcmd, before the stack starts); re-assert them."""
    is_root = os.geteuid() == 0
    for path, mode, core_owned in (
        (BASE, 0o755, False),
        (STATE, 0o700, False),
        (CONSUMED, 0o700, False),
        (CORE_DIR, 0o700, True),
        (STAGING, 0o700, True),
        (INBOX, 0o700, True),
        (OUTBOX, 0o755, False),
    ):
        full = P(path)
        os.makedirs(full, exist_ok=True)
        os.chmod(full, mode)
        if is_root:
            uid = CORE_UID if core_owned else 0
            os.chown(full, uid, uid)


# ---------------------------------------------------------------------------
# Configuration (updater.env, written by the render; core cannot reach it).
# ---------------------------------------------------------------------------


def parse_env(text):
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise ConfigError(f"not KEY=value: {line!r}")
        out[key.strip()] = value.strip()
    return out


def load_config():
    text = read_text(P(ENV_FILE))
    if text is None:
        raise ConfigError(f"{ENV_FILE} is missing")
    env = parse_env(text)
    cfg = {
        "channel": env.get("CHANNEL", ""),
        "repo": env.get("CORE_REPO", ""),
        "rollback_repos": env.get("ROLLBACK_REPOS", "").split(),
        "flavour": env.get("FLAVOUR", ""),
    }
    if cfg["channel"] not in CHANNELS:
        raise ConfigError("CHANNEL must be stable, edge or pinned")
    if cfg["flavour"] not in FLAVOURS:
        raise ConfigError("FLAVOUR must be core or play")
    for repo in [cfg["repo"], *cfg["rollback_repos"]]:
        if not REPO_RE.match(repo):
            raise ConfigError(f"not a repository: {repo!r}")
    try:
        cfg["health_timeout"] = int(env.get("HEALTH_TIMEOUT_S", "600"))
        cfg["stale_hours"] = int(env.get("MEETING_STALE_HOURS", "12"))
    except ValueError as exc:
        raise ConfigError("HEALTH_TIMEOUT_S and MEETING_STALE_HOURS are integers") from exc
    if not 0 <= cfg["health_timeout"] <= 86400 or not 1 <= cfg["stale_hours"] <= 720:
        raise ConfigError("HEALTH_TIMEOUT_S or MEETING_STALE_HOURS out of range")
    default = env.get("AUTO_UPDATE_DEFAULT", "true")
    if default not in ("true", "false"):
        raise ConfigError("AUTO_UPDATE_DEFAULT must be true or false")
    cfg["auto_update_default"] = default == "true"
    repos = "|".join(re.escape(r) for r in [cfg["repo"], *cfg["rollback_repos"]])
    cfg["ref_re"] = re.compile(rf"^({repos})@sha256:[0-9a-f]{{64}}$")
    return cfg


# ---------------------------------------------------------------------------
# compose.override.yaml: owned by this updater, core-platform only.
# ---------------------------------------------------------------------------


def override_text(image=None):
    """The whole override. A fresh render writes it with ``image=None``."""
    lines = [
        "# Owned by bin/burrow-update. Rewritten on every updater run, so a",
        "# re-render that replaces it loses nothing. core-platform only: its",
        "# inbox (rw) and the updater's status (ro), plus the pinned digest.",
        "services:",
        f"  {CORE_SERVICE}:",
    ]
    if image is not None:
        lines.append(f"    image: {json.dumps(image)}")
    lines += [
        "    volumes:",
        f"      - {json.dumps(CORE_MOUNT)}",
        f"      - {json.dumps(STATUS_MOUNT)}",
    ]
    return "\n".join(lines) + "\n"


def initial_status(channel, auto_update):
    """status.json before the first run (the render writes it)."""
    return status_text(
        {
            "channel": channel,
            "auto_update": auto_update,
            "last_result": "never_run",
            "last_checked_at": None,
            "deferred_since": None,
            "current": None,
            "available": None,
            "last_rollback": None,
            "pending_irreversible": None,
            "last_request": None,
        }
    )


def status_text(status):
    return json.dumps(status, indent=2, sort_keys=True) + "\n"


# ---------------------------------------------------------------------------
# External commands (docker, systemctl) and the registry.
# ---------------------------------------------------------------------------


def run(argv, cwd=None, stdout=None, timeout=1800):
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            stdout=stdout if stdout is not None else subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    out = proc.stdout.decode("utf-8", "replace") if stdout is None else ""
    return proc.returncode, out, proc.stderr.decode("utf-8", "replace")


def docker(*args, **kw):
    return run([os.environ.get("BURROW_UPDATE_DOCKER", "/usr/bin/docker"), *args], **kw)


def systemctl(*args):
    return run([os.environ.get("BURROW_UPDATE_SYSTEMCTL", "/usr/bin/systemctl"), *args])


def registry_base(repo):
    override = os.environ.get("BURROW_UPDATE_REGISTRY_URL")
    host, _, path = repo.partition("/")
    if override:
        return override.rstrip("/"), path
    if host == "docker.io":
        host = "registry-1.docker.io"
    return f"https://{host}", path


def _bearer(challenge):
    if not challenge.lower().startswith("bearer "):
        raise RegistryError("registry asked for non-bearer auth")
    params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    realm = params.pop("realm", None)
    if not realm or urllib.parse.urlsplit(realm).scheme not in ("http", "https"):
        raise RegistryError("registry token realm is not http(s)")
    url = realm + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as resp:
        body = json.loads(resp.read(65536))
    token = body.get("token") or body.get("access_token")
    if not isinstance(token, str):
        raise RegistryError("registry token response has no token")
    return token


def resolve_digest(repo, tag):
    """The channel tag's digest by HTTP HEAD (anonymous token), no pull; None if absent."""
    base, path = registry_base(repo)
    url = f"{base}/v2/{path}/manifests/{urllib.parse.quote(tag)}"
    headers = {"Accept": MANIFEST_TYPES}
    for attempt in (1, 2):
        req = urllib.request.Request(url, method="HEAD", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                digest = resp.headers.get("Docker-Content-Digest", "")
                if not DIGEST_RE.match(digest):
                    raise RegistryError("registry answered without a sha256 digest")
                return digest
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if exc.code == 401 and attempt == 1:
                token = _bearer(exc.headers.get("WWW-Authenticate", ""))
                headers["Authorization"] = f"Bearer {token}"
                continue
            raise RegistryError(f"registry HEAD answered {exc.code}") from exc
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise RegistryError(f"registry unreachable: {exc}") from exc
    raise RegistryError("registry refused the anonymous token")


def live_meetings_args(stale_hours):
    """docker argv (after ``docker``) counting live meetings within the stale bound.

    bin/burrow-updater-bootstrap (task 01a1b7b6 stage 4) runs the same query.
    """
    sql = (
        "select count(*) from meetings where status = 'live' and started_at > now() - "
        f"interval '{int(stale_hours)} hours'"
    )
    return [
        "exec", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
        "-tAqX", "-v", "ON_ERROR_STOP=1", "-c", sql,
    ]  # fmt: skip


def full_ref(ref):
    """``ref`` with its Docker Hub repository written out in full.

    docker shows a Docker Hub RepoDigest by its familiar name
    (``example/core@sha256:..``, ``nginx@sha256:..``), while updater.env
    and the override spell it ``docker.io/example/core``.
    """
    name, sep, rest = ref.partition("@")
    first = name.split("/", 1)[0]
    if "/" not in name:
        name = "docker.io/library/" + name
    elif not ("." in first or ":" in first or first == "localhost"):
        name = "docker.io/" + name
    return name + sep + rest


# ---------------------------------------------------------------------------
# The inbox: everything core writes is untrusted.
# ---------------------------------------------------------------------------


def _no_constants(name):
    raise ValueError(f"non-JSON constant {name}")


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = value
    return out


def read_untrusted(path):
    """lstat, open O_NOFOLLOW|O_NONBLOCK, fstat S_ISREG, read <= MAX_BYTES + 1, parse."""
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise Refused("not_regular_file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused("not_regular_file")
        data = b""
        while len(data) <= MAX_BYTES:
            chunk = os.read(fd, MAX_BYTES + 1 - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        raise Refused("oversize")
    try:
        obj = json.loads(
            data.decode("utf-8"), object_pairs_hook=_unique_pairs, parse_constant=_no_constants
        )
    except RecursionError as exc:
        raise Refused("nesting") from exc
    except ValueError as exc:
        raise Refused("bad_json") from exc
    if not isinstance(obj, dict):
        raise Refused("not_an_object")
    if any(isinstance(v, dict | list) for v in obj.values()):
        raise Refused("nesting")
    return obj


def validate_request(obj):
    if set(obj) - REQUEST_KEYS:
        raise Refused("unknown_key")
    if obj.get("action") not in ACTIONS:
        raise Refused("bad_action")
    request_id = obj.get("request_id")
    if request_id is not None and not (
        isinstance(request_id, str) and REQUEST_ID_RE.match(request_id)
    ):
        raise Refused("bad_request_id")
    requested_at = obj.get("requested_at")
    if requested_at is not None and not (
        isinstance(requested_at, str) and len(requested_at) <= 64 and requested_at.isprintable()
    ):
        raise Refused("bad_requested_at")
    return {"action": obj["action"], "request_id": request_id}


def validate_settings(obj):
    if set(obj) != SETTINGS_KEYS:
        raise Refused("unknown_key")
    if not isinstance(obj["auto_update"], bool):
        raise Refused("bad_auto_update")
    return {"auto_update": obj["auto_update"]}


def remove_any(path):
    try:
        if stat.S_ISDIR(os.lstat(path).st_mode):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    except FileNotFoundError:
        pass


# ---------------------------------------------------------------------------
# The updater.
# ---------------------------------------------------------------------------


class Updater:
    def __init__(self, cfg, mode):
        self.cfg = cfg
        self.mode = mode
        self.status = read_json(P(STATE + "/status.json"), None) or json.loads(
            initial_status(cfg["channel"], cfg["auto_update_default"])
        )
        self.meta = read_json(P(STATE + "/meta.json"), {})
        settings = read_json(P(STATE + "/settings"), {})
        self.auto_update = settings.get("auto_update", cfg["auto_update_default"]) is True
        self.seq = 0

    # -- state ----------------------------------------------------------------

    def state_path(self, name):
        return P(f"{STATE}/{name}")

    def previous(self):
        text = read_text(self.state_path("previous_digest"))
        return text.strip() if text else None

    def pinned(self):
        text = read_text(self.state_path("pinned"))
        ref = text.strip() if text else None
        return ref if ref and self.cfg["ref_re"].match(ref) else None

    def bad_digests(self):
        value = read_json(self.state_path("bad_digests"), [])
        return [d for d in value if isinstance(d, str) and DIGEST_RE.match(d)]

    def mark_bad(self, ref):
        bad = self.bad_digests()
        digest = ref.rpartition("@")[2]
        if digest not in bad:
            bad.append(digest)
        write_atomic(self.state_path("bad_digests"), json.dumps(bad) + "\n", 0o600)

    def pin(self, ref):
        write_atomic(self.state_path("pinned"), ref + "\n", 0o600)
        write_atomic(P(OVERRIDE), override_text(ref), 0o644)

    def reassert_override(self):
        write_atomic(P(OVERRIDE), override_text(self.pinned()), 0o644)

    def result(self, value, **fields):
        assert value in RESULTS, value
        self.status["last_result"] = value
        self.status.update(fields)
        return value

    def save(self):
        self.status["channel"] = self.cfg["channel"]
        self.status["auto_update"] = self.auto_update
        self.status["deferred_since"] = self.meta.get("deferred_since")
        write_atomic(self.state_path("meta.json"), json.dumps(self.meta) + "\n", 0o600)
        write_atomic(self.state_path("status.json"), status_text(self.status), 0o600)
        write_atomic(P(STATUS), status_text(self.status), 0o644)

    # -- docker ---------------------------------------------------------------

    def running_ref(self):
        """``<repo>@sha256:..`` of the running core image, or None (not pinnable)."""
        rc, image_id, _ = docker("inspect", "--format", "{{.Image}}", CORE_SERVICE)
        if rc != 0 or not image_id.strip():
            return None
        rc, out, _ = docker(
            "image", "inspect", "--format", "{{json .RepoDigests}}", image_id.strip()
        )
        if rc != 0:
            return None
        try:
            digests = json.loads(out)
        except ValueError:
            return None
        refs = [full_ref(d) for d in digests or [] if isinstance(d, str)]
        matching = [d for d in refs if self.cfg["ref_re"].match(d)]
        for repo in [self.cfg["repo"], *self.cfg["rollback_repos"]]:
            for ref in matching:
                if ref.startswith(repo + "@"):
                    return ref
        return None

    def commit_of(self, ref):
        label = "{{index .Config.Labels " + json.dumps(REVISION_LABEL) + "}}"
        rc, out, _ = docker("image", "inspect", "--format", label, ref)
        value = out.strip()
        if rc != 0 or value in ("", "unknown", "<no value>"):
            return None
        return value

    def irreversible_list(self, ref):
        rc, out, _ = docker(
            "run", "--rm", "--pull", "never", "--network", "none",
            "--entrypoint", "cat", ref, IRREVERSIBLE_LIST,
        )  # fmt: skip
        if rc != 0:
            return None
        return {ln.strip() for ln in out.splitlines() if ln.strip() and not ln.startswith("#")}

    def live_meetings(self):
        """Count of live meetings (started within the stale bound); None on ANY error."""
        rc, out, _ = docker(*live_meetings_args(self.cfg["stale_hours"]))
        if rc != 0 or not re.fullmatch(r"\d+", out.strip()):
            return None
        return int(out.strip())

    def meeting_hold(self):
        """True (and status deferred_meeting_live) when a meeting is live or unknowable."""
        count = self.live_meetings()
        if count is None or count > 0:
            if not self.meta.get("deferred_since"):
                self.meta["deferred_since"] = iso(now())  # kept across deferrals
            self.result("deferred_meeting_live")
            return True
        self.meta["deferred_since"] = None
        return False

    def dump_database(self):
        tmp = P(DUMP) + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as handle:
            rc, _, _ = docker(
                "exec", PG_CONTAINER, "pg_dump", "-U", PG_USER, "-d", PG_DB, "-Fc",
                stdout=handle,
            )  # fmt: skip
            handle.flush()
            os.fsync(handle.fileno())
        if rc != 0:
            os.unlink(tmp)
            return None
        os.replace(tmp, P(DUMP))  # keep 1
        return DUMP

    def healthy(self, expected_commit):
        """Health.Status healthy AND /health ok AND commit matches, within the timeout."""
        deadline = time.monotonic() + self.cfg["health_timeout"]
        fmt = "{{if .State.Health}}{{.State.Health.Status}}{{end}}"
        while True:
            rc, out, _ = docker("inspect", "--format", fmt, CORE_SERVICE)
            if rc == 0 and out.strip() == "healthy":
                rc, body, _ = docker(
                    "exec", CORE_SERVICE, "wget", "-qO-", "http://localhost:4000/health"
                )
                try:
                    health = json.loads(body) if rc == 0 else {}
                except ValueError:
                    health = {}
                if (
                    isinstance(health, dict)
                    and health.get("status") == "ok"
                    and (expected_commit is None or health.get("commit") == expected_commit)
                ):
                    return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(POLL_S, remaining))

    def compose_up(self):
        rc, _, _ = docker("compose", "up", "-d", "--no-deps", CORE_SERVICE, cwd=P(INSTALL_ROOT))
        return rc == 0

    def switch_to(self, ref):
        """Override -> compose up -> health wait. True when healthy."""
        self.pin(ref)
        return self.compose_up() and self.healthy(self.commit_of(ref))

    def cleanup_images(self, keep):
        rc, out, _ = docker(
            "image", "ls", "--digests", "--format", "{{.Repository}}@{{.Digest}}", self.cfg["repo"]
        )
        if rc != 0:
            return
        for ref in out.split():
            if self.cfg["ref_re"].match(ref) and ref not in keep:
                docker("image", "rm", ref)  # never `prune -a`

    def current_info(self, ref):
        return {"digest": ref, "commit": self.commit_of(ref)} if ref else None

    # -- the inbox ------------------------------------------------------------

    def drain_inbox(self):
        """Settings are applied here; returns the accepted request, or None."""
        try:
            names = os.listdir(P(INBOX))
        except FileNotFoundError:
            return None
        request = None
        for name in sorted(names, key=lambda n: (n != "settings.json", n)):
            src = os.path.join(P(INBOX), name)
            if name not in ("request.json", "settings.json"):
                remove_any(src)
                self.refuse(None, "unexpected_file")
                continue
            self.seq += 1
            dest = os.path.join(P(CONSUMED), f"{int(now() * 1000):015d}-{self.seq:02d}-{name}")
            try:
                os.rename(src, dest)  # out of core's reach before it is read
            except OSError:
                remove_any(src)
                continue
            try:
                obj = read_untrusted(dest)
                if name == "settings.json":
                    settings = validate_settings(obj)
                    write_atomic(self.state_path("settings"), json.dumps(settings) + "\n", 0o600)
                    self.auto_update = settings["auto_update"]
                    continue
                req = validate_request(obj)
                last = self.meta.get("last_request_at")
                if isinstance(last, int | float) and now() - last < RATE_LIMIT_S:
                    self.refuse(req["request_id"], "rate_limited")
                    remove_any(dest)
                    continue
                self.meta["last_request_at"] = now()
                request = req
            except Refused as exc:
                remove_any(dest)
                self.refuse(None, str(exc))
            except Exception:  # noqa: BLE001  every failure on untrusted input is a refusal
                remove_any(dest)
                self.refuse(None, "unreadable")
        self.cap_consumed()
        return request

    def cap_consumed(self):
        names = sorted(os.listdir(P(CONSUMED)))
        for name in names[: max(0, len(names) - CONSUMED_KEEP)]:
            remove_any(os.path.join(P(CONSUMED), name))

    def refuse(self, request_id, reason):
        self.status["last_request"] = {
            "request_id": request_id,
            "result": "refused",
            "reason": reason,
        }
        self.result("refused")

    # -- flows ----------------------------------------------------------------

    def run(self):
        if self.mode == "timer":
            # A path unit that hit its trigger limit stays failed until reset.
            systemctl("reset-failed", PATH_UNIT)
            systemctl("start", PATH_UNIT)
        self.status["error"] = None
        self.reassert_override()
        request = self.drain_inbox()
        current = self.running_ref()
        self.status["last_checked_at"] = iso(now())
        if current is None:
            # No RepoDigest (a preloaded image, a foreign repo): never switch.
            self.result("not_pinnable", current=None)
            if request:
                self.record_request(request, "refused", "not_pinnable")
            return
        if self.pinned() is None:
            # First run of ANY channel: pin what runs. The file only; it takes
            # effect at the next compose up, so pinning restarts nothing.
            self.pin(current)
        self.status["current"] = self.current_info(current)
        if request is not None:
            reason = self.handle_request(request, current)
            result = self.status["last_result"]
            if result == "pinned":
                result = "refused"
            self.record_request(request, result, reason)
        elif self.mode == "timer":
            if self.cfg["channel"] == "pinned":
                self.result("pinned")  # the timer never resolves a tag
            else:
                self.forward(current, requested=False)

    def record_request(self, request, result, reason=None):
        self.status["last_request"] = {
            "request_id": request["request_id"],
            "result": result,
            "reason": reason,
        }

    def handle_request(self, request, current):
        action = request["action"]
        if action == "rollback":
            return self.requested_rollback(current)
        if self.cfg["channel"] == "pinned":
            self.result("pinned")  # update (and check) refused; rollback above is allowed
            return "pinned"
        if action == "check":
            return self.forward(current, requested=False, check_only=True)
        return self.forward(current, requested=True)

    def forward(self, current, requested, check_only=False):
        """Channel tag -> (holds) -> switch -> health -> ok or auto-rollback. Returns a reason."""
        repo, tag = self.cfg["repo"], f"{self.cfg['flavour']}-{self.cfg['channel']}"
        try:
            digest = resolve_digest(repo, tag)
        except RegistryError as exc:
            self.result("no_release_on_channel", error=str(exc))
            return "registry_error"
        if digest is None:
            self.result("no_release_on_channel", available=None)
            return
        new = f"{repo}@{digest}"
        if new == current or digest == current.rpartition("@")[2]:
            self.result("up_to_date", available=None, pending_irreversible=None)
            return
        if digest in self.bad_digests():
            self.result("skipped_bad_digest", available=None)
            return
        self.status["available"] = {"digest": new}
        if check_only or (not self.auto_update and self.mode == "timer"):
            self.result("checked")
            return
        rc, _, _ = docker("pull", new)
        if rc != 0:
            self.result("checked", error="pull_failed")
            return "pull_failed"
        # Irreversible migrations (stage 2's list): new minus running. The new
        # image is read after the pull: there is no way to read a file in an
        # image without it.
        new_list = self.irreversible_list(new)
        old_list = self.irreversible_list(current) or set()
        if new_list is None:
            crossing = ["<new image has no irreversible-migrations list>"]
        else:
            crossing = sorted(new_list - old_list)
        crossed = False
        if crossing:
            if not requested:
                self.result("held_irreversible", pending_irreversible=crossing)
                return None
            # Only Update now crosses, and only after a dump of the database.
            if self.meeting_hold():
                return
            if self.dump_database() is None:
                self.result("refused")
                return "dump_failed"
            crossed = True
        if self.meeting_hold():
            return
        # previous_digest BEFORE the override changes (fsync in write_atomic).
        write_atomic(self.state_path("previous_digest"), current + "\n", 0o600)
        if self.switch_to(new):
            self.meta["crossed_into"] = new if crossed else None
            self.result("ok", available=None, pending_irreversible=None, dump=None)
            self.status["current"] = self.current_info(new)
            self.cleanup_images({new, current})
            return
        self.mark_bad(new)
        if crossed:
            # The schema moved forward; the old image must not run against it.
            self.meta["crossed_into"] = new
            self.result("failed_rollback_blocked", dump=DUMP, pending_irreversible=crossing)
            return
        self.auto_rollback(new, current)
        return None

    def auto_rollback(self, bad, previous):
        """Runs EVEN IF a meeting is live: core is down anyway. Never loops."""
        healthy = self.switch_to(previous)
        self.status["last_rollback"] = {
            "at": iso(now()),
            "from": self.commit_of(bad) or bad,
            "to": self.commit_of(previous) or previous,
        }
        if healthy:
            self.result("rolled_back")
            self.status["current"] = self.current_info(previous)
        else:
            self.result("rollback_failed")

    def requested_rollback(self, current):
        previous = self.previous()
        if not previous or not self.cfg["ref_re"].match(previous):
            self.result("refused")
            return "no_previous_digest"
        if previous == current:
            self.result("refused")
            return "already_on_previous"
        if self.meta.get("crossed_into") == current:
            self.result("refused")
            return "rollback_blocked_irreversible"
        if self.meeting_hold():
            return None
        # The rolled-from digest is bad, so the next timer run does not
        # re-apply it; previous_digest is kept.
        self.mark_bad(current)
        healthy = self.switch_to(previous)
        self.status["last_rollback"] = {
            "at": iso(now()),
            "from": self.commit_of(current) or current,
            "to": self.commit_of(previous) or previous,
        }
        if healthy:
            self.result("rolled_back")
            self.status["current"] = self.current_info(previous)
        else:
            self.result("rollback_failed")
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(prog="burrow-update")
    parser.add_argument(
        "--mode",
        choices=("timer", "path"),
        help="default: path when started by burrow-updater.path ($TRIGGER_UNIT), else timer",
    )
    args = parser.parse_args(argv)
    mode = args.mode or ("path" if os.environ.get("TRIGGER_UNIT") == PATH_UNIT else "timer")
    os.makedirs(os.path.dirname(P(LOCK)), exist_ok=True)
    with open(P(LOCK), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # one run at a time, timer or path
        ensure_dirs()
        try:
            cfg = load_config()
        except ConfigError as exc:
            print(f"burrow-update: {exc}", file=sys.stderr)
            return 2
        updater = Updater(cfg, mode)
        try:
            updater.run()
        finally:
            updater.save()
        print(f"burrow-update: {updater.status['last_result']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
