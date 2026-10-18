"""The mac setup CLI under Burrow names, with the legacy layout still found (task 01a14dd8).

- New installs go to ``~/burrow/<name>``. Discovery is ``--dir``, then
  ``$BURROW_INSTALL_DIR`` (legacy ``$SUITE_INSTALL_DIR``), then the single
  install under ``~/burrow``, then the single install under the legacy
  ``~/suite`` (read-only discovery, so a Mac that has not migrated keeps working).
- LaunchAgent labels are ``io.github.getburrowing.install.<name>.<job>``;
  teardown and the step that installs a job also boot out the legacy label.
- The registry credential check reads ``auths["ghcr.io"]`` for a ghcr.io image
  and Docker Hub's keys for a docker.io one.

Run: python3 -m unittest discover -s deployment/installer/tests -v
"""

import base64
import json
import os
import shutil
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from setup_fakes import MAC_LITE, FakeDockerHub, FakeHost, FakeKeychain, run_cli

from burrow_install.setup import cli, macos, state, steps
from burrow_install.setup.state import SetupError


class HomeMixin:
    """A scratch HOME, so ~/burrow and ~/suite resolve inside it."""

    def setUp(self):
        super().setUp()
        self.home = tempfile.mkdtemp(prefix="burrow-names-01a14dd8-")
        self.addCleanup(shutil.rmtree, self.home, True)
        old = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        self.addCleanup(self._restore_home, old)

    @staticmethod
    def _restore_home(old):
        if old is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = old

    def make_install(self, root, name):
        path = os.path.join(self.home, root, name)
        os.makedirs(path)
        with open(os.path.join(path, state.MANIFEST_FILE), "w", encoding="utf-8") as handle:
            handle.write("")
        return path


class DiscoveryTest(HomeMixin, unittest.TestCase):
    def test_roots_are_burrow_then_legacy_suite(self):
        self.assertEqual(state.default_root(), os.path.join(self.home, "burrow"))
        self.assertEqual(state.legacy_root(), os.path.join(self.home, "suite"))

    def test_a_legacy_install_is_found_when_burrow_has_none(self):
        legacy = self.make_install("suite", "old-mac")
        self.assertEqual(state.resolve_dir(environ={}), legacy)

    def test_burrow_wins_over_legacy(self):
        fresh = self.make_install("burrow", "new-mac")
        self.make_install("suite", "old-mac")
        self.assertEqual(state.resolve_dir(environ={}), fresh)

    def test_two_legacy_installs_are_ambiguous_and_named(self):
        self.make_install("suite", "a")
        self.make_install("suite", "b")
        with self.assertRaises(SetupError) as caught:
            state.resolve_dir(environ={})
        self.assertEqual(caught.exception.code, "install_dir_ambiguous")
        self.assertIn(os.path.join(self.home, "suite"), caught.exception.message)

    def test_none_anywhere_names_the_burrow_root(self):
        # Positive control for the two above: an empty HOME finds nothing.
        with self.assertRaises(SetupError) as caught:
            state.resolve_dir(environ={})
        self.assertEqual(caught.exception.code, "install_dir_missing")
        self.assertEqual(caught.exception.message, f"no install under {self.home}/burrow")

    def test_a_dir_without_a_manifest_is_not_an_install(self):
        os.makedirs(os.path.join(self.home, "suite", "empty"))
        with self.assertRaises(SetupError) as caught:
            state.resolve_dir(environ={})
        self.assertEqual(caught.exception.code, "install_dir_missing")


class InitPathTest(HomeMixin, unittest.TestCase):
    def init(self, *flags):
        env = cli.Env(host=FakeHost(self.home), keychain=FakeKeychain(), environ={})
        code, doc, _ = run_cli(
            env, "init", "--from", MAC_LITE, "--name", "mac-01a14dd8",
            "--domain", "mac-01a14dd8.example.com", *flags,
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        return doc

    def test_a_new_install_goes_under_burrow(self):
        doc = self.init()
        self.assertEqual(doc["install_dir"], os.path.join(self.home, "burrow", "mac-01a14dd8"))
        self.assertFalse(os.path.exists(os.path.join(self.home, "suite")))

    def test_a_legacy_install_of_that_name_is_kept_where_it_is(self):
        legacy = os.path.join(self.home, "suite", "mac-01a14dd8")
        os.makedirs(legacy)
        shutil.copyfile(MAC_LITE, os.path.join(legacy, state.MANIFEST_FILE))
        doc = self.init()
        self.assertEqual(doc["install_dir"], legacy)
        self.assertFalse(os.path.exists(os.path.join(self.home, "burrow", "mac-01a14dd8")))


class LaunchAgentLabelTest(HomeMixin, unittest.TestCase):
    def plist(self, label):
        directory = os.path.join(self.home, "Library", "LaunchAgents")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, f"{label}.plist")
        with open(path, "wb") as handle:
            handle.write(b"<plist/>")
        return path

    def test_labels(self):
        self.assertEqual(
            macos.agent_label("m", "backup"), "io.github.getburrowing.install.m.backup"
        )
        self.assertEqual(
            macos.legacy_agent_label("m", "backup"), "org.startupsuite.install.m.backup"
        )

    def test_remove_agent_boots_out_and_deletes_only_an_existing_plist(self):
        host = FakeHost(self.home)
        label = macos.legacy_agent_label("m", "backup")
        self.assertFalse(macos.remove_agent(host, label))
        self.assertEqual(host.calls, [])
        path = self.plist(label)
        self.assertTrue(macos.remove_agent(host, label))
        self.assertFalse(os.path.exists(path))
        self.assertEqual(host.calls[0][0][:2], ["launchctl", "bootout"])
        self.assertTrue(host.calls[0][0][2].endswith(f"/{label}"))

    def test_a_job_step_drops_its_legacy_label(self):
        host = FakeHost(self.home)
        ctx = types.SimpleNamespace(host=host)
        outputs = {}
        steps._drop_legacy_agent(ctx, "m", "ip-watch", outputs)
        self.assertEqual(outputs, {})  # positive control: nothing to drop
        legacy = self.plist(macos.legacy_agent_label("m", "ip-watch"))
        kept = self.plist(macos.agent_label("m", "ip-watch"))
        steps._drop_legacy_agent(ctx, "m", "ip-watch", outputs)
        self.assertEqual(
            outputs, {"legacy_launch_agent_removed": "org.startupsuite.install.m.ip-watch"}
        )
        self.assertFalse(os.path.exists(legacy))
        self.assertTrue(os.path.exists(kept))

    def test_teardown_removes_new_and_legacy_labels(self):
        host = FakeHost(self.home)
        env = cli.Env(host=host, keychain=FakeKeychain(), environ={})
        code, doc, _ = run_cli(
            env, "init", "--from", MAC_LITE, "--name", "mac-01a14dd8",
            "--domain", "mac-01a14dd8.example.com",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        planted = [
            macos.agent_label("mac-01a14dd8", "backup"),
            macos.legacy_agent_label("mac-01a14dd8", "backup"),
            macos.legacy_agent_label("mac-01a14dd8", "ip-watch"),
        ]
        paths = [self.plist(label) for label in planted]
        code, doc, _ = run_cli(env, "teardown", "--confirm", "mac-01a14dd8")
        self.assertEqual(code, 0, doc)
        self.assertEqual(sorted(doc["outputs"]["launch_agents_removed"]), sorted(planted))
        self.assertEqual([p for p in paths if os.path.exists(p)], [])
        self.assertIn("backups under ~/BurrowBackups", doc["outputs"]["left_in_place"])


class RegistryAuthTest(unittest.TestCase):
    BASIC = base64.b64encode(b"u:read-token-01a14dd8").decode()

    def setUp(self):
        self.fake = FakeDockerHub(self.BASIC)  # the token + v2 protocol GHCR also speaks
        self.addCleanup(self.fake.close)
        self.ctx = types.SimpleNamespace(
            seen_secrets={},
            docker_auth_url=self.fake.url + "/token",
            docker_registry_url=self.fake.url,
            ghcr_auth_url=self.fake.url + "/token",
            ghcr_registry_url=self.fake.url,
        )

    def auth(self, key):
        return json.dumps({"auths": {key: {"auth": self.BASIC}}})

    def test_image_parts(self):
        self.assertEqual(
            steps._image_parts("ghcr.io/example/core:core"), ("ghcr.io", "example/core", "core")
        )
        self.assertEqual(
            steps._image_parts("docker.io/example/suite-core:core"),
            ("docker.io", "example/suite-core", "core"),
        )
        self.assertEqual(steps._image_parts("example/x"), ("docker.io", "example/x", "latest"))

    def test_a_ghcr_image_uses_the_ghcr_key_and_endpoint(self):
        got = steps.check_registry_auth(
            self.ctx, self.auth("ghcr.io"), "ghcr.io/example/files-service:latest"
        )
        self.assertEqual(got, "example/files-service:latest pullable")
        tokens = [p for m, p in self.fake.requests if m == "GET"]
        self.assertEqual(
            tokens, ["/token?service=ghcr.io&scope=repository:example/files-service:pull"]
        )
        self.assertIn(("HEAD", "/v2/example/files-service/manifests/latest"), self.fake.requests)

    def test_a_ghcr_image_refuses_a_docker_hub_only_credential(self):
        with self.assertRaises(SetupError) as caught:
            steps.check_registry_auth(
                self.ctx, self.auth("https://index.docker.io/v1/"), "ghcr.io/example/core:core"
            )
        self.assertEqual(caught.exception.code, "registry_auth_unusable")
        self.assertIn("GHCR", caught.exception.message)
        self.assertIn('"ghcr.io"', caught.exception.remediation)

    def test_a_legacy_docker_hub_image_still_uses_docker_hub(self):
        got = steps.check_registry_auth(
            self.ctx,
            self.auth("https://index.docker.io/v1/"),
            "docker.io/example/suite-files-service:latest",
        )
        self.assertEqual(got, "example/suite-files-service:latest pullable")
        self.assertTrue(any("service=registry.docker.io" in p for _m, p in self.fake.requests))


if __name__ == "__main__":
    unittest.main()
