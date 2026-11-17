"""Automatic candidate selection and policy boundaries; no network or registry."""
import datetime as dt
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "release"))
import cut_candidate as cut
import promote_stable as release

SHA = "a" * 40
OTHER = "b" * 40


def boots():
    return [{"name": job, "steps": [{"name": name, "conclusion": "success"}]} for job, name in (
        ("Build and push image (amd64)", "Boot packaged core against a fresh database"),
        ("Build and push image (arm64)", "Boot packaged core against a fresh database"),
        ("Build and push image (play)", "Boot packaged Play against a fresh database"),
    )]


class BatchTest(unittest.TestCase):
    def test_every_flavour_and_architecture_must_have_booted(self):
        self.assertTrue(cut.boot_checked(boots()))
        self.assertFalse(cut.boot_checked(boots()[:2]))
        jobs = boots()
        jobs[2]["steps"][0]["conclusion"] = "failure"
        self.assertFalse(cut.boot_checked(jobs))

    def test_selection_skips_retried_and_failed_candidates(self):
        refs = release.Refs([])
        refs.fail[OTHER] = {"20261108T00Z"}
        runs = [{"id": 1, "head_sha": SHA, "run_attempt": 2},
                {"id": 2, "head_sha": OTHER, "run_attempt": 1},
                {"id": 3, "head_sha": SHA, "run_attempt": 1}]
        with patch.object(cut, "api", side_effect=[{"workflow_runs": runs}, {"jobs": boots()}]) as api, \
             patch.object(release, "known_commit", return_value=True):
            self.assertEqual(cut.latest_verified(refs, None, "owner/repo"), SHA)
            self.assertIn("/runs/3/jobs?", api.call_args.args[0])

    def test_canary_evidence_does_not_reuse_two_install_hours(self):
        lines = [f"{SHA}\trefs/soak/{SHA}/20261108T00Z",
                 f"{SHA}\trefs/soak-canary/{SHA}/20261108T01Z"]
        self.assertEqual(release.Refs(lines).soak[SHA], {"20261108T00Z"})
        self.assertEqual(release.Refs(lines, "canary").soak[SHA], {"20261108T01Z"})

    def test_canary_mode_does_not_claim_production_was_probed(self):
        refs = release.Refs([], "canary")
        with patch.object(release, "probe", return_value=(True, SHA, {})) as probe, \
             patch.object(release, "known_commit", return_value=True):
            specs = release.observe(refs, "prod", "canary", "20261108T00Z")
        probe.assert_called_once_with("canary")
        self.assertIn(f"{SHA}:refs/soak-canary/{SHA}/20261108T00Z", specs)
        self.assertNotIn("prod", refs.seen)

    def run_cut(self, refs, **extra):
        env = {"STABLE_BATCH_ENABLED": "true", "GITHUB_REPOSITORY": "owner/repo"}
        env.update(extra)
        with patch.dict(os.environ, env, clear=True), \
             patch.object(release, "list_refs", return_value=refs), \
             patch.object(release, "now_utc", return_value=dt.datetime(2026, 11, 8, tzinfo=dt.UTC)), \
             patch.object(release, "stable_revision", return_value=OTHER), \
             patch.object(cut, "latest_verified", return_value=SHA) as select, \
             patch.object(release, "imagetools", return_value=(0, "", "")) as images, \
             patch.object(release, "git", return_value=(0, "", "")) as git:
            status = cut.main()
            return status, select, images, git

    def test_disabled_switch_changes_nothing(self):
        status, select, images, git = self.run_cut(release.Refs([]), STABLE_BATCH_ENABLED="")
        self.assertEqual(status, 0)
        select.assert_not_called()
        images.assert_not_called()
        git.assert_not_called()

    def test_active_candidate_is_not_replaced_by_faster_main(self):
        refs = release.Refs([f"{SHA}\trefs/release-candidate/current"])
        _, select, images, git = self.run_cut(refs)
        select.assert_not_called()
        images.assert_not_called()
        git.assert_not_called()

    def test_cannot_cut_a_second_batch_on_the_same_day(self):
        refs = release.Refs([f"{SHA}\trefs/release-candidate/cut/20261108"])
        _, select, _, _ = self.run_cut(refs)
        select.assert_not_called()

    def test_cut_moves_only_candidate_tags_and_records_state(self):
        status, _, images, git = self.run_cut(release.Refs([]))
        self.assertEqual(status, 0)
        creates = [c.args for c in images.call_args_list if c.args[0] == "create"]
        self.assertEqual(creates, [
            ("create", "-t", f"{release.DEFAULT_REPO}:{f}-candidate", f"{release.DEFAULT_REPO}:{f}-{SHA}")
            for f in ("core", "play")])
        self.assertIn(f"+{SHA}:refs/release-candidate/current", git.call_args.args)

    def test_failed_image_lookup_never_updates_candidate_state(self):
        with patch.object(release, "imagetools", return_value=(1, "", "")):
            # Exercise the real main with the failure after selection.
            with patch.dict(os.environ, {"STABLE_BATCH_ENABLED": "true", "GITHUB_REPOSITORY": "owner/repo"}, clear=True), \
                 patch.object(release, "list_refs", return_value=release.Refs([])), \
                 patch.object(release, "stable_revision", return_value=None), \
                 patch.object(cut, "latest_verified", return_value=SHA), \
                 patch.object(release, "git") as git:
                self.assertEqual(cut.main(), 1)
                git.assert_not_called()

    def test_batch_does_not_shorten_the_soak(self):
        with patch.dict(os.environ, {"STABLE_BATCH_ENABLED": "true", "STABLE_SOAK_HOURS": "23",
                                   "STABLE_PROD_HEALTH_URL": "prod", "STABLE_CANARY_HEALTH_URL": "canary"}, clear=True):
            self.assertEqual(release.main(), 1)


if __name__ == "__main__":
    unittest.main()
