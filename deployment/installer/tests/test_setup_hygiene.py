"""Transcript hygiene: no secret value reaches argv, stdout, stderr or state.json.

Task 01a0d6ab stage 4. Run:
PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

``Harness`` runs EVERY step of a meetings-on, media_reach = "public" install
(so ``ddns`` applies too) against fakes: a recording FakeHost, an in-memory
Keychain, and http.server fakes of Cloudflare, pocket-id, Docker Hub and the
public edge. Secrets arrive by all three reference kinds (Keychain, 0600 file,
env var), plus one refused literal.

The grep target is everything an agent could see: the combined stdout+stderr
of every command, state.json, and every subprocess argv the CLI issued. The
positive control is a planted marker that travels through a non-secret input
and must be FOUND by the same grep. It runs twice: with the output scrubber
on (the shipped behaviour) and OFF, which shows the steps themselves print no
secret rather than relying on the scrubber.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from setup_fakes import (
    MAC,
    FakeCloudflare,
    FakeDockerHub,
    FakeEdge,
    FakeHost,
    FakeKeychain,
    FakePocketId,
    run_cli,
    write_secret_file,
)

from burrow_install.secrets import parse_env_file
from burrow_install.setup import cli, steps
from burrow_install.setup.host import Result
from burrow_install.setup.macos import MacKeychain

MARKER = "planted-01a0d6ab-marker"
CF_TOKEN = "cf-FAKE-token-01a0d6ab-9f8e7d6c5b4a"
OPENAI_KEY = "sk-FAKE-openai-01a0d6ab-1a2b3c4d5e6f"
REFUSED_LITERAL = "sk-FAKE-literal-01a0d6ab-typed-in-argv"
HUB_BASIC = "dXNlcjAxYTBkNmFiOmh1Yi1yZWFkLXRva2Vu"  # base64 of a fake user:token
REGISTRY_AUTH = json.dumps({"auths": {"https://index.docker.io/v1/": {"auth": HUB_BASIC}}})
PRIMARY = "suite-01a0d6ab.example.com"
AUTH_HOST = "auth-01a0d6ab.example.com"
LIVEKIT_HOST = "livekit-01a0d6ab.example.com"


def public_meetings_manifest(directory):
    """mac.install.toml with media_reach = "public" and a media_host (ddns applies)."""
    with open(MAC, encoding="utf-8") as handle:
        text = handle.read()
    assert '\nmedia_reach = "lan"\n' in text
    text = text.replace(
        '\nmedia_reach = "lan"\n',
        '\nmedia_reach = "public"\nmedia_host = "media-01a0d6ab.example.com"\n',
    )
    path = os.path.join(directory, "public.install.toml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return path


def compose_ps(argv, _input):
    rows = [
        {"Service": s, "State": "running", "Health": h}
        for s, h in (
            ("caddy", ""),
            ("core-platform", "healthy"),
            ("core-postgres", "healthy"),
            ("pocket-id", ""),
            ("cloudflared", ""),
        )
    ]
    return Result(0, "\n".join(json.dumps(r) for r in rows), "")


class Harness:
    def __init__(self, scrub=True):
        self.tmp = tempfile.mkdtemp(prefix="setup-01a0d6ab-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.dir = os.path.join(self.tmp, "suite", "suite-01a0d6ab")
        self.cf = FakeCloudflare(CF_TOKEN)
        self.hub = FakeDockerHub(HUB_BASIC)
        self.pocket = None  # started once STATIC_API_KEY exists (after render)
        self.edge = FakeEdge(PRIMARY, AUTH_HOST)
        self.host = FakeHost(self.home)
        self.keychain = FakeKeychain({"CLOUDFLARE_API_TOKEN": CF_TOKEN})
        self.transcript = []
        self.scrub = scrub
        self.host.add(
            ["docker", "info"],
            Result(
                0,
                json.dumps(
                    {
                        "OperatingSystem": "Docker Desktop",
                        "MemTotal": 8 * 2**30,
                        "ServerVersion": "28.0.0",
                        "Architecture": "aarch64",
                    }
                ),
            ),
        )
        self.host.add(["docker", "compose", "version"], Result(0, "2.35.0\n"))
        self.host.add(["sysctl"], Result(0, str(16 * 2**30)))
        self.host.add(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
            Result(
                0,
                "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
                "node 11 u 20u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)\n",
            ),
        )
        self.host.add(["lsof", "-nP", "-iTCP:7881"], Result(1, ""))
        self.host.add(["lsof", "-nP", "-iUDP:7882"], Result(1, ""))
        self.host.add(["compose-sub", "ps"], compose_ps)
        self.host.add(
            ["pmset", "-g"], Result(0, " sleep                1\n disksleep 10\n autorestart 0\n")
        )
        self.host.add(["fdesetup", "status"], Result(0, "FileVault is On.\n"))
        self.host.add(["defaults", "read"], Result(1, "", "does not exist"))
        self.host.add(
            ["/bin/bash"],
            lambda argv, _i: (
                Result(
                    0,
                    "backup start x\n"
                    + "".join(
                        f"dump {db} {argv[3]}/{db}-x.dump\nverified {db} 42\n"
                        for db in ("core_platform", "memory", "pocketid")
                    ),
                )
                if argv[1].endswith("backup.sh")
                else Result(0, "")
            ),
        )
        self.environ = {"PATH": "/usr/bin:/bin", "HUB_AUTH_01A0D6AB": REGISTRY_AUTH}

    def configure(self, ctx):
        ctx.cloudflare_api = self.cf.url
        ctx.docker_auth_url = self.hub.url + "/token"
        ctx.docker_registry_url = self.hub.url
        ctx.pocketid_url = self.pocket.url if self.pocket else "http://127.0.0.1:9"
        ctx.url_for = self.edge.url_for
        ctx.backup_root = os.path.join(self.home, "BurrowBackups")
        ctx.log_root = os.path.join(self.home, "Logs")
        ctx.disk_free_bytes = lambda path: 200 * 2**30
        ctx.health_wait_seconds = 1

    def env(self):
        return cli.Env(
            host=self.host,
            keychain=self.keychain,
            environ=self.environ,
            configure=self.configure,
            scrub=self.scrub,
        )

    def cli(self, *argv):
        code, doc, text = run_cli(self.env(), *argv)
        self.transcript.append(text)
        return code, doc

    def start_pocket(self):
        key = parse_env_file(os.path.join(self.dir, "secrets.env"))["STATIC_API_KEY"]
        self.pocket = FakePocketId(key)

    def run_everything(self, test):
        manifest = public_meetings_manifest(self.tmp)
        openai_file = write_secret_file(self.tmp, "openai.key", OPENAI_KEY)
        code, doc = self.cli(
            "init", "--from", manifest, "--dir", self.dir, "--name", "suite-01a0d6ab",
            "--domain", PRIMARY, "--auth-host", AUTH_HOST, "--livekit-host", LIVEKIT_HOST,
        )  # fmt: skip
        test.assertEqual(code, 0, doc)
        code, doc = self.cli("secret", "CLOUDFLARE_API_TOKEN", "--dir", self.dir)
        test.assertEqual((code, doc["stored"]), (0, "keychain"), doc)
        code, doc = self.cli(
            "run", "preflight", "--dir", self.dir, "--input", f"OPENAI_API_KEY={REFUSED_LITERAL}"
        )
        test.assertEqual((code, doc["error_code"]), (2, "secret_in_argv"), doc)
        steps_run = {}
        plan = [
            ("preflight", ["--input", "REGISTRY_AUTH=env:HUB_AUTH_01A0D6AB"]),
            ("domain", []),
            ("tunnel", []),
            ("ddns", []),
            ("render", ["--input", f"OPENAI_API_KEY=@{openai_file}"]),
            ("up", ["--input", f"ADMIN_EMAIL={MARKER}@example.test"]),
            ("pocket-id", []),
            ("oidc-client", []),
            ("keepalive", []),
            ("backup", []),
        ]
        for name, extra in plan:
            if name == "up":
                self.start_pocket()
            code, doc = self.cli("run", name, "--dir", self.dir, *extra)
            steps_run[name] = (code, doc)
        test.assertEqual(steps_run["pocket-id"][0], 3, steps_run["pocket-id"][1])
        test.assertEqual(steps_run["pocket-id"][1]["error_code"], "awaiting_passkey")
        admin = next(u for u in self.pocket.users if u["username"] == MARKER)
        self.pocket.passkeys[admin["id"]] = [{"id": "cred-1"}]
        steps_run["pocket-id-2"] = self.cli("run", "pocket-id", "--dir", self.dir)
        steps_run["verify"] = self.cli("run", "verify", "--dir", self.dir)
        steps_run["status"] = self.cli("status", "--json", "--dir", self.dir)
        return steps_run

    def secret_values(self):
        values = {
            "CLOUDFLARE_API_TOKEN": CF_TOKEN,
            "OPENAI_API_KEY": OPENAI_KEY,
            "refused literal": REFUSED_LITERAL,
            "REGISTRY_AUTH": REGISTRY_AUTH,
            "registry basic auth": HUB_BASIC,
            "registry bearer": "hub-bearer-01a0d6ab-fake",
            "TUNNEL_TOKEN": self.cf.tunnel_token,
        }
        for name, value in parse_env_file(os.path.join(self.dir, "secrets.env")).items():
            if name in ("STATIC_API_KEY", "OIDC_CLIENT_SECRET", "SECRET_KEY_BASE",
                        "POSTGRES_PASSWORD", "TUNNEL_TOKEN", "LIVEKIT_API_SECRET",
                        "VAULT_MASTER_KEY", "MEETING_AGENT_TOKEN"):  # fmt: skip
                values[name] = value
        for i, token in enumerate(self.pocket.tokens):
            values[f"one-time token {i}"] = token
        return values

    def visible_text(self):
        with open(os.path.join(self.dir, "state.json"), encoding="utf-8") as handle:
            state = handle.read()
        argv = "\n".join(" ".join(a) for a, _stdin in self.host.calls)
        return "\n".join(self.transcript) + "\n" + state + "\n" + argv

    def close(self):
        for server in (self.cf, self.hub, self.pocket, self.edge):
            if server:
                server.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


class HygieneBase:
    scrub = True

    @classmethod
    def setUpClass(cls):
        cls.h = Harness(scrub=cls.scrub)
        cls.results = cls.h.run_everything(unittest.TestCase())

    @classmethod
    def tearDownClass(cls):
        cls.h.close()

    def test_every_step_ran_ok(self):
        # Positive control for the grep below: the run did real work.
        for name in ("preflight", "domain", "tunnel", "ddns", "render", "up", "oidc-client",
                     "keepalive", "backup", "pocket-id-2", "verify"):  # fmt: skip
            code, doc = self.results[name]
            self.assertEqual(code, 0, (name, doc))
            self.assertTrue(doc["ok"], (name, doc))
        status = self.results["status"][1]
        self.assertTrue(status["complete"], status["steps"])
        self.assertEqual({r["name"] for r in status["steps"]}, {s.name for s in steps.STEPS})

    def test_positive_control_marker_is_found(self):
        self.assertIn(MARKER, self.h.visible_text())

    def test_no_secret_value_is_visible(self):
        text = self.h.visible_text()
        values = self.h.secret_values()
        self.assertGreaterEqual(len(values), 15, sorted(values))
        counts = {name: text.count(value) for name, value in values.items()}
        self.assertEqual({n: c for n, c in counts.items() if c}, {}, "secret(s) visible")

    def test_secrets_only_travel_on_stdin(self):
        values = self.h.secret_values()
        on_stdin = [stdin for _argv, stdin in self.h.host.calls if stdin]
        # The one-time sign-in link went to osascript on stdin, not argv.
        self.assertTrue(any(self.h.pocket.tokens[0] in s for s in on_stdin))
        for argv, _stdin in self.h.host.calls:
            joined = " ".join(argv)
            for name, value in values.items():
                self.assertNotIn(value, joined, (name, argv[:3]))

    def test_state_json_holds_references_not_values(self):
        with open(os.path.join(self.h.dir, "state.json"), encoding="utf-8") as handle:
            state = json.load(handle)
        self.assertEqual(state["inputs"]["CLOUDFLARE_API_TOKEN"], "keychain:CLOUDFLARE_API_TOKEN")
        self.assertEqual(state["inputs"]["REGISTRY_AUTH"], "env:HUB_AUTH_01A0D6AB")
        self.assertTrue(state["inputs"]["OPENAI_API_KEY"].startswith("@/"))
        self.assertEqual(state["inputs"]["ADMIN_EMAIL"], f"{MARKER}@example.test")


class HygieneScrubbedTest(HygieneBase, unittest.TestCase):
    scrub = True


class HygieneUnscrubbedTest(HygieneBase, unittest.TestCase):
    """Scrubber OFF: the steps themselves must print no secret."""

    scrub = False


class GrepCanFireTest(unittest.TestCase):
    """The absence grep is shown able to fire: an unscrubbed leak IS counted."""

    def test_leaked_value_is_detected(self):
        text = "\n".join(["ok", json.dumps({"outputs": {"x": CF_TOKEN}})])
        self.assertEqual(text.count(CF_TOKEN), 1)


class ScrubberTest(unittest.TestCase):
    """The second layer on its own: a value from secrets.env is replaced on output."""

    def test_scrubber_replaces_known_values_and_can_be_shown_off(self):
        import io

        from burrow_install.setup.state import Install

        tmp = tempfile.mkdtemp(prefix="scrub-01a0d6ab-")
        try:
            install = Install(tmp)
            install.upsert_secret("STATIC_API_KEY", "static-01a0d6ab-scrub-me-please")
            ctx = steps.Ctx(install, {"steps": {}, "inputs": {}, "ids": {}}, None, None, {})
            doc = {"outputs": {"oops": "static-01a0d6ab-scrub-me-please"}}
            for scrub, expect_leak in ((True, False), (False, True)):
                ctx._scrub = scrub
                out = io.StringIO()
                cli._emit(doc, ctx, out)
                self.assertEqual("static-01a0d6ab-scrub-me-please" in out.getvalue(), expect_leak)
            self.assertIn("<secret:secrets.env:STATIC_API_KEY>", self._scrubbed(ctx, doc))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_scrubber_replaces_the_pocket_id_api_key_alias(self):
        # task 01a113ea stage 4: secrets.env carries the static key twice, as
        # STATIC_API_KEY and as core's POCKET_ID_API_KEY alias. Either name may
        # win the placeholder; the value must not survive.
        import io

        from burrow_install.setup.state import Install

        tmp = tempfile.mkdtemp(prefix="scrub-01a113ea-")
        value = "static-01a113ea-alias-scrub-me"
        try:
            install = Install(tmp)
            install.upsert_secret("STATIC_API_KEY", value)
            install.upsert_secret("POCKET_ID_API_KEY", value)
            ctx = steps.Ctx(install, {"steps": {}, "inputs": {}, "ids": {}}, None, None, {})
            self.assertIn("secrets.env:POCKET_ID_API_KEY", ctx.secret_values())
            doc = {"outputs": {"core_key": value, "pocket_key": value}}
            ctx._scrub = False
            out = io.StringIO()
            cli._emit(doc, ctx, out)
            self.assertIn(value, out.getvalue())  # positive control: unscrubbed leaks
            scrubbed = self._scrubbed(ctx, doc)
            self.assertNotIn(value, scrubbed)
            self.assertEqual(scrubbed.count("<secret:secrets.env:"), 2)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @staticmethod
    def _scrubbed(ctx, doc):
        import io

        ctx._scrub = True
        out = io.StringIO()
        cli._emit(doc, ctx, out)
        return out.getvalue()


class MacKeychainArgvTest(unittest.TestCase):
    """The real Keychain backend, driven through a recording host."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="kc-01a0d6ab-")
        self.host = FakeHost(self.tmp)
        self.value = "kc-FAKE-value-01a0d6ab-abcdef"
        self.stored = {}

        def security_i(argv, stdin):
            parts = stdin.split()
            self.stored[(parts[parts.index("-s") + 1], parts[parts.index("-a") + 1])] = (
                bytes.fromhex(parts[parts.index("-X") + 1]).decode()
            )
            return Result(0, "", "")

        def find(argv, _stdin):
            key = (argv[argv.index("-s") + 1], argv[argv.index("-a") + 1])
            return Result(0, self.stored[key] + "\n") if key in self.stored else Result(44)

        self.host.add(["security", "-i"], security_i)
        self.host.add(["security", "find-generic-password"], find)
        self.host.add(["osascript", "-"], Result(0, self.value + "\n"))
        self.kc = MacKeychain(self.host)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_store_read_prompt_never_put_the_value_in_argv(self):
        typed = self.kc.prompt("CLOUDFLARE_API_TOKEN", "suite-01a0d6ab")
        self.assertEqual(typed, self.value)
        self.kc.store("suite-install.suite-01a0d6ab", "CLOUDFLARE_API_TOKEN", typed)
        self.assertEqual(
            self.kc.read("suite-install.suite-01a0d6ab", "CLOUDFLARE_API_TOKEN"), self.value
        )
        for argv, stdin in self.host.calls:
            self.assertNotIn(self.value, " ".join(argv))
            if argv[:2] == ["security", "-i"]:
                # Hex on stdin, so not even stdin carries the plain value.
                self.assertNotIn(self.value, stdin)
                self.assertIn(self.value.encode().hex(), stdin)
        # Positive control: the value did travel (stdout of find-generic-password).
        self.assertIn(("suite-install.suite-01a0d6ab", "CLOUDFLARE_API_TOKEN"), self.stored)

    def test_hidden_dialog_is_on_stdin(self):
        self.kc.prompt("OPENAI_API_KEY", "suite-01a0d6ab")
        argv, stdin = self.host.calls[-1]
        self.assertEqual(argv, ["osascript", "-"])
        self.assertIn("with hidden answer", stdin)

    def test_unstorable_value_is_refused(self):
        from burrow_install.setup.state import SetupError

        with self.assertRaises(SetupError) as caught:
            self.kc.store("suite-install.x", "ITEM", "has\nnewline")
        self.assertEqual(caught.exception.code, "keychain_value_unsupported")

    def test_off_darwin_the_backend_says_unavailable(self):
        from burrow_install.setup.state import SetupError

        self.host.platform = "linux"
        with self.assertRaises(SetupError) as caught:
            self.kc.read("suite-install.x", "ITEM")
        self.assertEqual(caught.exception.code, "keychain_unavailable")


@unittest.skipUnless(sys.platform == "darwin", "real login Keychain: macOS only")
class RealKeychainTest(unittest.TestCase):
    """One round trip through the real `security` binary (skipped off Darwin)."""

    def test_round_trip(self):
        from burrow_install.setup.host import Host

        kc = MacKeychain(Host())
        service, item = "suite-install.test-01a0d6ab", "ROUNDTRIP"
        value = "rt-01a0d6ab-" + os.urandom(8).hex()
        try:
            kc.store(service, item, value)
            self.assertEqual(kc.read(service, item), value)
        finally:
            kc.delete(service, item)
        self.assertIsNone(kc.read(service, item))


if __name__ == "__main__":
    unittest.main()
