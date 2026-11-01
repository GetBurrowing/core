"""One-click DigitalOcean droplet inputs (core task 01a10315 stage 1).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Covers the three manifest knobs a droplet needs and the bootstrap-admin
command:

- ``install.org_name``      -> core-platform's ROOT_ORG_NAME;
- ``host.ssh_authorized_key`` -> cloud-config ``ssh_authorized_keys``;
- ``[push] vapid``          -> bin/burrow-vapid + its ExecStartPre;
- ``bootstrap-admin``       -> pocket-id admin + a 0600 one-time link file.

The do-droplet golden itself is pinned by test_render.GoldenTest. Every knob
defaults off, and each test that checks a knob's effect first shows the
render WITHOUT it lacks that effect (positive control for the absence).
No test prints a key, a link or a code.
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
DO_DROPLET = os.path.join(RENDER_FIXTURES, "do-droplet.toml")
DO_AUTH = os.path.join(RENDER_FIXTURES, "do-droplet-registry-auth.json")
DO_MEETINGS = os.path.join(RENDER_FIXTURES, "do-droplet-meetings.toml")
DO_MEETINGS_CUSTOMER = os.path.join(RENDER_FIXTURES, "do-droplet-meetings-customer.env")
AGENTS_FULL = os.path.join(RENDER_FIXTURES, "single-host-agents-full.toml")
GOOD = os.path.join(HERE, "fixtures", "good.toml")
REPO = os.path.dirname(os.path.dirname(INSTALLER))
MAC = os.path.join(REPO, "deployment", "examples", "mac.install.toml")

sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from identity_terms import identity_hits
from setup_fakes import FakePocketId, write_secret_file

from burrow_install import registry, templates
from burrow_install.__main__ import main
from burrow_install.manifest import load
from burrow_install.render import build, plan, render
from burrow_install.setup import pocketid
from burrow_install.validate import validate

SSH_KEY = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f "
    "do-droplet-fixture"
)
VAPID_PRE = "ExecStartPre=/opt/burrow/bin/burrow-vapid"
# DigitalOcean caps a droplet's user_data at 64 KiB.
DO_USER_DATA_MAX = 65536


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError(f"manifest is invalid: {errors}")
    return normalized


def droplet():
    return build(valid(load(DO_DROPLET)), registry_auth=DO_AUTH)


def pairs(raw):
    errors, _ = validate(raw)
    return [(e.code, e.path) for e in errors]


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------


class DropletRenderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = droplet()
        cls.files = {rel: text for rel, (text, _mode) in cls.rendered.files.items()}
        cls.baseline = build(valid(load(AGENTS_FULL))).redacted()

    def test_00_positive_control_the_baseline_has_none_of_the_three(self):
        joined = "\n".join(self.baseline.values())
        for absent in ("ROOT_ORG_NAME", "burrow-vapid", "ssh_authorized_keys", '"openssl"'):
            self.assertNotIn(absent, joined)

    def test_root_org_name_is_a_plain_core_env_line(self):
        compose = self.files["compose.yaml"]
        self.assertIn('ROOT_ORG_NAME: "Acme Bakery"', compose)
        self.assertEqual(compose.count("ROOT_ORG_NAME"), 1)
        self.assertNotIn("ROOT_ORG_NAME", self.files["secrets.env"])
        core = compose.split("\n  core-platform:\n", 1)[1].split("\n  core-postgres:\n", 1)[0]
        self.assertIn("ROOT_ORG_NAME", core)

    def test_vapid_script_and_its_exec_start_pre_before_compose_up(self):
        user_data = self.files["user-data"]
        self.assertIn('path: "/opt/burrow/bin/burrow-vapid"', user_data)
        entry = user_data.split('path: "/opt/burrow/bin/burrow-vapid"', 1)[1]
        self.assertTrue(entry.lstrip().startswith('owner: "root:root"\n    permissions: "0755"'))
        unit = templates.stack_unit(plan(valid(load(DO_DROPLET))))
        lines = unit.splitlines()
        self.assertEqual(lines.count(VAPID_PRE), 1)
        self.assertLess(
            lines.index(VAPID_PRE),
            lines.index("ExecStart=/usr/bin/docker compose up -d --remove-orphans"),
        )
        self.assertIn('  - "openssl"\n', user_data)

    def test_ssh_authorized_keys_is_top_level_cloud_config(self):
        user_data = self.files["user-data"]
        self.assertIn(f"\nssh_authorized_keys:\n  - {json.dumps(SSH_KEY)}\n", user_data)
        self.assertNotIn("disable_root", user_data)

    def test_user_data_fits_digitaloceans_64_kib_cap(self):
        size = len(self.files["user-data"].encode("utf-8"))
        self.assertGreater(size, 1024)  # positive control: a real render was measured
        self.assertLess(size, DO_USER_DATA_MAX)

    def test_no_vapid_key_is_rendered(self):
        # The keys exist only on the host; the render carries the generator.
        for rel, text in self.files.items():
            with self.subTest(file=rel):
                self.assertNotIn("VAPID_PRIVATE_KEY=", text.replace("VAPID_PRIVATE_KEY=%s", ""))

    def test_fixture_and_render_carry_no_install_identity(self):
        with open(DO_DROPLET, encoding="utf-8") as handle:
            self.assertEqual(identity_hits(handle.read()), [])
        for rel, text in self.rendered.redacted().items():
            with self.subTest(file=rel):
                self.assertEqual(identity_hits(text), [])

    def test_fixture_is_agents_full_with_the_named_changes(self):
        base, drop = load(AGENTS_FULL), load(DO_DROPLET)
        self.assertEqual(drop["install"].pop("org_name"), "Acme Bakery")
        self.assertEqual(drop["host"].pop("ssh_authorized_key"), SSH_KEY)
        self.assertEqual(drop.pop("push"), {"vapid": "generate-on-host"})
        self.assertEqual(drop["domain"].pop("acme_email"), "owner@acme-bakery.test")
        self.assertEqual((base["domain"]["tls"], drop["domain"]["tls"]), ("internal", "acme"))
        drop["domain"]["tls"] = "internal"
        self.assertEqual(drop["images"]["source"], "registry")
        drop["images"]["source"] = base["images"]["source"]
        self.assertFalse(drop["services"]["voice"])
        self.assertEqual(drop["embeddings"].pop("model_source"), "download")
        # Task 01a18f76: the default s-2vcpu-4gb droplet is the "small" tier.
        self.assertEqual(
            (base["install"]["size_tier"], drop["install"]["size_tier"]), ("medium", "small")
        )
        drop["install"]["size_tier"] = base["install"]["size_tier"]
        self.assertEqual(base, drop)


# ---------------------------------------------------------------------------
# Meetings on the droplet (task 01a19505 stage 1)
# ---------------------------------------------------------------------------


def meetings_droplet():
    return build(
        valid(load(DO_MEETINGS)), registry_auth=DO_AUTH, customer_secrets=DO_MEETINGS_CUSTOMER
    )


def compose_blocks(compose):
    """{service name: its block of compose.yaml}, split on the 2-space service keys."""
    body = compose.split("\nservices:\n", 1)[1].split("\nvolumes:\n", 1)[0]
    parts = re.split(r"^  ([a-z][a-z0-9-]*):$", body, flags=re.MULTILINE)
    return dict(zip(parts[1::2], parts[2::2], strict=True))


def block_list(block, key):
    """The quoted items of the list under ``key`` in one compose service block."""
    match = re.search(rf"^    {key}:\n((?:      - .*\n)+)", block, re.MULTILINE)
    return [] if match is None else re.findall(r'^      - "(.*)"$', match.group(1), re.MULTILINE)


def all_ports(compose):
    return sorted(p for b in compose_blocks(compose).values() for p in block_list(b, "ports"))


def env_names(text):
    return sorted(
        line.split("=", 1)[0] for line in text.splitlines() if line and not line.startswith("#")
    )


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class DropletMeetingsRenderTest(unittest.TestCase):
    """services.meetings on single-host: rooms, media and transcription, no voice."""

    @classmethod
    def setUpClass(cls):
        cls.rendered = meetings_droplet()
        cls.files = {rel: text for rel, (text, _mode) in cls.rendered.files.items()}
        cls.base = {rel: text for rel, (text, _mode) in droplet().files.items()}
        cls.primary = load(DO_MEETINGS)["domain"]["primary"]

    def test_00_positive_control_the_pre_meetings_droplet_has_none_of_it(self):
        for absent in ("livekit", "LIVEKIT_", "meeting-transcriber", ":4080", "7881", "7882"):
            with self.subTest(absent=absent):
                self.assertFalse([r for r, t in self.base.items() if absent in t])

    def test_fixture_is_do_droplet_plus_meetings_only(self):
        base, meet = load(DO_DROPLET), load(DO_MEETINGS)
        self.assertIs(meet["services"].pop("meetings"), True)
        self.assertEqual(
            meet.pop("meetings"),
            {
                "media_reach": "public",
                "transcription": True,
                "stt_endpoint": "openai-stt",
                "stt_model": "whisper-1",
            },
        )
        self.assertEqual(
            meet.pop("models"),
            {
                "endpoints": [
                    {
                        "name": "openai-stt",
                        "kind": "hosted",
                        "base_url": "https://api.openai.com/v1",
                        "api_key_ref": "OPENAI_STT_API_KEY",
                    }
                ]
            },
        )
        self.assertEqual(
            meet["images"].pop("refs"),
            {"meeting-transcriber": "ghcr.io/example/meeting-transcriber:v1.0.0"},
        )
        self.assertEqual(base, meet)

    def test_livekit_and_transcriber_are_rendered(self):
        services = self.files["services.txt"].split()
        self.assertEqual(
            sorted(set(services) - set(self.base["services.txt"].split())),
            ["livekit", "meeting-transcriber"],
        )
        blocks = compose_blocks(self.files["compose.yaml"])
        self.assertEqual(sorted(blocks), services)
        self.assertIn('image: "docker.io/livekit/livekit-server:v1.13"', blocks["livekit"])
        self.assertIn("./livekit.yaml:/etc/livekit.yaml:ro", blocks["livekit"])
        self.assertIn("use_external_ip: true", self.files["livekit.yaml"])
        self.assertNotIn("node_ip", self.files["livekit.yaml"])
        transcriber = blocks["meeting-transcriber"]
        self.assertIn('image: "ghcr.io/example/meeting-transcriber:v1.0.0"', transcriber)
        self.assertIn('LIVEKIT_URL: "ws://livekit:7880"', transcriber)
        self.assertIn('STT_BASE_URL: "https://api.openai.com/v1"', transcriber)
        self.assertIn('STT_MODEL: "whisper-1"', transcriber)
        # PERSIST_URL and LiveKit's webhook reach core without leaving the
        # host: Caddy's internal listener, published on no host port.
        self.assertEqual(registry.CORE_INTERNAL_URL, "http://caddy:4080")
        self.assertIn('PERSIST_URL: "http://caddy:4080/api/meetings/segments"', transcriber)
        self.assertIn('"http://caddy:4080/api/webhooks/livekit"', self.files["livekit.yaml"])
        self.assertIn(
            "\nhttp://:4080 {\n\treverse_proxy core-platform:4000 {\n"
            "\t\theader_up X-Forwarded-Proto https\n\t}\n}\n",
            self.files["Caddyfile"],
        )
        self.assertEqual(block_list(blocks["caddy"], "ports"), ["80:80", "443:443"])
        self.assertEqual(
            env_names(self.files["secrets.env"]).count("STT_API_KEY"), 1
        )  # {customer:OPENAI_STT_API_KEY}, never in compose
        self.assertNotIn("STT_API_KEY", self.files["compose.yaml"])

    def test_media_ports_published_7881_tcp_7882_udp_and_nothing_else_new(self):
        before, after = all_ports(self.base["compose.yaml"]), all_ports(self.files["compose.yaml"])
        self.assertGreater(len(before), 0)  # positive control: the parser finds caddy's
        added = list(after)
        for port in before:
            added.remove(port)
        self.assertEqual(sorted(added), ["7881:7881/tcp", "7882:7882/udp"])
        livekit = compose_blocks(self.files["compose.yaml"])["livekit"]
        self.assertEqual(block_list(livekit, "ports"), ["7881:7881/tcp", "7882:7882/udp"])
        # Signalling (7880) stays behind Caddy; no host publishes it.
        self.assertFalse([p for p in after if "7880" in p])

    def test_caddy_routes_livekit_host_to_7880(self):
        host = f"livekit.{self.primary}"
        self.assertIn(f"\n{host} {{\n\treverse_proxy livekit:7880\n}}\n", self.files["Caddyfile"])
        caddy = compose_blocks(self.files["compose.yaml"])["caddy"]
        self.assertIn(f'          - "{host}"\n', caddy)  # the in-stack alias
        self.assertNotIn(host, self.base["Caddyfile"])

    def test_core_env_has_livekit_url_key_and_secret_only_via_secrets_env(self):
        core = compose_blocks(self.files["compose.yaml"])["core-platform"]
        self.assertIn(f'LIVEKIT_URL: "wss://livekit.{self.primary}"', core)
        self.assertIn('LIVEKIT_API_KEY: "suite"', core)
        self.assertEqual(block_list(core, "env_file"), ["secrets.env"])
        for text in (self.files["compose.yaml"], self.files["Caddyfile"]):
            self.assertNotIn("LIVEKIT_API_SECRET", text)
        names = env_names(self.files["secrets.env"])
        for name in ("LIVEKIT_API_SECRET", "LIVEKIT_KEYS", "MEETING_AGENT_TOKEN"):
            self.assertEqual(names.count(name), 1, name)
        value = self.rendered.generated["LIVEKIT_API_SECRET"]
        self.assertGreaterEqual(len(value), 32)
        hits = sorted(r for r, t in self.files.items() if value in t)
        self.assertEqual(hits, ["secrets.env", "user-data"])  # user-data carries secrets.env

    def test_livekit_secret_differs_between_two_renders(self):
        first, second = meetings_droplet(), meetings_droplet()
        for name in ("LIVEKIT_API_SECRET", "MEETING_AGENT_TOKEN"):
            with self.subTest(secret=name):
                self.assertNotEqual(digest(first.generated[name]), digest(second.generated[name]))

        def keys_line(rendered):
            env = rendered.files["secrets.env"][0]
            return next(line for line in env.splitlines() if line.startswith("LIVEKIT_KEYS="))

        self.assertNotEqual(digest(keys_line(first)), digest(keys_line(second)))

    def test_reuse_secrets_from_a_pre_meetings_install_keeps_every_old_value_and_adds_livekit(
        self,
    ):
        tmp = tempfile.mkdtemp(prefix="burrow-install-01a19505-")
        self.addCleanup(shutil.rmtree, tmp, True)
        from burrow_install.render import inside_git_worktree

        if inside_git_worktree(tmp):
            self.skipTest(f"the temp dir {tmp} is inside a git work tree")
        out = os.path.join(tmp, "pre-meetings")
        old = render(valid(load(DO_DROPLET)), out, registry_auth=DO_AUTH).generated
        new = build(
            valid(load(DO_MEETINGS)),
            registry_auth=DO_AUTH,
            customer_secrets=DO_MEETINGS_CUSTOMER,
            reuse_secrets=os.path.join(out, "secrets.env"),
        ).generated
        self.assertGreaterEqual(len(old), 11)  # positive control: a real install's set
        self.assertEqual(sorted(set(old) - set(new)), [])
        self.assertEqual(sorted(set(new) - set(old)), ["LIVEKIT_API_SECRET", "MEETING_AGENT_TOKEN"])
        changed = sorted(n for n in old if digest(old[n]) != digest(new[n]))
        self.assertEqual(changed, [])

    def test_turn_stays_off_with_reason(self):
        text = self.files["livekit.yaml"]
        self.assertIn("\nturn:\n  enabled: false\nwebhook:\n", text)
        reason = "\n".join(f"# {line}" for line in registry.TURN_OFF_REASON)
        self.assertIn(reason + "\nturn:\n", text)
        joined = " ".join(registry.TURN_OFF_REASON)
        for needle in ("UDP 7882", "ICE-TCP on 7881", "443", "SNI", "follow-up"):
            self.assertIn(needle, joined)

    def test_no_voice_worker_or_speaches_rendered(self):
        raw = load(DO_MEETINGS)
        raw["services"]["voice"] = True
        raw["voice"]["accelerator"] = "cpu"
        voiced = build(valid(raw), registry_auth=DO_AUTH, customer_secrets=DO_MEETINGS_CUSTOMER)
        self.assertIn("speaches", voiced.files["compose.yaml"][0])  # positive control
        for rel, text in self.files.items():
            for absent in ("speaches", "voice-worker", "burrow-voice", "TTS_"):
                with self.subTest(file=rel, absent=absent):
                    self.assertNotIn(absent, text)

    def test_files_service_gets_no_stt_base_url(self):
        # files-service reads STT_API_KEY from env (files-service app/stt.py:89,
        # origin/main 30eb7dd2) and the shared secrets.env carries the
        # transcriber's STT_API_KEY. Its transcription is gated on STT_BASE_URL
        # (app/stt.py:83), which only speaches (voice) injects, so with voice off
        # files-service never sends audio to the hosted key.
        blocks = compose_blocks(self.files["compose.yaml"])
        self.assertIn("STT_BASE_URL", blocks["meeting-transcriber"])  # positive control
        self.assertNotIn("STT_BASE_URL", blocks["files-service"])
        self.assertNotIn("STT_BASE_URL", env_names(self.files["secrets.env"]))
        self.assertIn("STT_API_KEY", env_names(self.files["secrets.env"]))

    def test_user_data_fits_digitaloceans_64_kib_cap(self):
        size = len(self.files["user-data"].encode("utf-8"))
        self.assertGreater(size, len(self.base["user-data"].encode("utf-8")))
        self.assertLess(size, DO_USER_DATA_MAX)

    def test_fixture_and_render_carry_no_install_identity(self):
        with open(DO_MEETINGS, encoding="utf-8") as handle:
            self.assertEqual(identity_hits(handle.read()), [])
        for rel, text in self.rendered.redacted().items():
            with self.subTest(file=rel):
                self.assertEqual(identity_hits(text), [])


class PublicImagesTest(unittest.TestCase):
    """images.public: source = "registry" without --registry-auth (task 01a10315 stage 2)."""

    def raw(self, public):
        raw = load(DO_DROPLET)
        if public is not None:
            raw["images"]["public"] = public
        return raw

    def test_private_default_still_needs_a_registry_auth(self):
        from burrow_install.render import RenderError

        for public in (None, False):
            with self.subTest(public=public), self.assertRaises(RenderError) as ctx:
                build(valid(self.raw(public)))
            self.assertEqual(ctx.exception.code, "registry_auth_required")

    def test_public_renders_with_no_auth_and_writes_no_docker_config(self):
        rendered = build(valid(self.raw(True)))
        self.assertNotIn("registry-auth.json", rendered.files)
        self.assertNotIn("/root/.docker/config.json", rendered.files["user-data"][0])
        self.assertIn('image: "ghcr.io/example/core:core"', rendered.files["compose.yaml"][0])
        self.assertNotIn("pull_policy", rendered.files["compose.yaml"][0])

    def test_public_with_an_auth_still_writes_it(self):
        rendered = build(valid(self.raw(True)), registry_auth=DO_AUTH)
        self.assertIn("/root/.docker/config.json", rendered.files["user-data"][0])

    def test_public_must_be_a_bool(self):
        self.assertEqual(pairs(self.raw("yes")), [("invalid_type", "images.public")])


class KnobIsolationTest(unittest.TestCase):
    """Each knob alone changes only the files it must; off changes nothing."""

    def render(self, mutate=None):
        raw = load(AGENTS_FULL)
        if mutate:
            mutate(raw)
        return build(valid(raw)).redacted()

    def changed(self, mutate):
        before, after = self.render(), self.render(mutate)
        self.assertEqual(sorted(before), sorted(after))
        return sorted(rel for rel in before if before[rel] != after[rel])

    def test_00_positive_control_two_renders_are_equal_once_redacted(self):
        self.assertEqual(self.changed(lambda raw: None), [])

    def test_explicit_defaults_render_byte_identical(self):
        def defaults(raw):
            raw["push"] = {"vapid": "off"}

        self.assertEqual(self.changed(defaults), [])

    def test_org_name_touches_compose_and_its_user_data_copy_only(self):
        def org(raw):
            raw["install"]["org_name"] = "Acme Bakery"

        self.assertEqual(self.changed(org), ["compose.yaml", "user-data"])

    def test_ssh_key_touches_user_data_only(self):
        def key(raw):
            raw["host"]["ssh_authorized_key"] = SSH_KEY

        self.assertEqual(self.changed(key), ["user-data"])

    def test_vapid_touches_user_data_only(self):
        def vapid(raw):
            raw["push"] = {"vapid": "generate-on-host"}

        self.assertEqual(self.changed(vapid), ["user-data"])

    def test_model_download_touches_user_data_only_and_operator_is_the_default(self):
        def download(raw):
            raw["embeddings"]["model_source"] = "download"

        def operator(raw):
            raw["embeddings"]["model_source"] = "operator"

        self.assertEqual(self.changed(operator), [])
        self.assertEqual(self.changed(download), ["user-data"])


# ---------------------------------------------------------------------------
# Validation (the one-field fixtures are in test_validate / test_mac_validate)
# ---------------------------------------------------------------------------


class DropletValidateTest(unittest.TestCase):
    def setUp(self):
        self.assertEqual(pairs(load(GOOD)), [])  # positive control

    def with_org(self, value):
        raw = load(GOOD)
        raw["install"]["org_name"] = value
        return pairs(raw)

    def with_key(self, value):
        raw = load(GOOD)
        raw["host"]["ssh_authorized_key"] = value
        return pairs(raw)

    def test_org_name_shapes(self):
        bad = [("invalid_org_name", "install.org_name")]
        for value in ("Acme Bakery", "A", "x" * 80, "Bäckerei & Söhne", "O'Brien (UK) Ltd."):
            with self.subTest(value=value):
                self.assertEqual(self.with_org(value), [])
        for value in ("", "x" * 81, "a\nb", "a\tb", 'say "hi"', "a$b", "a`b`", " lead", "trail "):
            with self.subTest(value=value):
                self.assertEqual(self.with_org(value), bad)
        self.assertEqual(self.with_org(7), [("invalid_type", "install.org_name")])

    def test_ssh_key_shapes(self):
        bad = [("invalid_ssh_authorized_key", "host.ssh_authorized_key")]
        for value in (
            SSH_KEY,
            SSH_KEY.rsplit(" ", 1)[0],
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= me@laptop",
            "ssh-ed25519 AAAA= a comment with spaces",
        ):
            with self.subTest(value=value):
                self.assertEqual(self.with_key(value), [])
        for value in (
            "ssh-rsa AAAAB3NzaC1yc2E= me",
            "ssh-dss AAAA",
            "ssh-ed25519",
            "ssh-ed25519 ",
            "ssh-ed25519 AAAA!",
            SSH_KEY + "\nssh-ed25519 AAAA second",
            SSH_KEY + "\n",
            " " + SSH_KEY,
        ):
            with self.subTest(value=value):
                self.assertEqual(self.with_key(value), bad)

    def test_vapid_on_single_host_is_valid_and_defaults_off(self):
        _e, normalized = validate(load(GOOD))
        self.assertEqual(normalized["push"]["vapid"], "off")
        self.assertIsNone(normalized["install"]["org_name"])
        self.assertIsNone(normalized["host"]["ssh_authorized_key"])
        raw = load(GOOD)
        raw["push"] = {"vapid": "generate-on-host"}
        self.assertEqual(pairs(raw), [])
        raw["push"] = {"vapid": "on"}
        self.assertEqual(pairs(raw), [("invalid_enum", "push.vapid")])

    def test_mac_refuses_vapid_and_the_ssh_key(self):
        self.assertEqual(pairs(load(MAC)), [])  # positive control
        raw = load(MAC)
        raw["push"] = {"vapid": "generate-on-host"}
        self.assertEqual(pairs(raw), [("vapid_requires_single_host", "push.vapid")])
        raw = load(MAC)
        raw["push"] = {"vapid": "off"}
        self.assertEqual(pairs(raw), [])
        raw.setdefault("host", {})["ssh_authorized_key"] = SSH_KEY
        self.assertEqual(pairs(raw), [("field_not_applicable", "host.ssh_authorized_key")])

    def test_mac_org_name_reaches_core(self):
        raw = load(MAC)
        raw["install"]["org_name"] = "Acme Bakery"
        env = plan(valid(raw)).services["core-platform"].env
        self.assertEqual(env["ROOT_ORG_NAME"], "Acme Bakery")


# ---------------------------------------------------------------------------
# bin/burrow-vapid, run for real
# ---------------------------------------------------------------------------

# NIST P-256 (FIPS 186-4 D.1.2.3), to check the public point IS the scalar's.
_P = 2**256 - 2**224 + 2**192 + 2**96 - 1
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % _P == 0:
        return None
    if p1 == p2:
        slope = (3 * x1 * x1 - 3) * pow(2 * y1, -1, _P) % _P
    else:
        slope = (y2 - y1) * pow(x2 - x1, -1, _P) % _P
    x3 = (slope * slope - x1 - x2) % _P
    return x3, (slope * (x1 - x3) - y1) % _P


def p256_public(scalar):
    result, addend = None, _G
    while scalar:
        if scalar & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        scalar >>= 1
    return result


def b64url_decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def env_lines(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().splitlines()


@unittest.skipUnless(
    shutil.which("openssl"), "openssl is not on PATH; bin/burrow-vapid cannot run here"
)
class VapidScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="burrow-vapid-01a10315-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.script = os.path.join(self.tmp, "burrow-vapid")
        with open(self.script, "w", encoding="utf-8") as handle:
            handle.write(templates.vapid_script(plan(valid(load(DO_DROPLET)))))
        self.secrets = write_secret_file(self.tmp, "secrets.env", "# header\nSECRET_KEY_BASE=x")

    def run_script(self, path=None):
        return subprocess.run(
            ["sh", self.script, path or self.secrets],
            capture_output=True,
            text=True,
            check=False,
        )

    def keys(self):
        lines = env_lines(self.secrets)
        return dict(line.split("=", 1) for line in lines if line.startswith("VAPID_"))

    def test_p256_helper_positive_control(self):
        # 1*G is G, and n*G is the point at infinity.
        self.assertEqual(p256_public(1), _G)
        self.assertIsNone(p256_public(_N))

    def test_first_run_appends_one_valid_key_pair(self):
        before = env_lines(self.secrets)
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")
        after = env_lines(self.secrets)
        self.assertEqual(after[: len(before)], before)
        self.assertEqual(
            [line.split("=", 1)[0] for line in after[len(before) :]],
            ["VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY"],
        )
        keys = self.keys()
        for value in keys.values():
            self.assertRegex(value, r"^[A-Za-z0-9_-]+$")  # base64url, no padding
        public = b64url_decode(keys["VAPID_PUBLIC_KEY"])
        private = b64url_decode(keys["VAPID_PRIVATE_KEY"])
        self.assertEqual(len(private), 32)
        self.assertEqual(len(public), 65)
        self.assertEqual(public[0], 0x04)
        scalar = int.from_bytes(private, "big")
        self.assertTrue(0 < scalar < _N)
        point = (int.from_bytes(public[1:33], "big"), int.from_bytes(public[33:], "big"))
        self.assertTrue(p256_public(scalar) == point, "public point is not the scalar's")

    def test_second_run_changes_nothing_and_mode_stays_0600(self):
        self.assertEqual(self.run_script().returncode, 0)
        with open(self.secrets, "rb") as handle:
            first = handle.read()
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(self.secrets, "rb") as handle:
            self.assertTrue(handle.read() == first, "second run changed secrets.env")
        self.assertEqual(stat.S_IMODE(os.stat(self.secrets).st_mode), 0o600)

    def test_two_hosts_get_different_keys(self):
        other = write_secret_file(self.tmp, "other.env", "# header")
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(other).returncode, 0)
        mine = self.keys()["VAPID_PRIVATE_KEY"]
        pairs_ = (line.split("=", 1) for line in env_lines(other) if line.startswith("VAPID_"))
        theirs = dict(pairs_)["VAPID_PRIVATE_KEY"]
        self.assertTrue(mine != theirs)

    def test_missing_secrets_env_fails_and_creates_nothing(self):
        missing = os.path.join(self.tmp, "absent.env")
        proc = self.run_script(missing)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(os.path.exists(missing))


# ---------------------------------------------------------------------------
# bootstrap-admin
# ---------------------------------------------------------------------------

API_KEY = "static-api-key-01a10315-fake-0123456789"
EMAIL = "owner@acme-bakery.test"


def run_main(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue(), err.getvalue()


def closed_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class BootstrapAdminTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="burrow-bootstrap-01a10315-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fake = FakePocketId(API_KEY)
        self.addCleanup(self.fake.close)
        self.key_file = write_secret_file(self.tmp, "api-key", API_KEY)
        self.link_file = os.path.join(self.tmp, "login-link")

    def bootstrap(self, *extra, base=None, key_file=None):
        return run_main(
            "bootstrap-admin",
            "--base",
            base or self.fake.url,
            "--api-key-file",
            key_file or self.key_file,
            "--email",
            EMAIL,
            "--link-file",
            self.link_file,
            *extra,
        )

    def secret_hits(self, text):
        """Every credential (minted codes, the API key) found in ``text``."""
        return [s for s in [API_KEY, *self.fake.tokens] if s in text]

    def read_link(self):
        with open(self.link_file, encoding="utf-8") as handle:
            return handle.read()

    def test_created_then_exists_with_a_fresh_0600_link_each_time(self):
        code, out, err = self.bootstrap()
        self.assertEqual(code, 0, out)
        doc = json.loads(out)
        self.assertEqual(
            (doc["ok"], doc["admin"], doc["link_file"]), (True, "created", self.link_file)
        )
        self.assertEqual(len(out.splitlines()), 1)
        self.assertEqual(stat.S_IMODE(os.stat(self.link_file).st_mode), 0o600)
        first = self.read_link()
        token = self.fake.tokens[-1]
        host = self.fake.url.removeprefix("http://")
        self.assertEqual(first, f"https://{host}/lc/{token}?redirect=%2Fsettings%2Faccount\n")
        # LOGIN_TTL > 15m: pocket-id mints the 12-character code /lc/ auto-submits.
        self.assertEqual(len(token), 12)
        # Positive control for the hygiene grep: it finds the code in the link file.
        self.assertEqual(self.secret_hits(first), [token])
        self.assertEqual(self.secret_hits(out + err), [])

        code, out2, err2 = self.bootstrap()
        self.assertEqual(code, 0, out2)
        self.assertEqual(json.loads(out2)["admin"], "exists")
        admins = [u for u in self.fake.users if u.get("email") == EMAIL]
        self.assertEqual(len(admins), 1)
        self.assertEqual(self.fake.count("POST"), 3)  # one user + two codes
        second = self.read_link()
        self.assertNotEqual(first, second)
        self.assertIn(self.fake.tokens[-1], second)
        self.assertEqual(stat.S_IMODE(os.stat(self.link_file).st_mode), 0o600)
        self.assertEqual(self.secret_hits(out2 + err2), [])
        self.assertEqual(sorted(os.listdir(self.tmp)), ["api-key", "login-link"])

    def test_username_defaults_from_the_email_and_can_be_set(self):
        code, out, _err = self.bootstrap("--username", "owner2")
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads(out)["admin_username"], "owner2")
        self.assertEqual(self.fake.users[-1]["username"], "owner2")
        self.assertTrue(self.fake.users[-1]["isAdmin"])
        self.assertEqual(pocketid.default_username(EMAIL), "owner")

    def test_unreachable_is_exit_1_with_its_kind(self):
        code, out, err = self.bootstrap(base=f"http://127.0.0.1:{closed_port()}")
        self.assertEqual(code, 1)
        doc = json.loads(out)
        self.assertEqual(
            (doc["ok"], doc["error"], doc["kind"]),
            (False, "pocketid_unreachable", "connection_refused"),
        )
        self.assertFalse(os.path.exists(self.link_file))
        self.assertEqual(self.secret_hits(out + err), [])

    def test_a_refused_key_is_exit_1_and_never_echoed(self):
        wrong = write_secret_file(self.tmp, "wrong", "wrong-key-01a10315-not-the-static-key")
        code, out, err = self.bootstrap(key_file=wrong)
        self.assertEqual(code, 1)
        doc = json.loads(out)
        self.assertEqual((doc["error"], doc["kind"]), ("pocketid_auth_failed", "http"))
        self.assertNotIn("wrong-key-01a10315", out + err)
        self.assertFalse(os.path.exists(self.link_file))

    def test_usage_errors_are_exit_2_and_call_nothing(self):
        loose = write_secret_file(self.tmp, "loose", API_KEY, mode=0o644)
        cases = {
            "api_key_file_mode": self.bootstrap(key_file=loose),
            "unreadable_api_key_file": self.bootstrap(key_file=os.path.join(self.tmp, "none")),
            "invalid_base": self.bootstrap(base="http://auth.acme-bakery.test"),
            "usage": run_main("bootstrap-admin", "--base", self.fake.url),
        }
        for error, (code, out, err) in cases.items():
            with self.subTest(error=error):
                self.assertEqual(code, 2, out)
                doc = json.loads(out)
                self.assertEqual((doc["ok"], doc["error"], doc["kind"]), (False, error, "usage"))
                self.assertEqual(self.secret_hits(out + err), [])
        self.assertEqual(self.fake.requests, [])
        self.assertFalse(os.path.exists(self.link_file))

    def test_registers_cores_oidc_client_once_with_the_render_secret(self):
        secret = "oidc-client-secret-01a10315-fake-abcdef"
        secret_file = write_secret_file(self.tmp, "oidc", secret)
        flags = ("--primary", "acme.example.test", "--oidc-secret-file", secret_file)
        code, out, err = self.bootstrap(*flags)
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads(out)["oidc_client"], "created")
        client = self.fake.clients[pocketid.CLIENT_ID]
        self.assertEqual(client["callbackURLs"], ["https://acme.example.test/auth/oidc/callback"])
        self.assertTrue(client["pkceEnabled"])
        # Stage 6 round 2: the install's own app, so no consent click, and
        # pocket-id's app tile opens Burrow.
        self.assertIs(client["skipConsent"], True)
        self.assertEqual(client["launchURL"], "https://acme.example.test")
        # pocket-id's auto-created secret is dropped; ours is the only one.
        listed = self.fake.secrets[pocketid.CLIENT_ID]
        self.assertEqual([s["secret"] == secret for s in listed], [True])

        code, out2, err2 = self.bootstrap(*flags)
        self.assertEqual(code, 0, out2)
        self.assertEqual(json.loads(out2)["oidc_client"], "exists")
        self.assertEqual(len(self.fake.secrets[pocketid.CLIENT_ID]), 1)
        for text in (out, err, out2, err2):
            self.assertNotIn(secret, text)
            self.assertEqual(self.secret_hits(text), [])

    def test_oidc_secret_needs_primary(self):
        secret_file = write_secret_file(self.tmp, "oidc", "oidc-secret-01a10315-fake")
        code, out, _err = self.bootstrap("--oidc-secret-file", secret_file)
        self.assertEqual(code, 2, out)
        self.assertEqual(json.loads(out)["error"], "usage")
        self.assertEqual(self.fake.requests, [])

    def test_with_primary_the_link_is_cores_handover_route(self):
        # Stage 6 round 2: the owner lands back in Burrow, not on pocket-id's
        # settings page. --primary alone (a hand-over re-mint) registers nothing.
        code, out, err = self.bootstrap("--primary", "acme.example.test")
        self.assertEqual(code, 0, out)
        token = self.fake.tokens[-1]
        self.assertEqual(len(token), 12)
        self.assertEqual(
            self.read_link(), f"https://acme.example.test/auth/handover?code={token}\n"
        )
        self.assertNotIn("oidc_client", json.loads(out))
        self.assertEqual(self.fake.clients, {})
        self.assertEqual(self.secret_hits(out + err), [])

    def test_an_existing_client_without_skip_consent_is_updated(self):
        secret = "oidc-client-secret-01a10315-fake-abcdef"
        secret_file = write_secret_file(self.tmp, "oidc", secret)
        flags = ("--primary", "acme.example.test", "--oidc-secret-file", secret_file)
        self.assertEqual(self.bootstrap(*flags)[0], 0)
        client = self.fake.clients[pocketid.CLIENT_ID]
        client.update(skipConsent=False, description="kept")
        code, out, _err = self.bootstrap(*flags)
        self.assertEqual(code, 0, out)
        self.assertIs(client["skipConsent"], True)
        self.assertEqual(client["description"], "kept")

    def test_runs_as_the_documented_module_command(self):
        env = dict(os.environ, PYTHONPATH=INSTALLER)
        proc = subprocess.run(
            [sys.executable, "-m", "burrow_install", "bootstrap-admin", "--base", self.fake.url]
            + ["--api-key-file", self.key_file, "--email", EMAIL]
            + ["--link-file", self.link_file],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertTrue(json.loads(proc.stdout)["ok"])
        self.assertEqual(self.secret_hits(proc.stdout + proc.stderr), [])


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Stage 6: the embeddings model is fetched on the host; keys-only root login
# ---------------------------------------------------------------------------


MODEL_URL = (
    "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/"
    "370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-f16.gguf"
)
MODEL_SHA = "421a27e58d165478cc7acb984a688c2aa41404968b0203e7cd743ece44c54340"
# The droplet's 4 GB profile runs the Q8_0 file of the same revision (core task
# 01a18f76, registry.EMBEDDINGS_PROFILES "small"; the fixture's tier has no
# measured row of its own and falls back to it).
DROPLET_MODEL_FILE = "Qwen3-Embedding-0.6B-Q8_0.gguf"
DROPLET_MODEL_URL = (
    "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/"
    "370f27d7550e0def9b39c1f16d3fbaa13aa67728/" + DROPLET_MODEL_FILE
)
DROPLET_MODEL_SHA = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"


def _write_files(user_data):
    """{path: content} of the user-data's write_files (the literal blocks)."""
    out = {}
    parts = user_data.split('\n  - path: "')[1:]
    for part in parts:
        path = part.split('"', 1)[0]
        body = part.split("content: |\n", 1)[1]
        lines = []
        for line in body.split("\n"):
            if line.startswith("      ") or line == "":
                lines.append(line[6:])
            else:
                break
        out[path] = "\n".join(lines).rstrip("\n") + "\n"
    return out


class ModelDownloadTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.user_data = droplet().files["user-data"][0]
        cls.files = _write_files(cls.user_data)

    def test_00_positive_control_the_operator_default_fetches_nothing(self):
        baseline = build(valid(load(AGENTS_FULL))).files["user-data"][0]
        self.assertIn("ExecStartPre=/usr/bin/test -s /opt/burrow/models/", baseline)
        self.assertNotIn("burrow-model.service", baseline)
        self.assertNotIn("huggingface.co", baseline)

    def test_the_source_is_pinned_to_a_revision_and_a_sha256(self):
        src = registry.EMBEDDINGS_MODEL_SOURCE
        self.assertEqual(src["url"], MODEL_URL)
        self.assertEqual(src["sha256"], MODEL_SHA)
        self.assertIn(src["revision"], src["url"])
        self.assertNotIn("/main/", src["url"])

    def test_the_fetch_script_carries_the_pinned_url_and_sha(self):
        script = self.files["/opt/burrow/bin/burrow-fetch-model"]
        self.assertIn(f"url={DROPLET_MODEL_URL}\n", script)
        self.assertIn(f"sha={DROPLET_MODEL_SHA}\n", script)
        self.assertIn(f"dest=/opt/burrow/models/{DROPLET_MODEL_FILE}\n", script)
        entry = self.user_data.split('path: "/opt/burrow/bin/burrow-fetch-model"', 1)[1]
        self.assertTrue(entry.lstrip().startswith('owner: "root:root"\n    permissions: "0755"'))

    def test_the_fetch_unit_runs_before_the_stack_and_the_stack_requires_it(self):
        unit = self.files["/etc/systemd/system/burrow-model.service"]
        self.assertIn("Before=burrow-stack.service\n", unit)
        self.assertIn("After=network-online.target\n", unit)
        self.assertIn("ExecStart=/opt/burrow/bin/burrow-fetch-model\n", unit)
        self.assertIn("Type=oneshot\n", unit)
        stack = self.files["/etc/systemd/system/burrow-stack.service"]
        self.assertIn("Requires=burrow-model.service\n", stack)
        self.assertIn("After=burrow-model.service\n", stack)
        # The gate stays: a missing or empty model still fails the stack loudly.
        self.assertIn(
            f"ExecStartPre=/usr/bin/test -s /opt/burrow/models/{DROPLET_MODEL_FILE}\n",
            stack,
        )
        self.assertIn('  - "curl"\n', self.user_data)

    def test_download_needs_single_host_and_local_embeddings(self):
        raw = load(DO_DROPLET)
        raw["embeddings"] = {
            "mode": "endpoint",
            "base_url": "https://embeddings.example.test/v1",
            "model_source": "download",
        }
        self.assertIn(("field_not_applicable", "embeddings.model_source"), pairs(raw))
        raw = load(DO_DROPLET)
        raw["embeddings"]["model_source"] = "somewhere"
        self.assertTrue(any(path == "embeddings.model_source" for _code, path in pairs(raw)))


class RootKeyLoginTest(unittest.TestCase):
    def test_keys_only_and_no_expired_password_with_a_key(self):
        user_data = droplet().files["user-data"][0]
        self.assertIn("\nchpasswd:\n  expire: false\n", user_data)
        self.assertIn("\nssh_pwauth: false\n", user_data)

    def test_positive_control_without_a_key_neither_is_rendered(self):
        baseline = build(valid(load(AGENTS_FULL))).files["user-data"][0]
        self.assertNotIn("chpasswd", baseline)
        self.assertNotIn("ssh_pwauth", baseline)


class FetchModelScriptTest(unittest.TestCase):
    """bin/burrow-fetch-model run for real against a stub curl (no network)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.dest = os.path.join(self.tmp, "models", "model.gguf")
        self.good = b"the pinned model bytes\n"
        import hashlib

        self.sha = hashlib.sha256(self.good).hexdigest()
        self.log = os.path.join(self.tmp, "curl.log")
        # Stub curl: answer N bad downloads, then the good bytes.
        with open(os.path.join(self.bin, "curl"), "w", encoding="utf-8") as handle:
            handle.write(
                "#!/bin/sh\n"
                'out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done\n'
                f"n=$(cat {self.tmp}/bad 2>/dev/null || echo 0)\n"
                f"echo call >> {self.log}\n"
                f'if [ "$n" -gt 0 ]; then echo $((n-1)) > {self.tmp}/bad; printf corrupt > "$out"; exit 0; fi\n'
                f'cp {self.tmp}/good "$out"\n'
            )
        with open(os.path.join(self.bin, "sleep"), "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        for name in ("curl", "sleep"):
            os.chmod(os.path.join(self.bin, name), 0o755)
        with open(os.path.join(self.tmp, "good"), "wb") as handle:
            handle.write(self.good)
        script = templates.fetch_model_script(plan(valid(load(DO_DROPLET))))
        script = script.replace(
            f"dest=/opt/burrow/models/{DROPLET_MODEL_FILE}", f"dest={self.dest}"
        ).replace(f"sha={DROPLET_MODEL_SHA}", f"sha={self.sha}")
        self.script = os.path.join(self.tmp, "fetch")
        with open(self.script, "w", encoding="utf-8") as handle:
            handle.write(script)
        os.chmod(self.script, 0o755)

    def run_script(self, bad=0):
        with open(os.path.join(self.tmp, "bad"), "w", encoding="utf-8") as handle:
            handle.write(str(bad))
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ.get("PATH", ""))
        return subprocess.run([self.script], check=False, env=env, capture_output=True, text=True)

    def calls(self):
        if not os.path.exists(self.log):
            return 0
        with open(self.log, encoding="utf-8") as handle:
            return len(handle.read().split())

    def test_downloads_verifies_and_is_idempotent(self):
        if shutil.which("sha256sum") is None:
            self.skipTest("sha256sum is not on PATH")
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        with open(self.dest, "rb") as handle:
            self.assertEqual(handle.read(), self.good)
        self.assertEqual(stat.S_IMODE(os.stat(self.dest).st_mode), 0o644)
        self.assertEqual(self.calls(), 1)
        again = self.run_script()
        self.assertEqual(again.returncode, 0)
        self.assertEqual(self.calls(), 1)  # a verified file is kept, not re-fetched

    def test_a_corrupt_download_is_retried_and_never_moved_into_place(self):
        if shutil.which("sha256sum") is None:
            self.skipTest("sha256sum is not on PATH")
        result = self.run_script(bad=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 3)
        self.assertIn("attempt 1 failed", result.stderr)
        with open(self.dest, "rb") as handle:
            self.assertEqual(handle.read(), self.good)

    def test_five_failures_exit_1_and_leave_no_file(self):
        if shutil.which("sha256sum") is None:
            self.skipTest("sha256sum is not on PATH")
        result = self.run_script(bad=99)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), 5)
        self.assertFalse(os.path.exists(self.dest))
        self.assertFalse(os.path.exists(self.dest + ".part"))
        self.assertIn("giving up", result.stderr)
