"""The old entry points still work after the rename to burrow_install (task 01a14dd8 stage 1).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

``python3 -m suite_install`` and ``mac/suite-install`` are compatibility shims.
Each must print exactly one deprecation line on stderr and otherwise behave as
``python3 -m burrow_install`` / ``mac/burrow-install``: the same argv, the same
stdout, the same exit code, and a byte-identical render.

Every CLI call is a real subprocess, so the shim's own argv handling is what
is tested, not a call into ``main`` that would bypass it.
"""

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
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
AGENTS_FULL = os.path.join(HERE, "render_fixtures", "single-host-agents-full.toml")
BAD_MANIFEST = os.path.join(HERE, "fixtures", "invalid_value.toml")
GOOD_MANIFEST = os.path.join(HERE, "fixtures", "good.toml")
MAC = os.path.join(INSTALLER, "mac")

sys.path.insert(0, INSTALLER)

from burrow_install.render import inside_git_worktree

PY_DEPRECATION = "suite_install is now burrow_install\n"
MAC_DEPRECATION = "suite-install is now burrow-install\n"


def clean_env():
    """The caller's env minus every BURROW_* name, so the caller's install dir cannot leak in."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BURROW_", "PYTHON"))}
    env["PYTHONPATH"] = INSTALLER
    return env


def run_module(module, *argv):
    return subprocess.run(
        [sys.executable, "-m", module, *argv],
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )


def tree_digest(root):
    """{relative path: (sha256, mode)} for every file under root."""
    out = {}
    for dirpath, _dirs, names in os.walk(root):
        for name in names:
            path = os.path.join(dirpath, name)
            with open(path, "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
            out[os.path.relpath(path, root)] = (digest, os.stat(path).st_mode & 0o777)
    return out


class TempMixin:
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix="burrow-install-01a14dd8-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        if inside_git_worktree(self.tmp):
            self.skipTest(f"the temp dir {self.tmp} is inside a git work tree")

    def out(self, name):
        return os.path.join(self.tmp, name)


class LegacyModuleRenderTest(TempMixin, unittest.TestCase):
    def render_pair(self, manifest):
        # A seed render fixes every generated secret, so the two renders under
        # test can only differ through the entry point.
        seed = run_module("burrow_install", "render", manifest, "--out", self.out("seed"))
        self.assertEqual(seed.returncode, 0, seed.stdout + seed.stderr)
        secrets = os.path.join(self.out("seed"), "secrets.env")
        old = run_module(
            "suite_install", "render", manifest, "--out", self.out("a"), "--reuse-secrets", secrets
        )
        new = run_module(
            "burrow_install", "render", manifest, "--out", self.out("b"), "--reuse-secrets", secrets
        )
        return old, new

    def check_identical(self, manifest):
        old, new = self.render_pair(manifest)
        self.assertEqual(old.returncode, 0, old.stdout + old.stderr)
        self.assertEqual(new.returncode, 0, new.stdout + new.stderr)
        a, b = tree_digest(self.out("a")), tree_digest(self.out("b"))
        # Positive control: the render wrote the files a comparison is about.
        for required in ("compose.yaml", "Caddyfile", "user-data", "secrets.env"):
            self.assertIn(required, a)
        self.assertEqual(a, b)
        # stdout differs only in the --out path it echoes.
        self.assertEqual(
            old.stdout.replace(self.out("a"), "<out>"), new.stdout.replace(self.out("b"), "<out>")
        )
        self.assertEqual(old.stderr, PY_DEPRECATION)
        self.assertEqual(new.stderr, "")

    def test_example_render_is_byte_identical(self):
        self.check_identical(EXAMPLE)

    def test_agents_full_render_is_byte_identical(self):
        self.check_identical(AGENTS_FULL)

    def test_digest_comparison_can_see_a_difference(self):
        # Positive control for check_identical: two renders WITHOUT a shared
        # seed draw different secrets, and tree_digest must tell them apart.
        one = run_module("suite_install", "render", EXAMPLE, "--out", self.out("one"))
        two = run_module("burrow_install", "render", EXAMPLE, "--out", self.out("two"))
        self.assertEqual(one.returncode, 0, one.stdout + one.stderr)
        self.assertEqual(two.returncode, 0, two.stdout + two.stderr)
        a, b = tree_digest(self.out("one")), tree_digest(self.out("two"))
        self.assertEqual(sorted(a), sorted(b))
        self.assertNotEqual(a["secrets.env"], b["secrets.env"])


class LegacyModuleExitCodeTest(unittest.TestCase):
    def test_bad_manifest_same_exit_code_and_output(self):
        old = run_module("suite_install", "validate", BAD_MANIFEST)
        new = run_module("burrow_install", "validate", BAD_MANIFEST)
        self.assertEqual(new.returncode, 2, new.stdout + new.stderr)
        self.assertEqual(old.returncode, new.returncode)
        self.assertEqual(old.stdout, new.stdout)
        self.assertTrue(new.stdout.startswith("error "), new.stdout)

    def test_good_manifest_exits_zero(self):
        old = run_module("suite_install", "validate", GOOD_MANIFEST)
        new = run_module("burrow_install", "validate", GOOD_MANIFEST)
        self.assertEqual((old.returncode, old.stdout), (0, "ok\n"))
        self.assertEqual((new.returncode, new.stdout), (0, "ok\n"))

    def test_usage_error_same_exit_code(self):
        old = run_module("suite_install", "frobnicate")
        new = run_module("burrow_install", "frobnicate")
        self.assertEqual(new.returncode, 2)
        self.assertEqual(old.returncode, new.returncode)

    def test_exactly_one_deprecation_line(self):
        old = run_module("suite_install", "validate", GOOD_MANIFEST)
        self.assertEqual(old.stderr.splitlines(), [PY_DEPRECATION.strip()])
        new = run_module("burrow_install", "validate", GOOD_MANIFEST)
        self.assertNotIn("suite_install", new.stderr)

    def test_setup_and_proof_dispatch_through_the_shim(self):
        for argv in (("setup", "--help"), ("proof", "--help")):
            old = run_module("suite_install", *argv)
            new = run_module("burrow_install", *argv)
            self.assertEqual(new.returncode, 0, new.stdout + new.stderr)
            self.assertEqual((old.returncode, old.stdout), (new.returncode, new.stdout))
            self.assertEqual(old.stderr, PY_DEPRECATION + new.stderr)

    def test_shim_package_holds_only_the_entry_point(self):
        names = sorted(
            n for n in os.listdir(os.path.join(INSTALLER, "suite_install")) if n != "__pycache__"
        )
        self.assertEqual(names, ["__init__.py", "__main__.py"])


@unittest.skipIf(shutil.which("bash") is None, "mac wrappers need bash")
@unittest.skipIf(sys.version_info < (3, 11), "burrow-install needs python >= 3.11")
class LegacyMacWrapperTest(unittest.TestCase):
    def run_wrapper(self, name, *argv):
        env = clean_env()
        # The wrapper picks the first python3 >= 3.11 on PATH; put this one first.
        env["PATH"] = os.path.dirname(sys.executable) + os.pathsep + env.get("PATH", "")
        return subprocess.run(
            [os.path.join(MAC, name), *argv],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )

    def test_old_wrapper_is_three_lines(self):
        with open(os.path.join(MAC, "suite-install"), encoding="utf-8") as handle:
            self.assertEqual(len(handle.read().splitlines()), 3)

    def test_old_wrapper_matches_new(self):
        for manifest, code in ((GOOD_MANIFEST, 0), (BAD_MANIFEST, 2)):
            old = self.run_wrapper("suite-install", "validate", manifest)
            new = self.run_wrapper("burrow-install", "validate", manifest)
            self.assertEqual(new.returncode, code, new.stdout + new.stderr)
            self.assertEqual((old.returncode, old.stdout), (new.returncode, new.stdout))
            self.assertEqual(old.stderr, MAC_DEPRECATION + new.stderr)


if __name__ == "__main__":
    unittest.main()
