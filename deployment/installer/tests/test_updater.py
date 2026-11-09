"""The host updater, bin/burrow-update (core task 01a1b7b6 stage 1).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Every updater run here is the real script in a subprocess, with every path
under a BURROW_UPDATE_ROOT temp tree, docker and systemctl replaced by a fake
(``FAKE_DOCKER`` below) that logs its argv plus a snapshot of
state/previous_digest and the override at each call, and the registry
replaced by a stdlib http.server that answers HEAD with Docker-Content-Digest
behind an anonymous bearer token.
"""

import base64
import copy
import gzip
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(os.path.dirname(INSTALLER))
sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from burrow_install import templates
from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import validate

UPDATER = templates.UPDATER_SOURCE
upd = templates.updater_module()

EXAMPLE = os.path.join(REPO_ROOT, "deployment", "examples", "single-host.install.toml")
DROPLET = os.path.join(HERE, "render_fixtures", "do-droplet.toml")
DROPLET_AUTH = os.path.join(HERE, "render_fixtures", "do-droplet-registry-auth.json")
PLAY = os.path.join(HERE, "render_fixtures", "single-host-play.toml")

REPO = "registry.example.test/acme/core"
LEGACY = "docker.io/acme/legacy-core"


def digest(ch):
    return "sha256:" + ch * 64


D_OLD, D_NEW, D_OTHER, D_THIRD = digest("a"), digest("b"), digest("c"), digest("d")
OLD, NEW, OTHER, THIRD = (f"{REPO}@{d}" for d in (D_OLD, D_NEW, D_OTHER, D_THIRD))

FAKE_DOCKER = r"""
import json, os, re, sys
world_path, log_path = os.environ["FAKE_WORLD"], os.environ["FAKE_LOG"]
root = os.environ.get("BURROW_UPDATE_ROOT", "")
with open(world_path) as h:
    world = json.load(h)
def snap(rel):
    try:
        with open(root + rel) as h:
            return h.read()
    except FileNotFoundError:
        return None
argv = sys.argv[1:]
with open(log_path, "a") as h:
    h.write(json.dumps({
        "tool": os.path.basename(sys.argv[0]),
        "argv": argv,
        "cwd": os.getcwd(),
        "previous_digest": snap("/var/lib/burrow-updater/state/previous_digest"),
        "override": snap("/opt/burrow/compose.override.yaml"),
    }) + "\n")
if os.path.basename(sys.argv[0]) == "systemctl":
    sys.exit(0)
images = world["images"]
def find(ref):
    for iid, img in images.items():
        if ref == iid or ref in img["refs"]:
            return iid, img
    return None, None
def save():
    with open(world_path, "w") as h:
        json.dump(world, h)
def out(text, rc=0):
    sys.stdout.write(text)
    sys.exit(rc)
running = world.get("running")
cur = images.get(running) if running else None
if argv[:3] == ["inspect", "--format", "{{.Image}}"]:
    out(running + "\n") if running else out("", 1)
if argv[:2] == ["image", "inspect"] and argv[3] == "{{json .RepoDigests}}":
    _, img = find(argv[4])
    out(json.dumps(img["refs"]) + "\n") if img else out("", 1)
if argv[:2] == ["image", "inspect"] and argv[3].startswith("{{index .Config.Labels"):
    _, img = find(argv[4])
    if not img:
        out("", 1)
    out((img.get("revision") or "<no value>") + "\n")
if argv[:2] == ["inspect", "--format"] and "Health" in argv[2]:
    out(((cur or {}).get("health", "healthy")) + "\n")
if argv[:2] == ["exec", "core-platform"]:
    if not cur or not cur.get("health_ok", True):
        out("", 1)
    out(json.dumps({"status": "ok", "commit": cur.get("health_commit", cur.get("revision"))}))
if argv[:3] == ["exec", "core-postgres", "psql"]:
    answers = world.setdefault("psql", [])
    answer = answers.pop(0) if len(answers) > 1 else (answers[0] if answers else [0, "0"])
    save()
    out(answer[1] + "\n", answer[0])
if argv[:3] == ["exec", "core-postgres", "pg_dump"]:
    if world.get("pg_dump_fails"):
        out("", 1)
    out("PGDMP-fake")
if argv[0] == "pull":
    iid, _ = find(argv[1])
    out("", 0 if iid else 1)
if argv[0] == "run" and "--entrypoint" in argv:
    _, img = find(argv[argv.index("--entrypoint") + 2])
    if not img or img.get("irreversible") is None:
        out("", 1)
    out("".join(line + "\n" for line in img["irreversible"]))
if argv[:4] == ["compose", "up", "-d", "--no-deps"]:
    with open(os.path.join(os.getcwd(), "compose.override.yaml")) as h:
        m = re.search(r'^    image: "([^"]+)"$', h.read(), re.MULTILINE)
    if m:
        iid, _ = find(m.group(1))
        if not iid:
            out("", 1)
        world["running"] = iid
        save()
    out("")
if argv[:2] == ["image", "ls"]:
    repo = argv[-1]
    refs = [r for img in images.values() for r in img["refs"] if r.startswith(repo + "@")]
    out("".join(r + "\n" for r in refs))
if argv[:2] == ["image", "rm"]:
    out("")
out("unhandled\n", 99)
"""


class FakeRegistry:
    """HEAD /v2/<path>/manifests/<tag> behind an anonymous bearer token."""

    def __init__(self):
        self.tags = {}
        self.requests = []
        registry = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                registry.requests.append(("GET", self.path))
                if self.path.startswith("/token"):
                    body = json.dumps({"token": "anon-token"}).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_response(405)
                self.end_headers()

            def do_HEAD(self):
                registry.requests.append(("HEAD", self.path))
                if self.headers.get("Authorization") != "Bearer anon-token":
                    self.send_response(401)
                    realm = f"http://127.0.0.1:{registry.port}/token"
                    self.send_header(
                        "WWW-Authenticate",
                        f'Bearer realm="{realm}",service="fake",scope="repository:acme/core:pull"',
                    )
                    self.end_headers()
                    return
                m = re.match(r"^/v2/(.+)/manifests/([^/]+)$", self.path)
                found = m and registry.tags.get(m.group(2))
                if not found:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Docker-Content-Digest", found)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def heads(self):
        return [p for m, p in self.requests if m == "HEAD"]


def env_text(channel="stable", flavour="core", repo=REPO, rollback="", health=0, stale=12):
    return (
        f"CHANNEL={channel}\nCORE_REPO={repo}\nROLLBACK_REPOS={rollback}\nFLAVOUR={flavour}\n"
        f"HEALTH_TIMEOUT_S={health}\nMEETING_STALE_HOURS={stale}\nAUTO_UPDATE_DEFAULT=true\n"
    )


def image(ref, revision, irreversible=(), health="healthy", health_ok=True):
    return {
        "refs": [ref] if ref else [],
        "revision": revision,
        "irreversible": None if irreversible is None else list(irreversible),
        "health": health,
        "health_ok": health_ok,
    }


class UpdaterCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="burrow-update-")
        self.root = os.path.join(self.tmp, "root")
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        for name in ("docker", "systemctl"):
            path = os.path.join(bindir, name)
            with open(path, "w") as h:
                h.write(f"#!{sys.executable} -I\n{FAKE_DOCKER}")
            os.chmod(path, 0o755)
        self.docker = os.path.join(bindir, "docker")
        self.systemctl = os.path.join(bindir, "systemctl")
        self.world_path = os.path.join(self.tmp, "world.json")
        self.log_path = os.path.join(self.tmp, "calls.jsonl")
        self.registry = FakeRegistry()
        self.registry.tags = {"core-stable": D_NEW, "core-edge": D_OTHER}
        self.world = {
            "running": "id-old",
            "images": {
                "id-old": image(OLD, "c0ffee1"),
                "id-new": image(NEW, "beef002"),
                "id-other": image(OTHER, "0ther03"),
            },
            "psql": [[0, "0"]],
        }
        self.write_env(env_text())
        os.makedirs(self.p("/opt/burrow"))
        self.write(self.p(upd.OVERRIDE), upd.override_text())
        self.save_world()

    def tearDown(self):
        self.registry.close()
        try:
            for call in self.calls():
                joined = " ".join(call["argv"])
                self.assertNotIn("migrate", joined)
                self.assertNotRegex(joined, r"\beval\b")
                self.assertNotIn("prune", joined)
        finally:
            shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ----------------------------------------------------------------

    def p(self, path):
        return self.root + path

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as h:
            h.write(text)

    def read(self, path):
        try:
            with open(path) as h:
                return h.read()
        except FileNotFoundError:
            return None

    def write_env(self, text):
        self.write(self.p(upd.ENV_FILE), text)

    def save_world(self):
        with open(self.world_path, "w") as h:
            json.dump(self.world, h)

    def load_world(self):
        with open(self.world_path) as h:
            return json.load(h)

    def run_updater(self, mode="timer", now=1_000_000, extra_env=None, timeout=60):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "BURROW_UPDATE_ROOT": self.root,
            "BURROW_UPDATE_DOCKER": self.docker,
            "BURROW_UPDATE_SYSTEMCTL": self.systemctl,
            "BURROW_UPDATE_REGISTRY_URL": f"http://127.0.0.1:{self.registry.port}",
            "BURROW_UPDATE_NOW": str(now),
            "FAKE_WORLD": self.world_path,
            "FAKE_LOG": self.log_path,
        }
        env.update(extra_env or {})
        argv = [sys.executable, "-I", UPDATER] + (["--mode", mode] if mode else [])
        proc = subprocess.run(
            argv, env=env, capture_output=True, text=True, timeout=timeout, check=False
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return self.status()

    def status(self):
        return json.loads(self.read(self.p(upd.STATUS)))

    def calls(self, prefix=None):
        text = self.read(self.log_path) or ""
        out = [json.loads(line) for line in text.splitlines()]
        if prefix is not None:
            out = [c for c in out if c["argv"][: len(prefix)] == prefix]
        return out

    def compose_ups(self):
        return self.calls(["compose", "up"])

    def state(self, name):
        text = self.read(self.p(f"{upd.STATE}/{name}"))
        return text.strip() if text is not None else None

    def bad(self):
        return json.loads(self.state("bad_digests") or "[]")

    def override_image(self):
        m = re.search(r'^    image: "([^"]+)"$', self.read(self.p(upd.OVERRIDE)), re.MULTILINE)
        return m.group(1) if m else None

    def drop(self, name, payload, raw=False):
        """Core's side: write into staging, rename into the inbox."""
        staging = self.p(upd.STAGING)
        os.makedirs(staging, exist_ok=True)
        os.makedirs(self.p(upd.INBOX), exist_ok=True)
        tmp = os.path.join(staging, name)
        with open(tmp, "w") as h:
            h.write(payload if raw else json.dumps(payload))
        os.rename(tmp, os.path.join(self.p(upd.INBOX), name))

    def request(self, action, request_id="r1", **extra):
        self.drop("request.json", {"action": action, "request_id": request_id, **extra})

    def pinned_first_run(self):
        """A first run pins the running digest; nothing switches."""
        self.registry.tags = {}
        self.run_updater()
        self.registry.tags = {"core-stable": D_NEW, "core-edge": D_OTHER}
        self.assertEqual(self.override_image(), OLD)


# ---------------------------------------------------------------------------
# The render.
# ---------------------------------------------------------------------------


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError([e.line() for e in errors])
    return normalized


def write_files(user_data):
    from test_agents_render import write_files as parse

    return {path: body for path, (_perms, body) in parse(user_data).items()}


def droplet():
    return build(valid(load(DROPLET)), registry_auth=DROPLET_AUTH)


class RenderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = droplet()
        cls.user_data = cls.rendered.files["user-data"][0]
        cls.on_host = write_files(cls.user_data)

    def test_the_script_is_rendered_byte_for_byte_and_executable(self):
        with open(UPDATER, encoding="utf-8") as h:
            source = h.read()
        self.assertEqual(self.on_host["/opt/burrow/bin/burrow-update"], source)
        entry = self.user_data.split('  - path: "/opt/burrow/bin/burrow-update"\n', 1)[1]
        self.assertTrue(entry.startswith('    owner: "root:root"\n    permissions: "0755"\n'))
        self.assertTrue(source.startswith("#!/usr/bin/env python3\n"))

    def test_the_install_directory_carries_no_updater_file(self):
        # A re-render's output never holds the override or the updater state.
        for rel in self.rendered.files:
            self.assertNotIn("override", rel)
            self.assertNotIn("burrow-update", rel)

    def test_units(self):
        service = self.on_host["/etc/systemd/system/burrow-updater.service"]
        for line in (
            "Type=oneshot",
            "User=root",
            "StartLimitIntervalSec=0",
            "ExecStart=/opt/burrow/bin/burrow-update",
        ):
            self.assertIn(line + "\n", service)
        self.assertIn("/run/burrow-updater.lock", service)
        timer = self.on_host["/etc/systemd/system/burrow-updater.timer"]
        for line in (
            "OnBootSec=5min",
            "OnCalendar=hourly",
            "RandomizedDelaySec=30min",
            "Persistent=true",
            "Unit=burrow-updater.service",
        ):
            self.assertIn(line + "\n", timer)
        path = self.on_host["/etc/systemd/system/burrow-updater.path"]
        for line in (
            "DirectoryNotEmpty=/var/lib/burrow-updater/core/inbox",
            "TriggerLimitIntervalSec=10s",
            "TriggerLimitBurst=20",
            "Unit=burrow-updater.service",
        ):
            self.assertIn(line + "\n", path)

    def test_dirs_are_made_and_chowned_before_the_stack_starts(self):
        runcmd = self.user_data.split("\nruncmd:\n", 1)[1].split("\n")
        runcmd = [json.loads(line[4:]) for line in runcmd if line.startswith("  - [")]
        start = runcmd.index(["systemctl", "start", "--no-block", "burrow-stack.service"])
        core = [
            "install", "-d", "-o", "1000", "-g", "1000", "-m", "0700",
            upd.CORE_DIR, upd.STAGING, upd.INBOX,
        ]  # fmt: skip
        state = ["install", "-d", "-o", "root", "-g", "root", "-m", "0700", upd.STATE, upd.CONSUMED]
        enable = ["systemctl", "enable", "--now", "burrow-updater.timer", "burrow-updater.path"]
        for cmd in (core, state, enable):
            self.assertIn(cmd, runcmd)
            self.assertLess(runcmd.index(cmd), start)
        self.assertLess(runcmd.index(core), runcmd.index(enable))

    def test_fresh_override_has_the_two_mounts_and_no_image(self):
        override = self.on_host["/opt/burrow/compose.override.yaml"]
        self.assertEqual(override, upd.override_text())
        self.assertNotIn("image:", override)
        self.assertEqual(
            re.findall(r'^      - "(.+)"$', override, re.MULTILINE),
            [
                "/var/lib/burrow-updater/core:/run/burrow/updater/core:rw",
                "/var/lib/burrow-updater/outbox:/run/burrow/updater/status:ro",
            ],
        )
        self.assertEqual(re.findall(r"^  (\S+):$", override, re.MULTILINE), ["core-platform"])

    def test_boundary_core_gets_no_host_power(self):
        override = upd.override_text(OLD)
        compose = self.rendered.files["compose.yaml"][0]
        core = compose.split("\n  core-platform:\n", 1)[1].split("\n  core-postgres:", 1)[0]
        for text in (override, core):
            for forbidden in (
                "docker.sock", "podman.sock", "privileged", "cap_add", "pid:", "user:",
                "/var/lib/burrow-updater/state", "/etc/burrow-updater",
            ):  # fmt: skip
                self.assertNotIn(forbidden, text)
        self.assertIn(":/run/burrow/updater/status:ro", override)

    def test_initial_status_never_run(self):
        status = json.loads(self.on_host["/var/lib/burrow-updater/outbox/status.json"])
        self.assertEqual(status["last_result"], "never_run")
        self.assertEqual(status["channel"], "stable")
        self.assertIn("/var/lib/burrow-updater/outbox/status.json", self.user_data)

    def test_updater_env_channel_flavour_repo(self):
        env = upd.parse_env(self.on_host["/etc/burrow-updater/updater.env"])
        self.assertEqual(env["CHANNEL"], "stable")
        self.assertEqual(env["CORE_REPO"], "ghcr.io/example/core")
        self.assertEqual(env["ROLLBACK_REPOS"], "")
        self.assertEqual(env["FLAVOUR"], "core")
        self.assertEqual(env["HEALTH_TIMEOUT_S"], "600")
        self.assertEqual(env["MEETING_STALE_HOURS"], "12")
        self.assertEqual(env["AUTO_UPDATE_DEFAULT"], "true")

    def env_of(self, raw, auth=DROPLET_AUTH):
        rendered = build(valid(raw), registry_auth=auth)
        return write_files(rendered.files["user-data"][0])["/etc/burrow-updater/updater.env"]

    def test_edge_play_pin_preloaded_and_legacy(self):
        raw = load(DROPLET)
        raw["day2"]["upgrade_channel"] = "edge"
        self.assertIn("\nCHANNEL=edge\n", self.env_of(raw))
        play = self.env_of(load(PLAY), auth=None)
        self.assertIn("\nFLAVOUR=play\n", play)
        raw = load(DROPLET)
        raw["images"]["refs"] = {"core-platform": "ghcr.io/example/core:core-x"}
        pinned = self.env_of(raw)
        self.assertIn("\nCHANNEL=pinned\n", pinned)
        self.assertIn("# CHANNEL is pinned: images.refs.core-platform", pinned)
        preloaded = self.env_of(load(EXAMPLE), auth=None)  # images.source = "preloaded"
        self.assertIn("\nCHANNEL=pinned\n", preloaded)
        raw = load(DROPLET)
        raw["images"].pop("registry")
        raw["images"]["image_namespace"] = "acme"
        legacy = upd.parse_env(self.env_of(raw))
        self.assertEqual(legacy["CORE_REPO"], templates.PUBLISHED_CORE_REPO)
        self.assertTrue(legacy["ROLLBACK_REPOS"].startswith("docker.io/acme/"))

    def test_the_rendered_env_loads(self):
        with tempfile.TemporaryDirectory() as root:
            path = root + upd.ENV_FILE
            os.makedirs(os.path.dirname(path))
            with open(path, "w") as h:
                h.write(self.on_host["/etc/burrow-updater/updater.env"])
            old = os.environ.get("BURROW_UPDATE_ROOT")
            os.environ["BURROW_UPDATE_ROOT"] = root
            try:
                cfg = upd.load_config()
            finally:
                if old is None:
                    os.environ.pop("BURROW_UPDATE_ROOT")
                else:
                    os.environ["BURROW_UPDATE_ROOT"] = old
        self.assertEqual(cfg["repo"], "ghcr.io/example/core")
        self.assertTrue(cfg["ref_re"].match("ghcr.io/example/core@" + D_OLD))
        self.assertFalse(cfg["ref_re"].match("ghcr.io/evil/core@" + D_OLD))

    def test_hosted_s3_droplet_fits_digitalocean_user_data_cap(self):
        raw = copy.deepcopy(load(DROPLET))
        raw["install"]["hosted"] = True
        raw["backup"] = {
            "target": "s3-compatible",
            "bucket": "example-bucket",
            "endpoint": "https://s3.example.test",
            "region": "r1",
            "access_key_ref": "BACKUP_ACCESS_KEY",
            "secret_key_ref": "BACKUP_SECRET_KEY",
        }
        with tempfile.TemporaryDirectory() as tmp:
            supplied = os.path.join(tmp, "customer.env")
            with open(supplied, "w") as h:
                h.write("BACKUP_ACCESS_KEY=fixture-a\nBACKUP_SECRET_KEY=fixture-b\n")
            rendered = build(valid(raw), registry_auth=DROPLET_AUTH, customer_secrets=supplied)
        size = len(rendered.files["user-data"][0].encode())
        self.assertGreater(size, 32 * 1024)
        self.assertLessEqual(size, 64 * 1024 - 512)


class MacRenderTest(unittest.TestCase):
    def test_mac_render_has_no_updater(self):
        # The mac target is out of scope; its goldens prove it byte-identical.
        from test_mac_render import MAC as MAC_EXAMPLE
        from test_mac_render import mac_build, manifest_from

        rendered = mac_build(manifest_from(MAC_EXAMPLE))
        self.assertIn("compose.yaml", rendered.files)  # positive control
        for rel, (text, _mode) in rendered.files.items():
            self.assertNotIn("burrow-update", text, rel)
            self.assertNotIn("override", rel)


# ---------------------------------------------------------------------------
# The updater.
# ---------------------------------------------------------------------------


class PinTest(UpdaterCase):
    def test_first_run_pins_the_running_digest_without_a_restart(self):
        self.write_env(env_text(channel="pinned"))
        status = self.run_updater()
        self.assertEqual(status["last_result"], "pinned")
        self.assertEqual(self.override_image(), OLD)
        self.assertEqual(self.compose_ups(), [])
        self.assertEqual(self.registry.requests, [])  # pinned: never resolves a tag
        self.assertEqual(status["current"], {"digest": OLD, "commit": "c0ffee1"})

    def test_not_pinnable_never_switches(self):
        self.world["images"]["id-old"]["refs"] = []  # preloaded: no RepoDigest
        self.save_world()
        status = self.run_updater()
        self.assertEqual(status["last_result"], "not_pinnable")
        self.request("update")
        status = self.run_updater(mode="path", now=1_000_100)
        self.assertEqual(status["last_result"], "not_pinnable")
        self.assertEqual(status["last_request"]["result"], "refused")
        self.assertEqual(self.compose_ups(), [])
        self.assertEqual(self.calls(["pull"]), [])
        self.assertIsNone(self.override_image())

    def test_a_foreign_repo_digest_is_not_pinnable(self):
        self.world["images"]["id-old"]["refs"] = ["ghcr.io/evil/core@" + D_OLD]
        self.save_world()
        self.assertEqual(self.run_updater()["last_result"], "not_pinnable")

    def test_re_render_then_updater_run_keeps_the_pin(self):
        self.pinned_first_run()
        # A re-render (task 01a1b11f) puts the fresh override back: no image line.
        self.write(self.p(upd.OVERRIDE), upd.override_text())
        self.registry.tags = {}
        self.run_updater(now=1_000_100)
        self.assertEqual(self.override_image(), OLD)

    def test_timer_rearms_the_path_unit_and_path_mode_does_not(self):
        self.run_updater()
        sc = [c["argv"] for c in self.calls() if c["tool"] == "systemctl"]
        self.assertEqual(
            sc, [["reset-failed", "burrow-updater.path"], ["start", "burrow-updater.path"]]
        )
        os.unlink(self.log_path)
        self.run_updater(mode="path")
        self.assertEqual([c for c in self.calls() if c["tool"] == "systemctl"], [])

    def test_mode_comes_from_trigger_unit(self):
        self.run_updater(mode=None, extra_env={"TRIGGER_UNIT": "burrow-updater.path"})
        self.assertEqual([c for c in self.calls() if c["tool"] == "systemctl"], [])
        self.run_updater(mode=None, extra_env={"TRIGGER_UNIT": "burrow-updater.timer"})
        self.assertTrue([c for c in self.calls() if c["tool"] == "systemctl"])

    def test_dirs_and_status_modes(self):
        self.run_updater()
        self.assertEqual(stat.S_IMODE(os.stat(self.p(upd.STATE)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.p(upd.CORE_DIR)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.p(upd.INBOX)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.p(upd.STATUS)).st_mode), 0o644)
        status = self.status()
        for key in (
            "channel", "auto_update", "last_result", "last_checked_at", "deferred_since",
            "current", "available", "last_rollback", "pending_irreversible", "last_request",
        ):  # fmt: skip
            self.assertIn(key, status)
        self.assertIn(status["last_result"], upd.RESULTS)


class ChannelTest(UpdaterCase):
    def test_up_to_date(self):
        self.registry.tags = {"core-stable": D_OLD}
        self.assertEqual(self.run_updater()["last_result"], "up_to_date")
        self.assertEqual(self.compose_ups(), [])

    def test_no_release_on_channel(self):
        self.registry.tags = {}
        self.assertEqual(self.run_updater()["last_result"], "no_release_on_channel")

    def test_registry_is_read_by_head_with_an_anonymous_token_and_no_pull(self):
        self.drop("settings.json", {"auto_update": False})
        status = self.run_updater()
        self.assertEqual(status["last_result"], "checked")
        self.assertEqual(status["available"], {"digest": NEW})
        self.assertEqual(self.calls(["pull"]), [])
        self.assertEqual(self.registry.heads(), ["/v2/acme/core/manifests/core-stable"] * 2)
        self.assertIn(("GET", "/token?service=fake&scope=repository%3Aacme%2Fcore%3Apull"),
                      self.registry.requests)  # fmt: skip
        self.assertFalse(
            [r for r in self.registry.requests if "manifests" in r[1] and r[0] == "GET"]
        )

    def test_edge_channel_and_play_flavour_name_the_tag(self):
        self.write_env(env_text(channel="edge", flavour="play"))
        self.registry.tags = {"play-edge": D_NEW}
        self.assertEqual(self.run_updater()["last_result"], "ok")
        self.assertIn("/v2/acme/core/manifests/play-edge", self.registry.heads())

    def test_vendor_candidate_channel_pulls_the_held_play_candidate(self):
        self.write_env(env_text(channel="candidate", flavour="play"))
        self.registry.tags = {"play-candidate": D_NEW}
        self.assertEqual(self.run_updater()["last_result"], "ok")
        self.assertIn("/v2/acme/core/manifests/play-candidate", self.registry.heads())

    def test_bad_digest_is_skipped(self):
        self.write(self.p(f"{upd.STATE}/bad_digests"), json.dumps([D_NEW]))
        self.assertEqual(self.run_updater()["last_result"], "skipped_bad_digest")
        self.assertEqual(self.calls(["pull"]), [])

    def test_bad_config_refuses_to_run(self):
        self.write_env(env_text(repo="NOT A REPO"))
        env = {
            "BURROW_UPDATE_ROOT": self.root, "BURROW_UPDATE_DOCKER": self.docker,
            "PATH": "/usr/bin:/bin",
        }  # fmt: skip
        proc = subprocess.run([sys.executable, "-I", UPDATER, "--mode", "timer"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)  # fmt: skip
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(self.calls(["compose"]), [])


class SwitchTest(UpdaterCase):
    def test_forward_update_ok_records_previous_before_the_switch(self):
        self.world["images"]["id-third"] = image(THIRD, "7hird04")
        self.save_world()
        self.pinned_first_run()
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "ok")
        self.assertEqual(status["current"], {"digest": NEW, "commit": "beef002"})
        ups = self.compose_ups()
        self.assertEqual(len(ups), 1)
        self.assertEqual(ups[0]["argv"], ["compose", "up", "-d", "--no-deps", "core-platform"])
        self.assertEqual(ups[0]["cwd"], os.path.realpath(self.p("/opt/burrow")))
        # previous_digest was on disk BEFORE the override changed and compose ran.
        self.assertEqual(ups[0]["previous_digest"], OLD + "\n")
        first_new_override = next(c for c in self.calls() if NEW in (c["override"] or ""))
        self.assertEqual(first_new_override["previous_digest"], OLD + "\n")
        self.assertEqual(self.state("previous_digest"), OLD)
        self.assertEqual(self.override_image(), NEW)
        self.assertEqual(self.calls(["pull"])[0]["argv"], ["pull", NEW])
        removed = [c["argv"][2] for c in self.calls(["image", "rm"])]
        self.assertEqual(sorted(removed), sorted([OTHER, THIRD]))

    def test_health_requires_the_new_commit(self):
        self.world["images"]["id-new"]["health_commit"] = "c0ffee1"  # old code answering
        self.save_world()
        self.pinned_first_run()
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "rolled_back")

    def test_unknown_revision_skips_the_commit_match(self):
        self.world["images"]["id-new"]["revision"] = "unknown"
        self.world["images"]["id-new"]["health_commit"] = "whatever"
        self.save_world()
        self.pinned_first_run()
        self.assertEqual(self.run_updater(now=1_000_100)["last_result"], "ok")

    def test_unhealthy_rolls_back_and_marks_the_digest_bad(self):
        self.world["images"]["id-new"]["health"] = "unhealthy"
        self.save_world()
        self.pinned_first_run()
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "rolled_back")
        self.assertEqual(len(self.compose_ups()), 2)
        self.assertEqual(self.override_image(), OLD)
        self.assertEqual(self.load_world()["running"], "id-old")
        self.assertEqual(self.bad(), [D_NEW])
        self.assertEqual(status["last_rollback"]["from"], "beef002")
        self.assertEqual(status["last_rollback"]["to"], "c0ffee1")
        # The next timer run does not re-apply it.
        status = self.run_updater(now=1_004_000)
        self.assertEqual(status["last_result"], "skipped_bad_digest")
        self.assertEqual(len(self.compose_ups()), 2)

    def test_a_failed_rollback_stops(self):
        self.world["images"]["id-new"]["health"] = "unhealthy"
        self.world["images"]["id-old"]["health_ok"] = False
        self.save_world()
        self.pinned_first_run()
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "rollback_failed")
        self.assertEqual(len(self.compose_ups()), 2)

    def test_auto_rollback_runs_even_if_a_meeting_went_live(self):
        self.world["images"]["id-new"]["health"] = "unhealthy"
        self.world["psql"] = [[0, "0"], [0, "3"]]
        self.save_world()
        self.pinned_first_run()
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "rolled_back")
        self.assertEqual(len(self.calls(["exec", "core-postgres", "psql"])), 1)


class MeetingTest(UpdaterCase):
    def test_a_live_meeting_defers_the_timer_and_keeps_deferred_since(self):
        self.world["psql"] = [[0, "1"]]
        self.save_world()
        status = self.run_updater(now=1_000_000)
        self.assertEqual(status["last_result"], "deferred_meeting_live")
        since = status["deferred_since"]
        self.assertIsNotNone(since)
        status = self.run_updater(now=1_003_600)
        self.assertEqual(status["deferred_since"], since)
        self.assertEqual(self.compose_ups(), [])
        self.assertIsNone(self.state("previous_digest"))
        self.world = self.load_world()
        self.world["psql"] = [[0, "0"]]
        self.save_world()
        status = self.run_updater(now=1_007_200)
        self.assertEqual(status["last_result"], "ok")
        self.assertIsNone(status["deferred_since"])

    def test_a_live_meeting_defers_update_now(self):
        self.world["psql"] = [[0, "2"]]
        self.save_world()
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "deferred_meeting_live")
        self.assertEqual(self.compose_ups(), [])

    def test_a_query_error_fails_closed(self):
        self.world["psql"] = [[2, ""]]
        self.save_world()
        self.assertEqual(self.run_updater()["last_result"], "deferred_meeting_live")
        self.world = self.load_world()
        self.world["psql"] = [[0, "garbage"]]
        self.save_world()
        self.assertEqual(self.run_updater(now=1_000_100)["last_result"], "deferred_meeting_live")
        self.assertEqual(self.compose_ups(), [])

    def test_the_stale_bound_is_in_the_query(self):
        self.write_env(env_text(stale=3))
        self.run_updater()
        sql = self.calls(["exec", "core-postgres", "psql"])[0]["argv"][-1]
        self.assertIn("status = 'live'", sql)
        self.assertIn("started_at > now() - interval '3 hours'", sql)
        self.assertIn("from meetings", sql)

    def test_the_default_stale_bound_is_twelve_hours(self):
        self.run_updater()
        sql = self.calls(["exec", "core-postgres", "psql"])[0]["argv"][-1]
        self.assertIn("interval '12 hours'", sql)


class IrreversibleTest(UpdaterCase):
    def test_the_timer_holds_a_crossing(self):
        self.world["images"]["id-old"]["irreversible"] = ["20260101_a"]
        self.world["images"]["id-new"]["irreversible"] = ["20260101_a", "20261101_b"]
        self.save_world()
        status = self.run_updater()
        self.assertEqual(status["last_result"], "held_irreversible")
        self.assertEqual(status["pending_irreversible"], ["20261101_b"])
        self.assertEqual(self.compose_ups(), [])
        self.assertIsNone(self.state("previous_digest"))

    def test_a_missing_list_on_the_new_image_holds(self):
        self.world["images"]["id-new"]["irreversible"] = None
        self.save_world()
        self.assertEqual(self.run_updater()["last_result"], "held_irreversible")

    def test_a_missing_list_on_the_running_image_is_empty(self):
        self.world["images"]["id-old"]["irreversible"] = None
        self.world["images"]["id-new"]["irreversible"] = []
        self.save_world()
        self.assertEqual(self.run_updater()["last_result"], "ok")

    def test_update_now_crosses_after_a_dump_and_then_blocks_rollback(self):
        self.world["images"]["id-new"]["irreversible"] = ["20261101_b"]
        self.save_world()
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "ok")
        self.assertEqual(len(self.calls(["exec", "core-postgres", "pg_dump"])), 1)
        dump = self.p(upd.DUMP)
        self.assertEqual(stat.S_IMODE(os.stat(dump).st_mode), 0o600)
        self.assertEqual(self.read(dump), "PGDMP-fake")
        dump_at = next(i for i, c in enumerate(self.calls()) if "pg_dump" in c["argv"])
        up_at = next(i for i, c in enumerate(self.calls()) if c["argv"][:2] == ["compose", "up"])
        self.assertLess(dump_at, up_at)
        self.request("rollback", request_id="r2")
        status = self.run_updater(mode="path", now=1_000_100)
        self.assertEqual(status["last_result"], "refused")
        self.assertEqual(status["last_request"]["reason"], "rollback_blocked_irreversible")
        self.assertEqual(len(self.compose_ups()), 1)

    def test_a_crossing_that_fails_health_is_not_rolled_back(self):
        self.world["images"]["id-new"]["irreversible"] = ["20261101_b"]
        self.world["images"]["id-new"]["health"] = "unhealthy"
        self.save_world()
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "failed_rollback_blocked")
        self.assertEqual(status["dump"], upd.DUMP)
        self.assertEqual(len(self.compose_ups()), 1)

    def test_a_failed_dump_does_not_cross(self):
        self.world["images"]["id-new"]["irreversible"] = ["20261101_b"]
        self.world["pg_dump_fails"] = True
        self.save_world()
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "refused")
        self.assertEqual(status["last_request"]["reason"], "dump_failed")
        self.assertEqual(self.compose_ups(), [])


class RequestTest(UpdaterCase):
    def test_requested_rollback_marks_bad_keeps_previous_and_the_timer_stays(self):
        self.pinned_first_run()
        self.run_updater(now=1_000_100)  # forward to NEW
        self.assertEqual(self.override_image(), NEW)
        self.request("rollback")
        status = self.run_updater(mode="path", now=1_000_200)
        self.assertEqual(status["last_result"], "rolled_back")
        self.assertEqual(status["last_request"], {"request_id": "r1", "result": "rolled_back",
                                                  "reason": None})  # fmt: skip
        self.assertEqual(self.override_image(), OLD)
        self.assertEqual(self.bad(), [D_NEW])
        self.assertEqual(self.state("previous_digest"), OLD)
        ups = len(self.compose_ups())
        status = self.run_updater(now=1_004_000)
        self.assertEqual(status["last_result"], "skipped_bad_digest")
        self.assertEqual(len(self.compose_ups()), ups)

    def test_rollback_without_previous_is_refused(self):
        self.request("rollback")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "refused")
        self.assertEqual(status["last_request"]["reason"], "no_previous_digest")

    def test_rollback_target_must_be_the_configured_repo(self):
        self.write(self.p(f"{upd.STATE}/previous_digest"), "ghcr.io/evil/core@" + D_OTHER)
        self.request("rollback")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "refused")
        self.assertEqual(self.compose_ups(), [])

    def test_pinned_refuses_update_and_allows_rollback(self):
        self.world["running"] = "id-new"
        self.save_world()
        self.write_env(env_text(channel="pinned"))
        self.write(self.p(f"{upd.STATE}/previous_digest"), OLD + "\n")
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "pinned")
        self.assertEqual(status["last_request"]["result"], "refused")
        self.assertEqual(self.registry.requests, [])
        self.request("rollback", request_id="r2")
        status = self.run_updater(mode="path", now=1_000_100)
        self.assertEqual(status["last_result"], "rolled_back")
        self.assertEqual(self.override_image(), OLD)

    def test_check_records_available_without_pulling(self):
        self.request("check")
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "checked")
        self.assertEqual(status["available"], {"digest": NEW})
        self.assertEqual(self.calls(["pull"]), [])

    def test_update_now_ignores_auto_update_off(self):
        self.drop("settings.json", {"auto_update": False})
        self.request("update")
        status = self.run_updater(mode="path")
        self.assertFalse(status["auto_update"])
        self.assertEqual(status["last_result"], "ok")

    def test_settings_persist_and_the_timer_only_records_available(self):
        self.drop("settings.json", {"auto_update": False})
        self.run_updater(mode="path")
        status = self.run_updater(now=1_000_100)
        self.assertEqual(status["last_result"], "checked")
        self.assertEqual(self.compose_ups(), [])

    def test_the_path_mode_alone_never_updates(self):
        self.assertNotEqual(self.run_updater(mode="path")["last_result"], "ok")
        self.assertEqual(self.compose_ups(), [])

    def test_a_request_can_never_name_an_image(self):
        self.world["images"]["id-evil"] = image("ghcr.io/evil/core@" + D_THIRD, "evil")
        self.save_world()
        self.request("update", image="ghcr.io/evil/core@" + D_THIRD)
        status = self.run_updater(mode="path")
        self.assertEqual(status["last_result"], "refused")
        self.assertEqual(status["last_request"]["reason"], "unknown_key")
        for call in self.calls():
            self.assertNotIn("evil", " ".join(call["argv"]))
        self.assertEqual(self.compose_ups(), [])

    def test_legacy_install_moves_to_the_published_repo(self):
        legacy_old = f"{LEGACY}@{D_OLD}"
        self.world["images"]["id-old"]["refs"] = [legacy_old]
        self.save_world()
        self.write_env(env_text(rollback=LEGACY))
        status = self.run_updater()
        self.assertEqual(status["last_result"], "ok")
        self.assertEqual(self.state("previous_digest"), legacy_old)
        self.assertEqual(self.override_image(), NEW)
        self.request("rollback")
        self.assertEqual(self.run_updater(mode="path", now=1_000_100)["last_result"], "rolled_back")
        self.assertEqual(self.override_image(), legacy_old)


class InboxTest(UpdaterCase):
    def assert_refused(self, reason=None):
        status = self.run_updater(mode="path", timeout=20)
        self.assertEqual(status["last_result"], "refused")
        if reason:
            self.assertEqual(status["last_request"]["reason"], reason)
        self.assertEqual(os.listdir(self.p(upd.INBOX)), [])
        self.assertEqual(os.listdir(self.p(upd.CONSUMED)), [])
        self.assertEqual(self.compose_ups(), [])

    def inbox(self, name):
        os.makedirs(self.p(upd.INBOX), exist_ok=True)
        return os.path.join(self.p(upd.INBOX), name)

    def test_symlink_is_refused_and_its_target_untouched(self):
        target = os.path.join(self.tmp, "secret.json")
        with open(target, "w") as h:
            h.write('{"action": "update"}')
        os.symlink(target, self.inbox("request.json"))
        self.assert_refused("not_regular_file")
        self.assertTrue(os.path.exists(target))

    def test_fifo_is_refused_without_blocking(self):
        os.mkfifo(self.inbox("request.json"))
        self.assert_refused("not_regular_file")

    def test_directory_is_refused(self):
        os.makedirs(self.inbox("request.json"))
        self.assert_refused("not_regular_file")

    def test_oversize_is_refused(self):
        body = json.dumps({"action": "check", "request_id": "r1"})
        self.drop("request.json", body + " " * (4097 - len(body)), raw=True)
        self.assert_refused("oversize")

    def test_exactly_the_limit_is_read(self):
        body = json.dumps({"action": "check", "request_id": "r1"})
        self.drop("request.json", body + " " * (4096 - len(body)), raw=True)
        self.assertEqual(self.run_updater(mode="path")["last_result"], "checked")

    def test_bad_json_is_refused(self):
        self.drop("request.json", '{"action": "check",', raw=True)
        self.assert_refused("bad_json")

    def test_deep_nesting_is_refused(self):
        self.drop("request.json", "[" * 2000 + "]" * 2000, raw=True)
        self.assert_refused()
        self.drop("request.json", '{"action": "check", "request_id": {"a": [1]}}', raw=True)
        self.assert_refused("nesting")

    def test_unknown_key_bad_action_and_non_bool_are_refused(self):
        for name, payload, reason in (
            ("request.json", {"action": "check", "extra": 1}, "unknown_key"),
            ("request.json", {"action": "shell"}, "bad_action"),
            ("request.json", {"action": "update", "request_id": "x" * 65}, "bad_request_id"),
            ("settings.json", {"auto_update": "false"}, "bad_auto_update"),
            ("settings.json", {"auto_update": 0}, "bad_auto_update"),
            ("settings.json", {"auto_update": True, "channel": "edge"}, "unknown_key"),
        ):
            with self.subTest(payload=payload):
                self.drop(name, payload)
                self.assert_refused(reason)

    def test_any_other_file_is_refused_and_deleted(self):
        with open(self.inbox("override.yaml"), "w") as h:
            h.write("services: {}")
        self.assert_refused("unexpected_file")

    def test_a_second_request_within_60s_is_rate_limited(self):
        self.request("check", request_id="r1")
        self.assertEqual(self.run_updater(mode="path", now=1_000_000)["last_result"], "checked")
        self.request("check", request_id="r2")
        status = self.run_updater(mode="path", now=1_000_030)
        self.assertEqual(status["last_request"],
                         {"request_id": "r2", "result": "refused", "reason": "rate_limited"})  # fmt: skip
        self.drop("settings.json", {"auto_update": False})  # settings are exempt
        self.assertFalse(self.run_updater(mode="path", now=1_000_031)["auto_update"])
        self.request("check", request_id="r3")
        status = self.run_updater(mode="path", now=1_000_061)
        self.assertEqual(status["last_request"]["request_id"], "r3")
        self.assertEqual(status["last_result"], "checked")

    def test_consumed_is_capped(self):
        for i in range(25):
            self.drop("settings.json", {"auto_update": bool(i % 2)})
            self.run_updater(mode="path", now=1_000_000 + i)
        self.assertEqual(len(os.listdir(self.p(upd.CONSUMED))), 20)
        self.assertEqual(os.listdir(self.p(upd.INBOX)), [])


class ScriptHygieneTest(unittest.TestCase):
    def test_stdlib_only(self):
        with open(UPDATER, encoding="utf-8") as h:
            source = h.read()
        imports = set(re.findall(r"^(?:import|from) ([a-z_.]+)", source, re.MULTILINE))
        allowed = {
            "argparse", "fcntl", "json", "os", "re", "shutil", "stat", "subprocess", "sys",
            "time", "urllib.error", "urllib.parse", "urllib.request",
        }  # fmt: skip
        self.assertEqual(imports - allowed, set())

    def test_every_result_is_named(self):
        self.assertEqual(len(upd.RESULTS), 14)
        with open(UPDATER, encoding="utf-8") as h:
            used = set(re.findall(r'self\.result\("([a-z_]+)"', h.read()))
        self.assertTrue(used <= set(upd.RESULTS), used - set(upd.RESULTS))

    def test_gz_b64_roundtrip(self):
        text = "hello\nworld\n"
        self.assertEqual(gzip.decompress(base64.b64decode(templates.gzip_b64(text))).decode(), text)
        self.assertEqual(templates.gzip_b64(text), templates.gzip_b64(text))


if __name__ == "__main__":
    unittest.main()
