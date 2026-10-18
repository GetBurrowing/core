"""migrate/suite-to-burrow.sh and its rollback, run for real in a throwaway container.

Task 01a14dd8 stage 4. The scripts act on fixed host paths (/opt, /etc, the
systemd unit dir), so the sandboxed tests below build a pre-rename host IN THE
ROOT FILESYSTEM and run the scripts against it. They run only when all of
these hold, and skip otherwise:

- ``BURROW_MIGRATE_SANDBOX=1`` is set,
- the process is root,
- the process is inside a container (``/.dockerenv`` or ``/run/.containerenv``).

systemctl, docker and visudo are PATH stubs that keep their state under
/var/lib/*-stub. The systemctl stub emulates the agent host's adoption
(services/agent-host/src/legacy.ts) when burrow-agent-host.service starts.
groupmod, getent, sed, install and the shell (/bin/sh, dash on Debian) are real.

    podman run --rm -e BURROW_MIGRATE_SANDBOX=1 -v <repo>:/src:ro,z -w /src \\
      docker.io/library/python:3.12-slim \\
      python3 -m unittest discover -s deployment/installer/tests -p 'test_migrate_scripts.py' -v

The non-sandboxed class checks what a plain checkout can: the render ships
the script byte for byte as bin/burrow-migrate.
"""

import grp
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from burrow_install import templates

MIGRATE = os.path.join(INSTALLER, "migrate", "suite-to-burrow.sh")
ROLLBACK = os.path.join(INSTALLER, "migrate", "burrow-to-suite-rollback.sh")
PACKAGING = os.path.join(REPO, "services", "agent-host", "packaging")

SANDBOX = (
    os.environ.get("BURROW_MIGRATE_SANDBOX") == "1"
    and hasattr(os, "geteuid")
    and os.geteuid() == 0
    and (os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv"))
)

UNITS = "/etc/systemd/system"
AGENT = "01a14dd8-0000-7000-8000-00000000a2c4"
OLD_IMAGE = "docker.io/example/suite-agent-host:latest"
NEW_IMAGE = "ghcr.io/example/burrow-agent-host:latest"
STUBS = "/var/lib/a2c-stubs-01a14dd8"
SYSTEMCTL_STATE = "/var/lib/systemctl-stub"
DOCKER_STATE = "/var/lib/docker-stub"

SYSTEMCTL = r"""#!/bin/sh
# systemctl stub (test_migrate_scripts.py). State: enabled/ and active/ marker files.
S=/var/lib/systemctl-stub
U=/etc/systemd/system
mkdir -p "$S/enabled" "$S/active"
echo "systemctl $*" >>"$S/calls"
has_file() {
	case "$1" in
	*@?*.service) [ -f "$U/${1%%@*}@.service" ] ;;
	*) [ -f "$U/$1" ] ;;
	esac
}
adopt() { # what agent-host src/legacy.ts does at daemon start
	if getent group suite-agents >/dev/null && ! getent group burrow-agents >/dev/null; then
		groupmod -n burrow-agents suite-agents
	fi
	for d in "$U"/suite-agent@*.service.d; do
		[ -f "$d/10-agent.conf" ] || continue
		u=${d##*/}; u=${u%.d}; id=${u#suite-agent@}; id=${id%.service}
		mkdir -p "$U/burrow-agent@$id.service.d" /etc/burrow-agents
		printf '[Service]\nGroup=burrow-agents\n' >"$U/burrow-agent@$id.service.d/10-agent.conf"
		if [ -f "/etc/suite-agents/$id.env" ]; then mv "/etc/suite-agents/$id.env" "/etc/burrow-agents/$id.env"; fi
		rm -f "$S/enabled/$u" "$S/active/$u"
		touch "$S/enabled/burrow-agent@$id.service" "$S/active/burrow-agent@$id.service"
		rm -rf "$d"
	done
}
cmd=$1
shift
case "$cmd" in
daemon-reload) ;;
enable)
	now=0
	for u in "$@"; do
		case "$u" in
		--now) now=1 ;;
		*)
			has_file "$u" || { echo "Failed to enable unit: Unit file $u does not exist." >&2; exit 1; }
			touch "$S/enabled/$u"
			if [ "$now" = 1 ]; then touch "$S/active/$u"; fi
			;;
		esac
	done
	;;
disable) for u in "$@"; do rm -f "$S/enabled/$u"; done ;;
start)
	for u in "$@"; do
		has_file "$u" || { echo "Failed to start $u: Unit $u not found." >&2; exit 5; }
		touch "$S/active/$u"
		case "$u" in
		*-agent-host.service)
			# Requires= in the full_machine drop-in starts the setup unit first.
			if [ -f "$U/${u%.service}-setup.service" ]; then touch "$S/active/${u%.service}-setup.service"; fi
			;;
		esac
		if [ "$u" = burrow-agent-host.service ] && [ -f "$S/adopt" ]; then adopt; fi
	done
	;;
stop) for u in "$@"; do rm -f "$S/active/$u"; done ;;
is-enabled)
	if [ -f "$S/enabled/$1" ]; then echo enabled; exit 0; fi
	if has_file "$1"; then echo disabled; exit 1; fi
	echo not-found
	exit 1
	;;
is-active)
	if [ -f "$S/active/$1" ]; then echo active; exit 0; fi
	echo inactive
	exit 3
	;;
list-units)
	for f in "$S/active"/*; do [ -e "$f" ] && echo "${f##*/} loaded active running"; done
	exit 0
	;;
*) echo "systemctl stub: unsupported $cmd" >&2; exit 1 ;;
esac
"""

DOCKER = r"""#!/bin/sh
# docker stub (test_migrate_scripts.py). Images are directories under $S/images/<key>/root.
S=/var/lib/docker-stub
echo "docker $*" >>"$S/calls"
key() { printf '%s' "$1" | tr '/:' '__'; }
case "$1" in
compose)
	case "$2" in
	ls) printf 'NAME STATUS CONFIG FILES\nsuite-x running(7) /opt/burrow/compose.yaml\n' ;;
	*) echo "docker stub: compose $2 not expected" >&2; exit 1 ;;
	esac
	;;
volume) printf 'DRIVER VOLUME NAME\nlocal suite-x_core-postgres-data\n' ;;
ps) echo core-platform ;;
inspect) echo "/core-platform ghcr.io/example/core:core sha256:c0de" ;;
image)
	# image inspect -f FMT REF
	k=$(key "$5")
	[ -f "$S/images/$k/id" ] || { echo "No such image: $5" >&2; exit 1; }
	cat "$S/images/$k/id"
	;;
create)
	# create --pull never REF
	k=$(key "$4")
	[ -d "$S/images/$k" ] || { echo "Unable to find image '$4' locally" >&2; exit 1; }
	id="ctr$$"
	echo "$k" >"$S/ctr-$id"
	echo "$id"
	;;
cp)
	id=${2%%:*}
	path=${2#*:}
	k=$(cat "$S/ctr-$id") || exit 1
	src="$S/images/$k/root$path"
	[ -e "$src" ] || { echo "Could not find the file $path in container $id" >&2; exit 1; }
	if [ "$3" = - ]; then
		tar -C "$(dirname "$src")" -cf - "$(basename "$src")"
	else
		cp -a "$src" "$3"
	fi
	;;
rm) rm -f "$S/ctr-$3" ;;
tag) echo "$2" >"$S/images/$(key "$3")/id" ;;
*) echo "docker stub: unsupported $1" >&2; exit 1 ;;
esac
"""

VISUDO = r"""#!/bin/sh
# visudo stub: -cf FILE fails when FILE carries SYNTAX-ERROR.
echo "visudo $*" >>/var/lib/docker-stub/calls
f=$2
if grep -q SYNTAX-ERROR "$f"; then echo "$f: syntax error" >&2; exit 1; fi
echo "$f: parsed OK"
"""

# A pre-rename full_machine host, as the installer rendered it before task 01a14dd8.
LEGACY_UNITS = {
    "suite-stack.service": """\
# Generated by suite_install (ADR 0053) for install 'suite-x'. Do not edit; re-render.
[Unit]
Description=Burrow stack (suite-x)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
Wants=suite-agent-host.service
ConditionPathExists=/opt/suite/.images-loaded

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/suite
ExecStartPre=/opt/suite/bin/suite-ca-bundle
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
""",
    "suite-agent-host.service": """\
[Unit]
Description=Burrow agent host
[Service]
EnvironmentFile=-/etc/suite-agent-host.env
ExecStart=/usr/local/bin/bun run /opt/suite/agent-host/src/main.ts
[Install]
WantedBy=multi-user.target
""",
    "suite-agent-host.service.d/10-full-machine.conf": """\
[Unit]
Requires=suite-agent-host-setup.service
After=suite-agent-host-setup.service suite-stack.service
""",
    "suite-agent-host-setup.service": """\
[Unit]
Description=Install Burrow's agent host and its pinned tools
ConditionPathExists=/opt/suite/.images-loaded

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/suite/bin/suite-agent-host-setup
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
""",
    "suite-agent@.service": """\
[Service]
EnvironmentFile=/etc/suite-agents/%i.env
ExecStart=/usr/local/bin/bun run /opt/suite/agent-host/src/runner.ts
[Install]
WantedBy=multi-user.target
""",
    f"suite-agent@{AGENT}.service.d/10-agent.conf": """\
[Service]
Group=suite-agents
""",
}

SETUP_SCRIPT = f"""\
#!/bin/sh
set -eu
image='{OLD_IMAGE}'
dest=/opt/suite/agent-host
getent group suite-agents >/dev/null || groupadd --system suite-agents
install -m 0644 /opt/suite/tls/root.crt /usr/local/share/ca-certificates/suite-suite-x-root.crt
ctr="$(docker create --pull never "$image")"
docker cp "$ctr:/opt/suite/agent-host" "$dest.incoming"
sh "$dest/packaging/install-tools.sh" /etc/suite-agent-host/versions.env
"""

ENABLED = [
    "suite-stack.service",
    "suite-agent-host.service",
    "suite-agent-host-setup.service",
    f"suite-agent@{AGENT}.service",
]

CLEAN = [
    "/opt/suite",
    "/opt/burrow",
    "/var/lib/burrow-migrate",
    SYSTEMCTL_STATE,
    DOCKER_STATE,
    STUBS,
    "/etc/suite-agent-host.env",
    "/etc/burrow-agent-host.env",
    "/etc/suite-agent-host",
    "/etc/burrow-agent-host",
    "/etc/suite-agents",
    "/etc/burrow-agents",
    "/etc/sudoers.d/suite-agents",
    "/etc/sudoers.d/burrow-agents",
]


def _write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, mode)


def _remove(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def _group(name):
    try:
        return grp.getgrnam(name).gr_gid
    except KeyError:
        return None


def _tree(root):
    """{relative path: (mode, sha256 or link target)} for every entry under ``root``."""
    out = {}
    if not os.path.lexists(root):
        return out
    if os.path.isfile(root) or os.path.islink(root):
        return {".": _entry(root)}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = os.path.join(dirpath, name)
            if os.path.isdir(path) and not os.path.islink(path):
                out[os.path.relpath(path, root)] = (oct(os.lstat(path).st_mode), "dir")
            else:
                out[os.path.relpath(path, root)] = _entry(path)
    return out


def _entry(path):
    st = os.lstat(path)
    if os.path.islink(path):
        return (oct(st.st_mode), "->" + os.readlink(path))
    with open(path, "rb") as handle:
        return (oct(st.st_mode), hashlib.sha256(handle.read()).hexdigest())


@unittest.skipUnless(SANDBOX, "needs BURROW_MIGRATE_SANDBOX=1, root, inside a throwaway container")
class MigrateScriptTest(unittest.TestCase):
    def setUp(self):
        self.cleanup()
        self.addCleanup(self.cleanup)
        os.makedirs(os.path.join(STUBS, "bin"))
        for name, text in (("systemctl", SYSTEMCTL), ("docker", DOCKER), ("visudo", VISUDO)):
            _write(os.path.join(STUBS, "bin", name), text, 0o755)
        os.makedirs(os.path.join(SYSTEMCTL_STATE, "enabled"))
        os.makedirs(os.path.join(SYSTEMCTL_STATE, "active"))
        os.makedirs(os.path.join(DOCKER_STATE, "images"))
        self.env = dict(os.environ, PATH=f"{STUBS}/bin:" + os.environ.get("PATH", "/usr/bin:/bin"))

    def cleanup(self):
        for path in CLEAN:
            _remove(path)
        for name in os.listdir(UNITS) if os.path.isdir(UNITS) else []:
            if name.startswith(("suite-", "burrow-", ".burrow-")):
                _remove(os.path.join(UNITS, name))
        for group in ("suite-agents", "burrow-agents"):
            if _group(group) is not None:
                subprocess.run(["groupdel", group], check=True)

    # -- fixture ----------------------------------------------------------

    def image(self, ref, root_files):
        key = ref.replace("/", "_").replace(":", "_")
        base = os.path.join(DOCKER_STATE, "images", key)
        for rel, text in root_files.items():
            _write(os.path.join(base, "root", rel.lstrip("/")), text)
        _write(
            os.path.join(base, "id"), "sha256:" + hashlib.sha256(ref.encode()).hexdigest() + "\n"
        )

    def legacy_host(self, agents=True):
        _write("/opt/suite/compose.yaml", 'name: "suite-x"\nservices: {}\n')
        _write("/opt/suite/.images-loaded", "")
        _write("/opt/suite/bin/suite-ca-bundle", "#!/bin/sh\n", 0o755)
        stack = LEGACY_UNITS["suite-stack.service"]
        if not agents:
            stack = stack.replace("Wants=suite-agent-host.service\n", "")
        _write(f"{UNITS}/suite-stack.service", stack)
        enabled = ["suite-stack.service"]
        if agents:
            for rel, text in LEGACY_UNITS.items():
                if rel != "suite-stack.service":
                    _write(f"{UNITS}/{rel}", text)
            _write("/opt/suite/bin/suite-agent-host-setup", SETUP_SCRIPT, 0o755)
            _write("/opt/suite/agent-host/src/main.ts", "// pre-rename daemon\n")
            _write("/opt/suite/agent-host/packaging/suite-agent-host.service", "[Unit]\n")
            _write("/etc/suite-agent-host.env", "AGENT_HOST_TOKEN=t-01a14dd8\n", 0o600)
            _write("/etc/suite-agent-host/versions.env", "NODE_VERSION=22\n")
            _write("/etc/sudoers.d/suite-agents", "%suite-agents ALL=(ALL) NOPASSWD:ALL\n", 0o440)
            _write(f"/etc/suite-agents/{AGENT}.env", "TOKEN=agent\n", 0o600)
            os.chmod("/etc/suite-agents", 0o711)  # as the agent host makes it
            subprocess.run(["groupadd", "--system", "suite-agents"], check=True)
            self.image(OLD_IMAGE, {"/opt/suite/agent-host/src/main.ts": "// old\n"})
            new = {"/opt/burrow/agent-host/src/main.ts": "// burrow\n"}
            new["/opt/burrow/agent-host/src/legacy.ts"] = "// adoption\n"
            for name in ("burrow-agent-host.service", "burrow-agent@.service"):
                with open(os.path.join(PACKAGING, name), encoding="utf-8") as handle:
                    new[f"/opt/burrow/agent-host/packaging/{name}"] = handle.read()
            self.image(NEW_IMAGE, new)
            enabled = ENABLED
        for unit in enabled:
            for kind in ("enabled", "active"):
                _write(os.path.join(SYSTEMCTL_STATE, kind, unit), "")
        _write(os.path.join(SYSTEMCTL_STATE, "adopt"), "")

    def snapshot(self):
        return {
            "units": _tree(UNITS),
            "opt_suite": _tree("/opt/suite"),
            "opt_burrow": _tree("/opt/burrow"),
            "etc": {p: _tree(p) for p in CLEAN if p.startswith("/etc/")},
            "enabled": sorted(os.listdir(os.path.join(SYSTEMCTL_STATE, "enabled"))),
            "active": sorted(os.listdir(os.path.join(SYSTEMCTL_STATE, "active"))),
            "groups": (_group("suite-agents"), _group("burrow-agents")),
        }

    def run_script(self, script, *args):
        return subprocess.run(
            ["/bin/sh", script, *args],
            check=False,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def calls(self, which):
        path = os.path.join(SYSTEMCTL_STATE if which == "systemctl" else DOCKER_STATE, "calls")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as handle:
            return handle.read().splitlines()

    def stamps(self):
        root = "/var/lib/burrow-migrate"
        return sorted(os.listdir(root)) if os.path.isdir(root) else []

    def migrate(self, *args):
        return self.run_script(MIGRATE, "--agent-host-image", NEW_IMAGE, *args)

    # -- fresh to migrated ------------------------------------------------

    def test_fresh_to_migrated(self):
        self.legacy_host()
        gid = _group("suite-agents")
        r = self.migrate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

        self.assertTrue(os.path.islink("/opt/suite"))
        self.assertEqual(os.readlink("/opt/suite"), "/opt/burrow")
        self.assertTrue(os.path.isfile("/opt/burrow/compose.yaml"))
        with open("/opt/burrow/compose.yaml", encoding="utf-8") as handle:
            self.assertEqual(handle.read(), 'name: "suite-x"\nservices: {}\n')

        with open(f"{UNITS}/burrow-stack.service", encoding="utf-8") as handle:
            stack = handle.read()
        self.assertIn("WorkingDirectory=/opt/burrow\n", stack)
        self.assertIn("Wants=burrow-agent-host.service\n", stack)
        self.assertIn("ExecStop=/usr/bin/docker compose down\n", stack)
        self.assertNotIn("/opt/suite", stack)
        self.assertIn("# Migrated from suite-stack.service by burrow-migrate", stack)

        units = sorted(os.listdir(UNITS))
        self.assertEqual([u for u in units if u.startswith("suite-")], [])
        self.assertEqual(
            [u for u in units if u.startswith("burrow-")],
            sorted(
                [
                    "burrow-stack.service",
                    "burrow-agent-host.service",
                    "burrow-agent-host.service.d",
                    "burrow-agent-host-setup.service",
                    "burrow-agent@.service",
                    f"burrow-agent@{AGENT}.service.d",
                ]
            ),
        )
        with open(f"{UNITS}/burrow-agent-host-setup.service", encoding="utf-8") as handle:
            setup_unit = handle.read()
        self.assertIn("ExecStart=/opt/burrow/bin/burrow-agent-host-setup\n", setup_unit)
        self.assertIn("ConditionPathExists=/opt/burrow/.images-loaded\n", setup_unit)
        with open(f"{UNITS}/burrow-agent-host.service.d/10-full-machine.conf") as handle:
            self.assertEqual(
                handle.read(),
                "[Unit]\nRequires=burrow-agent-host-setup.service\n"
                "After=burrow-agent-host-setup.service burrow-stack.service\n",
            )
        with open(os.path.join(PACKAGING, "burrow-agent-host.service"), encoding="utf-8") as h:
            packaged = h.read()
        with open(f"{UNITS}/burrow-agent-host.service", encoding="utf-8") as handle:
            self.assertEqual(handle.read(), packaged)

        with open("/opt/burrow/bin/burrow-agent-host-setup", encoding="utf-8") as handle:
            script = handle.read()
        self.assertIn(f"image='{NEW_IMAGE}'\n", script)
        self.assertIn("dest=/opt/burrow/agent-host\n", script)
        self.assertIn('docker cp "$ctr:/opt/burrow/agent-host"', script)
        self.assertIn("groupadd --system burrow-agents", script)
        self.assertIn("/etc/burrow-agent-host/versions.env", script)
        self.assertNotIn("/opt/suite", script)
        self.assertEqual(os.stat("/opt/burrow/bin/burrow-agent-host-setup").st_mode & 0o777, 0o755)
        self.assertTrue(os.path.isfile("/opt/burrow/agent-host/src/legacy.ts"))

        enabled = sorted(os.listdir(os.path.join(SYSTEMCTL_STATE, "enabled")))
        self.assertEqual(
            enabled,
            sorted(
                [
                    "burrow-stack.service",
                    "burrow-agent-host-setup.service",
                    "burrow-agent-host.service",
                    f"burrow-agent@{AGENT}.service",
                ]
            ),
        )
        active = sorted(os.listdir(os.path.join(SYSTEMCTL_STATE, "active")))
        self.assertIn("burrow-stack.service", active)
        self.assertIn(f"burrow-agent@{AGENT}.service", active)
        self.assertEqual([a for a in active if a.startswith("suite-")], [])

        self.assertIsNone(_group("suite-agents"))
        self.assertEqual(_group("burrow-agents"), gid)
        self.assertFalse(os.path.exists("/etc/suite-agent-host.env"))
        self.assertEqual(os.stat("/etc/burrow-agent-host.env").st_mode & 0o777, 0o600)
        self.assertTrue(os.path.isfile("/etc/burrow-agent-host/versions.env"))
        self.assertFalse(os.path.exists("/etc/sudoers.d/suite-agents"))
        with open("/etc/sudoers.d/burrow-agents", encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "%burrow-agents ALL=(ALL) NOPASSWD:ALL\n")
        self.assertEqual(os.stat("/etc/sudoers.d/burrow-agents").st_mode & 0o777, 0o440)
        self.assertEqual([n for n in os.listdir("/etc/sudoers.d") if n.startswith(".")], [])

        # The rollback record.
        (stamp,) = self.stamps()
        rb = os.path.join("/var/lib/burrow-migrate", stamp)
        with open(os.path.join(rb, "status")) as handle:
            self.assertEqual(handle.read(), "done\n")
        self.assertEqual(
            sorted(os.listdir(os.path.join(rb, "units"))),
            sorted(
                [
                    "suite-stack.service",
                    "suite-agent-host.service",
                    "suite-agent-host.service.d",
                    "suite-agent-host-setup.service",
                    "suite-agent@.service",
                    f"suite-agent@{AGENT}.service.d",
                ]
            ),
        )
        for name in ("compose-ls.txt", "volumes.txt", "images.txt", "units.txt"):
            with open(os.path.join(rb, name)) as handle:
                self.assertTrue(handle.read().strip(), name)
        self.assertTrue(os.path.isfile(os.path.join(rb, "agent-host", "src", "main.ts")))
        self.assertEqual(sorted(os.listdir(os.path.join(rb, "etc"))),
                         ["suite-agent-host", "suite-agent-host.env", "suite-agents"])  # fmt: skip

        # Order: stop the stack before the move; never a docker down with -v.
        sysd = self.calls("systemctl")
        self.assertIn("systemctl stop suite-stack.service", sysd)
        self.assertLess(
            sysd.index("systemctl stop suite-stack.service"),
            sysd.index("systemctl start burrow-stack.service"),
        )
        self.assertLess(
            sysd.index("systemctl start burrow-stack.service"),
            sysd.index("systemctl start burrow-agent-host.service"),
        )
        for call in self.calls("docker"):
            self.assertNotIn(" -v", call)
            self.assertNotIn("--volumes", call)
        self.assertIn("burrow-stack.service enabled=enabled active=active", r.stdout)
        self.assertIn(f"burrow-agent@{AGENT}.service enabled=enabled active=active", r.stdout)
        self.assertIn("/opt/suite -> /opt/burrow", r.stdout)

    def test_second_run_is_a_no_op(self):
        self.legacy_host()
        first = self.migrate()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        before = self.snapshot()
        sysd, dock, stamps = self.calls("systemctl"), self.calls("docker"), self.stamps()
        second = self.migrate()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("already migrated; nothing to do", second.stdout)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.stamps(), stamps)
        new_sysd = self.calls("systemctl")[len(sysd) :]
        self.assertTrue(new_sysd, "positive control: the second run reads unit state")
        self.assertEqual(
            [
                c
                for c in new_sysd
                if not c.startswith(("systemctl is-enabled", "systemctl is-active"))
            ],
            [],
        )
        self.assertEqual(self.calls("docker")[len(dock) :], [])

    def test_stack_only_host(self):
        self.legacy_host(agents=False)
        r = self.run_script(MIGRATE)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(os.readlink("/opt/suite"), "/opt/burrow")
        self.assertEqual(sorted(os.listdir(os.path.join(SYSTEMCTL_STATE, "enabled"))),
                         ["burrow-stack.service"])  # fmt: skip
        self.assertEqual([u for u in os.listdir(UNITS) if u.startswith(("suite-", "burrow-a"))], [])
        self.assertEqual(self.run_script(MIGRATE).returncode, 0)

    def test_pending_adoption_exits_3_and_a_rerun_finishes(self):
        self.legacy_host()
        os.unlink(os.path.join(SYSTEMCTL_STATE, "adopt"))  # the daemon has not adopted yet
        r = self.migrate("--adopt-wait", "0")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("run burrow-migrate again", r.stdout)
        self.assertTrue(os.path.exists(f"{UNITS}/suite-agent@.service"))
        _write(os.path.join(SYSTEMCTL_STATE, "adopt"), "")
        # The daemon adopts on its next start; emulate it, then re-run.
        subprocess.run(
            ["systemctl", "start", "burrow-agent-host.service"], env=self.env, check=True
        )
        r = self.migrate("--adopt-wait", "0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("resuming the run recorded in", r.stdout)
        self.assertFalse(os.path.exists(f"{UNITS}/suite-agent@.service"))
        self.assertEqual(len(self.stamps()), 1)
        self.assertIn("already migrated", self.migrate().stdout)

    # -- refusals: each changes nothing ----------------------------------

    def assert_refused(self, result, needle):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stderr)
        self.assertEqual(self.stamps(), [])
        self.assertEqual(
            [c for c in self.calls("systemctl") if not c.startswith("systemctl is-")], []
        )

    def test_refuses_without_a_legacy_root(self):
        r = self.migrate()
        self.assert_refused(r, "/opt/suite is not a directory")

    def test_refuses_without_the_legacy_stack_unit(self):
        self.legacy_host(agents=False)
        os.unlink(f"{UNITS}/suite-stack.service")
        before = self.snapshot()
        self.assert_refused(self.migrate(), "suite-stack.service not found")
        self.assertEqual(self.snapshot(), before)

    def test_refuses_a_non_empty_opt_burrow(self):
        # The reversed order: a new render was written before migrating.
        self.legacy_host()
        _write("/opt/burrow/compose.yaml", "name: x\n")
        before = self.snapshot()
        self.assert_refused(self.migrate(), "/opt/burrow exists and is not an empty directory")
        self.assertEqual(self.snapshot(), before)

    def test_an_empty_opt_burrow_is_accepted(self):
        self.legacy_host(agents=False)
        os.makedirs("/opt/burrow")
        r = self.run_script(MIGRATE)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(os.readlink("/opt/suite"), "/opt/burrow")

    def test_refuses_a_pre_rename_agent_host_image(self):
        self.legacy_host()
        before = self.snapshot()
        r = self.run_script(MIGRATE)  # defaults to the setup script's (old) image
        self.assert_refused(r, f"agent-host image {OLD_IMAGE} has no /opt/burrow/agent-host")
        self.assertEqual(self.snapshot(), before)

    def test_refuses_an_image_that_is_not_loaded(self):
        self.legacy_host()
        before = self.snapshot()
        r = self.run_script(MIGRATE, "--agent-host-image", "ghcr.io/example/absent:1")
        self.assert_refused(r, "is not on this host")
        self.assertEqual(self.snapshot(), before)

    def test_refuses_a_sudoers_file_visudo_rejects(self):
        self.legacy_host()
        _write("/etc/sudoers.d/suite-agents", "%suite-agents SYNTAX-ERROR\n", 0o440)
        before = self.snapshot()
        self.assert_refused(self.migrate(), "does not pass visudo -c")
        self.assertEqual(self.snapshot(), before)

    # -- rollback ---------------------------------------------------------

    def test_rollback_restores_the_unit_names(self):
        self.legacy_host()
        before = self.snapshot()
        r = self.migrate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotEqual(self.snapshot(), before)
        (stamp,) = self.stamps()
        rb = self.run_script(ROLLBACK, stamp)
        self.assertEqual(rb.returncode, 0, rb.stdout + rb.stderr)
        after = self.snapshot()
        self.assertEqual(after["units"], before["units"])
        self.assertEqual(after["opt_suite"], before["opt_suite"])
        self.assertEqual(after["opt_burrow"], {})
        self.assertEqual(after["etc"], before["etc"])
        self.assertEqual(after["enabled"], before["enabled"])
        self.assertEqual(after["groups"], before["groups"])
        for unit in ENABLED:
            self.assertIn(unit, after["active"])
        self.assertEqual([a for a in after["active"] if a.startswith("burrow-")], [])
        self.assertIn("suite-stack.service enabled=enabled active=active", rb.stdout)
        with open(os.path.join("/var/lib/burrow-migrate", stamp, "status")) as handle:
            self.assertEqual(handle.read(), "rolled-back\n")
        again = self.run_script(ROLLBACK, stamp)
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("already rolled back", again.stdout)
        self.assertEqual(self.snapshot(), after)

    def test_rollback_then_migrate_again(self):
        self.legacy_host()
        self.assertEqual(self.migrate().returncode, 0)
        (stamp,) = self.stamps()
        self.assertEqual(self.run_script(ROLLBACK, stamp).returncode, 0)
        r = self.migrate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.stamps()), 2)
        self.assertEqual(os.readlink("/opt/suite"), "/opt/burrow")

    def test_rollback_refuses_an_unknown_stamp(self):
        r = self.run_script(ROLLBACK, "20990101T000000Z")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no rollback record", r.stderr)
        r = self.run_script(ROLLBACK, "../etc")
        self.assertEqual(r.returncode, 1)


class MigrateShippingTest(unittest.TestCase):
    """Runs anywhere: what the render and the repo ship."""

    def test_render_ships_the_script_byte_for_byte(self):
        with open(MIGRATE, encoding="utf-8") as handle:
            self.assertEqual(templates.migrate_script(), handle.read())

    def test_every_single_host_render_writes_bin_burrow_migrate(self):
        from test_agents_render import CONTAINED, EXAMPLE, FULL, manifest_from, write_files

        from burrow_install.render import build

        script = templates.migrate_script()
        for path in (EXAMPLE, FULL, CONTAINED):
            with self.subTest(manifest=os.path.basename(path)):
                files = write_files(build(manifest_from(path)).files["user-data"][0])
                self.assertEqual(files["/opt/burrow/bin/burrow-migrate"], ("0755", script))

    def test_scripts_are_executable_posix_sh(self):
        for path in (MIGRATE, ROLLBACK):
            with self.subTest(path=os.path.basename(path)):
                self.assertTrue(os.access(path, os.X_OK))
                with open(path, encoding="utf-8") as handle:
                    self.assertEqual(handle.readline(), "#!/bin/sh\n")

    def test_the_sandbox_gate_is_closed_outside_a_container(self):
        # The sandboxed class rewrites /opt and /etc: it must never run on a real host.
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, BURROW_MIGRATE_SANDBOX="1")
            code = (
                f"import sys; sys.path.insert(0, {HERE!r}); import test_migrate_scripts as t; "
                "print(t.SANDBOX)"
            )
            out = subprocess.run(
                [sys.executable, "-c", code],
                check=False,
                env=env,
                capture_output=True,
                text=True,
                cwd=tmp,
            ).stdout.strip()
        in_container = os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")
        expected = in_container and os.geteuid() == 0
        self.assertEqual(out, str(expected))


if __name__ == "__main__":
    unittest.main()
