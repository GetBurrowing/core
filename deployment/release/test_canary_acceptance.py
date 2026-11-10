"""Acceptance uses isolated clocks/stores; none of these fixtures is live soak proof."""
import copy
import datetime as dt
import json
import os
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import canary_acceptance as accept
import soak_state

S = "a" * 40
START = dt.datetime(2026, 11, 1, tzinfo=dt.UTC)
CONFIG = {"install_id": "11111111-1111-1111-1111-111111111111", "health_url": "https://canary.test/health",
          "config": {"purpose": "vendor_canary", "channel": "candidate", "feedback": True,
                     "modules": "play", "extensions": ["feedback"], "kobo_parity_verified": True},
          "stable_before": {"core-stable": "b" * 40, "play-stable": "c" * 40},
          "workflow_run": "https://github.com/GetBurrowing/core/actions/runs/1"}


def ledger(hours=24):
    result = soak_state.initial(S, "canary")
    for hour in range(hours + 1):
        result = soak_state.observe(result, S, "canary", START + dt.timedelta(hours=hour), True, "")
    return result


class Store:
    def __init__(self):
        self.data = {}
        self.fail = False

    def read(self, ref):
        return copy.deepcopy(self.data.get(ref, (None, None)))

    def write(self, ref, previous, data):
        if self.fail or self.data.get(ref, (None,))[0] != previous:
            raise RuntimeError("storage failed/CAS conflict")
        oid = str(int(previous or "0") + 1)
        self.data[ref] = oid, copy.deepcopy(data)
        return oid


class AcceptanceTest(unittest.TestCase):
    def run_continuation(self, store, state, sender=lambda _: False, now=None):
        return accept.continue_task(store, copy.deepcopy(CONFIG), S, state,
                                    CONFIG["stable_before"], now or START + dt.timedelta(hours=24), 24, sender)

    def test_accepted_only_after_full_duration_and_stable_unchanged(self):
        self.assertEqual(accept.decide(CONFIG, S, ledger(23), CONFIG["stable_before"], START + dt.timedelta(hours=23), 24)["status"], "pending")
        result = self.run_continuation(Store(), ledger())
        self.assertEqual(result["evidence"]["status"], "accepted")
        self.assertEqual(result["evidence"]["elapsed_seconds"], 86400)
        self.assertTrue(result["evidence"]["hold_after"])
        changed = dict(CONFIG["stable_before"], **{"core-stable": S})
        self.assertEqual(accept.decide(CONFIG, S, ledger(), changed, START + dt.timedelta(hours=24), 24)["status"], "rejected")

    def test_restart_duplicate_outbox_and_no_bridge_remain_pending(self):
        store = Store()
        first = self.run_continuation(store, ledger())
        second = self.run_continuation(store, ledger())
        self.assertEqual([x["id"] for x in first["events"]], [x["id"] for x in second["events"]])
        self.assertEqual(len(second["events"]), 2)
        self.assertFalse(any(x["delivered"] for x in second["events"]))
        self.assertEqual(len(self.run_continuation(store, ledger(), lambda _: True)["events"]), 2)
        sent = []
        self.run_continuation(store, ledger(), lambda item: sent.append(item))
        self.assertEqual(sent, [])

    def test_commit_failure_prevents_delivery_and_crash_retries_same_key(self):
        store = Store()
        store.fail = True
        sent = []
        with self.assertRaises(RuntimeError):
            self.run_continuation(store, ledger(), lambda item: sent.append(item))
        self.assertEqual(sent, [])
        store.fail = False
        def crash(item):
            sent.append(item["id"])
            raise RuntimeError("process exit")
        with self.assertRaises(RuntimeError):
            self.run_continuation(store, ledger(), crash)
        self.run_continuation(store, ledger(), lambda item: sent.append(item["id"]) or True)
        self.assertEqual(sent[0], sent[1])

    def test_failure_stale_and_policy_identity_fail_closed(self):
        state = ledger()
        state["failures"] = [{"at": START.isoformat(), "reason": "rollback"}]
        store = Store()
        result = self.run_continuation(store, state)
        self.assertEqual(result["evidence"]["status"], "rejected")
        self.assertEqual(self.run_continuation(store, ledger())["evidence"]["status"], "rejected")
        self.assertNotIn("accepted", {x["kind"] for x in store.read(accept.PREFIX + S)[1]["events"]})
        self.assertEqual(self.run_continuation(Store(), ledger(), now=START + dt.timedelta(hours=26))["evidence"]["status"], "pending")
        for key, value in (("candidate", "d" * 40), ("mode", "both")):
            state = ledger()
            state[key] = value
            with self.assertRaises(ValueError):
                self.run_continuation(Store(), state)

    def test_rejection_never_delivers_queued_acceptance_or_erases_failure(self):
        store = Store()
        self.run_continuation(store, ledger())
        failed = ledger()
        failed["failures"] = [{"at": START.isoformat(), "reason": "rollback"}]
        sent = []
        self.run_continuation(store, failed, lambda item: sent.append(item["kind"]) or True)
        self.assertEqual(sent, ["configured", "rejected"])
        result = self.run_continuation(store, ledger())
        self.assertEqual(result["evidence"]["failures"], failed["failures"])
        with self.assertRaisesRegex(ValueError, "regressed"):
            self.run_continuation(store, ledger(23))

    def test_secret_schema_url_and_mutation_namespaces(self):
        for mutate in (lambda x: x.update(token="secret"), lambda x: x.update(health_url="https://u:secret@canary.test/health"), lambda x: x["config"].update(feedback=False)):
            config = copy.deepcopy(CONFIG)
            mutate(config)
            with self.assertRaises(ValueError):
                accept.activation(config)
        store = accept.GitStore()
        with patch.object(store, "command") as command:
            for ref in ("refs/tags/stable/now", "refs/release-candidate/current", "refs/soak-fail-canary/" + S):
                with self.assertRaises(ValueError):
                    store.write(ref, None, {})
            command.assert_not_called()
        self.assertNotIn("secret", json.dumps(self.run_continuation(Store(), ledger())))

    def test_no_endpoint_no_delivery_and_fixture_override_refused(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(accept.deliver({}))
        with patch.dict(os.environ, {"PROMOTE_NOW": START.isoformat()}), patch("sys.argv", ["canary_acceptance"]):
            with self.assertRaisesRegex(ValueError, "fixture"):
                accept.main()


class CompletionMutation(unittest.TestCase):
    def test_bypass_elapsed_guard_mutant_is_caught(self):
        with patch.object(soak_state, "complete", return_value=True):
            result = unittest.TestResult()
            AcceptanceTest("test_accepted_only_after_full_duration_and_stable_unchanged").run(result)
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(result.errors, [])


class GitStoreTest(unittest.TestCase):
    def test_real_git_restart_and_cas_refusal_preserves_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin = Path(tmp) / "origin.git"
            clone = Path(tmp) / "clone"
            subprocess.run(["git", "init", "--bare", str(origin)], check=True, capture_output=True)
            subprocess.run(["git", "clone", str(origin), str(clone)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(clone), "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "--allow-empty", "-m", "init"], check=True, capture_output=True)
            original = Path.cwd()
            try:
                os.chdir(clone)
                store = accept.GitStore()
                ref = accept.PREFIX + S
                oid = store.write(ref, None, {"failure": "retained"})
                restarted = accept.GitStore()
                self.assertEqual(restarted.read(ref), (oid, {"failure": "retained"}))
                with self.assertRaises(RuntimeError):
                    restarted.write(ref, None, {"failure": "erased"})
                self.assertEqual(store.read(ref)[1], {"failure": "retained"})
                refs = store.command("ls-remote", "--refs", "origin")
                self.assertNotIn("stable", refs)
            finally:
                os.chdir(original)

    def test_bridge_requires_persisted_receipt_and_rejects_redirect(self):
        with self.assertRaises(ValueError):
            accept.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.test")
        with patch.dict(os.environ, {"STABLE_CANARY_CONTINUATION_URL": "https://bridge.test", "STABLE_CANARY_CONTINUATION_TOKEN": "private"}):
            item = accept.event("configured", {"space_id": accept.SPACE})
            with patch.object(accept, "build_opener") as opener:
                response = opener.return_value.open.return_value.__enter__.return_value
                response.read.return_value = json.dumps({"event_id": item["id"], "persisted": True}).encode()
                self.assertTrue(accept.deliver(item))
                response.read.return_value = b'{}'
                self.assertFalse(accept.deliver(item))

    def test_workflow_gate_runs_only_after_committed_observation(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/promote-stable.yml").read_text()
        self.assertIn("success() && vars.STABLE_HELD_BOOTSTRAP == 'true'", workflow)
        self.assertLess(workflow.index("promote_stable.py"), workflow.index("canary_acceptance.py"))


if __name__ == "__main__":
    unittest.main()
