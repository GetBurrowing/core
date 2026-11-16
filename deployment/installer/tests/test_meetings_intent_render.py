"""The meeting intent model in the install manifest (core task 01a1e5da stage 4).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

What is pinned here, each check with a positive control:

- ``[meetings] intent_provider`` / ``intent_endpoint`` / ``intent_model``
  render core-platform's MEETINGS_INTENT_* env, under the names
  apps/platform/config/runtime.exs reads (checked against that file).
- The API key is the endpoint's ``api_key_ref``: its value lands in
  secrets.env only, never in compose.yaml or any other rendered file.
- MEETINGS_INTENT_BASE_URL is rendered for ollama only.
- A manifest without the keys renders none of the four variables, so every
  existing manifest renders unchanged (the goldens in test_render.py and
  test_droplet.py pin the bytes).
- Validation: intent_endpoint_unknown, intent_endpoint_required, and
  field_not_applicable while meetings are off.
"""

import os
import re
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
FIXTURES = os.path.join(HERE, "render_fixtures")
DO_MEETINGS = os.path.join(FIXTURES, "do-droplet-meetings.toml")
DO_MEETINGS_CUSTOMER = os.path.join(FIXTURES, "do-droplet-meetings-customer.env")
DO_AUTH = os.path.join(FIXTURES, "do-droplet-registry-auth.json")
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
MAC = os.path.join(REPO, "deployment", "examples", "mac.install.toml")
RUNTIME_EXS = os.path.join(REPO, "apps", "platform", "config", "runtime.exs")

sys.path.insert(0, INSTALLER)
sys.path.insert(0, HERE)

from test_agents_render import compose_services

from burrow_install import registry
from burrow_install.manifest import load
from burrow_install.render import build
from burrow_install.validate import (
    ERROR_CODES,
    MAC_ERROR_CODES,
    MEETINGS_INTENT_ERROR_CODES,
    validate,
)

INTENT_VARS = (
    "MEETINGS_INTENT_PROVIDER",
    "MEETINGS_INTENT_MODEL",
    "MEETINGS_INTENT_BASE_URL",
    "MEETINGS_INTENT_API_KEY",
)
# FAKE values, not anyone's key.
ANTHROPIC_VALUE = "fake-anthropic-intent-key-01a1e5da"
STT_VALUE = "fake-openai-stt-key-01a19505"


def with_intent(path=DO_MEETINGS, endpoints=(), **keys):
    raw = load(path)
    if endpoints:
        raw.setdefault("models", {}).setdefault("endpoints", []).extend(endpoints)
    raw.setdefault("meetings", {}).update(keys)
    return raw


ANTHROPIC_ENDPOINT = {
    "name": "anthropic",
    "kind": "hosted",
    "base_url": "https://api.anthropic.com",
    "api_key_ref": "ANTHROPIC_INTENT_KEY",
}
OLLAMA_ENDPOINT = {
    "name": "local-llm",
    "kind": "local",
    "base_url": "http://ollama.lan:11434",
}


def codes(errors):
    return [(e.code, e.path) for e in errors]


class Render(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.supplied = os.path.join(self.tmp, "customer.env")
        with open(self.supplied, "w", encoding="utf-8") as handle:
            handle.write(f"OPENAI_STT_API_KEY={STT_VALUE}\n")
            handle.write(f"ANTHROPIC_INTENT_KEY={ANTHROPIC_VALUE}\n")

    def render(self, raw):
        errors, m = validate(raw)
        self.assertEqual(errors, [])
        rendered = build(m, registry_auth=DO_AUTH, customer_secrets=self.supplied)
        core = compose_services(rendered.files["compose.yaml"][0])["core-platform"]
        return rendered, core, registry.meetings_intent_env(m)


class PositiveControl(Render):
    """The readers find a customer secret core-platform reads, where it should be."""

    def test_the_readers_find_core_platform_and_the_stt_key(self):
        rendered, core, _env = self.render(load(DO_MEETINGS))
        self.assertIn('container_name: "core-platform"', core)
        self.assertIn("secrets.env", core)
        self.assertIn(f"STT_API_KEY={STT_VALUE}\n", rendered.files["secrets.env"][0])


class RuntimeExsNamesTest(unittest.TestCase):
    def test_every_rendered_name_is_one_runtime_exs_reads(self):
        with open(RUNTIME_EXS, encoding="utf-8") as handle:
            runtime = handle.read()
        read = set(re.findall(r'meetings_intent_env\.\("(MEETINGS_INTENT_[A-Z_]+)"\)', runtime))
        # Positive control: the reader finds stage 1's reads at all.
        self.assertIn("MEETINGS_INTENT_PROVIDER", read)
        self.assertEqual(sorted(read), sorted(INTENT_VARS))


class AnthropicTest(Render):
    def raw(self, **extra):
        return with_intent(
            endpoints=[ANTHROPIC_ENDPOINT],
            intent_provider="anthropic",
            intent_endpoint="anthropic",
            **extra,
        )

    def test_the_key_lands_in_secrets_env_and_never_in_compose(self):
        rendered, core, env = self.render(self.raw(intent_model="claude-haiku-4-5"))
        secrets_env = rendered.files["secrets.env"][0]
        self.assertIn(f"MEETINGS_INTENT_API_KEY={ANTHROPIC_VALUE}\n", secrets_env)
        compose = rendered.files["compose.yaml"][0]
        self.assertNotIn("MEETINGS_INTENT_API_KEY", compose)
        self.assertNotIn(ANTHROPIC_VALUE, compose)
        for rel, (text, _mode) in rendered.files.items():
            if rel not in ("secrets.env", "user-data"):
                self.assertNotIn(ANTHROPIC_VALUE, text, rel)
        # (user-data legitimately carries secrets.env, mode 0600.) A key core
        # reads is not also parked in customer-secrets.env.
        self.assertNotIn("customer-secrets.env", rendered.files)
        self.assertEqual(env["MEETINGS_INTENT_API_KEY"], "{customer:ANTHROPIC_INTENT_KEY}")
        self.assertIn('MEETINGS_INTENT_PROVIDER: "anthropic"', core)
        self.assertIn('MEETINGS_INTENT_MODEL: "claude-haiku-4-5"', core)

    def test_hosted_providers_get_no_base_url(self):
        for provider in ("anthropic", "openai"):
            with self.subTest(provider=provider):
                rendered, _core, env = self.render(
                    with_intent(
                        endpoints=[ANTHROPIC_ENDPOINT],
                        intent_provider=provider,
                        intent_endpoint="anthropic",
                    )
                )
                self.assertEqual(env["MEETINGS_INTENT_PROVIDER"], provider)
                self.assertNotIn("MEETINGS_INTENT_BASE_URL", env)
                self.assertNotIn("MEETINGS_INTENT_BASE_URL", rendered.files["compose.yaml"][0])

    def test_intent_model_is_optional(self):
        _rendered, _core, env = self.render(self.raw())
        self.assertNotIn("MEETINGS_INTENT_MODEL", env)
        self.assertEqual(env["MEETINGS_INTENT_PROVIDER"], "anthropic")


class OllamaTest(Render):
    def test_base_url_is_the_endpoints_and_no_key_without_a_ref(self):
        rendered, core, env = self.render(
            with_intent(
                endpoints=[OLLAMA_ENDPOINT],
                intent_provider="ollama",
                intent_endpoint="local-llm",
                intent_model="qwen3:4b",
            )
        )
        self.assertEqual(
            env,
            {
                "MEETINGS_INTENT_PROVIDER": "ollama",
                "MEETINGS_INTENT_MODEL": "qwen3:4b",
                "MEETINGS_INTENT_BASE_URL": "http://ollama.lan:11434",
            },
        )
        self.assertIn('MEETINGS_INTENT_BASE_URL: "http://ollama.lan:11434"', core)
        self.assertNotIn("MEETINGS_INTENT_API_KEY", rendered.files["secrets.env"][0])


class UnchangedTest(Render):
    def test_no_intent_keys_render_none_of_the_four_vars(self):
        for path, auth, customer in (
            (DO_MEETINGS, DO_AUTH, DO_MEETINGS_CUSTOMER),
            (EXAMPLE, None, None),
        ):
            with self.subTest(fixture=os.path.basename(path)):
                errors, m = validate(load(path))
                self.assertEqual(errors, [])
                self.assertEqual(registry.meetings_intent_env(m), {})
                rendered = build(m, registry_auth=auth, customer_secrets=customer)
                for rel, (text, _mode) in rendered.files.items():
                    for var in INTENT_VARS:
                        self.assertNotIn(var, text, rel)


class ValidateTest(unittest.TestCase):
    def test_the_codes_are_their_own_set(self):
        self.assertEqual(
            sorted(MEETINGS_INTENT_ERROR_CODES),
            ["intent_endpoint_required", "intent_endpoint_unknown"],
        )
        self.assertFalse(set(MEETINGS_INTENT_ERROR_CODES) & set(ERROR_CODES))
        self.assertFalse(set(MEETINGS_INTENT_ERROR_CODES) & set(MAC_ERROR_CODES))

    def test_positive_control_a_named_endpoint_is_valid(self):
        for path in (DO_MEETINGS, MAC):
            with self.subTest(fixture=os.path.basename(path)):
                errors, _m = validate(
                    with_intent(
                        path,
                        endpoints=[ANTHROPIC_ENDPOINT],
                        intent_provider="anthropic",
                        intent_endpoint="anthropic",
                    )
                )
                self.assertEqual(errors, [])

    def test_unknown_endpoint(self):
        for path in (DO_MEETINGS, MAC):
            with self.subTest(fixture=os.path.basename(path)):
                errors, _m = validate(
                    with_intent(path, intent_provider="anthropic", intent_endpoint="nope")
                )
                self.assertEqual(
                    codes(errors), [("intent_endpoint_unknown", "meetings.intent_endpoint")]
                )

    def test_provider_without_endpoint(self):
        for path in (DO_MEETINGS, MAC):
            with self.subTest(fixture=os.path.basename(path)):
                errors, _m = validate(with_intent(path, intent_provider="openai"))
                self.assertEqual(
                    codes(errors), [("intent_endpoint_required", "meetings.intent_endpoint")]
                )

    def test_endpoint_or_model_without_provider(self):
        errors, _m = validate(
            with_intent(
                endpoints=[ANTHROPIC_ENDPOINT], intent_endpoint="anthropic", intent_model="m"
            )
        )
        self.assertEqual(
            codes(errors),
            [
                ("field_not_applicable", "meetings.intent_endpoint"),
                ("field_not_applicable", "meetings.intent_model"),
            ],
        )

    def test_unknown_provider_is_one_error(self):
        errors, _m = validate(with_intent(intent_provider="bogus", intent_endpoint="nope"))
        self.assertEqual(codes(errors), [("invalid_enum", "meetings.intent_provider")])

    def test_meetings_off_refuses_every_intent_key(self):
        raw = with_intent(
            EXAMPLE,
            endpoints=[ANTHROPIC_ENDPOINT],
            intent_provider="anthropic",
            intent_endpoint="anthropic",
            intent_model="m",
        )
        self.assertFalse(raw["services"].get("meetings", False))
        errors, _m = validate(raw)
        self.assertEqual(
            codes(errors),
            [
                ("field_not_applicable", "meetings.intent_provider"),
                ("field_not_applicable", "meetings.intent_endpoint"),
                ("field_not_applicable", "meetings.intent_model"),
            ],
        )
        # And the renderer, handed such a manifest anyway, renders nothing.
        normalized = load(EXAMPLE)
        _e, normalized = validate(normalized)
        normalized["meetings"].update(intent_provider="anthropic", intent_endpoint="anthropic")
        self.assertEqual(registry.meetings_intent_env(normalized), {})


if __name__ == "__main__":
    unittest.main()
