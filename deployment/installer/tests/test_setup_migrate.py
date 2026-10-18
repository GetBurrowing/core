"""``setup run migrate``: a pre-rename Mac install moves to ~/burrow (task 01a14dd8 stage 4).

The legacy install is built the way an old installer left it: the install dir
under the legacy root, LaunchAgents under the legacy labels pointing into it,
and backups under the legacy backup root. Docker and launchctl are FakeHost
calls, so the tests assert the argv order (down from the old dir, up from the
new one, never ``-v``) rather than a running stack.

Run: python3 -m unittest discover -s deployment/installer/tests -v
"""

import hashlib
import os
import plistlib
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from setup_fakes import MAC_LITE, FakeHost, FakeKeychain, run_cli

from burrow_install.setup import cli, macos, migrate, state
from burrow_install.setup.host import Result

NAME = "mac-01a14dd8"


class MigrateTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="burrow-migrate-01a14dd8-")
        self.addCleanup(shutil.rmtree, self.home, True)
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        self.addCleanup(self._restore, old_home)
        self.host = FakeHost(self.home)
        self.env = cli.Env(host=self.host, keychain=FakeKeychain(), environ={})
        self.old = os.path.join(self.home, "suite", NAME)
        self.new = os.path.join(self.home, "burrow", NAME)
        self.agents = os.path.join(self.home, "Library", "LaunchAgents")
        self.logs = os.path.join(self.home, "Library", "Logs")
        self.old_backups = os.path.join(self.home, migrate.LEGACY_BACKUP_ROOT, NAME)

    @staticmethod
    def _restore(old):
        if old is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = old

    def make_legacy(self):
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", self.old, "--name", NAME,
            "--domain", f"{NAME}.example.com", "--registry", "ghcr.io/example",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        with open(os.path.join(self.old, "compose.yaml"), "w", encoding="utf-8") as handle:
            handle.write(f'name: "{NAME}"\nservices: {{}}\n')
        os.makedirs(os.path.join(self.old, "bin"))
        os.makedirs(self.old_backups)
        os.makedirs(self.agents, exist_ok=True)
        jobs = {
            "backup": [
                "/bin/bash", os.path.join(self.old, "bin", "backup.sh"), self.old,
                self.old_backups, "14", "core_platform",
            ],
            "ip-watch": [
                "/bin/bash", os.path.join(self.old, "bin", "ip-watch.sh"), self.old, "-", "-", "-",
            ],
        }  # fmt: skip
        for job, args in jobs.items():
            label = macos.legacy_agent_label(NAME, job)
            log = os.path.join(self.logs, f"legacy-{NAME}-{job}.log")
            with open(os.path.join(self.agents, f"{label}.plist"), "wb") as handle:
                handle.write(macos.agent_plist(label, args, log, interval=300))
        self.host.calls.clear()

    def migrate(self, *extra):
        return run_cli(self.env, "run", "migrate", *extra)

    def compose_calls(self):
        return [argv for argv, _ in self.host.calls if argv[:2] == ["docker", "compose"]]

    def tree_digest(self, root):
        """Every file under ``root`` except state.json, whose step timestamp may move."""
        digest = hashlib.sha256()
        for dirpath, dirnames, filenames in sorted(os.walk(root)):
            dirnames.sort()
            for name in sorted(filenames):
                if name == state.STATE_FILE:
                    continue
                path = os.path.join(dirpath, name)
                digest.update(os.path.relpath(path, root).encode())
                with open(path, "rb") as handle:
                    digest.update(handle.read())
        return digest.hexdigest()

    # -- the move ---------------------------------------------------------

    def test_moves_the_dir_and_restarts_compose_from_the_new_one(self):
        self.make_legacy()
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        self.assertTrue(doc["ok"])
        self.assertEqual(doc["contract_version"], cli.CONTRACT_VERSION)
        self.assertEqual(doc["step"], "migrate")
        out = doc["outputs"]
        self.assertTrue(out["moved"])
        self.assertEqual(out["moved_from"], self.old)
        self.assertEqual(out["install_dir"], self.new)
        self.assertFalse(os.path.lexists(self.old))
        self.assertTrue(os.path.exists(os.path.join(self.new, state.MANIFEST_FILE)))
        calls = self.compose_calls()
        self.assertEqual(len(calls), 2, calls)
        down, up = calls
        self.assertEqual(down[2:4], ["--project-directory", self.old])
        self.assertEqual(down[6:], ["down"])
        self.assertEqual(up[2:4], ["--project-directory", self.new])
        self.assertEqual(up[6:], ["up", "-d"])
        for argv in calls:
            self.assertNotIn("-v", argv)
            self.assertNotIn("--volumes", argv)
            self.assertNotIn("-p", argv)  # the project name comes from compose.yaml

    def test_keeps_the_compose_project_name(self):
        self.make_legacy()
        with open(os.path.join(self.old, "compose.yaml"), "rb") as handle:
            before = handle.read()
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        with open(os.path.join(self.new, "compose.yaml"), "rb") as handle:
            after = handle.read()
        self.assertEqual(after, before)
        self.assertIn(f'name: "{NAME}"'.encode(), after)
        self.assertEqual(doc["outputs"]["compose_project"], NAME)

    def test_swaps_the_launch_agent_labels(self):
        self.make_legacy()
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        swapped = doc["outputs"]["launch_agents_swapped"]
        self.assertEqual(
            swapped,
            [
                {"from": macos.legacy_agent_label(NAME, j), "to": macos.agent_label(NAME, j)}
                for j in ("backup", "ip-watch")
            ],
        )
        left = sorted(os.listdir(self.agents))
        self.assertEqual(
            left,
            sorted(f"{macos.agent_label(NAME, j)}.plist" for j in ("backup", "ip-watch")),
        )
        with open(
            os.path.join(self.agents, f"{macos.agent_label(NAME, 'backup')}.plist"), "rb"
        ) as h:
            backup = plistlib.load(h)
        self.assertEqual(backup["Label"], macos.agent_label(NAME, "backup"))
        new_backups = os.path.join(self.home, migrate.BACKUP_ROOT, NAME)
        self.assertEqual(
            backup["ProgramArguments"],
            ["/bin/bash", os.path.join(self.new, "bin", "backup.sh"), self.new, new_backups, "14",
             "core_platform"],
        )  # fmt: skip
        self.assertTrue(os.path.isdir(new_backups))
        self.assertEqual(
            backup["StandardOutPath"], os.path.join(self.logs, f"burrow-install-{NAME}-backup.log")
        )
        self.assertEqual(backup["StartInterval"], 300)
        argvs = [argv for argv, _ in self.host.calls if argv[0] == "launchctl"]
        for job in ("backup", "ip-watch"):
            new_plist = os.path.join(self.agents, f"{macos.agent_label(NAME, job)}.plist")
            self.assertIn(["launchctl", "bootstrap", f"gui/{os.getuid()}", new_plist], argvs)
            self.assertIn(
                [
                    "launchctl",
                    "bootout",
                    f"gui/{os.getuid()}/{macos.legacy_agent_label(NAME, job)}",
                ],
                argvs,
            )
        # The new labels load before the legacy ones are booted out.
        order = [a[1] + a[-1].rsplit("/", 1)[-1] for a in argvs]
        self.assertLess(
            order.index("bootstrap" + f"{macos.agent_label(NAME, 'backup')}.plist"),
            order.index("bootout" + macos.legacy_agent_label(NAME, "backup")),
        )

    def test_leaves_old_backups_and_records_them(self):
        self.make_legacy()
        with open(os.path.join(self.old_backups, "core-20261001.dump"), "w") as handle:
            handle.write("dump")
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        self.assertTrue(os.path.exists(os.path.join(self.old_backups, "core-20261001.dump")))
        self.assertEqual(doc["outputs"]["legacy_backup_dir"], self.old_backups)
        saved = state.Install(self.new).load_state()
        self.assertEqual(saved["ids"]["legacy_backup_dir"], self.old_backups)
        self.assertEqual(saved["ids"]["migrated_from"], self.old)
        self.assertEqual(saved["steps"]["migrate"]["state"], "done")

    def test_status_is_unchanged_by_the_step(self):
        # migrate is not a STEPS entry: status neither lists it nor waits on it.
        self.make_legacy()
        code, before, _ = run_cli(self.env, "status", "--json")
        self.assertEqual(code, 0, before)
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        code, after, _ = run_cli(self.env, "status", "--json")
        self.assertEqual(code, 0, after)
        self.assertNotIn("migrate", [r["name"] for r in after["steps"]])
        self.assertEqual(after["install_dir"], self.new)
        self.assertEqual(after["next_step"], before["next_step"])

    # -- idempotence and refusals -----------------------------------------

    def test_a_second_run_changes_nothing(self):
        self.make_legacy()
        code, first, _ = self.migrate()
        self.assertEqual(code, 0, first)
        tree = self.tree_digest(self.home)
        self.host.calls.clear()
        code, second, _ = self.migrate()
        self.assertEqual(code, 0, second)
        self.assertFalse(second["outputs"]["moved"])
        self.assertEqual(second["outputs"]["launch_agents_swapped"], [])
        self.assertEqual(self.compose_calls(), [])
        self.assertEqual([a for a, _ in self.host.calls if a[0] == "launchctl"], [])
        self.assertEqual(self.tree_digest(self.home), tree)
        saved = state.Install(self.new).load_state()
        self.assertEqual(saved["ids"]["migrated_from"], self.old)
        self.assertFalse(os.path.lexists(self.old))

    def test_a_stopped_run_finishes_its_label_swap(self):
        self.make_legacy()
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        # Re-plant one legacy plist, as if the first run stopped before removing it.
        label = macos.legacy_agent_label(NAME, "backup")
        args = ["/bin/bash", os.path.join(self.old, "bin", "backup.sh"), self.old]
        with open(os.path.join(self.agents, f"{label}.plist"), "wb") as handle:
            handle.write(macos.agent_plist(label, args, os.path.join(self.logs, "x.log")))
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        self.assertEqual(
            doc["outputs"]["launch_agents_swapped"],
            [{"from": label, "to": macos.agent_label(NAME, "backup")}],
        )
        self.assertFalse(os.path.exists(os.path.join(self.agents, f"{label}.plist")))

    def test_refuses_when_both_dirs_exist(self):
        self.make_legacy()
        os.makedirs(self.new)
        with open(os.path.join(self.new, "marker"), "w") as handle:
            handle.write("x")
        code, doc, _ = self.migrate("--dir", self.old)
        self.assertEqual(code, 2, doc)
        self.assertFalse(doc["ok"])
        self.assertEqual(doc["error_code"], "migrate_both_exist")
        self.assertEqual(doc["step"], "migrate")
        self.assertIn(self.old, doc["error"])
        self.assertIn(self.new, doc["error"])
        # Nothing moved, nothing stopped, no label touched.
        self.assertTrue(os.path.exists(os.path.join(self.old, state.MANIFEST_FILE)))
        self.assertEqual(os.listdir(self.new), ["marker"])
        self.assertEqual(self.compose_calls(), [])
        self.assertEqual(len(os.listdir(self.agents)), 2)

    def test_refuses_an_install_outside_the_default_roots(self):
        elsewhere = os.path.join(self.home, "elsewhere", NAME)
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", elsewhere, "--name", NAME,
            "--domain", f"{NAME}.example.com", "--registry", "ghcr.io/example",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        self.host.calls.clear()
        code, doc, _ = self.migrate("--dir", elsewhere)
        self.assertEqual(code, 2, doc)
        self.assertEqual(doc["error_code"], "migrate_not_default_location")
        self.assertTrue(os.path.exists(os.path.join(elsewhere, state.MANIFEST_FILE)))
        self.assertEqual(self.compose_calls(), [])

    def test_a_failed_compose_down_moves_nothing(self):
        self.make_legacy()
        self.host.add(("compose-sub", "down"), Result(1, "", "daemon not running"))
        code, doc, _ = self.migrate()
        self.assertEqual(code, 1, doc)
        self.assertEqual(doc["error_code"], "migrate_compose_down_failed")
        self.assertTrue(os.path.exists(os.path.join(self.old, state.MANIFEST_FILE)))
        self.assertFalse(os.path.lexists(self.new))
        self.assertEqual(len(self.compose_calls()), 1)

    def test_not_macos_moves_but_installs_no_launch_agent(self):
        self.make_legacy()
        self.host.platform = "linux"
        code, doc, _ = self.migrate()
        self.assertEqual(code, 0, doc)
        self.assertTrue(doc["outputs"]["moved"])
        self.assertEqual(doc["outputs"]["launch_agents_swapped"], [])
        self.assertEqual([a for a, _ in self.host.calls if a[0] == "launchctl"], [])


if __name__ == "__main__":
    unittest.main()
