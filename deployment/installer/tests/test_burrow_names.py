"""Guard: deployment/installer names no pre-Burrow install name outside an allowlist (task 01a14dd8).

Fresh installs render under ``/opt/burrow`` with ``burrow-*`` units, the mac
target lives under ``~/burrow`` with ``io.github.getburrowing.install.*``
LaunchAgents, and images come from ``[images] registry``. The old names stay
only where something already installed depends on them. Every such place is
an ALLOWLIST entry of ``(path, needle, reason)``:

- ``path`` is a file relative to deployment/installer, or a directory ending
  in ``/``;
- ``needle`` is a substring the hit's line must contain, or None for every hit
  in that path (used for test files whose subject IS the legacy name);
- ``reason`` says why the name stays.

A hit is a line matching one of PATTERNS. The tests fail on a hit no entry
allows, and on a STALE entry that allows no hit (so the list cannot rot into
a blanket exemption). The positive control plants ``/opt/suite`` in
templates.py in a copy of the tree and requires the scan to report exactly it.

Run: python3 -m unittest discover -s deployment/installer/tests -v
"""

import collections
import os
import re
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)

PATTERNS = {
    "/opt/suite": re.compile(r"/opt/suite\b"),
    "suite-stack": re.compile(r"suite-stack"),
    "suite-agent": re.compile(r"suite-agent"),
    "suite_install": re.compile(r"\bsuite_install\b"),
    "suite-install": re.compile(r"suite-install"),
    "docker.io suite- image": re.compile(r"docker\.io/\S*suite-"),
    "~/suite": re.compile(r"~/suite\b"),
    "~/suite (code)": re.compile(r'expanduser\("~"\), "suite"'),
    "SuiteBackups": re.compile(r"SuiteBackups"),
    "legacy LaunchAgent label": re.compile(r"org\.startupsuite\.install"),
}

Allow = collections.namedtuple("Allow", "path needle reason")

KEYCHAIN = (
    "Keychain service prefix suite-install.<name> is KEPT on purpose: renaming it "
    "loses every secret an existing Mac install stored (stage 1 decision)"
)
SHIM = "stage-1 compatibility shim: the old module and CLI names still run, with a deprecation line"
CLI_SESSION = (
    "tmux session name owned by suite-cli; it moves when core bumps BURROW_CLI_REF to a 0.9 CLI "
    "(stage 2 deferred it); agents.py embeds packaging/burrow-agent@.service verbatim"
)

MIGRATE_MARK = "# legacy name, kept by burrow-migrate"
MIGRATE = (
    "the upgrade script moves an existing install off these names, so it must name them "
    "(docs/runbooks/burrow-rename-deferred.md)"
)

ALLOWLIST = (
    # Stage 1 shims.
    Allow("suite_install/", None, SHIM),
    Allow("mac/suite-install", None, SHIM),
    Allow("mac/burrow-install", "The old name mac/suite-install", SHIM),
    Allow("mac/README.md", "This CLI was called `suite-install`", SHIM),
    Allow("mac/README.md", "task 01a14dd8. Both old names still work", SHIM),
    Allow("mac/README.md", "`python3 -m suite_install` print one deprecation", SHIM),
    Allow("mac/README.md", "- `suite-install`: the old name", SHIM),
    Allow("tests/test_legacy_entrypoint.py", None, "tests the stage-1 shim, so it names it"),
    # The Keychain prefix.
    Allow("burrow_install/setup/macos.py", 'SERVICE_PREFIX = "suite-install"', KEYCHAIN),
    Allow(
        "burrow_install/setup/macos.py", "under service ``suite-install.<install.name>``", KEYCHAIN
    ),
    Allow("burrow_install/setup/inputs.py", "``suite-install.<install.name>``", KEYCHAIN),
    Allow("mac/README.md", "find-generic-password -s suite-install.<name>", KEYCHAIN),
    Allow("mac/README.md", "`suite-install.<install name>`. That prefix is KEPT", KEYCHAIN),
    Allow("mac/README.md", '"keychain_service": "suite-install.<name>"', KEYCHAIN),
    Allow("skill/SKILL.md", "`suite-install.<install name>`", KEYCHAIN),
    Allow("tests/test_setup_cli.py", '"suite-install.burrow-01a0d6ab"', KEYCHAIN),
    Allow("tests/test_setup_hygiene.py", '"suite-install.', KEYCHAIN),
    # The legacy [images] image_namespace branch.
    Allow(
        "burrow_install/registry.py",
        "docker.io/<image_namespace>/suite-core",
        "legacy [images] image_namespace renders the old Docker Hub refs unchanged",
    ),
    Allow(
        "burrow_install/registry.py",
        '"agent-host": "suite-agent-host"',
        "legacy [images] image_namespace renders the old Docker Hub refs unchanged",
    ),
    Allow(
        "tests/golden/mac/",
        "docker.io/example/suite-",
        "deployment/examples/mac.install.toml stays on the legacy image_namespace until "
        "meeting-transcriber publishes a registry build",
    ),
    Allow(
        "tests/test_render.py",
        "docker.io/example/suite-core:core",
        "asserts the legacy image_namespace render and the fresh-render pattern's control",
    ),
    Allow(
        "tests/test_agents_render.py",
        "/suite-agent-host",
        "CI still pushes the pre-rename agent-host name to GHCR for hosts installed before "
        "the rename (task 01a14dd8); Docker Hub publishing stopped with task 01a14afe",
    ),
    # Fresh-render guards spell what they forbid.
    Allow(
        "tests/test_render.py",
        "LEGACY = re.compile(",
        "the fresh-render test's pattern names the legacy forms",
    ),
    Allow(
        "tests/test_render.py",
        '"WorkingDirectory=/opt/suite"',
        "positive control of the fresh-render pattern",
    ),
    Allow(
        "tests/test_render.py",
        '"systemctl enable suite-stack.service"',
        "positive control of the fresh-render pattern",
    ),
    Allow(
        "tests/test_render.py",
        '"/etc/systemd/system/suite-agent@.service"',
        "positive control of the fresh-render pattern",
    ),
    Allow(
        "tests/test_mac_render.py",
        "LEGACY = re.compile(",
        "the fresh-render test's pattern names the legacy forms",
    ),
    Allow(
        "tests/test_mac_render.py",
        "self.LEGACY.search('image: \"docker.io/example/suite-core:core\"')",
        "positive control of the fresh-render pattern",
    ),
    # The ~/suite discovery and the legacy LaunchAgent label.
    Allow(
        "burrow_install/setup/state.py",
        None,
        "read-only discovery of a not-yet-migrated Mac install under ~/suite",
    ),
    Allow(
        "burrow_install/proof_mac.py",
        "legacy ~/suite):",
        "documents the same ~/suite discovery the proof commands use",
    ),
    Allow(
        "burrow_install/setup/macos.py",
        'LEGACY_LABEL_ROOT = "org.startupsuite.install"',
        "teardown and the job steps boot out the pre-01a14dd8 LaunchAgent labels",
    ),
    Allow(
        "tests/test_setup_burrow_names.py",
        None,
        "tests the ~/suite discovery and the legacy LaunchAgent label",
    ),
    # suite-cli-owned names (stage 2 deferred them).
    Allow("burrow_install/agents.py", "_AGENT_SESSION=suite-agent", CLI_SESSION),
    Allow("tests/golden/single-host-agents-full/", "_AGENT_SESSION=suite-agent", CLI_SESSION),
    # The pre-rename upgrade (stage 4). The scripts define each legacy name once,
    # on a line carrying MIGRATE_MARK; every render embeds the script, so the
    # goldens carry the same lines.
    Allow("migrate/suite-to-burrow.sh", MIGRATE_MARK, MIGRATE),
    Allow("migrate/burrow-to-suite-rollback.sh", MIGRATE_MARK, MIGRATE),
    Allow("tests/golden/single-host/", MIGRATE_MARK, MIGRATE),
    Allow("tests/golden/single-host-agents-contained/", MIGRATE_MARK, MIGRATE),
    Allow("tests/golden/single-host-agents-full/", MIGRATE_MARK, MIGRATE),
    Allow("tests/golden/single-host-memory-off/", MIGRATE_MARK, MIGRATE),
    Allow(
        "burrow_install/setup/migrate.py",
        'LEGACY_BACKUP_ROOT = "SuiteBackups"',
        "the Mac migrate step leaves the pre-rename backup dir in place as the read path "
        "for old backups",
    ),
    Allow(
        "tests/test_migrate_scripts.py",
        None,
        "builds a pre-rename host and runs the migration and rollback against it",
    ),
    # This guard spells the patterns it looks for.
    Allow("tests/test_burrow_names.py", None, "the guard's own patterns and allowlist"),
)


def scan(root):
    """Every ``(rel path, line number, pattern name, line)`` hit under ``root``."""
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            try:
                with open(path, encoding="utf-8") as handle:
                    lines = handle.read().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for number, line in enumerate(lines, 1):
                for pattern_name, pattern in PATTERNS.items():
                    if pattern.search(line):
                        hits.append((rel, number, pattern_name, line))
    return hits


def _covers(entry, rel, line):
    path_ok = rel.startswith(entry.path) if entry.path.endswith("/") else rel == entry.path
    return path_ok and (entry.needle is None or entry.needle in line)


def check(hits, allowlist):
    """``(hits no entry allows, entries that allow no hit)``."""
    used = set()
    unallowed = []
    for hit in hits:
        rel, _number, _pattern, line = hit
        matched = [i for i, entry in enumerate(allowlist) if _covers(entry, rel, line)]
        if matched:
            used.update(matched)
        else:
            unallowed.append(hit)
    stale = [entry for i, entry in enumerate(allowlist) if i not in used]
    return unallowed, stale


class BurrowNamesGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hits = scan(INSTALLER)

    def test_no_legacy_name_outside_the_allowlist(self):
        self.assertTrue(self.hits, "positive control: the tree has allowlisted hits")
        unallowed, _stale = check(self.hits, ALLOWLIST)
        self.assertEqual([f"{rel}:{n} [{p}] {line.strip()}" for rel, n, p, line in unallowed], [])

    def test_no_stale_allowlist_entry(self):
        _unallowed, stale = check(self.hits, ALLOWLIST)
        self.assertEqual(stale, [])

    def test_every_entry_names_a_real_path_and_a_reason(self):
        for entry in ALLOWLIST:
            with self.subTest(path=entry.path, needle=entry.needle):
                self.assertTrue(os.path.exists(os.path.join(INSTALLER, entry.path)))
                self.assertGreaterEqual(len(entry.reason), 20)

    def test_each_pattern_matches_its_form(self):
        samples = {
            "/opt/suite": "WorkingDirectory=/opt/suite",
            "suite-stack": "systemctl start suite-stack.service",
            "suite-agent": "/etc/sudoers.d/suite-agents",
            "suite_install": "python3 -m suite_install render",
            "suite-install": "mac/suite-install setup status",
            "docker.io suite- image": 'image: "docker.io/acme/suite-core:core"',
            "~/suite": "cd ~/suite/<name>",
            "~/suite (code)": 'os.path.join(os.path.expanduser("~"), "suite")',
            "SuiteBackups": "~/SuiteBackups/<name>",
            "legacy LaunchAgent label": "org.startupsuite.install.m.backup",
        }
        self.assertEqual(set(samples), set(PATTERNS))
        for name, text in samples.items():
            with self.subTest(pattern=name):
                self.assertTrue(PATTERNS[name].search(text))
        # Burrow names are not hits, nor is a test named after an install dir.
        for text in (
            "/opt/burrow burrow-stack.service burrow-agent@.service",
            "test_suite_install_dir",
            'image: "ghcr.io/example/core:core"',
            "docker.io/library/caddy:2",
            "~/suites",
        ):
            with self.subTest(text=text):
                self.assertFalse([n for n, p in PATTERNS.items() if p.search(text)])


class BurrowNamesPositiveControlTest(unittest.TestCase):
    """A copy of the tree with ``/opt/suite`` planted in templates.py fails the guard."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="burrow-names-guard-01a14dd8-")
        cls.root = os.path.join(cls.tmp, "installer")
        shutil.copytree(INSTALLER, cls.root, ignore=shutil.ignore_patterns("__pycache__", "golden"))
        # The goldens are not copied; their entry is checked against the real tree.
        cls.allowlist = tuple(e for e in ALLOWLIST if not e.path.startswith("tests/golden/"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_the_copy_is_clean_before_planting(self):
        unallowed, stale = check(scan(self.root), self.allowlist)
        self.assertEqual((unallowed, stale), ([], []))

    def test_a_planted_opt_suite_in_templates_is_reported(self):
        path = os.path.join(self.root, "burrow_install", "templates.py")
        with open(path, encoding="utf-8") as handle:
            original = handle.read()
        self.addCleanup(self._write, path, original)
        planted = original.replace(
            'INSTALL_ROOT = "/opt/burrow"\n', 'INSTALL_ROOT = "/opt/suite"\n', 1
        )
        self.assertNotEqual(planted, original, "the plant must change templates.py")
        self._write(path, planted)
        unallowed, stale = check(scan(self.root), self.allowlist)
        self.assertEqual(
            [(rel, p, line) for rel, _n, p, line in unallowed],
            [("burrow_install/templates.py", "/opt/suite", 'INSTALL_ROOT = "/opt/suite"')],
        )
        self.assertEqual(stale, [])

    def test_a_stale_entry_is_reported(self):
        extra = Allow("burrow_install/templates.py", "/opt/suite", "planted stale entry 01a14dd8")
        _unallowed, stale = check(scan(self.root), self.allowlist + (extra,))
        self.assertEqual(stale, [extra])

    @staticmethod
    def _write(path, text):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)


if __name__ == "__main__":
    unittest.main()
