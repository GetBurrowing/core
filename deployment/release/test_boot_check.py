import subprocess
import unittest
from unittest.mock import patch

import boot_check


class BootCheckTest(unittest.TestCase):
    def test_health_requires_the_built_revision(self):
        self.assertTrue(boot_check.healthy('{"status":"ok","commit":"abc"}', "abc"))
        for body in ('{}', '[]', 'broken', '{"status":"ok","commit":"old"}',
                     '{"status":"unavailable","commit":"abc"}'):
            self.assertFalse(boot_check.healthy(body, "abc"))

    def run_boot(self, running="true"):
        calls = []

        def fake(*args, **kwargs):
            calls.append(args)
            out = ""
            if args[0] == "inspect":
                out = running
            if "curl" in args:
                out = '{"status":"ok","commit":"abc"}'
            return subprocess.CompletedProcess(args, 0, out, "")

        with patch.object(boot_check, "docker", side_effect=fake), patch("builtins.print"):
            if running == "true":
                boot_check.boot("registry/image@sha256:abc", "abc")
            else:
                with self.assertRaisesRegex(RuntimeError, "exited before"):
                    boot_check.boot("registry/image@sha256:abc", "abc")
        return calls

    def test_real_image_command_and_disposable_database(self):
        calls = self.run_boot()
        app = next(call for call in calls if call[-1] == "registry/image@sha256:abc")
        self.assertIn("FEEDBACK_POLICY=trusted", app)
        self.assertNotIn("eval", app)
        self.assertNotIn("-p", app)
        self.assertEqual(calls[0][:3], ("network", "create", "--internal"))
        self.assertEqual(calls[-2][:2], ("rm", "-fv"))
        self.assertEqual(calls[-1][:2], ("network", "rm"))

    def test_early_boot_crash_fails_and_still_removes_every_resource(self):
        calls = self.run_boot(running="false")
        self.assertTrue(any(call[0] == "logs" for call in calls))
        self.assertFalse(any("curl" in call for call in calls))
        self.assertEqual(calls[-2][:2], ("rm", "-fv"))
        self.assertEqual(calls[-1][:2], ("network", "rm"))

    def test_health_timeout_is_a_failure(self):
        with patch.object(boot_check.time, "monotonic", side_effect=[0, 1, 181]), \
             patch.object(boot_check.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "did not become ready"):
                boot_check.wait_for(lambda: False, 180, "release")


if __name__ == "__main__":
    unittest.main()
