"""No legacy SUITE_ environment name anywhere in deployment/installer (task 01a18dab).

The Burrow rename finished here: envcompat.py is gone, the renderer writes
BURROW_ names only (agent-host env, units, versions.env, compose), and the
test knobs are BURROW_INSTALL_UPDATE_GOLDEN / BURROW_INSTALL_TEST_POCKETID_*.
This guard fails on any token matching (?<![A-Z0-9_])SUITE_[A-Z0-9_]+ in a
file under deployment/installer (goldens included) unless the name is on KEEP
below, with its reason.

The lookbehind (not \\b) is deliberate: in an escaped string such as a
newline escape followed by the name, the ``n`` is a word character, so \\b
finds no boundary (the positive control below checks exactly that case).

This file builds the prefix at runtime so it cannot trip itself.

Run: python3 -m unittest discover -s deployment/installer/tests -v
"""

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = "SUITE" + "_"
TOKEN = re.compile(r"(?<![A-Z0-9_])" + PREFIX + r"[A-Z0-9_]+")

# Name -> reason. Empty: inventory on 2026-10-30 found no box that sets only a SUITE_ name.
KEEP = {}

SKIP_DIRS = {"__pycache__", ".git", ".ruff_cache"}


def walk(root=ROOT):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        out.extend(os.path.join(dirpath, f) for f in filenames)
    return out


def offenders(files, keep=None):
    keep = KEEP if keep is None else keep
    hits = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
        except UnicodeDecodeError:
            continue
        for n, line in enumerate(lines, 1):
            for token in TOKEN.findall(line):
                if token not in keep:
                    hits.append(f"{os.path.relpath(path, ROOT)}:{n}:{token}")
    return hits


class NoSuiteEnvNamesTest(unittest.TestCase):
    def setUp(self):
        self.files = walk()

    def test_positive_control(self):
        # The scan sees the tree, and the token regex fires.
        self.assertGreater(len(self.files), 20)
        self.assertIn(os.path.join(ROOT, "burrow_install", "setup", "state.py"), self.files)
        probe = PREFIX + "PROBE_X"
        self.assertEqual(TOKEN.findall('x = "\\n' + probe + '"'), [probe])
        self.assertEqual(TOKEN.findall("BURROW_" + probe), [])

    def test_every_suite_token_is_on_the_keep_list(self):
        hits = offenders(self.files)
        self.assertEqual(hits, [], "legacy SUITE_ env names found:\n" + "\n".join(hits))

    def test_every_keep_entry_still_occurs(self):
        seen = {h.rsplit(":", 1)[1] for h in offenders(self.files, keep={})}
        for name in KEEP:
            self.assertIn(name, seen)


if __name__ == "__main__":
    unittest.main()
