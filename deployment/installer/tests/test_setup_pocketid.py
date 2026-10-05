"""pocket-id and oidc-client steps (task 01a0d6ab stage 4).

Two classes run the SAME assertions:

- ``PocketIdFakeTest`` against the http.server fake (always runs);
- ``PocketIdRealTest`` against a REAL pocket-id v2 container, skipped unless
  ``SUITE_INSTALL_TEST_POCKETID_URL`` and ``SUITE_INSTALL_TEST_POCKETID_KEY``
  are set. For stage 4 it ran against the throwaway container
  ``pocketid-01a0d6ab`` (ghcr.io/pocket-id/pocket-id:v2, sqlite, bound to
  127.0.0.1 on moon, reached from hive through an ssh -L forward).

Running ``pocket-id`` + ``oidc-client`` twice must leave exactly one admin
user, one client ``suite-core`` whose callback is the literal URL, PKCE on,
and exactly one client secret, whose prefix is OIDC_CLIENT_SECRET's.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from setup_fakes import (
    MAC_LITE,
    POCKETID_SHORT_CODE_TTL_MAX,
    FakeHost,
    FakeKeychain,
    FakePocketId,
    go_duration_seconds,
    run_cli,
)

from suite_install.setup import cli, pocketid
from suite_install.setup.host import Result
from suite_install.setup.state import Install

PRIMARY = "suite-01a0d6ab.example.com"
CALLBACK = "https://suite-01a0d6ab.example.com/auth/oidc/callback"


class PocketIdCases:
    url = None
    key = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pid-01a0d6ab-")
        self.dir = os.path.join(self.tmp, "inst")
        self.host = FakeHost(self.tmp)
        self.host.add(["osascript", "-"], Result(0, ""))
        self.env = cli.Env(
            host=self.host,
            keychain=FakeKeychain(),
            environ={},
            configure=lambda ctx: setattr(ctx, "pocketid_url", self.url),
        )
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", self.dir, "--name", "suite-01a0d6ab",
            "--domain", PRIMARY, "--auth-host", "auth-01a0d6ab.example.com",
        )  # fmt: skip
        self.assertEqual(code, 0, doc)
        install = Install(self.dir)
        self.client_secret = "oidc-01a0d6ab-" + uuid.uuid4().hex
        install.upsert_secret("STATIC_API_KEY", self.key)
        install.upsert_secret("OIDC_CLIENT_SECRET", self.client_secret)
        state = install.load_state()
        for step in ("preflight", "render", "up"):
            state["steps"][step] = {"state": "done", "at": "x"}
        install.save_state(state)
        self.api = pocketid.Client(self.url, self.key)
        self.username = "admin01a0d6ab" + uuid.uuid4().hex[:6]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_step(self, name, *extra):
        return run_cli(self.env, "run", name, "--dir", self.dir, *extra)

    def users(self):
        _s, page = self.api.call("GET", "/api/users?pagination[limit]=100")
        return [u for u in page["data"] if u["id"] != "00000000-0000-0000-0000-000000000000"]

    def test_twice_gives_one_user_one_client_one_secret(self):
        email = f"{self.username}@example.test"
        users_before = len(self.users())
        for attempt in (1, 2):
            code, doc, text = self.run_step(
                "pocket-id",
                "--input", f"ADMIN_EMAIL={email}",
                "--input", f"ADMIN_USERNAME={self.username}",
            )  # fmt: skip
            self.assertEqual((code, doc["error_code"]), (3, "awaiting_passkey"), doc)
            self.assertEqual(doc["outputs"]["admin"], "created" if attempt == 1 else "present")
            self.assertEqual(doc["outputs"]["passkeys"], 0)
            self.assertTrue(doc["outputs"]["browser_opened"])
            # The sign-in link went to osascript on stdin, never to output.
            link_file = doc["outputs"]["login_link_file"]
            with open(link_file) as handle:
                link = handle.read().strip()
            self.assertTrue(link.startswith("https://auth-01a0d6ab.example.com/lc/"), link)
            self.assertEqual(os.stat(link_file).st_mode & 0o777, 0o600)
            code_in_link = link.split("/lc/")[1].split("?")[0]
            # 12 characters: the length pocket-id's sign-in page auto-submits.
            self.assertEqual(len(code_in_link), 12, "short code: LOGIN_TTL <= 15m?")
            self.assertEqual(doc["outputs"]["login_link_expires_in"], pocketid.LOGIN_TTL)
            self.assertIn(f"expires {pocketid.LOGIN_TTL}", doc["remediation"])
            self.assertNotIn(code_in_link, text)
            self.assertIn(link, self.host.calls[-1][1])
            code, doc, text = self.run_step("oidc-client")
            self.assertEqual(code, 0, doc)
            self.assertEqual(doc["outputs"]["client"], "created" if attempt == 1 else "present")
            self.assertEqual(doc["outputs"]["secret"], "registered" if attempt == 1 else "present")
            self.assertNotIn(self.client_secret, text)
            self.assertNotIn(self.key, text)

        mine = [u for u in self.users() if u["username"] == self.username]
        self.assertEqual(len(mine), 1)
        self.assertTrue(mine[0]["isAdmin"])
        self.assertEqual(len(self.users()), users_before + 1)
        _s, client = self.api.call("GET", "/api/oidc/clients/suite-core")
        self.assertEqual(client["callbackURLs"], [CALLBACK])
        self.assertIs(client["pkceEnabled"], True)
        self.assertIs(client["isPublic"], False)
        _s, secrets = self.api.call("GET", "/api/oidc/clients/suite-core/secrets")
        self.assertEqual(len(secrets), 1, secrets)
        self.assertEqual(secrets[0]["prefix"], self.client_secret[:4])

    def test_bad_static_key_is_named(self):
        Install(self.dir).upsert_secret("STATIC_API_KEY", "wrong-01a0d6ab-key-000000")
        code, doc, text = self.run_step("oidc-client")
        self.assertEqual((code, doc["error_code"]), (1, "pocketid_auth_failed"), doc)
        self.assertNotIn("wrong-01a0d6ab-key-000000", text)


class LoginTtlTest(unittest.TestCase):
    """LOGIN_TTL must stay ABOVE 15 minutes.

    pocket-id v2.18.0 backend/internal/onetimeaccess/service.go:271-274 mints a
    6-character code when ttl <= 15m; its sign-in page then never auto-submits
    and keeps Submit disabled (task 01a0d6ab stage 5 behavioural gate). The
    TTL is parsed as Go parses it, so "900s" or "0.25h" cannot slip past.
    """

    def test_parser_positive_controls(self):
        self.assertEqual(go_duration_seconds("15m"), 900)
        self.assertEqual(go_duration_seconds("900s"), 900)
        self.assertEqual(go_duration_seconds("0.25h"), 900)
        self.assertEqual(go_duration_seconds("1h30m"), 5400)
        for bad in ("", "15", "15 m", "m15", "15mm", "abc"):
            with self.assertRaises(ValueError, msg=bad):
                go_duration_seconds(bad)

    def test_login_ttl_is_above_the_short_code_boundary(self):
        ttl = go_duration_seconds(pocketid.LOGIN_TTL)
        self.assertGreater(ttl, POCKETID_SHORT_CODE_TTL_MAX, pocketid.LOGIN_TTL)
        # Upper bound: the link is a credential until used or expired.
        self.assertLessEqual(ttl, 60 * 60, pocketid.LOGIN_TTL)


class PocketIdFakeTest(PocketIdCases, unittest.TestCase):
    def setUp(self):
        self.key = "static-01a0d6ab-" + uuid.uuid4().hex
        self.fake = FakePocketId(self.key)
        self.url = self.fake.url
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.fake.close()

    def test_passkey_enrolled_completes_the_step(self):
        email = f"{self.username}@example.test"
        self.run_step("pocket-id", "--input", f"ADMIN_EMAIL={email}")
        admin = next(u for u in self.fake.users if u.get("email") == email)
        self.fake.passkeys[admin["id"]] = [{"id": "c1"}]
        code, doc, _ = self.run_step("pocket-id")
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["outputs"]["passkeys"], 1)
        status = json.loads(json.dumps(run_cli(self.env, "status", "--dir", self.dir)[1]))
        row = next(r for r in status["steps"] if r["name"] == "pocket-id")
        self.assertEqual(row["state"], "done")

    def test_generated_client_secret_is_deleted(self):
        # pocket-id v2.17.0+ generates a secret with the client (createdSecret).
        code, doc, _text = self.run_step("oidc-client")
        self.assertEqual(code, 0, doc)
        self.assertIs(doc["outputs"]["generated_secret_deleted"], True)
        self.assertEqual([s["prefix"] for s in self.fake.secrets["suite-core"]],
                         [self.client_secret[:4]])  # fmt: skip
        self.assertIn(("DELETE", "/api/oidc/clients/suite-core/secrets/"),
                      [(m, p.rsplit("/", 1)[0] + "/") for m, p in self.fake.requests])  # fmt: skip


class PocketIdFakeV216Test(PocketIdCases, unittest.TestCase):
    """The same cases against v2.16.0 behaviour: no secret generated with the client."""

    def setUp(self):
        self.key = "static-01a0d6ab-" + uuid.uuid4().hex
        self.fake = FakePocketId(self.key, auto_create_secret=False)
        self.url = self.fake.url
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.fake.close()

    def test_nothing_is_deleted(self):
        code, doc, _ = self.run_step("oidc-client")
        self.assertEqual(code, 0, doc)
        self.assertIs(doc["outputs"]["generated_secret_deleted"], False)
        self.assertNotIn("DELETE", [m for m, _p in self.fake.requests])


@unittest.skipUnless(
    os.environ.get("SUITE_INSTALL_TEST_POCKETID_URL")
    and os.environ.get("SUITE_INSTALL_TEST_POCKETID_KEY"),
    "set SUITE_INSTALL_TEST_POCKETID_URL and _KEY to run against a real pocket-id v2",
)
class PocketIdRealTest(PocketIdCases, unittest.TestCase):
    def setUp(self):
        self.url = os.environ["SUITE_INSTALL_TEST_POCKETID_URL"]
        self.key = os.environ["SUITE_INSTALL_TEST_POCKETID_KEY"]
        super().setUp()
        # Each run on a real container starts from no suite-core client.
        status, _ = self.api.call("GET", "/api/oidc/clients/suite-core", allow=(404,))
        if status != 404:
            self.api.call("DELETE", "/api/oidc/clients/suite-core")


if __name__ == "__main__":
    unittest.main()
