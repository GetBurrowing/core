"""Tests for the install-manifest validator and CLI (ADR 0053, task 01a0d69d).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Design:
- Every test class validates the good moon-equivalent fixture FIRST, so a
  validator that rejects everything fails loudly instead of passing every
  negative case.
- One fixture per error code, each the good fixture with exactly ONE field
  changed (checked mechanically below), asserting exactly that code and no
  other.
- `services` output is compared with a hard-coded literal list, not a set
  derived from the registry, so a widened service set is caught.
"""

import contextlib
import difflib
import io
import os
import subprocess
import sys
import tomllib
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
FIXTURES = os.path.join(HERE, "fixtures")
GOOD = os.path.join(FIXTURES, "good.toml")
EXAMPLE = os.path.join(REPO, "deployment", "examples", "moon-equivalent.install.toml")

sys.path.insert(0, INSTALLER)

from suite_install import registry
from suite_install.__main__ import main
from suite_install.manifest import load
from suite_install.validate import ERROR_CODES, validate

# Loader-level codes: the file never reaches the validator.
LOADER_CODES = ("invalid_toml", "unreadable_manifest")

GOOD_SERVICES = [
    "caddy",
    "core-platform",
    "core-postgres",
    "embeddings",
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


def fixture(name):
    return os.path.join(FIXTURES, name)


def read_lines(path):
    with open(path) as handle:
        return handle.read().splitlines()


def expected_code(filename):
    return filename[: -len(".toml")].split("__")[0]


def bad_fixtures():
    return sorted(
        f
        for f in os.listdir(FIXTURES)
        if f.endswith(".toml") and f != "good.toml" and expected_code(f) not in LOADER_CODES
    )


def flatten(value, prefix=""):
    if isinstance(value, dict):
        out = {}
        for key, child in value.items():
            out.update(flatten(child, f"{prefix}.{key}" if prefix else key))
        return out
    return {prefix: value}


class PositiveControlMixin:
    """Validate the good fixture before anything else in the class."""

    @classmethod
    def setUpClass(cls):
        errors, normalized = validate(load(GOOD))
        if errors or normalized is None:
            raise AssertionError(f"positive control failed: good fixture rejected: {errors}")

    def test_00_good_fixture_is_valid(self):
        errors, normalized = validate(load(GOOD))
        self.assertEqual(errors, [])
        self.assertIsNotNone(normalized)


class GoodManifestTest(PositiveControlMixin, unittest.TestCase):
    def test_good_fixture_is_the_shipped_example(self):
        with open(GOOD, "rb") as a, open(EXAMPLE, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_cli_validate_prints_ok_and_exits_zero(self):
        self.assertEqual(run_cli("validate", GOOD), (0, "ok\n"))

    def test_cli_services_is_the_literal_list(self):
        code, out = run_cli("services", GOOD)
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), GOOD_SERVICES)

    def test_cli_as_a_module_subprocess(self):
        env = dict(os.environ, PYTHONPATH=INSTALLER)
        proc = subprocess.run(
            [sys.executable, "-m", "suite_install", "services", EXAMPLE],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout.splitlines(), GOOD_SERVICES)

    def test_example_declares_no_model_endpoint(self):
        raw = load(EXAMPLE)
        self.assertNotIn("models", raw)
        _, normalized = validate(raw)
        self.assertEqual(normalized["models"]["endpoints"], [])


class ErrorFixtureTest(PositiveControlMixin, unittest.TestCase):
    def test_every_validator_code_has_a_fixture(self):
        covered = {expected_code(f) for f in bad_fixtures()}
        self.assertEqual(sorted(covered), sorted(ERROR_CODES))

    def test_every_loader_code_that_a_file_can_trigger_has_a_fixture(self):
        self.assertTrue(os.path.exists(fixture("invalid_toml.toml")))

    def test_each_fixture_differs_from_good_in_exactly_one_field(self):
        good_text = read_lines(GOOD)
        good_flat = flatten(load(GOOD))
        for name in bad_fixtures():
            with self.subTest(fixture=name):
                if name.endswith("__typo.toml"):
                    # A misspelled key is a rename: one line replaced, same value.
                    text = read_lines(fixture(name))
                    changed = [
                        line
                        for line in difflib.ndiff(good_text, text)
                        if line.startswith(("- ", "+ "))
                    ]
                    self.assertEqual(len(changed), 2, changed)
                    continue
                flat = flatten(load(fixture(name)))
                differing = {
                    k for k in set(good_flat) | set(flat) if good_flat.get(k) != flat.get(k)
                }
                self.assertEqual(len(differing), 1, differing)

    def test_each_fixture_yields_exactly_its_code(self):
        for name in bad_fixtures():
            with self.subTest(fixture=name):
                self.assertEqual(codes(load(fixture(name))), [expected_code(name)])

    def test_each_fixture_via_cli_exits_2_with_one_error_line(self):
        for name in bad_fixtures():
            with self.subTest(fixture=name):
                code, out = run_cli("validate", fixture(name))
                self.assertEqual(code, 2)
                lines = out.splitlines()
                self.assertEqual(len(lines), 1, lines)
                self.assertTrue(lines[0].startswith(f"error {expected_code(name)} at "), lines[0])
                self.assertNotIn("ok", lines)

    def test_services_refuses_an_invalid_manifest(self):
        code, out = run_cli("services", fixture("unknown_service.toml"))
        self.assertEqual(code, 2)
        self.assertNotIn("core-platform", out)


class NamedCaseTest(PositiveControlMixin, unittest.TestCase):
    """The cases the task-level review re-executes, with their exact paths."""

    def assert_single(self, name, code, path):
        errors, _ = validate(load(fixture(name)))
        self.assertEqual([(e.code, e.path) for e in errors], [(code, path)])

    def test_unknown_service_path(self):
        self.assert_single("unknown_service.toml", "unknown_service", "services.mailserver")

    def test_typo_cannot_silently_leave_memory_off(self):
        self.assert_single("unknown_service__typo.toml", "unknown_service", "services.memmory")

    def test_missing_domain_path(self):
        self.assert_single("missing_domain.toml", "missing_domain", "domain.primary")

    def test_gpu_required_path(self):
        self.assert_single("gpu_required.toml", "gpu_required", "voice.accelerator")

    def test_unknown_key_at_depth(self):
        raw = load(GOOD)
        raw["images"]["refs"] = {"core-platfrom": "example.org/core:1"}
        errors, _ = validate(raw)
        self.assertEqual(
            [(e.code, e.path) for e in errors], [("unknown_key", "images.refs.core-platfrom")]
        )

    def test_unknown_key_at_top_level(self):
        raw = load(GOOD)
        raw["servics"] = {"memory": False}
        self.assertEqual(codes(raw), ["unknown_key"])

    def test_invalid_toml_via_cli(self):
        code, out = run_cli("validate", fixture("invalid_toml.toml"))
        self.assertEqual(code, 2)
        self.assertTrue(out.startswith("error invalid_toml at "), out)

    def test_unreadable_manifest_via_cli(self):
        code, out = run_cli("validate", fixture("does-not-exist.toml"))
        self.assertEqual(code, 2)
        self.assertTrue(out.startswith("error unreadable_manifest at "), out)

    def test_bad_mode_type_does_not_cascade(self):
        raw = load(GOOD)
        raw["domain"]["tls"] = "letsencrypt"
        self.assertEqual(codes(raw), ["invalid_enum"])

    def test_bad_primary_type_does_not_also_report_missing(self):
        raw = load(GOOD)
        raw["domain"]["primary"] = 42
        self.assertEqual(codes(raw), ["invalid_type"])


class RuleTest(PositiveControlMixin, unittest.TestCase):
    """Rules beyond the one-field fixtures, including their positive sides."""

    def good(self):
        return load(GOOD)

    def test_gpu_host_accepts_cuda_voice(self):
        raw = self.good()
        raw["services"]["voice"] = True
        raw["host"]["gpu"] = True
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertIn("speaches", registry.enabled_containers(normalized))

    def test_cpu_voice_needs_no_gpu(self):
        raw = self.good()
        raw["services"]["voice"] = True
        raw["voice"]["accelerator"] = "cpu"
        self.assertEqual(codes(raw), [])

    def test_memory_with_endpoint_embeddings_is_valid_and_runs_no_embeddings_container(self):
        raw = self.good()
        raw["embeddings"] = {"mode": "endpoint", "base_url": "https://emb.example.com/v1"}
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertNotIn("embeddings", registry.enabled_containers(normalized))
        self.assertIn("memory-service", registry.enabled_containers(normalized))

    def test_memory_off_drops_memory_service_only(self):
        raw = self.good()
        raw["services"]["memory"] = False
        _, normalized = validate(raw)
        self.assertEqual(
            registry.enabled_containers(normalized),
            [
                "caddy",
                "core-platform",
                "core-postgres",
                "embeddings",
                "files-service",
                "pocket-id",
            ],
        )

    def test_external_oidc_complete_is_valid_and_drops_pocket_id(self):
        raw = self.good()
        raw["auth"] = {
            "mode": "external-oidc",
            "issuer": "https://id.example.com",
            "client_id": "suite",
            "client_secret_ref": "OIDC_CLIENT_SECRET",
        }
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertNotIn("pocket-id", registry.enabled_containers(normalized))

    def test_external_oidc_issuer_must_be_https(self):
        raw = self.good()
        raw["auth"] = {
            "mode": "external-oidc",
            "issuer": "http://id.example.com",
            "client_id": "suite",
            "client_secret_ref": "OIDC_CLIENT_SECRET",
        }
        self.assertEqual(codes(raw), ["invalid_value"])

    def test_bundled_auth_rejects_external_fields(self):
        raw = self.good()
        raw["auth"]["issuer"] = "https://id.example.com"
        self.assertEqual(codes(raw), ["field_not_applicable"])

    def test_acme_with_email_is_valid(self):
        raw = self.good()
        raw["domain"]["tls"] = "acme"
        raw["domain"]["acme_email"] = "ops@example.com"
        self.assertEqual(codes(raw), [])

    def test_domain_shapes(self):
        for value, ok in (
            ("suite.example.com", True),
            ("a-b.example.co.uk", True),
            ("localhost", False),
            ("203.0.113.10", False),
            ("-bad.example.com", False),
            ("example.com.", False),
            ("under_score.example.com", False),
        ):
            with self.subTest(domain=value):
                raw = self.good()
                raw["domain"]["primary"] = value
                self.assertEqual(codes(raw), [] if ok else ["invalid_domain"])

    def test_every_endpoint_kind_is_first_class(self):
        for kind in ("local", "hosted", "byo"):
            with self.subTest(kind=kind):
                raw = self.good()
                raw["models"] = {
                    "endpoints": [
                        {
                            "name": "primary",
                            "kind": kind,
                            "base_url": "https://llm.example.com/v1",
                            "api_key_ref": "PRIMARY_LLM_KEY",
                        }
                    ]
                }
                self.assertEqual(codes(raw), [])

    def test_endpoint_missing_fields(self):
        raw = self.good()
        raw["models"] = {"endpoints": [{"name": "primary"}]}
        self.assertEqual(codes(raw), ["missing_required", "missing_required"])

    def test_secret_ref_rejects_a_literal_value(self):
        raw = self.good()
        raw["models"] = {
            "endpoints": [
                {
                    "name": "primary",
                    "kind": "byo",
                    "base_url": "https://llm.example.com/v1",
                    "api_key_ref": "sk-not-a-ref",
                }
            ]
        }
        self.assertEqual(codes(raw), ["invalid_value"])

    def test_s3_backup(self):
        raw = self.good()
        raw["backup"] = {
            "target": "s3-compatible",
            "bucket": "suite-backups",
            "endpoint": "https://s3.example.com",
            "region": "auto",
            "access_key_ref": "BACKUP_ACCESS_KEY",
            "secret_key_ref": "BACKUP_SECRET_KEY",
        }
        self.assertEqual(codes(raw), [])
        del raw["backup"]["bucket"]
        self.assertEqual(codes(raw), ["backup_incomplete"])

    def test_local_backup_path_must_be_absolute(self):
        raw = self.good()
        raw["backup"] = {"target": "local-path", "path": "backups"}
        self.assertEqual(codes(raw), ["invalid_value"])

    def test_backup_none_rejects_target_fields(self):
        raw = self.good()
        raw["backup"]["path"] = "/srv/backups"
        self.assertEqual(codes(raw), ["field_not_applicable"])

    def test_image_ref_override_for_a_known_container(self):
        raw = self.good()
        raw["images"]["refs"] = {"core-platform": "registry.example.com/suite-core:1.2.3"}
        self.assertEqual(codes(raw), [])

    def test_day2_keys_validate(self):
        raw = self.good()
        raw["day2"] = {"upgrade_channel": "nightly", "phone_home": True}
        self.assertEqual(codes(raw), ["invalid_enum"])

    def test_bool_is_not_an_int_for_schema_version(self):
        raw = self.good()
        raw["schema_version"] = True
        self.assertEqual(codes(raw), ["unsupported_schema_version"])

    def test_missing_schema_version(self):
        raw = self.good()
        del raw["schema_version"]
        self.assertEqual(codes(raw), ["unsupported_schema_version"])

    def test_minimal_manifest_defaults(self):
        raw = tomllib.loads(
            'schema_version = 1\n[install]\nname = "x"\n'
            '[domain]\nprimary = "x.example.com"\ntls = "internal"\n'
        )
        errors, normalized = validate(raw)
        self.assertEqual(errors, [])
        self.assertEqual(
            registry.enabled_containers(normalized),
            ["caddy", "core-platform", "core-postgres", "pocket-id"],
        )


if __name__ == "__main__":
    unittest.main()
