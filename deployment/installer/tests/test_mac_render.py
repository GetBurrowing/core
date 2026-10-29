"""Renderer tests for install.target = "mac" (task 01a0d6ab stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Design (mirrors test_render.py):
- Every class renders BOTH mac examples first (positive control).
- Goldens golden/mac/ and golden/mac-lite/ are compared whole-file after
  secret values are replaced with ``<secret:NAME>``. Regenerate with
  ``BURROW_INSTALL_UPDATE_GOLDEN=1`` (legacy ``SUITE_INSTALL_UPDATE_GOLDEN=1``)
  and review the diff.
- media_reach = "lan" detects the machine's LAN address at render time; the
  detector is replaced here by a documentation address (RFC 5737) so renders
  are deterministic and no real address reaches a golden.
- Every absence check has a positive control showing the same search hits.
"""

import contextlib
import copy
import difflib
import io
import os
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLES = os.path.join(REPO, "deployment", "examples")
MAC = os.path.join(EXAMPLES, "mac.install.toml")
MAC_LITE = os.path.join(EXAMPLES, "mac-lite.install.toml")
SINGLE_HOST = os.path.join(EXAMPLES, "single-host.install.toml")
RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
CUSTOMER = os.path.join(RENDER_FIXTURES, "mac-customer.env")
REGISTRY_AUTH = os.path.join(RENDER_FIXTURES, "mac-registry-auth.json")
GOLDEN = os.path.join(HERE, "golden")

sys.path.insert(0, INSTALLER)

from identity_terms import identity_hits, planted_term
from render_identity_scan import identity_scan_text

from burrow_install import envcompat, registry
from burrow_install.__main__ import main
from burrow_install.manifest import load
from burrow_install.render import RenderError, build, plan, render
from burrow_install.secrets import parse_env_file
from burrow_install.validate import validate

DOC_IP = "192.0.2.10"  # RFC 5737 TEST-NET-1
GOLDEN_CASES = {"mac": MAC, "mac-lite": MAC_LITE}
CUSTOMER_VALUES = parse_env_file(CUSTOMER)
# Install and personal identity is checked by identity_hits, on the same
# digest rule as core's Elixir guard, so this file does not spell it (task
# 01a14b9e stage 5). The LAN prefix and harness settings stay literal.
FORBIDDEN = ("192.168.", "lightning", "OPENCLAW_")


def manifest_from(path):
    errors, normalized = validate(load(path))
    if errors:
        raise AssertionError(f"{path} is invalid: {errors}")
    return normalized


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError(f"mutated manifest is invalid: {errors}")
    return normalized


def mac_build(manifest, **kwargs):
    kwargs.setdefault("customer_secrets", CUSTOMER)
    kwargs.setdefault("registry_auth", REGISTRY_AUTH)
    return build(manifest, **kwargs)


def all_text(rendered):
    return "\n".join(text for text, _mode in rendered.files.values())


def identity_guard_text(rendered, manifest):
    """The identity guard's final text, retaining its image-ref exemption."""
    text = identity_scan_text(rendered)
    images = {svc.image for svc in plan(manifest).services.values()}
    for image in sorted(images, key=len, reverse=True):
        text = text.replace(image, "<image>")
    return text


def compose_block(compose, service):
    match = re.search(
        rf"^  {re.escape(service)}:\n((?:    .*\n|      .*\n)*)", compose, re.MULTILINE
    )
    if not match:
        raise AssertionError(f"no compose service {service}")
    return match.group(1)


def run_cli(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(list(argv))
    return code, out.getvalue()


class FixedMediaIpMixin:
    """Replace render-time address detection for the whole class."""

    @classmethod
    def setUpClass(cls):
        cls._detectors = dict(registry.MEDIA_IP_DETECTORS)
        registry.MEDIA_IP_DETECTORS["lan"] = lambda: DOC_IP
        registry.MEDIA_IP_DETECTORS["tailnet"] = lambda: "100.64.0.10"
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        registry.MEDIA_IP_DETECTORS.clear()
        registry.MEDIA_IP_DETECTORS.update(cls._detectors)
        super().tearDownClass()


class PositiveControlMixin(FixedMediaIpMixin):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for path in (MAC, MAC_LITE):
            rendered = mac_build(manifest_from(path))
            for required in ("compose.yaml", "Caddyfile", "secrets.env", "services.txt"):
                if not rendered.files.get(required, ("", 0))[0].strip():
                    raise AssertionError(f"positive control failed: {path} {required} is empty")


class TempDirMixin:
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix="burrow-install-01a0d6ab-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        from burrow_install.render import inside_git_worktree

        if inside_git_worktree(self.tmp):
            self.skipTest(f"the temp dir {self.tmp} is inside a git work tree")


# ---------------------------------------------------------------------------
# Goldens
# ---------------------------------------------------------------------------


class MacGoldenTest(PositiveControlMixin, unittest.TestCase):
    def check_golden(self, case):
        redacted = mac_build(manifest_from(GOLDEN_CASES[case])).redacted()
        golden_dir = os.path.join(GOLDEN, case)
        if envcompat.get("BURROW_INSTALL_UPDATE_GOLDEN", "SUITE_INSTALL_UPDATE_GOLDEN") == "1":
            shutil.rmtree(golden_dir, ignore_errors=True)
            for rel, text in redacted.items():
                path = os.path.join(golden_dir, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(text)
        on_disk = {}
        for root, _dirs, names in os.walk(golden_dir):
            for name in names:
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as handle:
                    on_disk[os.path.relpath(path, golden_dir)] = handle.read()
        self.assertEqual(sorted(redacted), sorted(on_disk), "rendered file set changed")
        for rel in sorted(redacted):
            if redacted[rel] != on_disk[rel]:
                diff = "".join(
                    difflib.unified_diff(
                        on_disk[rel].splitlines(True),
                        redacted[rel].splitlines(True),
                        f"golden/{case}/{rel}",
                        "rendered",
                    )
                )
                self.fail(f"{case}/{rel} differs from golden:\n{diff}")

    def test_golden_mac(self):
        self.check_golden("mac")

    def test_golden_mac_lite(self):
        self.check_golden("mac-lite")

    def test_the_file_sets_are_the_literal_lists(self):
        self.assertEqual(
            sorted(mac_build(manifest_from(MAC)).files),
            [
                "Caddyfile",
                "compose.yaml",
                "livekit.yaml",
                "models.json",
                "postgres-init/10-memory.sql",
                "postgres-init/20-pocket-id.sql",
                "registry-auth.json",
                "secrets.env",
                "secrets/OPENAI_API_KEY",
                "services.txt",
            ],
        )
        self.assertEqual(
            sorted(mac_build(manifest_from(MAC_LITE)).files),
            [
                "Caddyfile",
                "compose.yaml",
                "postgres-init/10-memory.sql",
                "postgres-init/20-pocket-id.sql",
                "registry-auth.json",
                "secrets.env",
                "secrets/OPENAI_API_KEY",
                "services.txt",
            ],
        )

    def test_no_cloud_init_on_mac(self):
        for path in (MAC, MAC_LITE):
            files = mac_build(manifest_from(path)).files
            self.assertNotIn("user-data", files)
            self.assertNotIn("meta-data", files)
        # Positive control: single-host does render cloud-init.
        self.assertIn("user-data", build(manifest_from(SINGLE_HOST)).files)


# ---------------------------------------------------------------------------
# Knob semantics: meetings and transcription
# ---------------------------------------------------------------------------


class MacKnobTest(PositiveControlMixin, unittest.TestCase):
    MEETINGS_LITERALS = ("livekit", "LIVEKIT_", "7881", "7882", "meeting-transcriber")

    def test_mac_contains_every_meetings_literal_and_mac_lite_none(self):
        on = all_text(mac_build(manifest_from(MAC)))
        off = all_text(mac_build(manifest_from(MAC_LITE)))
        # Positive control first: the same search hits the meetings render.
        self.assertEqual([s for s in self.MEETINGS_LITERALS if s not in on], [])
        self.assertEqual([s for s in self.MEETINGS_LITERALS if s in off], [])

    def pair(self, mutate):
        on = load(MAC)
        off = copy.deepcopy(on)
        mutate(off)
        return valid(on), valid(off)

    def assert_owns(self, containers, on, off):
        on_text = all_text(mac_build(on))
        off_text = all_text(mac_build(off))
        for container in containers:
            ids = registry.identifiers(container, registry.Ctx(on))
            with self.subTest(service=container):
                self.assertIn(container, ids)
                self.assertGreater(len(ids), 1, f"{container} declares only its name")
                self.assertEqual(sorted(i for i in ids if i not in on_text), [])
                self.assertEqual(sorted(i for i in ids if i in off_text), [])

    def test_meetings_knob_owns_livekit_and_the_transcriber(self):
        on, off = self.pair(lambda raw: raw["services"].update(meetings=False))
        self.assert_owns(["livekit", "meeting-transcriber"], on, off)

    def test_transcription_knob_owns_the_transcriber_only(self):
        on, off = self.pair(lambda raw: raw["meetings"].update(transcription=False))
        self.assert_owns(["meeting-transcriber"], on, off)
        self.assertIn("livekit", all_text(mac_build(off)))

    def test_meetings_identifiers_are_the_expected_literal_sets(self):
        ctx = registry.Ctx(manifest_from(MAC))
        self.assertEqual(
            registry.identifiers("livekit", ctx),
            {"livekit", "LIVEKIT_API_SECRET", "LIVEKIT_KEYS", "livekit.yaml"},
        )
        self.assertEqual(
            registry.identifiers("meeting-transcriber", ctx),
            {
                "meeting-transcriber",
                "MEETING_AGENT_TOKEN",
                "PERSIST_TOKEN",
                "PERSIST_URL",
                "STT_API_KEY",
                "STT_BASE_URL",
                "STT_MODEL",
                "ROOM_PATTERN",
                "IDLE_TIMEOUT_S",
                "EMPTY_GRACE_S",
                # No LOG_LEVEL: the bundled pocket-id declares it too (task
                # 01a114c1), so a meetings-off render still carries the name.
            },
        )

    def test_no_dangling_reference_either_way(self):
        for path in (MAC, MAC_LITE):
            with self.subTest(example=os.path.basename(path)):
                m = manifest_from(path)
                p = plan(m)
                for svc in p.services.values():
                    self.assertLessEqual(set(svc.depends_on), set(p.services))
                rendered = mac_build(m)
                text = all_text(rendered)
                self.assertNotIn("{secret:", text)
                self.assertNotIn("{customer:", text)
                names = re.findall(
                    r"^  ([a-z][a-z0-9-]*):$", rendered.files["compose.yaml"][0], re.MULTILINE
                )
                self.assertEqual(names, p.containers)

    def test_reuse_secrets_across_the_meetings_flip_keeps_shared_values(self):
        with tempfile.TemporaryDirectory(prefix="burrow-install-01a0d6ab-") as tmp:
            out = os.path.join(tmp, "lite")
            lite = render(
                manifest_from(MAC_LITE), out, customer_secrets=CUSTOMER, registry_auth=REGISTRY_AUTH
            )
            full = mac_build(manifest_from(MAC), reuse_secrets=os.path.join(out, "secrets.env"))
        shared = sorted(set(lite.generated) & set(full.generated))
        self.assertGreaterEqual(len(shared), 13)
        self.assertEqual([n for n in shared if lite.generated[n] != full.generated[n]], [])
        self.assertEqual(
            sorted(set(full.generated) - set(lite.generated)),
            ["LIVEKIT_API_SECRET", "MEETING_AGENT_TOKEN"],
        )


# ---------------------------------------------------------------------------
# Edge, TLS and core wiring
# ---------------------------------------------------------------------------


class MacEdgeTest(PositiveControlMixin, unittest.TestCase):
    def test_no_auth_alias_and_no_ca_mount_on_mac(self):
        # Positive control: the single-host tls = "internal" golden case HAS both.
        single = build(manifest_from(SINGLE_HOST))
        single_compose = single.files["compose.yaml"][0]
        self.assertIn('- "auth.burrow-01a0d69d.test"', single_compose)
        self.assertIn(registry.CASTORE_PATH, single_compose)
        self.assertIn("aliases:", single_compose)
        for path in (MAC, MAC_LITE):
            with self.subTest(example=os.path.basename(path)):
                text = all_text(mac_build(manifest_from(path)))
                self.assertNotIn("aliases:", text)
                self.assertNotIn("networks:", text)
                self.assertNotIn(registry.CASTORE_PATH, text)
                self.assertNotIn("castore", text.lower())
                self.assertNotIn("ca-bundle", text)
                self.assertNotIn("tls internal", text)

    def test_caddy_is_plain_http_by_host_and_publishes_nothing(self):
        rendered = mac_build(manifest_from(MAC))
        caddy = rendered.files["Caddyfile"][0]
        self.assertIn("\tauto_https off\n", caddy)
        self.assertIn("\t\ttrusted_proxies static private_ranges\n", caddy)
        for host, upstream in (
            ("burrow.example.test", "core-platform:4000"),
            ("auth.burrow.example.test", "pocket-id:1411"),
            ("livekit.burrow.example.test", "livekit:7880"),
        ):
            self.assertIn(f"http://{host} {{\n\treverse_proxy {upstream}\n}}", caddy)
        self.assertNotIn("https://", caddy)
        self.assertIn("http:// {\n\trespond 404\n}", caddy)
        self.assertNotIn("ports:", compose_block(rendered.files["compose.yaml"][0], "caddy"))

    def test_service_to_core_calls_use_the_internal_https_asserting_listener(self):
        # core force_ssl redirects a plain internal POST (307, measured on the
        # smoke VM); the internal listener sets X-Forwarded-Proto: https.
        rendered = mac_build(manifest_from(MAC))
        caddy = rendered.files["Caddyfile"][0]
        self.assertIn(
            "http://:4080 {\n\treverse_proxy core-platform:4000 {\n"
            "\t\theader_up X-Forwarded-Proto https\n\t}\n}",
            caddy,
        )
        text = all_text(rendered)
        self.assertNotIn("core-platform:4000/api", text)
        # mac-lite runs nothing that calls core, so it has no such listener.
        self.assertNotIn(":4080", all_text(mac_build(manifest_from(MAC_LITE))))

    def test_only_livekit_publishes_host_ports_and_only_7881_7882(self):
        compose = mac_build(manifest_from(MAC)).files["compose.yaml"][0]
        published = re.findall(r'^      - "(\d+:\d+/(?:tcp|udp))"$', compose, re.MULTILINE)
        self.assertEqual(published, ["7881:7881/tcp", "7882:7882/udp"])
        self.assertEqual(compose.count("    ports:\n"), 1)
        self.assertIn("ports:", compose_block(compose, "livekit"))
        lite = mac_build(manifest_from(MAC_LITE)).files["compose.yaml"][0]
        self.assertNotIn("ports:", lite)

    def test_core_env_for_an_edge_terminated_install(self):
        compose = mac_build(manifest_from(MAC)).files["compose.yaml"][0]
        core = compose_block(compose, "core-platform")
        for line in (
            'TRUST_PROXY_HEADERS: "true"',
            'PHX_HOST: "burrow.example.test"',
            'APP_URL: "https://burrow.example.test"',
            'OIDC_ISSUER: "https://auth.burrow.example.test"',
            'OIDC_PKCE_ENABLED: "true"',
            'LIVEKIT_URL: "wss://livekit.burrow.example.test"',
            'LIVEKIT_API_KEY: "suite"',
        ):
            self.assertIn(line, core)
        # Positive control that TRUST_PROXY_HEADERS is a mac addition only.
        self.assertNotIn(
            "TRUST_PROXY_HEADERS", build(manifest_from(SINGLE_HOST)).files["compose.yaml"][0]
        )

    def test_cloudflared_runs_the_token_from_secrets_env(self):
        rendered = mac_build(manifest_from(MAC_LITE))
        block = compose_block(rendered.files["compose.yaml"][0], "cloudflared")
        self.assertIn('- "tunnel"\n', block)
        self.assertIn('- "run"\n', block)
        self.assertIn('- "secrets.env"', block)
        self.assertIn("TUNNEL_TOKEN=fake-tunnel-token-01a0d6ab\n", rendered.files["secrets.env"][0])

    def test_flat_hostnames_override_the_defaults(self):
        raw = load(MAC)
        raw["domain"] = {
            "primary": "suite-01a0d6ab.example.test",
            "auth_host": "auth-01a0d6ab.example.test",
            "livekit_host": "livekit-01a0d6ab.example.test",
        }
        rendered = mac_build(valid(raw))
        caddy = rendered.files["Caddyfile"][0]
        self.assertIn("http://auth-01a0d6ab.example.test {", caddy)
        self.assertIn("http://livekit-01a0d6ab.example.test {", caddy)
        compose = rendered.files["compose.yaml"][0]
        self.assertIn('OIDC_ISSUER: "https://auth-01a0d6ab.example.test"', compose)
        self.assertIn('APP_URL: "https://auth-01a0d6ab.example.test"', compose)
        self.assertIn('LIVEKIT_URL: "wss://livekit-01a0d6ab.example.test"', compose)

    def test_tailscale_renders_one_sidecar_per_hostname(self):
        raw = load(MAC)
        raw["domain"] = {
            "primary": "suite.tailnet-example.ts.net",
            "auth_host": "suite-auth.tailnet-example.ts.net",
            "livekit_host": "suite-livekit.tailnet-example.ts.net",
        }
        raw["access"] = {"mode": "tailscale", "tailscale_authkey_ref": "TS_AUTHKEY"}
        rendered = mac_build(valid(raw))
        compose = rendered.files["compose.yaml"][0]
        self.assertNotIn("cloudflared", compose)
        for role, label in (
            ("primary", "suite"),
            ("auth", "suite-auth"),
            ("livekit", "suite-livekit"),
        ):
            block = compose_block(compose, f"tailscale-{role}")
            self.assertIn(f'TS_HOSTNAME: "{label}"', block)
            self.assertIn(f'"./tailscale/{role}.json:/config/serve.json:ro"', block)
            serve = rendered.files[f"tailscale/{role}.json"][0]
            self.assertIn('"Proxy": "http://caddy:80"', serve)
            self.assertIn("${TS_CERT_DOMAIN}:443", serve)
        self.assertIn("TS_AUTHKEY=fake-ts-authkey-01a0d6ab\n", rendered.files["secrets.env"][0])
        self.assertNotIn("fake-ts-authkey-01a0d6ab", compose)
        self.assertNotIn(registry.CASTORE_PATH, all_text(rendered))


# ---------------------------------------------------------------------------
# Models: hosted embeddings, STT, no local model
# ---------------------------------------------------------------------------


class MacModelsTest(PositiveControlMixin, unittest.TestCase):
    def test_memory_embeds_through_the_hosted_api_with_a_mounted_key_file(self):
        rendered = mac_build(manifest_from(MAC_LITE))
        block = compose_block(rendered.files["compose.yaml"][0], "memory-service")
        for line in (
            'MEMORY_EMBEDDING_BACKEND: "http"',
            'MEMORY_EMBEDDING_URL: "https://api.openai.com"',
            'MEMORY_EMBEDDING_MODEL: "text-embedding-3-small"',
            'MEMORY_EMBEDDING_QUERY_PREFIX: ""',
            'MEMORY_EMBEDDING_API_KEY_FILE: "/run/secrets/OPENAI_API_KEY"',
            '"./secrets/OPENAI_API_KEY:/run/secrets/OPENAI_API_KEY:ro"',
        ):
            self.assertIn(line, block)
        self.assertNotIn("embeddings:", block)  # no depends_on a local container
        self.assertEqual(
            rendered.files["secrets/OPENAI_API_KEY"], ("fake-openai-key-01a0d6ab\n", 0o600)
        )
        # The key is mounted into memory-service alone, never in secrets.env.
        self.assertNotIn("fake-openai-key-01a0d6ab", rendered.files["secrets.env"][0])
        self.assertEqual(
            rendered.files["compose.yaml"][0].count("/run/secrets/OPENAI_API_KEY:ro"), 1
        )

    def test_no_local_model_container_or_gpu(self):
        for path in (MAC, MAC_LITE):
            text = all_text(mac_build(manifest_from(path)))
            for word in ("speaches", "llama.cpp", "embeddings:8188", "nvidia", "/models"):
                self.assertNotIn(word, text)
        # Positive control: the single-host example does run a local model.
        self.assertIn("llama.cpp", all_text(build(manifest_from(SINGLE_HOST))))

    def test_transcriber_speaks_to_the_named_hosted_endpoint(self):
        rendered = mac_build(manifest_from(MAC))
        block = compose_block(rendered.files["compose.yaml"][0], "meeting-transcriber")
        for line in (
            'STT_BASE_URL: "https://api.openai.com/v1"',
            'STT_MODEL: "whisper-1"',
            'LIVEKIT_URL: "ws://livekit:7880"',
            'PERSIST_URL: "http://caddy:4080/api/meetings/segments"',
            'ROOM_PATTERN: "space-*"',
        ):
            self.assertIn(line, block)
        env = rendered.files["secrets.env"][0]
        self.assertIn("STT_API_KEY=fake-openai-key-01a0d6ab\n", env)
        tokens = dict(line.split("=", 1) for line in env.splitlines() if "=" in line)
        self.assertEqual(tokens["PERSIST_TOKEN"], tokens["MEETING_AGENT_TOKEN"])

    def test_livekit_keys_arrive_by_env_and_the_yaml_names_only_the_key_id(self):
        rendered = mac_build(manifest_from(MAC))
        secret = rendered.generated["LIVEKIT_API_SECRET"]
        self.assertIn(f"LIVEKIT_KEYS=suite: {secret}\n", rendered.files["secrets.env"][0])
        yaml_text = rendered.files["livekit.yaml"][0]
        self.assertIn('  api_key: "suite"\n', yaml_text)
        self.assertIn('    - "http://caddy:4080/api/webhooks/livekit"\n', yaml_text)
        self.assertIn("  tcp_port: 7881\n  udp_port: 7882\n", yaml_text)
        self.assertIn("turn:\n  enabled: false\n", yaml_text)


class MediaReachTest(PositiveControlMixin, unittest.TestCase):
    def livekit_yaml(self, **meetings):
        raw = load(MAC)
        raw["meetings"].update(meetings)
        return mac_build(valid(raw)).files["livekit.yaml"][0]

    def test_lan_uses_the_detected_address(self):
        text = self.livekit_yaml()
        self.assertIn(f'  node_ip: "{DOC_IP}"\n', text)
        self.assertIn("  use_external_ip: false\n", text)

    def test_pinned_node_ip_wins_over_detection(self):
        self.assertIn('  node_ip: "198.51.100.7"\n', self.livekit_yaml(node_ip="198.51.100.7"))

    def test_tailnet_uses_the_hosts_tailscale_address(self):
        self.assertIn('  node_ip: "100.64.0.10"\n', self.livekit_yaml(media_reach="tailnet"))

    def test_public_discovers_by_stun(self):
        text = self.livekit_yaml(media_reach="public")
        self.assertIn("  use_external_ip: true\n", text)
        self.assertNotIn("node_ip", text)

    def test_failed_detection_refuses_instead_of_going_public(self):
        saved = registry.MEDIA_IP_DETECTORS["tailnet"]
        registry.MEDIA_IP_DETECTORS["tailnet"] = lambda: None
        self.addCleanup(registry.MEDIA_IP_DETECTORS.__setitem__, "tailnet", saved)
        raw = load(MAC)
        raw["meetings"]["media_reach"] = "tailnet"
        with self.assertRaises(RenderError) as ctx:
            mac_build(valid(raw))
        self.assertEqual(ctx.exception.code, "media_ip_undetected")
        self.assertEqual(ctx.exception.path, "meetings.node_ip")


# ---------------------------------------------------------------------------
# Secrets and pocket-id
# ---------------------------------------------------------------------------


class MacSecretsTest(PositiveControlMixin, TempDirMixin, unittest.TestCase):
    def test_no_secret_value_in_compose_caddyfile_or_livekit_yaml(self):
        rendered = mac_build(manifest_from(MAC))
        values = dict(rendered.generated)
        values.update(rendered.customer)
        env = rendered.files["secrets.env"][0] + rendered.files["secrets/OPENAI_API_KEY"][0]
        # Positive control: the same search finds every value where it belongs.
        self.assertEqual([n for n, v in values.items() if v not in env], [])
        for rel in ("compose.yaml", "Caddyfile", "livekit.yaml", "services.txt", "models.json"):
            text = rendered.files[rel][0]
            self.assertEqual([n for n, v in values.items() if v in text], [], rel)

    def test_secret_files_are_0600(self):
        out = os.path.join(self.tmp, "mac")
        render(manifest_from(MAC), out, customer_secrets=CUSTOMER, registry_auth=REGISTRY_AUTH)
        import stat

        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o700)
        for rel in ("secrets.env", "secrets/OPENAI_API_KEY", "registry-auth.json"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, rel)).st_mode), 0o600, rel)
        for rel in ("compose.yaml", "Caddyfile", "livekit.yaml"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, rel)).st_mode), 0o644, rel)

    def test_redact_cli_round_trip_covers_the_key_file(self):
        out = os.path.join(self.tmp, "raw")
        red = os.path.join(self.tmp, "red")
        rendered = render(
            manifest_from(MAC), out, customer_secrets=CUSTOMER, registry_auth=REGISTRY_AUTH
        )
        # The key file is redacted through the value it holds in secrets.env
        # (STT_API_KEY), so the customer file is not needed here.
        code, _ = run_cli("redact", out, "--out", red)
        self.assertEqual(code, 0)
        with open(os.path.join(red, "secrets", "OPENAI_API_KEY"), encoding="utf-8") as handle:
            self.assertNotIn("fake-openai-key-01a0d6ab", handle.read())
        with open(os.path.join(red, "compose.yaml"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), rendered.redacted()["compose.yaml"])

    def test_pocket_id_uses_the_bundled_postgres_and_gets_a_static_api_key(self):
        rendered = mac_build(manifest_from(MAC_LITE))
        env = rendered.files["secrets.env"][0]
        pw = rendered.generated["POCKETID_DB_PASSWORD"]
        self.assertIn(
            f"DB_CONNECTION_STRING=postgres://pocketid:{pw}@core-postgres:5432/pocketid"
            "?sslmode=disable\n",
            env,
        )
        self.assertIn(f"STATIC_API_KEY={rendered.generated['STATIC_API_KEY']}\n", env)
        sql = rendered.files["postgres-init/20-pocket-id.sql"][0]
        self.assertIn("CREATE DATABASE pocketid OWNER pocketid;", sql)
        self.assertNotIn(pw, sql)
        block = compose_block(rendered.files["compose.yaml"][0], "pocket-id")
        self.assertIn('image: "ghcr.io/pocket-id/pocket-id:v2.18.0"', block)
        self.assertIn('core-postgres:\n        condition: "service_healthy"', block)
        # Positive control: single-host keeps sqlite. It does get the static key
        # since task 01a113ea stage 4 (core's Users page needs it on every
        # bundled install); test_render.SignInAdminEnvTest covers that.
        single = build(manifest_from(SINGLE_HOST))
        single_env = single.files["secrets.env"][0]
        self.assertNotIn("DB_CONNECTION_STRING", single_env)
        self.assertIn(f"STATIC_API_KEY={single.generated['STATIC_API_KEY']}\n", single_env)

    def test_bundled_mac_wires_core_to_the_pocket_id_admin_api(self):
        rendered = mac_build(manifest_from(MAC_LITE))
        compose = rendered.files["compose.yaml"][0]
        core = compose_block(compose, "core-platform")
        self.assertIn('POCKET_ID_ADMIN_ENABLED: "true"', core)
        self.assertIn('POCKET_ID_ADMIN_URL: "http://pocket-id:1411"', core)
        key = rendered.generated["STATIC_API_KEY"]
        text, mode = rendered.files["secrets.env"]
        self.assertEqual(mode, 0o600)
        env = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        self.assertEqual(env["POCKET_ID_API_KEY"], key)
        self.assertNotIn("POCKET_ID_API_KEY", compose)
        self.assertNotIn(key, compose)

    def test_external_oidc_mac_writes_none_of_the_users_page_vars(self):
        names = ("POCKET_ID_ADMIN_ENABLED", "POCKET_ID_ADMIN_URL", "POCKET_ID_API_KEY")
        bundled = all_text(mac_build(manifest_from(MAC_LITE)))
        for name in names:
            self.assertIn(name, bundled)  # positive control
        raw = load(MAC_LITE)
        raw["auth"] = {
            "mode": "external-oidc",
            "issuer": "https://id.customer.example",
            "client_id": "suite",
            "client_secret_ref": "CUSTOMER_OIDC_SECRET",
        }
        errors, manifest = validate(raw)
        self.assertEqual(errors, [])
        with open(CUSTOMER, encoding="utf-8") as handle:
            customer = handle.read()
        supplied = os.path.join(self.tmp, "c.env")
        with open(supplied, "w") as handle:
            handle.write(customer + "CUSTOMER_OIDC_SECRET=oidc-value-01a113ea\n")
        text = all_text(mac_build(manifest, customer_secrets=supplied))
        for name in (*names, "STATIC_API_KEY", "pocket-id:1411"):
            self.assertNotIn(name, text)

    def test_tunnel_token_is_required_at_render(self):
        with open(os.path.join(self.tmp, "c.env"), "w") as handle:
            handle.write("OPENAI_API_KEY=x\n")
        with self.assertRaises(RenderError) as ctx:
            mac_build(manifest_from(MAC_LITE), customer_secrets=os.path.join(self.tmp, "c.env"))
        self.assertEqual(ctx.exception.code, "customer_secret_missing")
        self.assertEqual(ctx.exception.path, "access.tunnel_token_ref")

    def test_cli_render_prints_names_never_values(self):
        out = os.path.join(self.tmp, "cli")
        code, stdout = run_cli(
            "render",
            MAC,
            "--out",
            out,
            "--customer-secrets",
            CUSTOMER,
            "--registry-auth",
            REGISTRY_AUTH,
        )
        self.assertEqual(code, 0, stdout)
        self.assertIn("rendered target mac into ", stdout)
        self.assertIn("file secrets/OPENAI_API_KEY 0600", stdout)
        values = parse_env_file(os.path.join(out, "secrets.env"))
        self.assertEqual([n for n, v in values.items() if v in stdout], [])

    def test_renders_hold_no_literal_of_ours(self):
        for path in (MAC, MAC_LITE):
            m = manifest_from(path)
            text = identity_guard_text(mac_build(m), m)
            with self.subTest(example=os.path.basename(path)):
                self.assertEqual([f for f in FORBIDDEN if f in text], [])
                self.assertEqual(identity_hits(text), [])

    def test_generated_identity_collision_is_excluded(self):
        term = planted_term()
        secret = "safe_" + term.capitalize() + "_" + "x" * 40
        for path in (MAC, MAC_LITE):
            with self.subTest(example=os.path.basename(path)):
                m = manifest_from(path)
                with patch.object(registry._random, "token_urlsafe", return_value=secret) as generate:
                    rendered = mac_build(m)
                generate.assert_called()
                self.assertRegex(secret, r"^[A-Za-z0-9_-]+$")
                self.assertTrue(identity_hits(secret))
                self.assertIn(secret, all_text(rendered))
                self.assertIn(secret, rendered.files["secrets.env"][0])
                # Mac deliberately confines generated values to secrets.env.
                # The focused helper tests cover repeated values in key/config files.
                self.assertGreater(rendered.files["secrets.env"][0].count(secret), 1)
                text = identity_guard_text(rendered, m)
                self.assertEqual([f for f in FORBIDDEN if f in text], [])
                self.assertEqual(identity_hits(text), [])
                # A colliding credential must not hide operator config elsewhere.
                for violation in (term, "safe" + term.capitalize() + "Value",
                                  "192." + "168.0.9", *FORBIDDEN[1:]):
                    rendered.files["identity-control.conf"] = ("endpoint=" + violation, 0o600)
                    final = identity_guard_text(rendered, m)
                    with self.subTest(violation=violation):
                        if violation in FORBIDDEN:
                            self.assertIn(violation, final)
                        else:
                            self.assertTrue(identity_hits(final))
                del rendered.files["identity-control.conf"]
                self.assertEqual(identity_hits(identity_guard_text(rendered, m)), [])

    def test_compose_parses_as_yaml(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed (stdlib-only CI container)")
        for path in (MAC, MAC_LITE):
            m = manifest_from(path)
            doc = yaml.safe_load(mac_build(m).files["compose.yaml"][0])
            self.assertEqual(sorted(doc["services"]), registry.enabled_containers(m))


class MacFreshRenderNamesTest(PositiveControlMixin, unittest.TestCase):
    """A fresh mac render (images.registry set) carries no pre-01a14dd8 name (task 01a14dd8)."""

    LEGACY = re.compile(r"/opt/suite\b|suite-[a-z@-]+\.service|docker\.io/\S*suite-")
    PINNED = "ghcr.io/example/meeting-transcriber:v0-pinned"

    def registry_mac(self, pin=True):
        raw = load(MAC)
        raw["images"].pop("image_namespace")
        raw["images"]["registry"] = "ghcr.io/example"
        if pin:
            raw["images"]["refs"] = {"meeting-transcriber": self.PINNED}
        return raw

    def test_mac_lite_and_mac_with_a_registry_carry_no_legacy_name(self):
        self.assertIsNone(self.LEGACY.search("ghcr.io/example/core:core /opt/burrow"))
        self.assertTrue(self.LEGACY.search('image: "docker.io/example/suite-core:core"'))
        for name, m in (("mac-lite", manifest_from(MAC_LITE)), ("mac", valid(self.registry_mac()))):
            files = mac_build(m).redacted()
            self.assertTrue(files, name)
            for rel, text in files.items():
                with self.subTest(case=name, file=rel):
                    self.assertEqual(self.LEGACY.findall(rel + "\n" + text), [])
        compose = mac_build(valid(self.registry_mac())).files["compose.yaml"][0]
        self.assertIn(f'image: "{self.PINNED}"', compose)
        self.assertIn('image: "ghcr.io/example/core:core"', compose)

    def test_registry_with_transcription_needs_the_transcriber_pinned(self):
        errors, _m = validate(self.registry_mac(pin=False))
        self.assertEqual(
            [(e.code, e.path) for e in errors],
            [("missing_required", "images.refs.meeting-transcriber")],
        )
        # meetings off (mac-lite) or transcription off needs no pin.
        raw = self.registry_mac(pin=False)
        raw["meetings"]["transcription"] = False
        raw["meetings"].pop("stt_endpoint", None)
        raw["meetings"].pop("stt_model", None)
        self.assertEqual(validate(raw)[0], [])

    def test_an_unvalidated_manifest_cannot_reach_an_unpublished_registry_image(self):
        m = manifest_from(MAC)
        m["images"]["image_namespace"] = None
        m["images"]["registry"] = "ghcr.io/example"
        with self.assertRaises(RenderError) as ctx:
            mac_build(m)
        self.assertEqual(ctx.exception.code, "missing_required")
        self.assertEqual(ctx.exception.path, "images.refs.meeting-transcriber")


if __name__ == "__main__":
    unittest.main()
