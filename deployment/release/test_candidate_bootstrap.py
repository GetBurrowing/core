"""Held bootstrap integration tests: real entrypoints, fake external tools only."""

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

import promote_stable as release
import soak_state

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "promote_harness", ROOT / "deployment/installer/tests/test_promote_stable.py"
)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
S, T, OLD, IMG = fixture.S, fixture.T, fixture.OLD, fixture.IMG


def boots():
    return [{"name": job, "steps": [{"name": step, "conclusion": "success"}]} for job, step in (
        ("Build and push image (amd64)", "Boot packaged core against a fresh database"),
        ("Build and push image (arm64)", "Boot packaged core against a fresh database"),
        ("Build and push image (play)", "Boot packaged Play against a fresh database"),
    )]


class BootstrapTest(fixture.PromoteHarness):
    def setUp(self):
        super().setUp()
        # Exercise gh, partial registry failure and Git CAS through subprocesses.
        fake = fixture.FAKE.replace(
            'a not in ("--atomic", "origin")',
            'a != "origin" and not a.startswith("--")',
        ).replace(
            'if st.get("push_fail"):',
            '''leases = [a.split("=", 1)[1].split(":", 1) for a in args if a.startswith("--force-with-lease=")]
        if st.get("push_fail") or any(st["remote"].get(ref, "") != sha for ref, sha in leases) or (st.get("finish_fail") and ":refs/release-candidate/pending" in args):''',
        ).replace(
            'if src in st["images"]:',
            'if src in st["images"] and dst != st.get("create_fail"):',
        ).replace(
            'elif tool == "curl":',
            '''elif tool == "gh":
    out = json.dumps(st["runs"] if "/workflows/" in args[1] else st["jobs"][args[1].split("/runs/")[1].split("/")[0]])
elif tool == "curl":''',
        )
        Path(self.fake).write_text(fake)
        # cut_candidate invokes gh through PATH, while existing tool fakes use env.
        gh = Path(self.tmp.name) / "gh"
        gh.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{self.fake}" gh "$@"\n')
        gh.chmod(0o755)
        self.env.update({
            "PATH": self.tmp.name + os.pathsep + self.env["PATH"],
            "STABLE_HOLD": "true", "STABLE_BATCH_ENABLED": "true",
            "STABLE_SOAK_MODE": "canary", "GITHUB_REPOSITORY": "owner/repo",
            "STABLE_CANARY_HEALTH_URL": "https://canary.test/health",
        })
        self.state["health"]["https://canary.test/health"] = self.state["health"].pop("canary-health")
        self.state["runs"] = {"workflow_runs": [{"id": 1, "head_sha": S, "run_attempt": 1}]}
        self.state["jobs"] = {"1": {"jobs": boots()}}

    def run_script(self, name="cut_candidate", bootstrap=True, **env):
        Path(self.state_path).write_text(json.dumps(self.state))
        full = dict(self.env, **env)
        args = [sys.executable, str(ROOT / "deployment/release" / f"{name}.py")]
        if bootstrap:
            args.append("--held-bootstrap")
        proc = subprocess.run(args, env=full, capture_output=True, text=True, check=False)
        self.state = json.loads(Path(self.state_path).read_text())
        self.output = proc.stdout + proc.stderr
        return proc.returncode

    def candidate(self):
        ledger = json.dumps(soak_state.initial(S, "canary"), sort_keys=True)
        oid = hashlib.sha1(ledger.encode()).hexdigest()
        self.state.setdefault("objects", {})[oid] = ledger
        self.state["remote"][f"refs/soak-state/canary/{S}"] = oid
        self.state["remote"]["refs/release-candidate/current"] = S
        for flavour in ("core", "play"):
            self.state["images"][f"{IMG}:{flavour}-candidate"] = S

    def assert_candidate_only(self):
        # Literal allowlist, independent of implementation's regular expressions.
        destinations = {
            "refs/release-candidate/pending", "refs/release-candidate/current",
            "refs/release-candidate/cut/20261107", "refs/soak-seen/canary",
            f"refs/soak-state/canary/{S}",
            f"refs/soak-canary/{S}/20261107T21Z",
            f"refs/soak-fail-canary/{S}/20261107T21Z",
        }
        for call in self.calls("git"):
            if call[0] == "push":
                self.assertIn("--atomic", call)
                for value in call[1:]:
                    if value != "origin" and not value.startswith("--"):
                        self.assertIn(value.split(":", 1)[1], destinations)
            else:
                self.assertIn(call[0], ("ls-remote", "cat-file", "fetch", "hash-object", "commit-tree", "show"))
        for call in self.creates():
            self.assertIn(call, [
                ["create", "-t", f"{IMG}:core-candidate", f"{IMG}:core-{S}"],
                ["create", "-t", f"{IMG}:play-candidate", f"{IMG}:play-{S}"],
            ])
        self.assertEqual(self.state["images"][f"{IMG}:core-stable"], OLD)
        self.assertEqual(self.state["tags"], {})

    def test_default_hold_is_full_freeze_even_with_bootstrap_variable(self):
        for name in ("cut_candidate", "promote_stable"):
            self.assertEqual(self.run_script(name, bootstrap=False, STABLE_HELD_BOOTSTRAP="true"), 0)
            self.assertEqual(self.state["log"], [])

    def test_held_bootstrap_cuts_once_automatically_and_only_candidate_writes(self):
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.state["remote"]["refs/release-candidate/current"], S)
        self.assertNotIn("refs/release-candidate/pending", self.state["remote"])
        creates = list(self.creates())
        self.assertEqual(self.run_script(PROMOTE_NOW="2026-11-08T21:30:00+00:00"), 0, self.output)
        self.assertEqual(self.creates(), creates)
        self.assert_candidate_only()

    def test_newest_eligible_excludes_retry_boot_missing_failed_and_current_stable(self):
        bad = "d" * 40
        self.state["commits"].append(bad)
        self.state["remote"][f"refs/soak-fail-canary/{T}/20261107T20Z"] = T
        self.state["runs"]["workflow_runs"] = [
            {"id": 4, "head_sha": S, "run_attempt": 2},
            {"id": 3, "head_sha": bad, "run_attempt": 1},
            {"id": 2, "head_sha": T, "run_attempt": 1},
            {"id": 5, "head_sha": OLD, "run_attempt": 1},
            {"id": 1, "head_sha": S, "run_attempt": 1},
        ]
        self.state["jobs"]["3"] = {"jobs": boots()[:2]}
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.state["remote"]["refs/release-candidate/current"], S)
        self.assert_candidate_only()

    def test_incompatible_activation_and_force_or_sha_refused_before_tools(self):
        for config in ({"STABLE_HOLD": "false"}, {"STABLE_BATCH_ENABLED": "false"},
                       {"STABLE_SOAK_MODE": "both"}, {"STABLE_CANARY_HEALTH_URL": ""},
                       {"PROMOTE_FORCE": "true"}, {"PROMOTE_SHA": S},
                       {"STABLE_SOAK_HOURS": "23"}, {"STABLE_CANARY_HEALTH_URL": "http://canary.test/health"}):
            for name in ("cut_candidate", "promote_stable"):
                with self.subTest(config=config, name=name):
                    self.assertEqual(self.run_script(name, **config), 1, self.output)
                    self.assertEqual(self.state["log"], [])

    def test_observation_while_held_never_promotes_even_with_forceable_history(self):
        self.candidate()
        self.state["remote"].update({key.replace("refs/soak/", "refs/soak-canary/"): value
                                     for key, value in fixture.soak_refs(S, range(1, 30)).items()})
        self.assertEqual(self.run_script("promote_stable"), 0, self.output)
        self.assertEqual(len(self.calls("curl")), 1)
        self.assertIn(f"refs/soak-canary/{S}/20261107T21Z", self.state["remote"])
        self.assertEqual(self.creates(), [])
        self.assert_candidate_only()

    def test_failed_probe_and_rollback_evidence_preserved_under_hold(self):
        self.candidate()
        self.state["remote"]["refs/soak-seen/canary"] = S
        self.state["health"]["https://canary.test/health"] = {"rc": 7}
        self.assertEqual(self.run_script("promote_stable"), 0, self.output)
        self.assertIn(f"refs/soak-fail-canary/{S}/20261107T21Z", self.state["remote"])
        self.state["health"]["https://canary.test/health"] = {"body": {
            "status": "ok", "commit": S, "update": {"last_rollback": {"from": S}}
        }}
        self.assertEqual(self.run_script("promote_stable"), 0, self.output)
        self.assertIn(f"refs/soak-fail-canary/{S}/20261107T21Z", self.state["remote"])
        self.assert_candidate_only()

    def test_partial_registry_publication_is_durably_pending_and_blocks_observation(self):
        self.state["create_fail"] = f"{IMG}:play-candidate"
        self.assertEqual(self.run_script(), 1, self.output)
        self.assertEqual(self.state["remote"]["refs/release-candidate/pending"], S)
        self.assertNotIn("refs/release-candidate/current", self.state["remote"])
        count = len(self.creates())
        self.assertEqual(self.run_script(), 1, self.output)
        self.assertEqual(len(self.creates()), count)
        self.assertEqual(self.run_script("promote_stable"), 1, self.output)
        self.assertEqual(self.calls("curl"), [])
        self.assert_candidate_only()

    def test_git_finish_failure_keeps_pending_marker(self):
        self.state["finish_fail"] = True
        self.assertEqual(self.run_script(), 1, self.output)
        self.assertEqual(self.state["remote"]["refs/release-candidate/pending"], S)
        self.assertEqual(self.run_script("promote_stable"), 1, self.output)
        self.assertEqual(self.calls("curl"), [])
        self.assert_candidate_only()

    def test_intent_failure_writes_no_registry_tags(self):
        self.state["push_fail"] = True
        self.assertEqual(self.run_script(), 1, self.output)
        self.assertEqual(self.creates(), [])

    def test_registry_git_mismatch_cannot_be_observed(self):
        self.candidate()
        self.state["images"][f"{IMG}:play-candidate"] = T
        self.assertEqual(self.run_script("promote_stable"), 0, self.output)
        self.assertEqual(len(self.calls("curl")), 1)
        self.assertEqual(self.run_script(PROMOTE_NOW="2026-11-08T21:30:00+00:00"), 1, self.output)
        self.assertEqual(self.creates(), [])

    def test_observation_write_failure_is_red(self):
        self.candidate()
        self.state["push_fail"] = True
        self.assertEqual(self.run_script("promote_stable"), 1, self.output)
        self.assert_candidate_only()

    def test_pending_publication_also_blocks_ordinary_promotion(self):
        self.candidate()
        self.state["remote"]["refs/release-candidate/pending"] = T
        self.assertEqual(self.run_script("promote_stable", bootstrap=False, STABLE_HOLD="false"), 1)
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.creates(), [])


class AuthorityTest(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "STABLE_HOLD": "true", "STABLE_BATCH_ENABLED": "true",
            "STABLE_SOAK_MODE": "canary", "STABLE_CANARY_HEALTH_URL": "https://canary.test/health",
        }, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(setattr, release, "HELD_BOOTSTRAP", False)
        release.held_bootstrap_config()

    def test_stable_writes_are_denied_at_command_boundary(self):
        with patch.object(release, "run") as run:
            for args in (("create", "-t", f"{IMG}:core-stable", f"{IMG}:core-{S}"),
                         ("create", "-t", f"{IMG}:play-stable", f"{IMG}:play-{S}"),
                         ("create", "-t", f"{IMG}:core-candidate", f"{IMG}:play-{S}")):
                with self.assertRaisesRegex(RuntimeError, "refused registry"):
                    release.imagetools(*args)
            for args in (("tag", "-a", "stable/x", "-m", "x", S),
                         ("push", "--atomic", "origin", f"{S}:refs/tags/stable/x"),
                         ("push", "--atomic", "origin", f"{S}:refs/heads/main"),
                         ("push", "--atomic", "origin", f":refs/soak-fail-canary/{S}/20261107T21Z"),
                         ("push", "--atomic", "origin", f":refs/soak-state/canary/{S}")):
                with self.assertRaises(RuntimeError):
                    release.git(*args)
            with self.assertRaisesRegex(RuntimeError, "no stable promotion authority"):
                release.promote(IMG, S, OLD, fixture.NOW)
            run.assert_not_called()

    def test_mixed_architecture_candidate_revision_is_unverified(self):
        body = {"linux/amd64": {"config": {"Labels": {release.REVISION_LABEL: S}}},
                "linux/arm64": {"config": {"Labels": {release.REVISION_LABEL: T}}}}
        with patch.object(release, "imagetools", return_value=(0, json.dumps(body), "")):
            self.assertIsNone(release.stable_revision(IMG, "core-candidate"))

    def test_cas_intent_cannot_be_overwritten_by_competing_candidate(self):
        # The real Git CAS primitive, not just the registry fake's model.
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory) / "remote.git"
            local = Path(directory) / "local"
            def git(*args):
                return subprocess.run(["git", *args], cwd=local if local.exists() else directory,
                                      capture_output=True, text=True, check=False)
            self.assertEqual(git("init", "--bare", str(remote)).returncode, 0)
            self.assertEqual(git("clone", str(remote), str(local)).returncode, 0)
            self.assertEqual(git("-c", "user.name=fixture", "-c", "user.email=fixture@localhost",
                                 "commit", "--allow-empty", "-m", "fixture").returncode, 0)
            command = ("push", "--atomic", "--force-with-lease=refs/release-candidate/pending:",
                       "origin", "HEAD:refs/release-candidate/pending")
            self.assertEqual(git(*command).returncode, 0)
            self.assertEqual(git("-c", "user.name=fixture", "-c", "user.email=fixture@localhost",
                                 "commit", "--allow-empty", "-m", "competing candidate").returncode, 0)
            self.assertNotEqual(git(*command).returncode, 0)


class MutationControls(unittest.TestCase):
    def test_scheduled_workflows_require_separate_explicit_bootstrap_activation(self):
        for workflow, script in (("cut-candidate", "cut_candidate"), ("promote-stable", "promote_stable")):
            source = (ROOT / ".github/workflows" / f"{workflow}.yml").read_text()
            self.assertIn("STABLE_HELD_BOOTSTRAP: ${{ vars.STABLE_HELD_BOOTSTRAP }}", source)
            self.assertIn("STABLE_SOAK_HOURS: ${{ vars.STABLE_SOAK_HOURS }}", source)
            self.assertIn("group: promote-stable", source)
            shell = textwrap.dedent(source.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
            for activation, expected in (("true", ["--held-bootstrap"]), ("", []), ("false", [])):
                with self.subTest(workflow=workflow, activation=activation), tempfile.TemporaryDirectory() as directory:
                    python = Path(directory) / "python3"
                    python.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGV_FILE"\n')
                    python.chmod(0o755)
                    output = Path(directory) / "argv"
                    proc = subprocess.run(["bash", "-e", "-c", shell], capture_output=True, text=True,
                                          env={"PATH": directory + os.pathsep + os.environ["PATH"],
                                               "STABLE_HELD_BOOTSTRAP": activation, "ARGV_FILE": str(output)},
                                          check=False)
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    self.assertEqual(output.read_text().splitlines(),
                                     [f"deployment/release/{script}.py", *expected])

    def test_literal_assertions_detect_stable_write_and_hold_bypass(self):
        mutations = (
            ("cut_candidate.py", '    release.log(f"cut automatic candidate',
             ('    release.run([*release.cmd("PROMOTE_IMAGETOOLS", "docker buildx imagetools"), '
             '"create", "-t", f"{repo}:core-stable", f"{repo}:core-{sha}"])\n'
             '    release.log(f"cut automatic candidate'),
             "test_held_bootstrap_cuts_once_automatically_and_only_candidate_writes", "core-stable"),
            ("promote_stable.py", 'if truthy(os.environ.get("STABLE_HOLD")) and not held_bootstrap:',
             'if False:  # mutation: bypass default HOLD',
             "test_default_hold_is_full_freeze_even_with_bootstrap_variable", "1 != 0"),
        )
        for filename, old, new, test, diagnostic in mutations:
            with self.subTest(mutation=filename), tempfile.TemporaryDirectory() as directory:
                target = Path(directory)
                release_dir = target / "deployment/release"
                release_dir.mkdir(parents=True)
                for name in ("cut_candidate.py", "promote_stable.py", "soak_state.py", "test_candidate_bootstrap.py"):
                    shutil.copyfile(ROOT / "deployment/release" / name, release_dir / name)
                harness = target / "deployment/installer/tests/test_promote_stable.py"
                harness.parent.mkdir(parents=True)
                shutil.copyfile(ROOT / "deployment/installer/tests/test_promote_stable.py", harness)
                path = release_dir / filename
                source = path.read_text()
                self.assertEqual(source.count(old), 1)
                path.write_text(source.replace(old, new))
                proc = subprocess.run(
                    [sys.executable, "-m", "unittest", f"test_candidate_bootstrap.BootstrapTest.{test}"],
                    cwd=release_dir, capture_output=True, text=True, check=False,
                )
                self.assertNotEqual(proc.returncode, 0, "SURVIVING MUTANT: report this finding")
                self.assertIn("FAIL:", proc.stderr)
                self.assertIn(diagnostic, proc.stderr)


if __name__ == "__main__":
    unittest.main()
