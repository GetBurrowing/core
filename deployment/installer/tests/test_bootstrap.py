"""bootstrap.sh: the host updater on an existing install (core task 01a1b7b6 stage 4).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Each case runs the tracked deployment/installer/updater/bootstrap.sh with
``sh`` under ``--root <tmp>``, a tree extracted from the checked-in copy of
origin/main's golden do-droplet user-data (fixtures/bootstrap/; taken before
the updater existed, never read through git). docker, systemctl, id and
chown are fakes on PATH that log their argv; docker answers from a JSON
"world" (the running core image, its RepoDigests, the live-meeting count).
"""

import base64
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(os.path.dirname(INSTALLER))
sys.path.insert(0, INSTALLER)

from burrow_install import templates, updater_bootstrap
from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import validate

BOOTSTRAP = updater_bootstrap.OUTPUT
USER_DATA = os.path.join(HERE, "fixtures", "bootstrap", "do-droplet-user-data")
DROPLET = os.path.join(HERE, "render_fixtures", "do-droplet.toml")
DROPLET_AUTH = os.path.join(HERE, "render_fixtures", "do-droplet-registry-auth.json")
INSTALLS_DOC = os.path.join(REPO_ROOT, "docs", "burrow", "installs.md")
upd = templates.updater_module()

COMMAND = (
    "sudo docker run --rm --entrypoint cat ghcr.io/getburrowing/core:core "
    "/app/updater/bootstrap.sh | sudo sh -s -- --channel stable"
)
REPO = "ghcr.io/example/core"
DIGEST = "sha256:" + "a" * 64
RUNNING = f"{REPO}@{DIGEST}"
UNITS = "/etc/systemd/system"
UPDATER_FILES = (
    "/opt/burrow/bin/burrow-update",
    "/etc/burrow-updater/updater.env",
    f"{UNITS}/burrow-updater.service",
    f"{UNITS}/burrow-updater.timer",
    f"{UNITS}/burrow-updater.path",
    "/opt/burrow/compose.override.yaml",
    "/var/lib/burrow-updater/outbox/status.json",
)

FAKE_DOCKER = r"""
import json, os, sys
world = json.load(open(os.environ["FAKE_WORLD"]))
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"argv": ["docker", *sys.argv[1:]], "cwd": os.getcwd()}) + "\n")
args = sys.argv[1:]
def out(lines):
    sys.stdout.write("".join(line + "\n" for line in lines))
    sys.exit(0)
if args[:1] == ["inspect"] and args[-1] == "core-platform":
    if world.get("no_container"):
        sys.exit(1)
    fmt = args[2]
    if fmt == "{{.Config.Image}}":
        out([world["image"]])
    if fmt == "{{.Image}}":
        out(["sha256:" + "f" * 64])
    if fmt.startswith("{{range .Config.Env}}"):
        out(world.get("env", []))
if args[:2] == ["image", "inspect"]:
    out(world.get("repo_digests", []))
if args[:2] == ["exec", "core-postgres"]:
    if world.get("meetings") is None:
        sys.stderr.write("psql: error\n")
        sys.exit(2)
    out([str(world["meetings"])])
if args[:2] == ["compose", "up"]:
    sys.exit(0)
sys.stderr.write("fake docker: unexpected argv %r\n" % (args,))
sys.exit(64)
"""

FAKE_LOGGER = r"""
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"argv": [os.path.basename(sys.argv[0]), *sys.argv[1:]], "cwd": os.getcwd()}) + "\n")
"""

FAKE_ID = r"""
import os, sys
if sys.argv[1:] == ["-u"]:
    print(os.environ.get("FAKE_UID", "0"))
    sys.exit(0)
sys.exit(1)
"""


def parse_write_files(text):
    """{path: (content, mode)} from a burrow_install user-data (its own YAML subset)."""
    files, lines, i = {}, text.split("\n"), 0
    while i < len(lines):
        m = re.match(r'^  - path: "(.*)"$', lines[i])
        if not m:
            i += 1
            continue
        path, mode, content, encoded = m.group(1), None, None, False
        i += 1
        while i < len(lines) and lines[i].startswith("    "):
            line = lines[i]
            pm = re.match(r'^    permissions: "(\d+)"$', line)
            if pm:
                mode = int(pm.group(1), 8)
            if line == '    encoding: "gz+b64"':
                encoded = True
            cm = re.match(r'^    content: (".*")$', line)
            if cm:
                content = json.loads(cm.group(1))
                if encoded:
                    content = gzip.decompress(base64.b64decode(content)).decode("utf-8")
            if line == "    content: |":
                body = []
                i += 1
                while i < len(lines) and (lines[i] == "" or lines[i].startswith("      ")):
                    body.append(lines[i][6:])
                    i += 1
                while body and body[-1] == "":
                    body.pop()
                content = "\n".join(body) + "\n"
                continue
            i += 1
        files[path] = (content, mode)
    return files


def snapshot(root):
    """{relpath: (kind, mode, sha256 or link target)} of every entry under root."""
    out = {}
    for base, dirs, names in os.walk(root):
        for name in dirs + names:
            full = os.path.join(base, name)
            st = os.lstat(full)
            rel = os.path.relpath(full, root)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", 0, os.readlink(full))
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = ("dir", stat.S_IMODE(st.st_mode), "")
            else:
                with open(full, "rb") as handle:
                    digest = hashlib.sha256(handle.read()).hexdigest()
                out[rel] = ("file", stat.S_IMODE(st.st_mode), digest)
    return out


class Rig:
    """A tmp root extracted from the golden, plus the fakes."""

    def __init__(self, case):
        self.tmp = tempfile.mkdtemp(prefix="bootstrap-test-")
        case.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        with open(USER_DATA, encoding="utf-8") as handle:
            for path, (content, mode) in parse_write_files(handle.read()).items():
                if path.startswith("/root/") or content is None:
                    continue
                full = self.root + path
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w", encoding="utf-8") as out:
                    out.write(content)
                os.chmod(full, mode)
        self.bin = os.path.join(self.tmp, "fakebin")
        os.makedirs(self.bin)
        for name, body in (
            ("docker", FAKE_DOCKER),
            ("systemctl", FAKE_LOGGER),
            ("chown", FAKE_LOGGER),
            ("id", FAKE_ID),
        ):
            path = os.path.join(self.bin, name)
            with open(path, "w", encoding="utf-8") as out:
                out.write(f"#!{sys.executable}\n{body}")
            os.chmod(path, 0o755)
        self.log = os.path.join(self.tmp, "log.jsonl")
        self.world_path = os.path.join(self.tmp, "world.json")
        self.world = {"image": f"{REPO}:core", "repo_digests": [RUNNING], "meetings": 0}

    def path(self, abspath):
        return self.root + abspath

    def read(self, abspath):
        with open(self.path(abspath), encoding="utf-8") as handle:
            return handle.read()

    def write(self, abspath, text):
        with open(self.path(abspath), "w", encoding="utf-8") as handle:
            handle.write(text)

    def mode(self, abspath):
        return stat.S_IMODE(os.lstat(self.path(abspath)).st_mode)

    def run(self, *args, script=BOOTSTRAP, uid="0"):
        with open(self.world_path, "w", encoding="utf-8") as handle:
            json.dump(self.world, handle)
        env = {
            "PATH": self.bin + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "FAKE_WORLD": self.world_path,
            "FAKE_LOG": self.log,
            "FAKE_UID": uid,
            "TMPDIR": self.tmp,
            "LC_ALL": "C",
        }
        return subprocess.run(
            ["sh", script, "--root", self.root, *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def calls(self, prog=None):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            calls = [json.loads(line) for line in handle if line.strip()]
        return [c for c in calls if prog is None or c["argv"][0] == prog]

    def snapshot(self):
        return snapshot(self.root)


def fresh_render():
    errors, manifest = validate(load(DROPLET))
    assert not errors, errors
    return parse_write_files(build(manifest, registry_auth=DROPLET_AUTH).files["user-data"][0])


class GeneratedTest(unittest.TestCase):
    def test_tracked_script_is_the_render(self):
        with open(BOOTSTRAP, encoding="utf-8") as handle:
            tracked = handle.read()
        self.assertEqual(
            tracked,
            updater_bootstrap.render(),
            "bootstrap.sh drifted: PYTHONPATH=deployment/installer "
            "python3 -m burrow_install.updater_bootstrap --write",
        )

    def test_sh_parses(self):
        proc = subprocess.run(["sh", "-n", BOOTSTRAP], capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_meeting_query_is_the_updaters(self):
        with open(BOOTSTRAP, encoding="utf-8") as handle:
            text = handle.read()
        sql = upd.live_meetings_args(templates.UPDATER_MEETING_STALE_HOURS)[-1]
        self.assertIn("'select count(*) from meetings where status = '\"'\"'live'\"'\"'", text)
        self.assertIn("12 hours", sql)

    def test_both_dockerfiles_copy_it(self):
        line = "COPY deployment/installer/updater/bootstrap.sh /app/updater/bootstrap.sh"
        for rel in ("apps/platform/Dockerfile", "apps/burrow_release/Dockerfile"):
            with open(os.path.join(REPO_ROOT, rel), encoding="utf-8") as handle:
                self.assertEqual(handle.read().count(line), 1, rel)

    def test_dockerignore_keeps_it_in_context(self):
        with open(os.path.join(REPO_ROOT, ".dockerignore"), encoding="utf-8") as handle:
            ignored = [ln.strip() for ln in handle if ln.strip() and not ln.startswith("#")]
        for pattern in ignored:
            self.assertFalse(
                "deployment/installer/updater/bootstrap.sh".startswith(pattern.rstrip("/*")),
                pattern,
            )

    def test_docs_carry_the_command_verbatim(self):
        with open(INSTALLS_DOC, encoding="utf-8") as handle:
            self.assertIn(COMMAND, handle.read())

    def test_shellcheck(self):
        uvx = shutil.which("uvx")
        if uvx is None:
            self.skipTest("shellcheck not run: no uvx")
        try:
            proc = subprocess.run(
                [uvx, "--from", "shellcheck-py", "shellcheck", "-s", "sh", BOOTSTRAP],
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self.skipTest("shellcheck not run: uvx timed out")
        if proc.returncode != 0 and "shellcheck" not in proc.stdout + proc.stderr.split("\n")[0]:
            self.skipTest(f"shellcheck not run: {proc.stderr.strip()[:200]}")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class BootstrapTest(unittest.TestCase):
    def install(self, rig, *args):
        proc = rig.run(*args)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def assert_refused(self, rig, needle, *args, code=1):
        before = rig.snapshot()
        proc = rig.run(*args)
        self.assertEqual(proc.returncode, code, proc.stdout + proc.stderr)
        self.assertIn(needle, proc.stderr)
        self.assertEqual(rig.snapshot(), before, "a refusal wrote something")
        self.assertEqual(rig.calls("systemctl"), [])
        self.assertEqual(rig.calls("chown"), [])
        self.assertFalse(any(c["argv"][1:3] == ["compose", "up"] for c in rig.calls("docker")))
        return proc

    # -- A: a fresh install ----------------------------------------------------

    def test_installs_files_units_dirs_and_pinned_override(self):
        rig = Rig(self)
        compose = rig.read("/opt/burrow/compose.yaml")
        secrets = rig.read("/opt/burrow/secrets.env")
        self.install(rig, "--channel", "stable")
        for path, mode in (
            ("/opt/burrow/bin/burrow-update", 0o755),
            ("/etc/burrow-updater/updater.env", 0o644),
            (f"{UNITS}/burrow-updater.service", 0o644),
            (f"{UNITS}/burrow-updater.timer", 0o644),
            (f"{UNITS}/burrow-updater.path", 0o644),
            ("/opt/burrow/compose.override.yaml", 0o644),
            ("/var/lib/burrow-updater/outbox/status.json", 0o644),
            ("/var/lib/burrow-updater/state/pinned", 0o600),
            ("/var/lib/burrow-updater", 0o755),
            ("/var/lib/burrow-updater/outbox", 0o755),
            ("/var/lib/burrow-updater/state", 0o700),
            ("/var/lib/burrow-updater/state/consumed", 0o700),
            ("/var/lib/burrow-updater/core", 0o700),
            ("/var/lib/burrow-updater/core/staging", 0o700),
            ("/var/lib/burrow-updater/core/inbox", 0o700),
        ):
            self.assertEqual(rig.mode(path), mode, path)
        override = rig.read("/opt/burrow/compose.override.yaml")
        self.assertEqual(override, upd.override_text(RUNNING))
        self.assertIn(f'    image: "{RUNNING}"\n', override)
        self.assertEqual(rig.read("/var/lib/burrow-updater/state/pinned"), RUNNING + "\n")
        # Owners, from the fake chown's log.
        owners = {c["argv"][2][len(rig.root) :]: c["argv"][1] for c in rig.calls("chown")}
        for path in ("/var/lib/burrow-updater/core", "/var/lib/burrow-updater/core/staging",
                     "/var/lib/burrow-updater/core/inbox"):  # fmt: skip
            self.assertEqual(owners[path], "1000:1000", path)
        for path in ("/var/lib/burrow-updater", "/var/lib/burrow-updater/state",
                     "/var/lib/burrow-updater/outbox", "/var/lib/burrow-updater/state/consumed"):  # fmt: skip
            self.assertEqual(owners[path], "0:0", path)
        systemctl = [c["argv"][1:] for c in rig.calls("systemctl")]
        self.assertEqual(
            systemctl,
            [["daemon-reload"], ["enable", "--now", "burrow-updater.timer", "burrow-updater.path"]],
        )
        ups = [c for c in rig.calls("docker") if c["argv"][1:3] == ["compose", "up"]]
        self.assertEqual([c["argv"] for c in ups],
                         [["docker", "compose", "up", "-d", "--no-deps", "core-platform"]])  # fmt: skip
        self.assertEqual(ups[0]["cwd"], os.path.realpath(rig.path("/opt/burrow")))
        # Never compose.yaml, secrets.env or the database (one read-only select).
        self.assertEqual(rig.read("/opt/burrow/compose.yaml"), compose)
        self.assertEqual(rig.read("/opt/burrow/secrets.env"), secrets)
        for call in rig.calls("docker"):
            joined = " ".join(call["argv"]).lower()
            self.assertNotIn("migrate", joined)
            self.assertNotIn("eval", joined)
            if call["argv"][1] == "exec":
                self.assertEqual(
                    call["argv"][1:],
                    upd.live_meetings_args(templates.UPDATER_MEETING_STALE_HOURS),
                )

    def test_updater_files_match_a_fresh_render(self):
        rig = Rig(self)
        self.install(rig, "--channel", "stable")
        rendered = fresh_render()
        for path in UPDATER_FILES:
            text = rig.read(path)
            if path.endswith("compose.override.yaml"):
                text = text.replace(f'    image: "{RUNNING}"\n', "")
            self.assertEqual(text, rendered[path][0], path)

    def test_the_updater_accepts_what_it_wrote(self):
        rig = Rig(self)
        self.install(rig)
        os.environ["BURROW_UPDATE_ROOT"] = rig.root
        try:
            cfg = upd.load_config()
        finally:
            del os.environ["BURROW_UPDATE_ROOT"]
        self.assertEqual((cfg["channel"], cfg["repo"], cfg["flavour"]), ("stable", REPO, "core"))
        self.assertTrue(cfg["ref_re"].match(RUNNING))
        status = json.loads(rig.read(upd.STATUS))
        self.assertEqual((status["last_result"], status["auto_update"]), ("never_run", True))

    def test_second_run_says_no_changes(self):
        rig = Rig(self)
        self.install(rig, "--channel", "stable")
        before, calls = rig.snapshot(), len(rig.calls())
        proc = self.install(rig, "--channel", "stable")
        self.assertIn("no changes", proc.stdout)
        self.assertEqual(rig.snapshot(), before)
        later = rig.calls()[calls:]
        self.assertEqual(
            [c for c in later if c["argv"][0] != "docker" or c["argv"][1] == "compose"], []
        )

    def test_dry_run_writes_nothing(self):
        rig = Rig(self)
        before = rig.snapshot()
        proc = self.install(rig, "--dry-run")
        self.assertIn("would write", proc.stdout)
        self.assertIn("nothing written", proc.stdout)
        self.assertEqual(rig.snapshot(), before)
        self.assertEqual(rig.calls("systemctl") + rig.calls("chown"), [])

    def test_auto_update_off(self):
        rig = Rig(self)
        self.install(rig, "--auto-update", "off")
        self.assertEqual(
            rig.read("/var/lib/burrow-updater/state/settings"), '{"auto_update": false}\n'
        )
        self.assertEqual(rig.mode("/var/lib/burrow-updater/state/settings"), 0o600)
        self.assertFalse(json.loads(rig.read(upd.STATUS))["auto_update"])

    def test_channel_edge_and_pinned(self):
        for channel in ("edge", "pinned"):
            rig = Rig(self)
            self.install(rig, "--channel", channel)
            env = rig.read(templates.UPDATER_ENV)
            self.assertIn(f"\nCHANNEL={channel}\n", env)
            self.assertNotIn("# CHANNEL is pinned", env)

    def test_default_channel_pinned_for_a_digest_or_commit_tag(self):
        for image in (f"{REPO}:core-0123abc", f"{REPO}:play-{'1' * 40}", RUNNING):
            rig = Rig(self)
            rig.world["image"] = image
            self.install(rig)
            env = rig.read(templates.UPDATER_ENV)
            self.assertIn("\nCHANNEL=pinned\n", env, image)
            self.assertIn("# CHANNEL is pinned: the running core image is a digest", env)
        rig = Rig(self)
        self.install(rig)
        self.assertIn("\nCHANNEL=stable\n", rig.read(templates.UPDATER_ENV))

    def test_play_flavour(self):
        rig = Rig(self)
        rig.world["image"] = f"{REPO}:play"
        self.install(rig)
        self.assertIn("\nFLAVOUR=play\n", rig.read(templates.UPDATER_ENV))

    # -- B, C, D: layout ---------------------------------------------------------

    def test_symlinked_opt_suite_is_accepted(self):
        rig = Rig(self)
        os.symlink("burrow", rig.path("/opt/suite"))
        self.install(rig)
        self.assertEqual(rig.read("/opt/burrow/compose.override.yaml"), upd.override_text(RUNNING))

    def test_real_opt_suite_is_refused(self):
        rig = Rig(self)
        os.makedirs(rig.path("/opt/suite"))
        self.assert_refused(rig, "run burrow-migrate first")

    def test_dash_f_in_execstart_is_refused(self):
        rig = Rig(self)
        unit = f"{UNITS}/burrow-stack.service"
        text = rig.read(unit).replace(
            "ExecStart=/usr/bin/docker compose up",
            "ExecStart=/usr/bin/docker compose -f compose.yaml up",
        )
        rig.write(unit, text)
        self.assert_refused(rig, "-f")

    def test_foreign_override_is_refused(self):
        rig = Rig(self)
        rig.write("/opt/burrow/compose.override.yaml", "services: {}\n")
        self.assert_refused(rig, "is not the updater's")
        self.assertEqual(rig.read("/opt/burrow/compose.override.yaml"), "services: {}\n")

    def test_updaters_own_override_is_replaced(self):
        rig = Rig(self)
        rig.write("/opt/burrow/compose.override.yaml", upd.override_text())
        self.install(rig)
        self.assertEqual(rig.read("/opt/burrow/compose.override.yaml"), upd.override_text(RUNNING))

    def test_not_root_is_refused(self):
        rig = Rig(self)
        before = rig.snapshot()
        proc = rig.run(uid="1000")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("root", proc.stderr)
        self.assertEqual(rig.snapshot(), before)

    # -- E and the image -------------------------------------------------------

    def test_legacy_suite_core_moves_to_the_published_repo(self):
        rig = Rig(self)
        legacy = "docker.io/acme/suite-core"
        rig.world["image"] = f"{legacy}:latest"
        # docker spells a Docker Hub RepoDigest by its familiar name.
        rig.world["repo_digests"] = [f"acme/suite-core@{DIGEST}"]
        self.install(rig, "--channel", "stable")
        env = rig.read(templates.UPDATER_ENV)
        self.assertIn(f"\nCORE_REPO={templates.PUBLISHED_CORE_REPO}\n", env)
        self.assertIn(f"\nROLLBACK_REPOS={legacy}\n", env)
        self.assertIn("\nFLAVOUR=core\n", env)
        pinned = f"{legacy}@{DIGEST}"
        self.assertEqual(rig.read("/opt/burrow/compose.override.yaml"), upd.override_text(pinned))
        os.environ["BURROW_UPDATE_ROOT"] = rig.root
        try:
            cfg = upd.load_config()
        finally:
            del os.environ["BURROW_UPDATE_ROOT"]
        self.assertTrue(cfg["ref_re"].match(pinned))
        # The updater finds the same running ref from docker's familiar spelling.
        self.assertEqual(upd.full_ref(f"acme/suite-core@{DIGEST}"), pinned)

    def test_legacy_play_from_the_container_env(self):
        rig = Rig(self)
        rig.world["image"] = "docker.io/acme/suite-core:latest"
        rig.world["repo_digests"] = [f"acme/suite-core@{DIGEST}"]
        rig.world["env"] = ["PATH=/usr/bin", "GAME_STREAM_ENABLED=true"]
        self.install(rig)
        self.assertIn("\nFLAVOUR=play\n", rig.read(templates.UPDATER_ENV))

    def test_no_repo_digest_is_refused(self):
        rig = Rig(self)
        rig.world["repo_digests"] = []
        self.assert_refused(rig, "not pinnable")

    def test_digest_of_another_repo_is_refused(self):
        rig = Rig(self)
        rig.world["repo_digests"] = [f"registry.example.test/other/core@{DIGEST}"]
        self.assert_refused(rig, "not pinnable")

    def test_non_core_image_is_refused(self):
        rig = Rig(self)
        rig.world["image"] = "ghcr.io/example/files-service:core"
        rig.world["repo_digests"] = [f"ghcr.io/example/files-service@{DIGEST}"]
        self.assert_refused(rig, "not a core image")

    def test_no_container_is_refused(self):
        rig = Rig(self)
        rig.world["no_container"] = True
        self.assert_refused(rig, "no core-platform container")

    # -- the live-meeting check ------------------------------------------------

    def test_live_meeting_exits_3_and_writes_nothing(self):
        rig = Rig(self)
        rig.world["meetings"] = 1
        self.assert_refused(rig, "a meeting is live; re-run when it ends", code=3)

    def test_meeting_check_error_fails_closed(self):
        rig = Rig(self)
        rig.world["meetings"] = None
        self.assert_refused(rig, "could not check for a live meeting", code=3)

    def test_full_ref(self):
        self.assertEqual(upd.full_ref(f"nginx@{DIGEST}"), f"docker.io/library/nginx@{DIGEST}")
        self.assertEqual(upd.full_ref(f"{REPO}@{DIGEST}"), f"{REPO}@{DIGEST}")
        self.assertEqual(upd.full_ref(f"localhost:5000/x@{DIGEST}"), f"localhost:5000/x@{DIGEST}")


if __name__ == "__main__":
    unittest.main()
