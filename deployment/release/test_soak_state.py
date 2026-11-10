"""Clock boundaries, durable entrypoint behavior, and real Git CAS races."""
import concurrent.futures
import datetime as dt
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import promote_stable as release
import soak_state
from test_candidate_bootstrap import IMG, BootstrapTest, S, T

START = dt.datetime(2026, 11, 7, 0, 59, tzinfo=dt.UTC)


class IntervalTest(unittest.TestCase):
    def test_24_buckets_spanning_23h01m_is_not_24_hours(self):
        state = soak_state.initial(S, "canary")
        state = soak_state.observe(state, S, "canary", START, True, "")
        for hour in range(1, 24):
            state = soak_state.observe(state, S, "canary", START.replace(minute=0) + dt.timedelta(hours=hour), True, "")
        self.assertEqual(len(state["hours"]), 24)
        self.assertFalse(soak_state.complete(state))
        state = soak_state.observe(state, S, "canary", START + dt.timedelta(hours=23), True, "")
        state = soak_state.observe(state, S, "canary", START + dt.timedelta(hours=24) - dt.timedelta(microseconds=1), True, "")
        self.assertFalse(soak_state.complete(state))
        state = soak_state.observe(state, S, "canary", START + dt.timedelta(hours=24), True, "")
        self.assertTrue(soak_state.complete(state))

    def test_gap_clock_reversal_and_failure_are_permanent(self):
        for delta in (dt.timedelta(seconds=5401), -dt.timedelta(seconds=1)):
            with self.subTest(delta=delta):
                state = soak_state.observe(soak_state.initial(S, "canary"), S, "canary", START, True, "")
                state = soak_state.observe(state, S, "canary", START + delta, True, "")
                self.assertTrue(state["failures"])
                state = soak_state.observe(state, S, "canary", START + dt.timedelta(hours=24), True, "")
                self.assertFalse(soak_state.complete(state))

    def test_duplicate_observations_cannot_make_independent_hours(self):
        state = soak_state.initial(S, "canary")
        for _ in range(30):
            state = soak_state.observe(state, S, "canary", START, True, "")
        self.assertEqual(len(state["hours"]), 1)
        self.assertFalse(soak_state.complete(state))

    def test_malformed_and_lost_interval_state_is_refused(self):
        for field, value in (("last", "2026-11-07T01:00:00"), ("hours", ["nonsense"]),
                             ("failures", "lost"), ("first", START.isoformat())):
            state = soak_state.initial(S, "canary")
            state[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                soak_state.observe(state, S, "canary", START, True, "")

    def test_generation_and_policy_cannot_reuse_state(self):
        state = soak_state.initial(S, "both")
        for candidate, mode in ((T, "both"), (S, "canary")):
            with self.assertRaises(ValueError):
                soak_state.observe(state, candidate, mode, START, True, "")
        self.assertIsNone(soak_state.initial(T, "canary")["first"])


class DurationMutation(unittest.TestCase):
    def test_hour_count_only_mutant_is_detected(self):
        # Run the actual boundary case with elapsed-time acceptance removed.
        with patch.object(soak_state, "complete", side_effect=lambda state, hours=24: len(state["hours"]) >= hours):
            result = unittest.TestResult()
            IntervalTest("test_24_buckets_spanning_23h01m_is_not_24_hours").run(result)
        self.assertEqual(len(result.failures), 1, "SURVIVING MUTANT: report rather than weakening test")
        self.assertEqual(result.errors, [])
        self.assertIn("True is not false", result.failures[0][1])


class DurableTest(BootstrapTest):
    def ledger(self):
        oid = self.state["remote"][f"refs/soak-state/canary/{S}"]
        return json.loads(self.state["objects"][oid])

    def test_real_entrypoint_restart_elapsed_completion_and_no_stable_writes(self):
        self.candidate()
        for hour in range(25):
            now = START + dt.timedelta(hours=hour)
            self.assertEqual(self.run_script("promote_stable", PROMOTE_NOW=now.isoformat()), 0, self.output)
            self.assertEqual("soak_complete=True" in self.output, hour == 24)
        self.assertEqual(self.ledger()["first"], START.isoformat())
        self.assertEqual(self.creates(), [])
        self.assertEqual(self.state["tags"], {})

    def test_never_answered_unavailable_malformed_wrong_identity_and_rollback_fail_active_candidate(self):
        for response in ({"rc": 7}, {"body": "[1]"}, {"body": {"status": "ok"}},
                         {"body": {"status": "ok", "commit": T}},
                         {"body": {"status": "ok", "commit": S, "update": {"last_rollback": {"from": S}}}}):
            with self.subTest(response=response):
                self.candidate()
                self.state["health"]["https://canary.test/health"] = response
                self.assertEqual(self.run_script("promote_stable"), 0, self.output)
                self.assertTrue(self.ledger()["failures"])
                self.assertIsNone(self.ledger()["first"])
                self.assertIn(f"refs/soak-fail-canary/{S}/20261107T21Z", self.state["remote"])

    def test_missing_state_and_write_fetch_failure_never_report_success(self):
        self.candidate()
        previous = self.state["remote"][f"refs/soak-state/canary/{S}"]
        for flag in ("push_fail", "fetch_fail"):
            self.state[flag] = True
            self.assertEqual(self.run_script("promote_stable"), 1, self.output)
            self.assertNotIn("soak_complete=", self.output)
            self.assertEqual(self.state["remote"][f"refs/soak-state/canary/{S}"], previous)
            del self.state[flag]
        del self.state["remote"][f"refs/soak-state/canary/{S}"]
        self.assertEqual(self.run_script("promote_stable"), 1, self.output)
        self.assertNotIn("soak_complete=", self.output)

    def test_mode_switch_fails_closed_and_failed_candidate_cannot_be_recut(self):
        self.candidate()
        self.assertEqual(self.run_script("promote_stable", bootstrap=False, STABLE_HOLD="false", STABLE_SOAK_MODE="both"), 1)
        self.state["health"]["https://canary.test/health"] = {"rc": 7}
        self.assertEqual(self.run_script("promote_stable"), 0)
        self.assertEqual(self.run_script(PROMOTE_NOW="2026-11-08T21:30:00+00:00"), 0)
        self.assertEqual(self.creates(), [])

    def test_automatic_replacement_starts_a_new_interval(self):
        self.candidate()
        self.assertEqual(self.run_script("promote_stable", PROMOTE_NOW=START.isoformat()), 0)
        self.state["health"]["https://canary.test/health"] = {"rc": 7}
        self.assertEqual(self.run_script("promote_stable", PROMOTE_NOW=(START + dt.timedelta(hours=1)).isoformat()), 0)
        self.state["runs"] = {"workflow_runs": [{"id": 1, "head_sha": T, "run_attempt": 1}]}
        self.state["images"][f"{IMG}:play-{T}"] = T
        next_day = START + dt.timedelta(days=1)
        self.assertEqual(self.run_script(PROMOTE_NOW=next_day.isoformat()), 0, self.output)
        oid = self.state["remote"][f"refs/soak-state/canary/{T}"]
        self.assertIsNone(json.loads(self.state["objects"][oid])["first"])
        self.state["health"]["https://canary.test/health"] = {"body": {"status": "ok", "commit": T}}
        self.assertEqual(self.run_script("promote_stable", PROMOTE_NOW=next_day.isoformat()), 0, self.output)
        oid = self.state["remote"][f"refs/soak-state/canary/{T}"]
        ledger = json.loads(self.state["objects"][oid])
        self.assertEqual(ledger["first"], next_day.isoformat())
        self.assertFalse(soak_state.complete(ledger))
        self.assertTrue(self.ledger()["failures"])

    def test_canary_durable_evidence_promotes_only_when_hold_explicitly_not_set(self):
        self.candidate()
        self.state["health"]["prod-health"]["body"]["commit"] = T
        for hour in range(25):
            self.assertEqual(self.run_script("promote_stable", PROMOTE_NOW=(START + dt.timedelta(hours=hour)).isoformat()), 0)
        self.assertEqual(self.run_script("promote_stable", bootstrap=False, STABLE_HOLD="false",
                                         PROMOTE_NOW=(START + dt.timedelta(hours=24, minutes=1)).isoformat()), 0, self.output)
        self.assertTrue(self.creates())
        self.assertEqual(len([c for c in self.calls("curl") if c[-1] == "prod-health"]), 0)


class GitCAS(unittest.TestCase):
    def test_real_git_objects_restart_and_competing_observers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote.git"
            local = root / "writer"
            def command(*args, cwd=None):
                result = subprocess.run(["git", *args], cwd=cwd or root, capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()
            command("init", "--bare", str(remote))
            command("clone", str(remote), str(local))
            command("-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "--allow-empty", "-m", "candidate", cwd=local)
            candidate = command("rev-parse", "HEAD", cwd=local)
            old_cwd = os.getcwd()
            os.chdir(local)
            self.addCleanup(os.chdir, old_cwd)
            with patch.dict(os.environ, {"PROMOTE_GIT": "git"}), patch.object(release, "HELD_BOOTSTRAP", True):
                state = soak_state.initial(candidate, "canary")
                old = release.state_commit(state)
                ref = release.state_ref(candidate, "canary")
                self.assertEqual(release.git("push", "--atomic", "origin", f"{old}:{ref}")[0], 0)
                state_a = soak_state.observe(state, candidate, "canary", START, True, "")
                state_b = soak_state.observe(state, candidate, "canary", START + dt.timedelta(seconds=1), False, "failure")
                commits = [release.state_commit(s) for s in (state_a, state_b)]
                def compete(oid):
                    return release.git("push", "--atomic", f"--force-with-lease={ref}:{old}", "origin", f"{oid}:{ref}")[0]
                with concurrent.futures.ThreadPoolExecutor(2) as pool:
                    results = list(pool.map(compete, commits))
                self.assertEqual(sum(rc == 0 for rc in results), 1)
                winner = command("ls-remote", "origin", ref, cwd=local).split()[0]
                self.assertIn(json.loads(command("show", "-s", "--format=%B", winner, cwd=local)), (state_a, state_b))
                # Actual observation transaction also guards current/pending refs.
                command("push", "origin", f"{candidate}:refs/release-candidate/current", cwd=local)
                with patch.object(release, "stable_revision", return_value=candidate), patch.object(release, "probe", return_value=(True, candidate, {})):
                    self.assertFalse(release.candidate_observation(release.list_refs("canary"), IMG, "", "health", START + dt.timedelta(seconds=2), 24))
                # A stale observer must not overwrite a concurrent failure or success.
                self.assertNotEqual(compete(commits[1] if winner == commits[0] else commits[0]), 0)

                # Both full observers start from the same snapshot; a failed probe
                # survives either ordering, including a failed CAS followed by retry.
                latest = command("ls-remote", "origin", ref, cwd=local).split()[0]
                self.assertEqual(release.git("push", "--atomic", f"--force-with-lease={ref}:{latest}", "origin", f"{old}:{ref}")[0], 0)
                snapshot = release.list_refs("canary")
                gate = threading.Barrier(2)
                thread_state = threading.local()
                def measured_probe(_url):
                    gate.wait(timeout=10)
                    return thread_state.healthy, candidate, {}
                def observer(healthy):
                    thread_state.healthy = healthy
                    return release.candidate_observation(snapshot, IMG, "", "health", START + dt.timedelta(seconds=3), 24)
                with (patch.object(release, "stable_revision", return_value=candidate),
                      patch.object(release, "probe", side_effect=measured_probe),
                      concurrent.futures.ThreadPoolExecutor(2) as pool):
                    self.assertEqual(list(pool.map(observer, (True, False))), [False, False])
                final = command("ls-remote", "origin", ref, cwd=local).split()[0]
                self.assertTrue(json.loads(command("show", "-s", "--format=%B", final, cwd=local))["failures"])
