"""Tests for ``suite-install proof`` / mac/proof.sh (task 01a0d6ab stage 5).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

No Docker, no Mac and no Burrow: every subprocess goes through the recording
FakeHost, ``bin/platform rpc`` is answered by a fake that plays core's side,
and HTTP goes to an in-memory fake of the attachment routes. Each check that
must be able to FAIL is shown failing once (a negative control), so a PASS
here means the check discriminated.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from setup_fakes import MAC, MAC_LITE, FakeHost, FakeKeychain, run_cli, write_secret_file

from suite_install import proof_mac
from suite_install.manifest import load
from suite_install.render import build
from suite_install.setup import cli
from suite_install.setup.host import Result
from suite_install.validate import validate

PROOF_SH = os.path.join(INSTALLER, "mac", "proof.sh")
FIXTURES = os.path.join(HERE, "render_fixtures")
TOKEN = "proof-FAKE-runtime-token-01a0d6ab-000111222333"
DB_SECRET = "pgFAKE01a0d6abNeverPrintThisValue"
OPENAI = "sk-FAKE-01a0d6ab-openai-never-print-me"
HUB_TOKEN = "dckr_pat_FAKE01a0d6abHubToken"
CANARY_ID = "01a0d6ab-0000-7000-8000-00000000c001"
CONTROL_ID = "01a0d6ab-0000-7000-8000-00000000c002"


def run_proof(env, *argv):
    out = io.StringIO()
    code = proof_mac.main(list(argv), env=env, out=out)
    return code, out.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="proof-01a0d6ab-")
        self.dir = os.path.join(self.tmp, "suite-01a0d6ab")
        self.host = FakeHost(self.tmp)
        self.keychain = FakeKeychain()
        self.env = cli.Env(host=self.host, keychain=self.keychain, environ={})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def init(self):
        code, text = run_proof(self.env, "init", "--zone", "example.com", "--dir", self.dir)
        self.assertEqual(code, 0, text)
        return json.loads(text)

    def write_secrets(self, **values):
        lines = [f"{k}={v}" for k, v in values.items()]
        write_secret_file(self.dir, "secrets.env", "\n".join(lines))

    def rpc(self, answer):
        """Answer ``bin/platform rpc <code>`` with ``answer(code)``."""

        def rule(argv, _input):
            return Result(0, answer(argv[-1]), "")

        self.host.add(
            ("compose-sub", "exec", "-T", "core-platform", proof_mac.RELEASE, "rpc"), rule
        )


# ---------------------------------------------------------------------------
# init and the manifest it writes
# ---------------------------------------------------------------------------


class InitTest(Base):
    def test_init_uses_the_01a0d6ab_names_the_pin_and_meetings_off(self):
        doc = self.init()
        self.assertEqual(doc["install_name"], "suite-01a0d6ab")
        m = load(os.path.join(self.dir, "install.toml"))
        self.assertEqual(m["install"]["name"], "suite-01a0d6ab")
        self.assertEqual(
            (m["domain"]["primary"], m["domain"]["auth_host"], m["domain"]["livekit_host"]),
            (
                "suite-01a0d6ab.example.com",
                "auth-01a0d6ab.example.com",
                "livekit-01a0d6ab.example.com",
            ),
        )
        self.assertIs(m["services"]["meetings"], False)
        self.assertEqual(
            m["images"]["refs"]["core-platform"],
            "docker.io/example/suite-core:feat-01a0d6ab-multiarch",
        )

    def test_default_init_keeps_the_hosted_openai_endpoints(self):
        # Positive control for the override test below: without flags the
        # proof manifest is mac.install.toml's hosted OpenAI setup.
        self.init()
        m = load(os.path.join(self.dir, "install.toml"))
        self.assertEqual(m["embeddings"]["base_url"], "https://api.openai.com")
        self.assertEqual(m["embeddings"]["model"], "text-embedding-3-small")
        self.assertEqual(m["models"]["endpoints"][0]["base_url"], "https://api.openai.com/v1")
        self.assertEqual(m["models"]["endpoints"][0]["kind"], "hosted")

    def test_local_endpoint_overrides_reach_the_manifest_and_render(self):
        code, text = run_proof(
            self.env,
            "init",
            "--zone",
            "example.com",
            "--dir",
            self.dir,
            "--embed-url",
            "http://192.0.2.20:8188/",
            "--embed-model",
            "embeddings",
            "--stt-url",
            "http://192.0.2.20:8000/v1",
            "--stt-model",
            "Systran/faster-distil-whisper-large-v3",
        )
        self.assertEqual(code, 0, text)
        m = load(os.path.join(self.dir, "install.toml"))
        self.assertEqual(m["embeddings"]["base_url"], "http://192.0.2.20:8188")
        self.assertEqual(m["embeddings"]["model"], "embeddings")
        self.assertEqual(m["embeddings"]["api_key_ref"], "OPENAI_API_KEY")
        endpoint = m["models"]["endpoints"][0]
        self.assertEqual(
            (endpoint["base_url"], endpoint["kind"]), ("http://192.0.2.20:8000/v1", "byo")
        )
        self.assertEqual(m["meetings"]["stt_model"], "Systran/faster-distil-whisper-large-v3")
        self.assertIs(m["meetings"]["transcription"], True)

    def test_no_transcription_drops_the_stt_endpoint_reference(self):
        code, text = run_proof(
            self.env, "init", "--zone", "example.com", "--dir", self.dir, "--no-transcription"
        )
        self.assertEqual(code, 0, text)
        m = load(os.path.join(self.dir, "install.toml"))
        self.assertIs(m["meetings"]["transcription"], False)
        self.assertNotIn("stt_endpoint", m["meetings"])

    def test_meetings_flip_is_one_flag_and_a_mac_lite_base_could_not_do_it(self):
        self.init()
        code, doc, _ = run_cli(self.env, "init", "--dir", self.dir, "--meetings", "on")
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["changed"], ["services.meetings"])
        # Negative control: the same flip on a mac-lite manifest is refused,
        # which is why init starts from mac.install.toml.
        other = os.path.join(self.tmp, "lite")
        code, doc, _ = run_cli(
            self.env, "init", "--from", MAC_LITE, "--dir", other, "--domain", "s.example.com"
        )
        self.assertEqual(code, 0, doc)
        code, doc, _ = run_cli(self.env, "init", "--dir", other, "--meetings", "on")
        self.assertEqual((code, doc["error_code"]), (2, "manifest_invalid"), doc)
        self.assertIn("meetings_media_reach_required", doc["error"])


class RenderEquivalenceTest(unittest.TestCase):
    """mac.install.toml with meetings off renders as mac-lite plus an unmounted models.json."""

    def render(self, source, meetings=False):
        raw = load(source)
        raw["services"]["meetings"] = meetings
        raw["install"]["name"] = "suite-01a0d6ab"
        raw["domain"]["primary"] = "suite-01a0d6ab.example.com"
        raw["domain"]["auth_host"] = "auth-01a0d6ab.example.com"
        raw["domain"]["livekit_host"] = "livekit-01a0d6ab.example.com"
        raw.setdefault("images", {}).setdefault("refs", {})["core-platform"] = "x/core:pin"
        errors, manifest = validate(raw)
        self.assertEqual(errors, [])
        return build(
            manifest,
            customer_secrets=os.path.join(FIXTURES, "mac-customer.env"),
            registry_auth=os.path.join(FIXTURES, "mac-registry-auth.json"),
        ).redacted()

    def test_every_file_but_models_json_is_identical(self):
        proof, lite = self.render(MAC), self.render(MAC_LITE)
        self.assertEqual(set(proof) - set(lite), {"models.json"})
        self.assertEqual(set(lite) - set(proof), set())
        for rel in sorted(lite):
            self.assertEqual(proof[rel], lite[rel], rel)
        self.assertNotIn("models.json", proof["compose.yaml"])

    def test_positive_control_meetings_on_does_differ(self):
        lite, on = self.render(MAC_LITE), self.render(MAC, meetings=True)
        self.assertNotEqual(on["compose.yaml"], lite["compose.yaml"])
        self.assertIn("livekit", on["compose.yaml"])


# ---------------------------------------------------------------------------
# memory
# ---------------------------------------------------------------------------


class ElixirTest(unittest.TestCase):
    def test_ex_str_blocks_interpolation(self):
        self.assertEqual(proof_mac.ex_str("a#{b}'c"), '"a\\#{b}\'c"')

    def test_memory_create_goes_through_the_tool_function(self):
        code = proof_mac.ex_memory_create("2026-09-25", [("canary", "x")])
        self.assertIn('ToolSurface.execute("memory_create"', code)
        self.assertIn('"org/journal/2026-09-25.md"', code)

    def test_mint_avoids_link_agent_and_scopes_the_bundle(self):
        code = proof_mac.ex_mint("proof-01a0d6ab-abc")
        self.assertNotIn("link_agent", code)
        self.assertIn('allowed_bundles: ["attachment"]', code)
        self.assertIn("activate_runtime", code)

    def test_revoke_revokes_the_runtime_row(self):
        code = proof_mac.ex_revoke("proof-01a0d6ab-abc")
        self.assertIn("Federation.revoke_runtime(rt)", code)


class JudgeOrderTest(unittest.TestCase):
    def hits(self, *rows):
        return [
            {"rank": i, "id": row[0], "sem": row[1], "lex": row[2], "score": "0.1"}
            for i, row in enumerate(rows, 1)
        ]

    def test_first_above_second_fused_and_semantically(self):
        ok, facts = proof_mac.judge_order(self.hits(("a", 1, 1), ("b", 2, None)), "a", "b")
        self.assertTrue(ok, facts)

    def test_negative_control_swapped_order_fails(self):
        ok, _ = proof_mac.judge_order(self.hits(("b", 1, 1), ("a", 2, None)), "a", "b")
        self.assertFalse(ok)

    def test_lexical_only_top_hit_fails(self):
        # The semantic rank is what proves the hosted embeddings work.
        ok, _ = proof_mac.judge_order(self.hits(("a", None, 1), ("b", 1, None)), "a", "b")
        self.assertFalse(ok)

    def test_semantic_inversion_under_a_fused_win_fails(self):
        ok, _ = proof_mac.judge_order(self.hits(("a", 2, 1), ("b", 1, None)), "a", "b")
        self.assertFalse(ok)

    def test_parse_hits(self):
        status, hits = proof_mac.parse_hits("status ok\nhit 1 x 1 - 0.03\nhit 2 y - 1 0.01\n")
        self.assertEqual(status, "ok")
        self.assertEqual(
            [(h["id"], h["sem"], h["lex"]) for h in hits], [("x", 1, None), ("y", None, 1)]
        )


class MemoryCommandTest(Base):
    def setUp(self):
        super().setUp()
        self.init()
        self.width = "1536"
        self.swap = False
        self.host.add(
            ("compose-sub", "exec", "-T", "core-postgres", "psql"),
            lambda argv, _i: Result(0, self.width + "\n", ""),
        )

        def answer(code):
            if "memory_create" in code:
                return f"canary_id {CANARY_ID}\ncontrol_id {CONTROL_ID}\n"
            canary_first = proof_mac.ex_str(proof_mac.CANARY_QUERY) in code
            if self.swap:
                canary_first = not canary_first
            a, b = (CANARY_ID, CONTROL_ID) if canary_first else (CONTROL_ID, CANARY_ID)
            return f"status ok\nhit 1 {a} 1 1 0.032\nhit 2 {b} 2 - 0.016\n"

        self.rpc(answer)

    def test_pass(self):
        code, text = run_proof(self.env, "memory", "--dir", self.dir, "--poll", "0")
        self.assertEqual(code, 0, text)
        self.assertIn("PASS memory.atttypmod 1536", text)
        self.assertIn("RESULT PASS memory", text)

    def test_negative_control_wrong_width_fails(self):
        self.width = "1024"
        code, text = run_proof(self.env, "memory", "--dir", self.dir, "--poll", "0")
        self.assertEqual(code, 1)
        self.assertIn("FAIL memory.atttypmod 1024", text)

    def test_negative_control_inverted_ranking_fails_both_queries(self):
        self.swap = True
        code, text = run_proof(self.env, "memory", "--dir", self.dir, "--poll", "0")
        self.assertEqual(code, 1)
        self.assertIn("FAIL memory.canary_query.order", text)
        self.assertIn("FAIL memory.control_query.order", text)

    def test_output_carries_ids_not_the_texts(self):
        _code, text = run_proof(self.env, "memory", "--dir", self.dir, "--poll", "0")
        self.assertNotIn("Quasar", text)
        self.assertNotIn("9-B", text)


# ---------------------------------------------------------------------------
# files
# ---------------------------------------------------------------------------


class FakeSuite:
    """Plays core's attachment routes and the runtime row."""

    def __init__(self, corrupt=False):
        self.active = False
        self.stored = None
        self.corrupt = corrupt
        self.requests = []
        self.revoked = False

    def rpc(self, code):
        if "activate_runtime" in code:
            self.active = True
            return (
                "runtime_id proof-01a0d6ab-x\nowner_user_id u1\nagent_id a1\n"
                f"space_id s1\ntoken {TOKEN}\n"
            )
        if "revoke_runtime" in code:
            self.active, self.revoked = False, True
            return "runtime_status revoked token_hash_nil=true\nagent_status archived\n"
        return ""

    def http(self, method, url, body=None, headers=None, timeout=120):
        headers = headers or {}
        self.requests.append((method, url, dict(headers)))
        authed = headers.get("Authorization") == f"Bearer {TOKEN}" and self.active
        if url.endswith("/mcp"):
            if not authed:
                return 401, {}, b"{}"
            args = json.loads(body)["params"]["arguments"]
            result = {
                "id": "att1",
                "upload_url": "/chat/attachments/upload/SIGNEDUPLOADTOKEN0123",
                "url": "/chat/attachments/att1",
                "byte_size": args["byte_size"],
            }
            doc = {"result": {"content": [{"type": "text", "text": json.dumps(result)}]}}
            return 200, {}, json.dumps(doc).encode()
        if "/upload/" in url:
            self.stored = body
            return 200, {}, json.dumps({"id": "att1", "url": "/chat/attachments/att1"}).encode()
        if url.endswith("/chat/attachments/att1"):
            if "Authorization" not in headers:
                return 302, {"Location": "/auth/login"}, b""
            if not authed:
                return 401, {}, b"{}"
            data = self.stored
            if self.corrupt:
                data = bytes([data[0] ^ 1]) + data[1:]
            return 200, {}, data
        return 404, {}, b""


class FilesCommandTest(Base):
    def setUp(self):
        super().setUp()
        self.init()

    def run_files(self, suite):
        self.rpc(suite.rpc)

        def cmp_rule(argv, _input):
            with open(argv[1], "rb") as a, open(argv[2], "rb") as b:
                return Result(0 if a.read() == b.read() else 1, "", "")

        self.host.add(("cmp",), cmp_rule)
        args = proof_mac.parser().parse_args(["files", "--dir", self.dir, "--size", "4096"])
        out = io.StringIO()
        from suite_install.setup.state import Install

        proof = proof_mac.Proof(Install(self.dir), self.env, out)
        code = proof_mac.cmd_files(proof, args, http_fn=suite.http)
        return code, out.getvalue()

    def test_round_trip_denials_revoke_and_cleanup(self):
        suite = FakeSuite()
        code, text = self.run_files(suite)
        self.assertEqual(code, 0, text)
        for expected in (
            "PASS files.token_file_mode 0o600",
            "PASS files.upload_post_status 200",
            "PASS files.download_status 200",
            "PASS files.cmp identical",
            "PASS files.unauthenticated_get_status 302",
            "PASS files.runtime_status revoked",
            "PASS files.revoked_token_get_status 401",
            "PASS files.token_file deleted",
            "RESULT PASS files",
        ):
            self.assertIn(expected, text)
        self.assertTrue(suite.revoked)
        self.assertEqual(
            [f for f in os.listdir(os.path.join(self.dir, ".setup")) if "proof-token" in f], []
        )

    def test_the_token_and_upload_credential_never_print(self):
        _code, text = self.run_files(FakeSuite())
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("SIGNEDUPLOADTOKEN0123", text)

    def test_token_travels_in_headers_not_argv(self):
        self.run_files(FakeSuite())
        for argv, _stdin in self.host.calls:
            self.assertNotIn(TOKEN, " ".join(argv))

    def test_negative_control_corrupted_download_fails(self):
        code, text = self.run_files(FakeSuite(corrupt=True))
        self.assertEqual(code, 1)
        self.assertIn("FAIL files.download_sha256", text)
        self.assertIn("FAIL files.cmp differ", text)
        # Cleanup still ran.
        self.assertIn("PASS files.runtime_status revoked", text)


# ---------------------------------------------------------------------------
# arch, meetings, livekit, ports
# ---------------------------------------------------------------------------


def ps_rule(services, image_for=None):
    rows = [
        {
            "Service": s,
            "Name": s,
            "Image": (image_for or {}).get(s, f"docker.io/x/{s}:1"),
            "State": "running",
        }
        for s in services
    ]
    text = "\n".join(json.dumps(r) for r in rows) + "\n"
    return lambda argv, _i: Result(0, text, "")


class ArchCommandTest(Base):
    SERVICES = ("caddy", "core-platform", "files-service", "memory-service")

    def setUp(self):
        super().setUp()
        self.init()
        write_secret_file(self.dir, "compose.yaml", "services: {}")
        self.host.add(("compose-sub", "ps"), ps_rule(self.SERVICES))

    def test_pass_when_everything_is_arm64(self):
        self.host.add(("docker", "image", "inspect"), Result(0, "arm64\n", ""))
        self.host.add(("compose-sub", "exec", "-T"), Result(0, "aarch64\n", ""))
        code, text = run_proof(self.env, "arch", "--dir", self.dir)
        self.assertEqual(code, 0, text)
        self.assertEqual(text.count("PASS uname"), 3)

    def test_negative_control_emulated_amd64_fails(self):
        self.host.add(("docker", "image", "inspect"), Result(0, "amd64\n", ""))
        self.host.add(("compose-sub", "exec", "-T"), Result(0, "x86_64\n", ""))
        code, text = run_proof(self.env, "arch", "--dir", self.dir)
        self.assertEqual(code, 1)
        self.assertIn("FAIL uname core-platform x86_64", text)


class MeetingsCommandTest(Base):
    def setUp(self):
        super().setUp()
        self.init()
        write_secret_file(self.dir, "compose.yaml", "services: {}")

    def run_with(self, services, env_text, expect):
        self.host.add(("compose-sub", "ps"), ps_rule(services))
        self.host.add(
            ("compose-sub", "exec", "-T", "core-platform", "env"), Result(0, env_text, "")
        )
        return run_proof(self.env, "meetings", "--dir", self.dir, "--expect", expect)

    def test_off_counts_names_and_never_prints_values(self):
        code, text = self.run_with(
            ("core-platform",), f"PORT=4000\nSECRET_KEY_BASE={DB_SECRET}\n", "off"
        )
        self.assertEqual(code, 0, text)
        self.assertIn("PASS meetings.core_livekit_env_count 0", text)
        self.assertNotIn(DB_SECRET, text)

    def test_negative_control_livekit_left_behind_fails_off(self):
        code, text = self.run_with(
            ("core-platform", "livekit"), f"LIVEKIT_API_SECRET={DB_SECRET}\n", "off"
        )
        self.assertEqual(code, 1)
        self.assertIn("FAIL meetings.livekit_running yes", text)
        self.assertIn("FAIL meetings.core_livekit_env_count 1", text)
        self.assertNotIn(DB_SECRET, text)


class LivekitCommandTest(Base):
    def test_key_and_secret_travel_in_env_not_argv(self):
        self.init()
        run_cli(self.env, "init", "--dir", self.dir, "--meetings", "on")
        self.write_secrets(LIVEKIT_API_SECRET=DB_SECRET)
        self.host.add(
            ("compose-sub", "exec", "-T", "core-platform", "printenv"), Result(0, "suite\n", "")
        )
        seen = {}

        class FakeLoad:
            returncode = 0

            def __init__(self, argv, env, **_kw):
                seen["load"] = (argv, env)

            def communicate(self, timeout=None):
                return f"published 2 tracks {DB_SECRET}\n", None

        def fake_run(argv, env, **_kw):
            seen["list"] = (argv, env)
            return subprocess.CompletedProcess(argv, 0, "proof-a\nproof-b\n", "")

        args = proof_mac.parser().parse_args(["livekit", "--dir", self.dir])
        out = io.StringIO()
        from suite_install.setup.state import Install

        proof = proof_mac.Proof(Install(self.dir), self.env, out)
        code = proof_mac.cmd_livekit(
            proof, args, popen=FakeLoad, run=fake_run, sleep=lambda s: None
        )
        text = out.getvalue()
        self.assertEqual(code, 0, text)
        for argv, env in seen.values():
            self.assertNotIn(DB_SECRET, " ".join(argv))
            self.assertEqual(env["LIVEKIT_API_SECRET"], DB_SECRET)
            self.assertEqual(env["LIVEKIT_URL"], "wss://livekit-01a0d6ab.example.com")
        # Scrubber: a secret echoed by lk never reaches the output.
        self.assertNotIn(DB_SECRET, text)
        self.assertIn("<secret:", text)
        self.assertIn("RESULT CHECK livekit", text)


class PortsCommandTest(Base):
    LSOF_TCP = (
        "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
        "node 1 j 20u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)\n"
    )

    def test_before_install_reports_ports_and_free_media_ports(self):
        self.host.add(("lsof", "-nP", "-iTCP"), Result(0, self.LSOF_TCP, ""))
        self.host.add(("lsof", "-nP", "-iUDP"), Result(0, "COMMAND\n", ""))
        self.host.add(("docker", "ps"), Result(0, "", ""))
        code, text = run_proof(self.env, "ports", "--dir", os.path.join(self.tmp, "none"))
        self.assertEqual(code, 0, text)
        self.assertIn("ports.tcp 3000 node", text)
        self.assertIn("PASS media_port tcp/7881 free", text)

    def test_negative_control_held_media_port_and_name_clash_fail(self):
        self.init()
        write_secret_file(
            self.dir, "compose.yaml", 'services:\n  caddy:\n    container_name: "caddy"\n'
        )
        held = self.LSOF_TCP + "other 2 j 21u IPv4 0x2 0t0 TCP *:7881 (LISTEN)\n"
        self.host.add(("lsof", "-nP", "-iTCP"), Result(0, held, ""))
        self.host.add(("lsof", "-nP", "-iUDP"), Result(0, "COMMAND\n", ""))
        self.host.add(("docker", "ps"), Result(0, "caddy\n", ""))
        self.host.add(("compose-sub", "ps"), Result(0, "", ""))
        code, text = run_proof(self.env, "ports", "--dir", self.dir)
        self.assertEqual(code, 1)
        self.assertIn("FAIL media_port tcp/7881 held-by other", text)
        self.assertIn("FAIL container_name_collisions caddy", text)


# ---------------------------------------------------------------------------
# transcript hygiene
# ---------------------------------------------------------------------------


class TranscriptInstall(Base):
    """An install with recorded secret inputs and a key file, for grep-transcript."""

    MARKER = "MARKER-01a0d6ab-planted"

    def setUp(self):
        super().setUp()
        self.init()
        self.write_secrets(POSTGRES_PASSWORD=DB_SECRET)
        key = write_secret_file(self.tmp, "openai", OPENAI)
        auth = __import__("base64").b64encode(f"example:{HUB_TOKEN}".encode()).decode()
        hub = write_secret_file(
            self.tmp,
            "hub.json",
            json.dumps({"auths": {"https://index.docker.io/v1/": {"auth": auth}}}),
        )
        # Preflight records the input references (whatever the fake host's checks say).
        run_cli(
            self.env, "run", "preflight", "--dir", self.dir,
            "--input", f"OPENAI_API_KEY=@{key}", "--input", f"REGISTRY_AUTH=@{hub}",
            "--input", "ADMIN_EMAIL=a@b.test",
        )  # fmt: skip
        with open(os.path.join(self.dir, "state.json"), encoding="utf-8") as handle:
            recorded = json.load(handle)["inputs"]
        self.assertEqual(set(recorded), {"OPENAI_API_KEY", "REGISTRY_AUTH", "ADMIN_EMAIL"})
        self.key = key


class GrepTranscriptTest(TranscriptInstall):
    def grep(self, lines):
        path = os.path.join(self.tmp, "transcript.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(json.dumps(line) for line in lines) + "\n")
        return run_proof(
            self.env, "--grep-transcript", "--dir", self.dir, "--transcript", path,
            "--marker", self.MARKER, "--key-file", self.key,
        )  # fmt: skip

    def test_clean_transcript_with_marker_passes(self):
        code, text = self.grep([{"type": "assistant", "text": f"{self.MARKER} starting"}])
        self.assertEqual(code, 0, text)
        self.assertIn("PASS transcript.marker_count 1", text)
        self.assertIn("transcript.count secrets.env:POSTGRES_PASSWORD 0", text)
        self.assertIn("transcript.count input:OPENAI_API_KEY 0", text)
        self.assertIn(
            "transcript.count input:REGISTRY_AUTH:token:https://index.docker.io/v1/ 0", text
        )

    def test_negative_control_each_leak_is_counted_by_name_only(self):
        for leaked, label in (
            (DB_SECRET, "secrets.env:POSTGRES_PASSWORD"),
            (OPENAI, "input:OPENAI_API_KEY"),
            (HUB_TOKEN, "input:REGISTRY_AUTH:token:https://index.docker.io/v1/"),
        ):
            with self.subTest(label=label):
                code, text = self.grep([{"text": self.MARKER}, {"tool_result": f"x {leaked} y"}])
                self.assertEqual(code, 1, text)
                self.assertIn(f"transcript.count {label} 1", text)
                self.assertIn("FAIL transcript.secret_occurrences", text)
                self.assertNotIn(leaked, text)

    def test_negative_control_missing_marker_fails(self):
        code, text = self.grep([{"text": "nothing planted"}])
        self.assertEqual(code, 1)
        self.assertIn("FAIL transcript.marker_count 0", text)


# The four human inputs the install clause allows, planted in a synthetic
# transcript among every kind of user record that is NOT a human turn.
PLANTED = [
    "Install Suite on this Mac. Domain: suite-01a0d6ab.example.com",
    "The Cloudflare token is in ~/secrets/cf-token-01a0d6ab",
    "OpenAI key file: ~/secrets/openai-01a0d6ab",
    "I added the passkey",
]


def stream_json_transcript():
    """``claude -p ... --output-format stream-json --replay-user-messages`` records."""

    def human(text):
        return {"type": "user", "message": {"role": "user", "content": text},
                "parent_tool_use_id": None, "session_id": "s", "isReplay": True}  # fmt: skip

    def tool_result(text):
        return {"type": "user", "parent_tool_use_id": None, "session_id": "s",
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t", "content": text}]},
                "tool_use_result": {"stdout": text}}  # fmt: skip

    def assistant(text):
        return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}

    return [
        {"type": "system", "subtype": "init", "session_id": "s"},
        human(PLANTED[0]),
        assistant("Running preflight. What is the Cloudflare token path?"),
        tool_result('{"ok": false, "error_code": "input_missing"}'),
        human(PLANTED[1]),
        # A subagent's prompt is a user record too; the agent wrote it.
        {
            "type": "user",
            "parent_tool_use_id": "toolu_1",
            "session_id": "s",
            "message": {"role": "user", "content": "Check the tunnel for suite-01a0d6ab"},
        },
        tool_result("tunnel ok"),
        human(PLANTED[2]),
        tool_result('{"ok": false, "error_code": "awaiting_passkey"}'),
        {"type": "user", "isSynthetic": True, "message": {"content": "continue"}},
        "not json at all",
        human([{"type": "text", "text": PLANTED[3]}]),
        {"type": "result", "subtype": "success", "result": "done"},
    ]


def session_jsonl_transcript():
    """An interactive session's ~/.claude/projects/<cwd>/<session>.jsonl records."""

    def rec(content, **extra):
        return {"type": "user", "message": {"role": "user", "content": content}, **extra}

    human = {"origin": {"kind": "human"}, "promptSource": "typed"}
    return [
        rec(PLANTED[0], **human),
        rec("<command-caveat>local command</command-caveat>", isMeta=True),
        rec(
            "<task-notification>bg job done</task-notification>",
            origin={"kind": "task-notification"},
            promptSource="system",
        ),
        rec(PLANTED[1], **human),
        # origin alone must decide: this harness text has no telltale prefix.
        rec(
            "Background job finished",
            origin={"kind": "task-notification", "producer": "session-task"},
            promptSource="system",
        ),
        rec("<local-command-stdout>ok</local-command-stdout>"),
        rec("subagent prompt", isSidechain=True),
        rec("Summary of the conversation so far", isCompactSummary=True),
        rec([{"type": "tool_result", "tool_use_id": "t", "content": "x"}], toolUseResult={}),
        rec(PLANTED[2], **human),
        rec(PLANTED[3], **human),
    ]


class HumanTurnsTest(unittest.TestCase):
    """Positive control: exactly the planted inputs, in order, from both shapes."""

    def lines(self, records):
        return [r if isinstance(r, str) else json.dumps(r) for r in records]

    def test_stream_json_lists_exactly_the_planted_inputs(self):
        turns, bad = proof_mac.human_turns(self.lines(stream_json_transcript()))
        self.assertEqual(turns, PLANTED)
        self.assertEqual(bad, 1)

    def test_session_jsonl_lists_exactly_the_planted_inputs(self):
        turns, bad = proof_mac.human_turns(self.lines(session_jsonl_transcript()))
        self.assertEqual(turns, PLANTED)
        self.assertEqual(bad, 0)

    def test_negative_control_an_extra_human_turn_is_listed(self):
        records = stream_json_transcript()
        records.insert(3, {"type": "user", "isReplay": True, "parent_tool_use_id": None,
                           "message": {"content": "my OpenAI key is sk-pasted"}})  # fmt: skip
        turns, _ = proof_mac.human_turns(self.lines(records))
        self.assertEqual(len(turns), 5)
        self.assertIn("my OpenAI key is sk-pasted", turns)


class GrepTranscriptHumanTurnsTest(TranscriptInstall):
    def write(self, records):
        path = os.path.join(self.tmp, "turns.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.writelines((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in records)
        return path

    def run_turns(self, records, *extra):
        records = [{"type": "assistant", "text": self.MARKER}, *records]
        return run_proof(
            self.env, "--grep-transcript", "--dir", self.dir, "--transcript",
            self.write(records), "--marker", self.MARKER, "--key-file", self.key, *extra,
        )  # fmt: skip

    def test_lists_the_planted_turns_and_reads_check(self):
        code, text = self.run_turns(stream_json_transcript(), "--human-turns")
        self.assertEqual(code, 0, text)
        for n, planted in enumerate(PLANTED, 1):
            self.assertIn(f"transcript.human_turn {n} {json.dumps(planted)}", text)
        self.assertNotIn("transcript.human_turn 5 ", text)
        self.assertIn("transcript.human_turns 4", text)
        self.assertTrue(text.rstrip().endswith("RESULT CHECK grep-transcript"), text)

    def test_expected_count_passes(self):
        code, text = self.run_turns(
            stream_json_transcript(), "--human-turns", "--expect-human-turns", "4"
        )
        self.assertEqual(code, 0, text)
        self.assertIn("PASS transcript.human_turns 4 expected 4", text)
        self.assertTrue(text.rstrip().endswith("RESULT PASS grep-transcript"), text)

    def test_negative_control_wrong_count_fails(self):
        code, text = self.run_turns(stream_json_transcript(), "--expect-human-turns", "3")
        self.assertEqual(code, 1, text)
        self.assertIn("FAIL transcript.human_turns 4 expected 3", text)

    def test_a_pasted_secret_in_a_human_turn_is_scrubbed_and_counted(self):
        records = [{"type": "user", "isReplay": True, "parent_tool_use_id": None,
                    "message": {"content": f"here is the key {OPENAI}"}}]  # fmt: skip
        code, text = self.run_turns(records, "--human-turns")
        self.assertEqual(code, 1, text)
        self.assertIn("transcript.human_turn 1 ", text)
        self.assertNotIn(OPENAI, text)
        self.assertIn("FAIL transcript.secret_occurrences", text)


# ---------------------------------------------------------------------------
# the shell door
# ---------------------------------------------------------------------------


@unittest.skipIf(shutil.which("bash") is None, "bash not installed")
class ProofShTest(unittest.TestCase):
    def test_parses_and_is_executable(self):
        self.assertTrue(os.access(PROOF_SH, os.X_OK))
        self.assertEqual(subprocess.run(["bash", "-n", PROOF_SH], check=False).returncode, 0)

    @unittest.skipIf(sys.version_info < (3, 11), "suite-install needs python >= 3.11")
    def test_grep_transcript_flag_reaches_the_subcommand(self):
        result = subprocess.run(
            [PROOF_SH, "--grep-transcript", "--help"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--marker", result.stdout)


if __name__ == "__main__":
    unittest.main()
