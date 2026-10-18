"""BURROW_* names with a SUITE_* fallback (task 01a14b9e stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Every case injects its own ``environ`` dict and its own ``warn`` collector, and
clears the module's warn-once set first, so no case depends on the process
environment or on test order.
"""

import contextlib
import io
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from suite_install import envcompat
from suite_install.setup import state
from suite_install.setup.state import SetupError

LINE = "deprecated: SUITE_INSTALL_DIR is set; rename it to BURROW_INSTALL_DIR"


class EnvcompatGetTest(unittest.TestCase):
    def setUp(self):
        envcompat._warned.clear()
        self.lines = []

    def tearDown(self):
        envcompat._warned.clear()

    def get(self, environ, default=None):
        return envcompat.get(
            "BURROW_INSTALL_DIR",
            "SUITE_INSTALL_DIR",
            environ=environ,
            default=default,
            warn=self.lines.append,
        )

    def test_burrow_only_is_used_without_a_line(self):
        self.assertEqual(self.get({"BURROW_INSTALL_DIR": "/new"}), "/new")
        self.assertEqual(self.lines, [])

    def test_suite_only_is_used_with_exactly_one_line(self):
        self.assertEqual(self.get({"SUITE_INSTALL_DIR": "/old"}), "/old")
        self.assertEqual(self.lines, [LINE])

    def test_both_set_burrow_wins_without_a_line(self):
        environ = {"BURROW_INSTALL_DIR": "/new", "SUITE_INSTALL_DIR": "/old"}
        self.assertEqual(self.get(environ), "/new")
        self.assertEqual(self.lines, [])

    def test_empty_burrow_counts_as_unset(self):
        environ = {"BURROW_INSTALL_DIR": "", "SUITE_INSTALL_DIR": "/old"}
        self.assertEqual(self.get(environ), "/old")
        self.assertEqual(self.lines, [LINE])

    def test_empty_suite_counts_as_unset(self):
        self.assertEqual(self.get({"SUITE_INSTALL_DIR": ""}, default="d"), "d")
        self.assertEqual(self.lines, [])

    def test_neither_set_returns_the_default(self):
        self.assertIsNone(self.get({}))
        self.assertEqual(self.get({}, default="d"), "d")
        self.assertEqual(self.lines, [])

    def test_warns_once_per_name_per_process(self):
        for _ in range(3):
            self.assertEqual(self.get({"SUITE_INSTALL_DIR": "/old"}), "/old")
        self.assertEqual(self.lines, [LINE])
        # A different name still gets its own line.
        envcompat.get(
            "BURROW_INSTALL_UPDATE_GOLDEN",
            "SUITE_INSTALL_UPDATE_GOLDEN",
            environ={"SUITE_INSTALL_UPDATE_GOLDEN": "1"},
            warn=self.lines.append,
        )
        self.assertEqual(
            self.lines,
            [LINE, "deprecated: SUITE_INSTALL_UPDATE_GOLDEN is set; rename it to BURROW_INSTALL_UPDATE_GOLDEN"],
        )

    def test_default_warn_writes_to_stderr(self):
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            value = envcompat.get("BURROW_INSTALL_DIR", "SUITE_INSTALL_DIR", environ={"SUITE_INSTALL_DIR": "/old"})
        self.assertEqual(value, "/old")
        self.assertEqual(buffer.getvalue(), LINE + "\n")


class ResolveDirTest(unittest.TestCase):
    """setup/state.py resolve_dir: BURROW_INSTALL_DIR first, SUITE_ fallback."""

    def setUp(self):
        envcompat._warned.clear()
        self.tmp = tempfile.mkdtemp(prefix="envcompat-01a14b9e-")

    def tearDown(self):
        envcompat._warned.clear()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def resolve(self, environ):
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            return state.resolve_dir(environ=environ), buffer.getvalue()

    def test_burrow_install_dir(self):
        path, err = self.resolve({"BURROW_INSTALL_DIR": os.path.join(self.tmp, "new")})
        self.assertEqual(path, os.path.join(self.tmp, "new"))
        self.assertEqual(err, "")

    def test_suite_install_dir(self):
        path, err = self.resolve({"SUITE_INSTALL_DIR": os.path.join(self.tmp, "old")})
        self.assertEqual(path, os.path.join(self.tmp, "old"))
        self.assertEqual(err, LINE + "\n")

    def test_both_set_burrow_wins(self):
        environ = {
            "BURROW_INSTALL_DIR": os.path.join(self.tmp, "new"),
            "SUITE_INSTALL_DIR": os.path.join(self.tmp, "old"),
        }
        path, err = self.resolve(environ)
        self.assertEqual(path, os.path.join(self.tmp, "new"))
        self.assertEqual(err, "")

    def test_empty_burrow_falls_back(self):
        environ = {"BURROW_INSTALL_DIR": "", "SUITE_INSTALL_DIR": os.path.join(self.tmp, "old")}
        path, err = self.resolve(environ)
        self.assertEqual(path, os.path.join(self.tmp, "old"))
        self.assertEqual(err, LINE + "\n")

    def test_ambiguous_remediation_names_burrow(self):
        root = os.path.join(self.tmp, "suite")
        for name in ("a", "b"):
            os.makedirs(os.path.join(root, name))
            with open(os.path.join(root, name, state.MANIFEST_FILE), "w") as handle:
                handle.write("")
        original = state.default_root
        state.default_root = lambda: root
        try:
            with self.assertRaises(SetupError) as caught:
                state.resolve_dir(environ={})
        finally:
            state.default_root = original
        self.assertEqual(caught.exception.code, "install_dir_ambiguous")
        self.assertIn("BURROW_INSTALL_DIR", caught.exception.remediation)
        self.assertNotIn("SUITE_INSTALL_DIR", caught.exception.remediation)


if __name__ == "__main__":
    unittest.main()
