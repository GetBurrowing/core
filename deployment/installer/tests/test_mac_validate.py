"""Validator tests for install.target = "mac" (task 01a0d6ab stage 3).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Design (mirrors test_validate.py):
- Every class validates BOTH shipped mac examples first (positive control), so
  a validator that rejects everything fails loudly instead of passing every
  negative case.
- One fixture per mac code under tests/fixtures/mac/, each the mac example with
  exactly ONE field changed (checked mechanically), asserting exactly that code.
- The task-level review's cases (a)-(e), which vary mac-lite, are asserted
  with their exact code and path.
- `services` output is compared with hard-coded literal lists.
"""

import contextlib
import difflib
import io
import os
import sys
import tomllib
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLES = os.path.join(REPO, "deployment", "examples")
MAC = os.path.join(EXAMPLES, "mac.install.toml")
MAC_LITE = os.path.join(EXAMPLES, "mac-lite.install.toml")
SINGLE_HOST = os.path.join(EXAMPLES, "single-host.install.toml")
MAC_FIXTURES = os.path.join(HERE, "fixtures", "mac")

sys.path.insert(0, INSTALLER)

from identity_terms import identity_hits

from burrow_install import registry
from burrow_install.__main__ import main
from burrow_install.manifest import load
from burrow_install.validate import ERROR_CODES, MAC_ERROR_CODES, validate

MAC_SERVICES = [
    "caddy",
    "cloudflared",
    "core-platform",
    "core-postgres",
    "files-service",
    "livekit",
    "meeting-transcriber",
    "memory-service",
    "pocket-id",
]
MAC_LITE_SERVICES = [
    "caddy",
    "cloudflared",
    "core-platform",
    "core-postgres",
    "files-service",
    "memory-service",
    "pocket-id",
]


def run_cli(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(list(argv))
    return code, out.getvalue()


def codes(raw):
    errors, _ = validate(raw)
    return [e.code for e in errors]


def pairs(raw):
    errors, _ = validate(raw)
    return [(e.code, e.path) for e in errors]


def expected_code(filename):
    return filename[: -len(".toml")].split("__")[0]


def mac_fixtures():
    return sorted(f for f in os.listdir(MAC_FIXTURES) if f.endswith(".toml"))


def flatten(value, prefix=""):
    if isinstance(value, dict):
        out = {}
        for key, child in value.items():
            out.update(flatten(child, f"{prefix}.{key}" if prefix else key))
        return out
    if isinstance(value, list):
        out = {}
        for index, child in enumerate(value):
            out.update(flatten(child, f"{prefix}[{index}]"))
        return out
    return {prefix: value}


class PositiveControlMixin:
    @classmethod
    def setUpClass(cls):
        for path in (MAC, MAC_LITE):
            errors, normalized = validate(load(path))
            if errors or normalized is None:
                raise AssertionError(f"positive control failed: {path} rejected: {errors}")

    def test_00_both_examples_are_valid(self):
        for path in (MAC, MAC_LITE):
            with self.subTest(example=os.path.basename(path)):
                self.assertEqual(run_cli("validate", path), (0, "ok\n"))


class MacExampleTest(PositiveControlMixin, unittest.TestCase):
    def test_services_are_the_literal_lists(self):
        self.assertEqual(run_cli("services", MAC), (0, "\n".join(MAC_SERVICES) + "\n"))
        self.assertEqual(run_cli("services", MAC_LITE), (0, "\n".join(MAC_LITE_SERVICES) + "\n"))

    def test_mac_lite_is_mac_with_meetings_off_and_its_meetings_config_dropped(self):
        mac, lite = load(MAC), load(MAC_LITE)
        self.assertTrue(mac["services"]["meetings"])
        self.assertFalse(lite["services"]["meetings"])
        for key in ("meetings", "models"):
            del mac[key]
        mac["services"]["meetings"] = False
        # The image source differs on purpose (task 01a14dd8): mac keeps the
        # legacy image_namespace while meeting-transcriber has no registry build.
        self.assertEqual(mac["images"].pop("image_namespace"), "example")
        self.assertEqual(lite["images"].pop("registry"), "ghcr.io/example")
        self.assertEqual(mac, lite)

    def test_examples_are_non_personal(self):
        for path in (MAC, MAC_LITE):
            with open(path, encoding="utf-8") as handle:
                text = handle.read().lower()
            with self.subTest(example=os.path.basename(path)):
                # Identity terms go through the shared digest rule (task 01a14b9e
                # stage 5), so this file does not spell them.
                self.assertEqual(identity_hits(text), [])
                for word in ("192.168.", "10.0.", "sk-", "node_ip ="):
                    self.assertNotIn(word, text)
                self.assertIn('primary = "burrow.example.test"', text)

    def test_single_host_example_is_untouched_by_the_target_field(self):
        raw = load(SINGLE_HOST)
        self.assertNotIn("target", raw["install"])
        _, normalized = validate(raw)
        self.assertEqual(normalized["install"]["target"], "single-host")


class MacFixtureTest(PositiveControlMixin, unittest.TestCase):
    def test_every_mac_code_has_a_fixture(self):
        covered = {expected_code(f) for f in mac_fixtures()}
        self.assertEqual(
            sorted(covered - {"unknown_key", "unknown_service"}), sorted(MAC_ERROR_CODES)
        )
        self.assertEqual(len(MAC_ERROR_CODES), 7)
        self.assertFalse(set(MAC_ERROR_CODES) & set(ERROR_CODES))

    def test_each_fixture_differs_from_the_mac_example_in_exactly_one_field(self):
        with open(MAC, encoding="utf-8") as handle:
            good_text = handle.read().splitlines()
        good_flat = flatten(load(MAC))
        for name in mac_fixtures():
            path = os.path.join(MAC_FIXTURES, name)
            with self.subTest(fixture=name):
                if name.endswith("__typo.toml"):
                    with open(path, encoding="utf-8") as handle:
                        text = handle.read().splitlines()
                    changed = [
                        line
                        for line in difflib.ndiff(good_text, text)
                        if line.startswith(("- ", "+ "))
                    ]
                    self.assertEqual(len(changed), 2, changed)
                    continue
                flat = flatten(load(path))
                differing = {
                    k for k in set(good_flat) | set(flat) if good_flat.get(k) != flat.get(k)
                }
                self.assertEqual(len(differing), 1, differing)

    def test_each_fixture_yields_exactly_its_code(self):
        for name in mac_fixtures():
            with self.subTest(fixture=name):
                self.assertEqual(
                    codes(load(os.path.join(MAC_FIXTURES, name))), [expected_code(name)]
                )

    def test_each_fixture_via_cli_exits_2_with_one_error_line(self):
        for name in mac_fixtures():
            with self.subTest(fixture=name):
                code, out = run_cli("validate", os.path.join(MAC_FIXTURES, name))
                self.assertEqual(code, 2)
                lines = out.splitlines()
                self.assertEqual(len(lines), 1, lines)
                self.assertTrue(lines[0].startswith(f"error {expected_code(name)} at "), lines[0])
                self.assertNotIn("ok", lines)


class ReviewCaseTest(PositiveControlMixin, unittest.TestCase):
    """The task-level review's validator cases, which vary mac-lite (and mac)."""

    def lite(self):
        return load(MAC_LITE)

    def test_a_voice_on_mac(self):
        raw = self.lite()
        raw["services"]["voice"] = True
        self.assertEqual(pairs(raw), [("mac_voice_unsupported", "services.voice")])

    def test_b_local_embeddings_on_mac(self):
        raw = self.lite()
        raw["embeddings"]["mode"] = "local"
        self.assertEqual(pairs(raw), [("mac_local_embeddings_unsupported", "embeddings.mode")])

    def test_b2_embeddings_knob_on_mac(self):
        raw = self.lite()
        raw["services"]["embeddings"] = True
        self.assertEqual(pairs(raw), [("mac_local_embeddings_unsupported", "services.embeddings")])

    def test_c_tunnel_token_ref_removed(self):
        raw = self.lite()
        del raw["access"]["tunnel_token_ref"]
        self.assertEqual(pairs(raw), [("tunnel_token_ref_missing", "access.tunnel_token_ref")])

    def test_d_media_reach_removed(self):
        raw = load(MAC)
        del raw["meetings"]["media_reach"]
        self.assertEqual(pairs(raw), [("meetings_media_reach_required", "meetings.media_reach")])

    def test_e_misspelled_meetings_knob(self):
        raw = self.lite()
        raw["services"]["meetngs"] = raw["services"].pop("meetings")
        self.assertEqual(pairs(raw), [("unknown_service", "services.meetngs")])


class MacRuleTest(PositiveControlMixin, unittest.TestCase):
    def test_memory_without_any_embeddings_table_is_hosted_embeddings_required(self):
        # The schema default mode is "local"; with no [embeddings] table at all
        # the owner asked for nothing local, so the hosted rule names the fix.
        raw = load(MAC_LITE)
        del raw["embeddings"]
        self.assertEqual(pairs(raw), [("hosted_embeddings_required", "embeddings")])

    def test_hosted_embeddings_need_a_model(self):
        raw = load(MAC_LITE)
        del raw["embeddings"]["model"]
        self.assertEqual(codes(raw), ["hosted_embeddings_required"])

    def test_memory_off_needs_no_embeddings(self):
        raw = load(MAC_LITE)
        raw["services"]["memory"] = False
        del raw["embeddings"]
        self.assertEqual(codes(raw), [])

    def test_mac_needs_no_acme_email_and_rejects_tls_fields(self):
        raw = load(MAC_LITE)
        self.assertNotIn("tls", raw["domain"])
        raw["domain"]["tls"] = "internal"
        self.assertEqual(pairs(raw), [("field_not_applicable", "domain.tls")])

    def test_meetings_knob_is_mac_only(self):
        raw = load(SINGLE_HOST)
        raw["services"]["meetings"] = True
        self.assertEqual(pairs(raw), [("field_not_applicable", "services.meetings")])

    def test_access_table_is_mac_only(self):
        raw = load(SINGLE_HOST)
        raw["access"] = {"tunnel_token_ref": "TUNNEL_TOKEN"}
        self.assertEqual(pairs(raw), [("field_not_applicable", "access.tunnel_token_ref")])

    def test_tailscale_with_its_ref_is_valid_and_runs_sidecars(self):
        raw = load(MAC)
        raw["access"] = {"mode": "tailscale", "tailscale_authkey_ref": "TS_AUTHKEY"}
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        names = registry.enabled_containers(normalized)
        self.assertEqual(
            [n for n in names if n.startswith(("tailscale", "cloudflared"))],
            ["tailscale-auth", "tailscale-livekit", "tailscale-primary"],
        )

    def test_leftover_ref_of_the_other_mode_is_not_applicable(self):
        raw = load(MAC_LITE)
        raw["access"]["tailscale_authkey_ref"] = "TS_AUTHKEY"
        self.assertEqual(pairs(raw), [("field_not_applicable", "access.tailscale_authkey_ref")])

    def test_access_refs_are_names_not_values(self):
        raw = load(MAC_LITE)
        raw["access"]["tunnel_token_ref"] = "eyJhIjoiMDFhMGQ2YWIifQ"
        self.assertEqual(codes(raw), ["invalid_value"])

    def test_meetings_table_is_ignored_while_the_knob_is_off(self):
        # One-field flip back from mac to mac-lite, as the proof run does.
        raw = load(MAC)
        raw["services"]["meetings"] = False
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertNotIn("livekit", registry.enabled_containers(normalized))
        self.assertNotIn("meeting-transcriber", registry.enabled_containers(normalized))

    def test_transcription_off_drops_the_transcriber_and_its_endpoint_rule(self):
        raw = load(MAC)
        raw["meetings"]["transcription"] = False
        raw["meetings"]["stt_endpoint"] = "nowhere"
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertIn("livekit", registry.enabled_containers(normalized))
        self.assertNotIn("meeting-transcriber", registry.enabled_containers(normalized))

    def test_transcription_needs_an_stt_endpoint(self):
        raw = load(MAC)
        del raw["meetings"]["stt_endpoint"]
        self.assertEqual(pairs(raw), [("stt_endpoint_unknown", "meetings.stt_endpoint")])

    def test_node_ip_shapes(self):
        for value, expected in (
            ("192.0.2.10", []),
            ("300.1.1.1", ["invalid_value"]),
            ("mac.lan", ["invalid_value"]),
        ):
            with self.subTest(node_ip=value):
                raw = load(MAC)
                raw["meetings"]["node_ip"] = value
                self.assertEqual(codes(raw), expected)

    def test_public_reach_takes_no_node_ip(self):
        raw = load(MAC)
        raw["meetings"]["media_reach"] = "public"
        self.assertEqual(codes(raw), [])
        raw["meetings"]["node_ip"] = "192.0.2.10"
        self.assertEqual(pairs(raw), [("field_not_applicable", "meetings.node_ip")])

    def test_flat_hostnames(self):
        raw = load(MAC)
        raw["domain"] = {
            "primary": "suite-01a0d6ab.example.test",
            "auth_host": "auth-01a0d6ab.example.test",
            "livekit_host": "livekit-01a0d6ab.example.test",
        }
        self.assertEqual(codes(raw), [])
        raw["domain"]["auth_host"] = "suite-01a0d6ab.example.test"
        self.assertEqual(pairs(raw), [("invalid_value", "domain.auth_host")])
        raw["domain"]["auth_host"] = "not a host"
        self.assertEqual(pairs(raw), [("invalid_domain", "domain.auth_host")])

    def test_new_enums_reject_unknown_values(self):
        for section, key, value in (
            ("install", "target", "windows"),
            ("access", "mode", "ngrok"),
            ("meetings", "media_reach", "anywhere"),
        ):
            with self.subTest(key=f"{section}.{key}"):
                raw = load(MAC)
                raw[section][key] = value
                self.assertEqual(codes(raw), ["invalid_enum"])

    def test_minimal_mac_manifest(self):
        raw = tomllib.loads(
            'schema_version = 1\n[install]\nname = "x"\ntarget = "mac"\n'
            '[domain]\nprimary = "x.example.com"\n'
            '[access]\ntunnel_token_ref = "TUNNEL_TOKEN"\n'
            '[images]\nregistry = "ghcr.io/example"\n'
        )
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertEqual(
            registry.enabled_containers(normalized),
            ["caddy", "cloudflared", "core-platform", "core-postgres", "pocket-id"],
        )


if __name__ == "__main__":
    unittest.main()
