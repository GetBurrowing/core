"""Tests for the single-host renderer (ADR 0053, task 01a0d69d stage 2).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

Design:
- Every class renders the shipped single-host example FIRST (positive
  control), so a renderer that emits nothing, or refuses everything, fails
  loudly instead of passing the absence checks.
- (a) Golden files are compared byte-for-byte, whole-file, after secret values
  are replaced with ``<secret:NAME>``: a raw full-content assertion catches a
  widened render as well as a narrowed one.
- (b) Knob semantics are checked for EVERY optional service against the
  identifiers the registry says that service owns: all present when on (the
  positive control for the absence check), none present when off.
- Secret values are only ever compared in memory; no test prints one.

Regenerate golden files after an intended change with
``BURROW_INSTALL_UPDATE_GOLDEN=1``
and review the diff.
"""

import contextlib
import copy
import difflib
import io
import os
import re
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
GOLDEN = os.path.join(HERE, "golden")

sys.path.insert(0, INSTALLER)

from identity_terms import identity_hits, planted_term
from migrate_embed import cut_migrate_script

from burrow_install import registry
from burrow_install.__main__ import main
from burrow_install.manifest import load
from burrow_install.render import TARGETS, RenderError, build, plan, render
from burrow_install.secrets import parse_env_file
from burrow_install.validate import validate

MEMORY_OFF = os.path.join(RENDER_FIXTURES, "single-host-memory-off.toml")
VOICE_CUDA = os.path.join(RENDER_FIXTURES, "voice-cuda-gpu.toml")
BYO = os.path.join(RENDER_FIXTURES, "byo-endpoint.toml")
PLAY = os.path.join(RENDER_FIXTURES, "single-host-play.toml")
MAC_MEETINGS = os.path.join(REPO, "deployment", "examples", "mac.install.toml")
CI_WORKFLOW = os.path.join(REPO, ".github", "workflows", "ci.yml")

# The knobs the single-host target runs. `meetings` is a mac-only knob in v1
# (task 01a0d6ab); its on/off semantics are tested in test_mac_render.py.
SINGLE_HOST_SERVICES = {
    knob: registry.OPTIONAL_SERVICES[knob] for knob in registry.TARGET_KNOBS["single-host"]
}

GOLDEN_CASES = {
    "single-host": EXAMPLE,
    "single-host-memory-off": MEMORY_OFF,
    # Native agents (task 01a10322 stage 3); test_agents_render.py covers the rest.
    "single-host-agents-full": os.path.join(RENDER_FIXTURES, "single-host-agents-full.toml"),
    "single-host-agents-contained": os.path.join(
        RENDER_FIXTURES, "single-host-agents-contained.toml"
    ),
    # One-click DigitalOcean droplet (task 01a10315 stage 1); test_droplet.py covers the rest.
    "do-droplet": os.path.join(RENDER_FIXTURES, "do-droplet.toml"),
    # The s-4vcpu-8gb droplet (task 01a18f76): size_tier = "medium".
    "do-droplet-8gb": os.path.join(RENDER_FIXTURES, "do-droplet-8gb.toml"),
}
# images.source = "registry" cases need a (fake) pull credential to render.
GOLDEN_REGISTRY_AUTH = {
    "do-droplet": os.path.join(RENDER_FIXTURES, "do-droplet-registry-auth.json"),
    "do-droplet-8gb": os.path.join(RENDER_FIXTURES, "do-droplet-registry-auth.json"),
}

# Host literals and agent-harness settings of ours that must never be rendered
# unless a manifest declares them (product decision, 2026-09-25). Install and
# personal identity (an operator's org, domains, hosts, people) is checked by
# identity_hits, on the same digest rule as core's Elixir guard, so this file
# does not spell it (task 01a14b9e stage 5); the LAN prefix stays literal.
FORBIDDEN = ("192.168.", "lightning", "OPENCLAW_")

MEMORY_EXPECTED_IDENTIFIERS = {
    "memory-service",
    "MEMORY_SERVICE_URL",
    "MEMORY_SERVICE_API_KEY",
    "MEMORY_API_KEY",
    "MEMORY_DATABASE_URL",
    "MEMORY_DB_PASSWORD",
    "MEMORY_EMBEDDING_URL",
    "MEMORY_EMBEDDING_BACKEND",
    "MEMORY_EMBEDDING_MODEL",
    "MEMORY_HOST",
    "MEMORY_PORT",
    "10-memory.sql",
    # The 4 GB local-embeddings profile (task 01a18f76, registry.EMBEDDINGS_PROFILES).
    "MEMORY_CHUNK_MAX_TOKENS",
    "MEMORY_CHUNK_OVERLAP_TOKENS",
    "MEMORY_EMBEDDING_MAX_BATCH_TOKENS",
    "MEMORY_EMBEDDING_MAX_INPUT_TOKENS",
    "MEMORY_EMBEDDING_MAX_CONCURRENCY",
    "MEMORY_SERVICE_INGEST_TIMEOUT_MS",
}


def manifest_from(path):
    errors, normalized = validate(load(path))
    if errors:
        raise AssertionError(f"fixture {path} is invalid: {errors}")
    return normalized


def valid(raw):
    errors, normalized = validate(raw)
    if errors:
        raise AssertionError(f"mutated manifest is invalid: {errors}")
    return normalized


def all_text(rendered):
    return "\n".join(text for text, _mode in rendered.files.values())


def run_cli(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(list(argv))
    return code, out.getvalue()


class TempDirMixin:
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix="burrow-install-01a0d69d-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        if _inside_git(self.tmp):
            self.skipTest(f"the temp dir {self.tmp} is inside a git work tree")


def _inside_git(path):
    from burrow_install.render import inside_git_worktree

    return inside_git_worktree(path)


class PositiveControlMixin:
    """Render the shipped example before anything else in the class."""

    @classmethod
    def setUpClass(cls):
        rendered = build(manifest_from(EXAMPLE))
        for required in ("compose.yaml", "Caddyfile", "user-data", "secrets.env"):
            if not rendered.files.get(required, ("", 0))[0].strip():
                raise AssertionError(f"positive control failed: {required} is empty")


# ---------------------------------------------------------------------------
# (a) golden files
# ---------------------------------------------------------------------------


class GoldenTest(PositiveControlMixin, unittest.TestCase):
    def check_golden(self, case):
        redacted = build(
            manifest_from(GOLDEN_CASES[case]), registry_auth=GOLDEN_REGISTRY_AUTH.get(case)
        ).redacted()
        golden_dir = os.path.join(GOLDEN, case)
        if os.environ.get("BURROW_INSTALL_UPDATE_GOLDEN") == "1":
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

    def test_golden_single_host(self):
        self.check_golden("single-host")

    def test_golden_single_host_memory_off(self):
        self.check_golden("single-host-memory-off")

    def test_golden_single_host_agents_full(self):
        self.check_golden("single-host-agents-full")

    def test_golden_single_host_agents_contained(self):
        self.check_golden("single-host-agents-contained")

    def test_golden_do_droplet(self):
        self.check_golden("do-droplet")

    def test_golden_do_droplet_8gb(self):
        self.check_golden("do-droplet-8gb")

    def test_do_droplet_8gb_fixture_differs_only_in_size_tier(self):
        small, medium = load(GOLDEN_CASES["do-droplet"]), load(GOLDEN_CASES["do-droplet-8gb"])
        self.assertEqual(
            (small["install"]["size_tier"], medium["install"]["size_tier"]), ("small", "medium")
        )
        medium["install"]["size_tier"] = "small"
        self.assertEqual(small, medium)

    def test_golden_files_hold_no_secret_value(self):
        # Positive control for the search: a raw render's secrets.env DOES
        # hold its values; the redacted form of the same render holds none.
        rendered = build(manifest_from(EXAMPLE))
        values = list(rendered.generated.values())
        self.assertTrue(all(v in rendered.files["secrets.env"][0] for v in values))
        for text in rendered.redacted().values():
            self.assertFalse([v for v in values if v in text])

    def test_memory_off_fixture_differs_from_example_in_one_field(self):
        on, off = load(EXAMPLE), load(MEMORY_OFF)
        self.assertTrue(on["services"]["memory"])
        off["services"]["memory"] = True
        self.assertEqual(on, off)


# ---------------------------------------------------------------------------
# (b) knob semantics
# ---------------------------------------------------------------------------


def all_on_raw():
    """The example with every optional service on (GPU host so voice can run)."""
    raw = load(EXAMPLE)
    raw["host"]["gpu"] = True
    for knob in SINGLE_HOST_SERVICES:
        raw["services"][knob] = True
    return raw


class KnobTest(PositiveControlMixin, unittest.TestCase):
    def pair(self, knob):
        base = all_on_raw()
        if knob == "embeddings":
            # memory needs embeddings (memory_requires_embeddings), so the
            # embeddings knob is flipped with memory off in BOTH renders.
            base["services"]["memory"] = False
        off = copy.deepcopy(base)
        off["services"][knob] = False
        return valid(base), valid(off)

    def test_every_optional_service_owns_all_of_its_identifiers(self):
        for knob, container in SINGLE_HOST_SERVICES.items():
            with self.subTest(service=container):
                on, off = self.pair(knob)
                ids = registry.identifiers(container, registry.Ctx(on))
                self.assertIn(container, ids)
                self.assertGreater(len(ids), 1, f"{container} declares only its name")
                on_text = all_text(build(on))
                off_text = all_text(build(off))
                missing = sorted(i for i in ids if i not in on_text)
                self.assertEqual(missing, [], f"{container} on: identifiers not rendered")
                leaked = sorted(i for i in ids if i in off_text)
                self.assertEqual(leaked, [], f"{container} off: identifiers still rendered")

    def test_memory_identifiers_are_the_expected_literal_set(self):
        # Raw literal, so widening the registry's memory entry is caught too.
        on, _off = self.pair("memory")
        self.assertEqual(
            registry.identifiers("memory-service", registry.Ctx(on)), MEMORY_EXPECTED_IDENTIFIERS
        )

    def test_memory_diff_removes_only_memory_lines_and_adds_none(self):
        on = build(manifest_from(EXAMPLE)).redacted()
        off = build(manifest_from(MEMORY_OFF)).redacted()
        self.assertEqual(sorted(set(on) - set(off)), ["postgres-init/10-memory.sql"])
        self.assertEqual(sorted(set(off) - set(on)), [])
        ids = MEMORY_EXPECTED_IDENTIFIERS
        for rel in sorted(off):
            matcher = difflib.SequenceMatcher(
                a=on[rel].splitlines(), b=off[rel].splitlines(), autojunk=False
            )
            for tag, i1, i2, _j1, _j2 in matcher.get_opcodes():
                if tag == "equal":
                    continue
                with self.subTest(file=rel, lines=f"{i1 + 1}-{i2}"):
                    self.assertEqual(tag, "delete", f"{rel}: memory-off changed or added lines")
                    hunk = on[rel].splitlines()[i1:i2]
                    self.assertTrue(
                        any(i in line for line in hunk for i in ids),
                        f"{rel}: a removed hunk holds no memory identifier: {hunk}",
                    )

    def test_no_dangling_reference_for_any_single_service_off(self):
        for knob in SINGLE_HOST_SERVICES:
            with self.subTest(off=knob):
                _on, off = self.pair(knob)
                p = plan(off)
                running = set(p.services)
                for svc in p.services.values():
                    self.assertLessEqual(set(svc.depends_on), running)
                rendered = build(off)
                text = all_text(rendered)
                self.assertNotIn("{secret:", text)
                self.assertNotIn("{customer:", text)
                compose_services = re.findall(
                    r"^  ([a-z][a-z0-9-]*):$", rendered.files["compose.yaml"][0], re.MULTILINE
                )
                self.assertEqual(compose_services, p.containers)
                self.assertEqual(
                    rendered.files["services.txt"][0].split(), registry.enabled_containers(off)
                )

    def test_endpoint_embeddings_runs_no_container_and_leaves_no_edge_to_it(self):
        # memory-service declares depends_on embeddings; in endpoint mode the
        # capability is on but no embeddings container runs, so the edge,
        # the model mount and the model-file check must all go.
        raw = load(EXAMPLE)
        raw["embeddings"] = {"mode": "endpoint", "base_url": "https://emb.customer.example/v1"}
        m = valid(raw)
        p = plan(m)
        self.assertNotIn("embeddings", p.services)
        self.assertEqual(sorted(p.services["memory-service"].depends_on), ["core-postgres"])
        compose = build(m).files["compose.yaml"][0]
        self.assertIn('MEMORY_EMBEDDING_URL: "https://emb.customer.example/v1"', compose)
        self.assertNotIn("embeddings:", compose)
        self.assertNotIn("/models", all_text(build(m)))

    def test_compose_and_user_data_parse_as_yaml(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed (stdlib-only CI container)")
        rendered = build(valid(all_on_raw()))
        compose = yaml.safe_load(rendered.files["compose.yaml"][0])
        self.assertEqual(
            sorted(compose["services"]), registry.enabled_containers(valid(all_on_raw()))
        )
        user_data = rendered.files["user-data"][0]
        self.assertTrue(user_data.startswith("#cloud-config\n"))
        doc = yaml.safe_load(user_data)
        by_path = {w["path"]: w for w in doc["write_files"]}
        for rel, (text, mode) in rendered.files.items():
            if rel in ("user-data", "meta-data", "registry-auth.json"):
                continue
            entry = by_path[f"/opt/burrow/{rel}"]
            self.assertEqual(entry["content"], text, rel)
            self.assertEqual(entry["permissions"], f"0{mode:o}", rel)


# ---------------------------------------------------------------------------
# (c) (d) secrets
# ---------------------------------------------------------------------------


class SecretsTest(PositiveControlMixin, TempDirMixin, unittest.TestCase):
    def test_every_generated_secret_differs_between_fresh_renders(self):
        m = manifest_from(EXAMPLE)
        first, second = build(m).generated, build(m).generated
        self.assertEqual(sorted(first), sorted(second))
        self.assertGreaterEqual(len(first), 11)
        same = sorted(n for n in first if first[n] == second[n])
        self.assertEqual(same, [])

    def test_reuse_secrets_keeps_every_value(self):
        m = manifest_from(EXAMPLE)
        out = os.path.join(self.tmp, "one")
        first = render(m, out).generated
        again = build(m, reuse_secrets=os.path.join(out, "secrets.env")).generated
        self.assertEqual(sorted(first), sorted(again))
        self.assertEqual([n for n in first if first[n] != again[n]], [])

    def test_reuse_after_memory_off_drops_memory_secrets_only(self):
        out = os.path.join(self.tmp, "on")
        on = render(manifest_from(EXAMPLE), out).generated
        off = build(manifest_from(MEMORY_OFF), reuse_secrets=os.path.join(out, "secrets.env"))
        self.assertEqual(
            sorted(set(on) - set(off.generated)), ["MEMORY_DB_PASSWORD", "MEMORY_SERVICE_API_KEY"]
        )
        self.assertEqual([n for n in off.generated if off.generated[n] != on[n]], [])
        names = [line.split("=", 1)[0] for line in off.files["secrets.env"][0].splitlines()]
        self.assertFalse([n for n in names if n.startswith("MEMORY_")])

    def test_generated_values_never_in_compose_or_caddyfile(self):
        rendered = build(manifest_from(EXAMPLE))
        values = rendered.generated
        secrets_env = rendered.files["secrets.env"][0]
        # Positive control: the same search hits every value in secrets.env.
        self.assertEqual([n for n, v in values.items() if v not in secrets_env], [])
        for rel in ("compose.yaml", "Caddyfile", "services.txt", "meta-data"):
            text = rendered.files[rel][0]
            self.assertEqual([n for n, v in values.items() if v in text], [], rel)

    def test_secret_files_are_written_0600_and_out_dir_0700(self):
        out = os.path.join(self.tmp, "modes")
        render(manifest_from(EXAMPLE), out)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o700)
        for rel in ("secrets.env", "user-data"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, rel)).st_mode), 0o600, rel)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(out, "compose.yaml")).st_mode), 0o644)

    def test_generated_formats_match_their_consumers(self):
        import base64

        values = build(manifest_from(EXAMPLE)).generated
        self.assertEqual(len(base64.b64decode(values["VAULT_MASTER_KEY"], validate=True)), 32)
        self.assertGreaterEqual(len(values["SECRET_KEY_BASE"]), 64)
        for name in (
            "ATTACHMENT_SIGNING_KEY",
            "MEETING_GUEST_SIGNING_KEY",
            "MEETING_CALENDAR_SIGNING_KEY",
        ):
            self.assertGreaterEqual(len(values[name]), 32, name)
        for name in ("POSTGRES_PASSWORD", "MEMORY_DB_PASSWORD"):
            self.assertRegex(values[name], r"^[0-9a-f]{48}$", name)
        for name, value in values.items():
            self.assertNotRegex(value, r"[\s\"'$`\\#]", name)

    def test_cli_render_prints_names_never_values(self):
        out = os.path.join(self.tmp, "cli")
        code, stdout = run_cli("render", EXAMPLE, "--out", out)
        self.assertEqual(code, 0, stdout)
        values = parse_env_file(os.path.join(out, "secrets.env"))
        self.assertIn("secret generated-or-reused POSTGRES_PASSWORD", stdout)
        self.assertIn("file secrets.env 0600", stdout)
        self.assertEqual([n for n, v in values.items() if v in stdout], [])

    def test_customer_secret_is_required_and_kept_out_of_secrets_env(self):
        m = manifest_from(BYO)
        with self.assertRaises(RenderError) as ctx:
            build(m)
        self.assertEqual(ctx.exception.code, "customer_secret_missing")
        self.assertEqual(ctx.exception.path, "models.endpoints[0].api_key_ref")
        supplied = os.path.join(self.tmp, "customer.env")
        with open(supplied, "w") as handle:
            handle.write("OWN_LLM_API_KEY=customer-value-01a0d69d\nUNUSED=x\n")
        rendered = build(m, customer_secrets=supplied)
        self.assertEqual(sorted(rendered.customer), ["OWN_LLM_API_KEY"])
        self.assertIn("customer-value-01a0d69d", rendered.files["customer-secrets.env"][0])
        for rel in ("secrets.env", "compose.yaml", "Caddyfile", "models.json"):
            self.assertNotIn("customer-value-01a0d69d", rendered.files[rel][0], rel)
        self.assertNotIn("UNUSED", all_text(rendered))

    def test_customer_ref_cannot_shadow_a_generated_name(self):
        raw = load(BYO)
        raw["models"]["endpoints"][0]["api_key_ref"] = "SECRET_KEY_BASE"
        supplied = os.path.join(self.tmp, "customer.env")
        with open(supplied, "w") as handle:
            handle.write("SECRET_KEY_BASE=x\n")
        with self.assertRaises(RenderError) as ctx:
            build(valid(raw), customer_secrets=supplied)
        self.assertEqual(ctx.exception.code, "customer_secret_conflict")

    def test_registry_source_needs_registry_auth(self):
        raw = load(EXAMPLE)
        raw["images"]["source"] = "registry"
        with self.assertRaises(RenderError) as ctx:
            build(valid(raw))
        self.assertEqual(ctx.exception.code, "registry_auth_required")
        auth = os.path.join(self.tmp, "config.json")
        with open(auth, "w") as handle:
            handle.write('{"auths": {"docker.io": {"auth": "c2VjcmV0LTAxYTBkNjlk"}}}\n')
        rendered = build(valid(raw), registry_auth=auth)
        self.assertEqual(rendered.files["registry-auth.json"][1], 0o600)
        self.assertIn("/root/.docker/config.json", rendered.files["user-data"][0])
        self.assertNotIn("pull_policy", rendered.files["compose.yaml"][0])
        self.assertNotIn("ConditionPathExists", rendered.files["user-data"][0])
        for rel in ("compose.yaml", "Caddyfile", "secrets.env"):
            self.assertNotIn("c2VjcmV0LTAxYTBkNjlk", rendered.files[rel][0], rel)
        self.assertNotIn("c2VjcmV0LTAxYTBkNjlk", "".join(rendered.redacted().values()))

    def test_preloaded_gates_the_unit_and_never_pulls(self):
        rendered = build(manifest_from(EXAMPLE))
        self.assertIn(
            "ConditionPathExists=/opt/burrow/.images-loaded", rendered.files["user-data"][0]
        )
        compose = rendered.files["compose.yaml"][0]
        self.assertEqual(
            compose.count('pull_policy: "never"'),
            len(registry.enabled_containers(manifest_from(EXAMPLE))),
        )
        self.assertIn("--pull never", rendered.files["user-data"][0])


# ---------------------------------------------------------------------------
# (e) no baked endpoints
# ---------------------------------------------------------------------------


class NoBakedEndpointsTest(PositiveControlMixin, TempDirMixin, unittest.TestCase):
    def test_byo_endpoint_base_url_renders(self):
        # Positive control: a declared endpoint DOES reach the render, so the
        # absence check below can fail.
        supplied = os.path.join(self.tmp, "customer.env")
        with open(supplied, "w") as handle:
            handle.write("OWN_LLM_API_KEY=k\n")
        rendered = build(manifest_from(BYO), customer_secrets=supplied)
        self.assertIn("https://llm.byo-endpoint.example/v1", rendered.files["models.json"][0])
        self.assertIn("https://llm.byo-endpoint.example/v1", rendered.files["user-data"][0])

    def test_manifest_without_models_renders_no_literal_of_ours(self):
        for path in (EXAMPLE, MEMORY_OFF, VOICE_CUDA):
            with self.subTest(manifest=os.path.basename(path)):
                m = manifest_from(path)
                self.assertEqual(m["models"]["endpoints"], [])
                rendered = build(m)
                self.assertNotIn("models.json", rendered.files)
                text = all_text(rendered)
                # The image namespace is the manifest's own input (task
                # 01a14b9e), so image refs are searched like everything else.
                self.assertEqual([f for f in FORBIDDEN if f in text], [])
                self.assertEqual(identity_hits(text), [])

    def test_forbidden_search_can_hit(self):
        raw = load(BYO)
        # A LAN address planted on purpose; assembled so this file does not
        # carry one (task 01a14b9e stage 5).
        raw["models"]["endpoints"][0]["base_url"] = "http://" + "192." + "168.0.9:8000/v1"
        raw["models"]["endpoints"][0].pop("api_key_ref")
        self.assertIn("192.168.", all_text(build(valid(raw))))

    def test_identity_search_can_hit(self):
        raw = load(BYO)
        raw["models"]["endpoints"][0]["base_url"] = f"http://llm.{planted_term()}.example/v1"
        raw["models"]["endpoints"][0].pop("api_key_ref")
        hits = identity_hits(all_text(build(valid(raw))))
        # the endpoint is rendered more than once (models.json and user-data)
        self.assertGreater(len(hits), 0)
        self.assertEqual(set(hits), {planted_term()})


# ---------------------------------------------------------------------------
# (f) refuse an output dir inside a git work tree
# ---------------------------------------------------------------------------


class GitTreeTest(PositiveControlMixin, TempDirMixin, unittest.TestCase):
    def test_render_outside_git_succeeds(self):
        # Positive control: the same layout without .git renders.
        out = os.path.join(self.tmp, "repo", "out")
        render(manifest_from(EXAMPLE), out)
        self.assertTrue(os.path.exists(os.path.join(out, "secrets.env")))

    def test_refuses_inside_a_git_dir_and_writes_nothing(self):
        for kind in ("dir", "file"):
            with self.subTest(dot_git=kind):
                repo = os.path.join(self.tmp, f"repo-{kind}")
                os.makedirs(repo)
                if kind == "dir":
                    os.makedirs(os.path.join(repo, ".git"))
                else:  # a linked worktree has a .git FILE
                    with open(os.path.join(repo, ".git"), "w") as handle:
                        handle.write("gitdir: /elsewhere\n")
                out = os.path.join(repo, "deep", "out")
                code, stdout = run_cli("render", EXAMPLE, "--out", out)
                self.assertEqual(code, 2)
                self.assertEqual(
                    [line.split(" at ")[0] for line in stdout.splitlines()],
                    ["error output_inside_git_worktree"],
                )
                self.assertFalse(os.path.exists(os.path.join(repo, "deep")))

    def test_refuses_a_non_empty_out_dir(self):
        out = os.path.join(self.tmp, "full")
        os.makedirs(out)
        with open(os.path.join(out, "stale.sql"), "w") as handle:
            handle.write("-- from an earlier render\n")
        with self.assertRaises(RenderError) as ctx:
            render(manifest_from(EXAMPLE), out)
        self.assertEqual(ctx.exception.code, "output_not_empty")

    def test_redact_cli_round_trip(self):
        out = os.path.join(self.tmp, "raw")
        red = os.path.join(self.tmp, "red")
        rendered = render(manifest_from(EXAMPLE), out)
        code, _ = run_cli("redact", out, "--out", red)
        self.assertEqual(code, 0)
        for rel, text in rendered.redacted().items():
            with open(os.path.join(red, rel), encoding="utf-8") as handle:
                self.assertEqual(handle.read(), text, rel)


# ---------------------------------------------------------------------------
# (g) GPU
# ---------------------------------------------------------------------------


class GpuTest(PositiveControlMixin, unittest.TestCase):
    def test_cuda_voice_on_gpu_host_reserves_the_gpu(self):
        rendered = build(manifest_from(VOICE_CUDA))
        compose = rendered.files["compose.yaml"][0]
        block = compose.split("\n  speaches:\n", 1)[1].split("\nvolumes:", 1)[0]
        self.assertIn('image: "ghcr.io/speaches-ai/speaches:latest-cuda"', block)
        self.assertIn('driver: "nvidia"', block)
        self.assertIn('- "gpu"', block)
        self.assertEqual(compose.count('driver: "nvidia"'), 1)
        self.assertIn(
            'STT_BASE_URL: "http://speaches:8000/v1"',
            compose.split("\n  files-service:\n", 1)[1],
        )

    def test_cpu_voice_has_no_reservation(self):
        raw = load(VOICE_CUDA)
        raw["voice"]["accelerator"] = "cpu"
        compose = build(valid(raw)).files["compose.yaml"][0]
        self.assertIn("speaches:latest-cpu", compose)
        self.assertNotIn("nvidia", compose)

    def test_voice_off_renders_no_speaches(self):
        raw = load(VOICE_CUDA)
        raw["services"]["voice"] = False
        text = all_text(build(valid(raw)))
        self.assertNotIn("speaches", text)
        self.assertNotIn("STT_BASE_URL", text)
        self.assertNotIn("nvidia", text)


# ---------------------------------------------------------------------------
# Targets and TLS
# ---------------------------------------------------------------------------


class TargetAndTlsTest(PositiveControlMixin, unittest.TestCase):
    def test_single_host_is_the_default_target(self):
        # Task 01a0d6ab added `mac`; a manifest names its target in
        # install.target, and the example (which sets none) is single-host.
        self.assertEqual(sorted(TARGETS), ["mac", "single-host"])
        self.assertEqual(manifest_from(EXAMPLE)["install"]["target"], "single-host")
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
            main(["render", EXAMPLE, "--out", "/nonexistent-01a0d69d", "--target", "quadlet"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("invalid choice: 'quadlet'", err.getvalue())
        self.assertFalse(os.path.exists("/nonexistent-01a0d69d"))

    def test_target_flag_must_match_the_manifest(self):
        code, out = run_cli("render", EXAMPLE, "--out", "/nonexistent-01a0d6ab", "--target", "mac")
        self.assertEqual(code, 2)
        self.assertTrue(out.startswith("error target_mismatch at --target: "), out)
        self.assertFalse(os.path.exists("/nonexistent-01a0d6ab"))

    def test_internal_tls_mounts_the_bundle_over_the_measured_castore_path(self):
        rendered = build(manifest_from(EXAMPLE))
        compose = rendered.files["compose.yaml"][0]
        self.assertEqual(registry.CASTORE_PATH, "/app/lib/castore-1.0.17/priv/cacerts.pem")
        self.assertIn(f'"./tls/ca-bundle.pem:{registry.CASTORE_PATH}:ro"', compose)
        user_data = rendered.files["user-data"][0]
        self.assertIn("/opt/burrow/bin/burrow-root-ca", user_data)
        self.assertIn(f"castore='{registry.CASTORE_PATH}'", user_data)
        self.assertIn("\ttls internal\n", rendered.files["Caddyfile"][0])
        # The root key is generated on the host; no key material is rendered.
        self.assertNotIn("PRIVATE KEY", all_text(rendered))

    def test_acme_renders_email_and_no_internal_ca(self):
        rendered = build(manifest_from(VOICE_CUDA))
        caddy = rendered.files["Caddyfile"][0]
        self.assertIn("\temail ops@burrow-gpu.test\n", caddy)
        self.assertNotIn("tls internal", caddy)
        text = all_text(rendered)
        self.assertNotIn("ca-bundle", text)
        self.assertNotIn(registry.CASTORE_PATH, text)
        self.assertNotIn("burrow-root-ca", text)

    def test_bundled_auth_wires_core_to_pocket_id(self):
        compose = build(manifest_from(EXAMPLE)).files["compose.yaml"][0]
        core = compose.split("\n  core-platform:\n", 1)[1].split("\n  core-postgres:\n", 1)[0]
        for line in (
            'OIDC_ISSUER: "https://auth.burrow-01a0d69d.test"',
            'OIDC_PKCE_ENABLED: "true"',
            'APP_URL: "https://burrow-01a0d69d.test"',
            'PHX_HOST: "burrow-01a0d69d.test"',
        ):
            self.assertIn(line, core)
        self.assertIn('- "auth.burrow-01a0d69d.test"', compose)

    def test_external_oidc_drops_pocket_id_and_uses_the_customer_secret(self):
        raw = load(EXAMPLE)
        raw["auth"] = {
            "mode": "external-oidc",
            "issuer": "https://id.customer.example",
            "client_id": "suite",
            "client_secret_ref": "CUSTOMER_OIDC_SECRET",
        }
        with tempfile.TemporaryDirectory(prefix="burrow-install-01a0d69d-") as tmp:
            supplied = os.path.join(tmp, "c.env")
            with open(supplied, "w") as handle:
                handle.write("CUSTOMER_OIDC_SECRET=oidc-value-01a0d69d\n")
            rendered = build(valid(raw), customer_secrets=supplied)
        text = all_text(rendered)
        self.assertNotIn("pocket-id", text)
        self.assertNotIn("auth.burrow-01a0d69d.test", text)
        self.assertIn("OIDC_CLIENT_SECRET=oidc-value-01a0d69d", rendered.files["secrets.env"][0])
        self.assertNotIn("customer-secrets.env", rendered.files)
        self.assertIn(
            'OIDC_ISSUER: "https://id.customer.example"', rendered.files["compose.yaml"][0]
        )


# ---------------------------------------------------------------------------
# core's Users page env (task 01a113ea stage 4)
# ---------------------------------------------------------------------------

SIGN_IN_ADMIN_VARS = ("POCKET_ID_ADMIN_ENABLED", "POCKET_ID_ADMIN_URL", "POCKET_ID_API_KEY")


def core_compose_block(compose):
    return compose.split("\n  core-platform:\n", 1)[1].split("\n  core-postgres:\n", 1)[0]


def external_oidc_render(path):
    raw = load(path)
    raw["auth"] = {
        "mode": "external-oidc",
        "issuer": "https://id.customer.example",
        "client_id": "suite",
        "client_secret_ref": "CUSTOMER_OIDC_SECRET",
    }
    with tempfile.TemporaryDirectory(prefix="burrow-install-01a113ea-") as tmp:
        supplied = os.path.join(tmp, "c.env")
        with open(supplied, "w") as handle:
            handle.write("CUSTOMER_OIDC_SECRET=oidc-value-01a113ea\n")
        return build(valid(raw), customer_secrets=supplied)


class SignInAdminEnvTest(PositiveControlMixin, unittest.TestCase):
    """Bundled pocket-id gives core the Users page env; external OIDC gives none.

    The key is pocket-id's admin-grade STATIC_API_KEY, aliased as
    POCKET_ID_API_KEY: it must reach core only through secrets.env (0600).
    """

    def test_bundled_single_host_wires_core_to_the_pocket_id_admin_api(self):
        rendered = build(manifest_from(EXAMPLE))
        compose = rendered.files["compose.yaml"][0]
        core = core_compose_block(compose)
        self.assertIn('POCKET_ID_ADMIN_ENABLED: "true"', core)
        self.assertIn('POCKET_ID_ADMIN_URL: "http://pocket-id:1411"', core)
        # The URL names the upstream Caddy already proxies the auth host to.
        self.assertIn("reverse_proxy pocket-id:1411", rendered.files["Caddyfile"][0])

        key = rendered.generated["STATIC_API_KEY"]
        self.assertGreaterEqual(len(key), 16)  # pocket-id refuses a shorter key
        text, mode = rendered.files["secrets.env"]
        self.assertEqual(mode, 0o600)
        env = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        self.assertEqual(env["POCKET_ID_API_KEY"], key)
        self.assertEqual(env["STATIC_API_KEY"], key)
        # Never in compose.yaml: neither the name nor the value.
        self.assertNotIn("POCKET_ID_API_KEY", compose)
        self.assertNotIn(key, compose)
        self.assertNotIn(key, rendered.files["Caddyfile"][0])

    def test_external_oidc_writes_none_of_the_users_page_vars(self):
        # Positive control: the bundled render of the same manifest has all three.
        bundled = all_text(build(manifest_from(EXAMPLE)))
        for name in SIGN_IN_ADMIN_VARS:
            self.assertIn(name, bundled)
        text = all_text(external_oidc_render(EXAMPLE))
        for name in (*SIGN_IN_ADMIN_VARS, "STATIC_API_KEY", "pocket-id:1411"):
            self.assertNotIn(name, text)


# ---------------------------------------------------------------------------
# bundled pocket-id log level (task 01a114c1 stage 2)
# ---------------------------------------------------------------------------

MAC_EXAMPLE = os.path.join(REPO, "deployment", "examples", "mac.install.toml")
MAC_RENDER_FIXTURES = os.path.join(HERE, "render_fixtures")
POCKET_ID_LOG_LEVEL = 'LOG_LEVEL: "error"'


def compose_service_block(compose, service):
    """The lines of one top-level compose service, header excluded."""
    match = re.search(rf"^  {re.escape(service)}:\n((?:    .*\n)*)", compose, re.MULTILINE)
    if not match:
        raise AssertionError(f"no {service} service in compose.yaml")
    return match.group(1)


class PocketIdLogLevelTest(PositiveControlMixin, unittest.TestCase):
    """pocket-id's request log carries one-time sign-in codes in the URL path.

    The bundled pocket-id runs at LOG_LEVEL=error so only 5xx request lines
    are written. The assertions read the pocket-id service block, not the
    whole file.
    """

    def renders(self):
        mac = build(
            manifest_from(MAC_EXAMPLE),
            customer_secrets=os.path.join(MAC_RENDER_FIXTURES, "mac-customer.env"),
            registry_auth=os.path.join(MAC_RENDER_FIXTURES, "mac-registry-auth.json"),
        )
        return {"single-host": build(manifest_from(EXAMPLE)), "mac": mac}

    def test_bundled_pocket_id_runs_at_error_and_nothing_else_inherits_it(self):
        for name, rendered in self.renders().items():
            with self.subTest(render=name):
                compose = rendered.files["compose.yaml"][0]
                pocket_id = compose_service_block(compose, "pocket-id")
                # The extractor found the right block.
                self.assertIn('image: "ghcr.io/pocket-id/pocket-id:', pocket_id)
                self.assertIn(POCKET_ID_LOG_LEVEL, pocket_id)
                # Scope control: the level belongs to pocket-id alone.
                self.assertNotIn(
                    POCKET_ID_LOG_LEVEL, compose_service_block(compose, "core-platform")
                )
                self.assertEqual(compose.count(POCKET_ID_LOG_LEVEL), 1)
                # Not a secret: it must not move into secrets.env.
                self.assertNotIn("LOG_LEVEL", rendered.files["secrets.env"][0])

    def test_the_block_reader_tells_services_apart(self):
        # Positive control for the scoping: in the mac render another service
        # sets its own LOG_LEVEL, and the reader returns that value for it.
        compose = self.renders()["mac"].files["compose.yaml"][0]
        transcriber = compose_service_block(compose, "meeting-transcriber")
        self.assertIn('LOG_LEVEL: "INFO"', transcriber)
        self.assertNotIn(POCKET_ID_LOG_LEVEL, transcriber)
        self.assertNotIn('LOG_LEVEL: "INFO"', compose_service_block(compose, "pocket-id"))

    def test_external_oidc_renders_no_pocket_id_log_level(self):
        compose = external_oidc_render(EXAMPLE).files["compose.yaml"][0]
        self.assertNotRegex(compose, r"(?m)^  pocket-id:$")
        self.assertNotIn(POCKET_ID_LOG_LEVEL, compose)


if __name__ == "__main__":
    unittest.main()


class HealthcheckPortTest(unittest.TestCase):
    """A compose healthcheck must probe the port the service listens on.

    Measured on the throwaway VM (stage 3): llama.cpp's stock HEALTHCHECK
    probes 8080 while the rendered server listens on 8188, so a healthy
    embeddings server showed as unhealthy.
    """

    def test_embeddings_healthcheck_probes_its_listen_port(self):
        svc = registry.SERVICES["embeddings"]
        command = svc.command_for(registry.Ctx(manifest_from(EXAMPLE)))
        port = command[command.index("--port") + 1]
        self.assertEqual(svc.healthcheck, ["CMD", "curl", "-f", f"http://localhost:{port}/health"])


# ---------------------------------------------------------------------------
# (f) build-time modules choose the core image flavour (ADR 0055, task
#     01a0ee08 stage 4)
# ---------------------------------------------------------------------------


def _ci_main_build_steps():
    """The steps of ci.yml that publish tags on main, as text.

    Since task 01a0d6ab the `core` flavour is built per arch by digest and
    tagged by publish-manifest's `Create manifest list (main)` step
    (`docker buildx imagetools create -t ...`); the `play` flavour is still
    tagged by its `Build and push play (main)` step.
    """
    with open(CI_WORKFLOW, encoding="utf-8") as handle:
        text = handle.read()
    steps = re.split(r"^(?=      - name: )", text, flags=re.MULTILINE)
    return [
        s
        for s in steps
        if re.match(r"      - name: (Build and push \S+|Create manifest list) \(main\)", s)
    ]


# CI publishes to GHCR only (task 01a14afe). The installer's registry refs
# are under images.registry (01a14dd8); its legacy refs under
# images.image_namespace still render the old Docker Hub names, images that
# are frozen at their last Docker Hub push.


def _published_tags(step):
    """Image refs a step tags: `tags:` list lines and `-t <ref> \\` arguments."""
    refs = re.findall(r"^\s+(?:-t )?((?:docker|ghcr)\.io/\S+?)(?: \\)?$", step, flags=re.MULTILINE)
    return set(refs)


def _ci_publish_refs(text):
    """Every ref a workflow publishes, in file order.

    Each `outputs: type=image,"name=a,b"` name, each `tags: |` list entry and
    each `-t <ref> \\` argument; comment lines are dropped first. Refs may
    contain `${{ ... }}` with spaces, so each runs to the end of its line.
    """
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    outputs = [
        name
        for names in re.findall(r'^\s+outputs: type=image,"name=([^"]+)"', code, re.MULTILINE)
        for name in names.split(",")
    ]
    tags = [
        entry.strip()
        for _indent, block in re.findall(r"^( +)tags: \|\n((?:\1  .*\n?)+)", code, re.MULTILINE)
        for entry in block.splitlines()
        if entry.strip()
    ]
    dash_t = re.findall(r"^\s+-t (.+?) \\\s*$", code, re.MULTILINE)
    return outputs + tags + dash_t


class ModuleFlavourTest(PositiveControlMixin, unittest.TestCase):
    def core_image(self, path_or_raw):
        manifest = (
            manifest_from(path_or_raw) if isinstance(path_or_raw, str) else valid(path_or_raw)
        )
        return plan(manifest).core_image

    def test_no_modules_runs_the_core_flavour(self):
        self.assertEqual(self.core_image(EXAMPLE), "ghcr.io/example/core:core")

    def test_play_runs_the_play_flavour(self):
        self.assertEqual(self.core_image(PLAY), "ghcr.io/example/core:play")

    def test_play_fixture_differs_from_example_in_one_field(self):
        example, play = load(EXAMPLE), load(PLAY)
        self.assertEqual(play["install"].pop("modules"), ["play"])
        self.assertEqual(example, play)

    def test_selecting_play_changes_only_the_core_image_and_its_gate(self):
        # The module is compiled into the image, so the WHOLE render diff of
        # "add play" is the image tag plus Play's transitional in-module gate
        # (registry.MODULE_CORE_ENV): no container, secret, volume or route.
        core = build(manifest_from(EXAMPLE)).redacted()
        play = build(manifest_from(PLAY)).redacted()
        self.assertEqual(sorted(core), sorted(play))
        changed = [rel for rel in sorted(core) if core[rel] != play[rel]]
        self.assertTrue(changed, "positive control: selecting play must change the render")
        for rel in changed:
            with self.subTest(file=rel):
                matcher = difflib.SequenceMatcher(
                    a=core[rel].splitlines(), b=play[rel].splitlines(), autojunk=False
                )
                for tag, i1, i2, j1, j2 in matcher.get_opcodes():
                    if tag == "equal":
                        continue
                    removed = core[rel].splitlines()[i1:i2]
                    added = play[rel].splitlines()[j1:j2]
                    self.assertEqual(
                        [line.replace("/core:core", "/core:play") for line in removed],
                        [line for line in added if "GAME_STREAM_ENABLED" not in line],
                        f"{rel}: selecting play changed more than the image and its gate",
                    )

    def test_play_sets_its_gate_on_core_platform_only(self):
        plan_play = plan(manifest_from(PLAY))
        self.assertEqual(plan_play.services["core-platform"].env.get("GAME_STREAM_ENABLED"), "true")
        for name, svc in plan_play.services.items():
            if name != "core-platform":
                self.assertNotIn("GAME_STREAM_ENABLED", svc.env, name)
        self.assertNotIn(
            "GAME_STREAM_ENABLED", plan(manifest_from(EXAMPLE)).services["core-platform"].env
        )

    def test_an_explicit_core_image_ref_wins_over_the_flavour(self):
        raw = load(PLAY)
        raw["images"]["refs"] = {"core-platform": "registry.example/core:play-pinned"}
        self.assertEqual(self.core_image(raw), "registry.example/core:play-pinned")

    def test_every_module_set_has_a_flavour(self):
        self.assertEqual(
            set(registry.IMAGE_FLAVOURS),
            {frozenset(), frozenset({"play"})},
        )
        self.assertEqual(sorted(registry.MODULES), ["play"])

    def test_every_flavour_tag_is_published_by_ci_on_main(self):
        steps = _ci_main_build_steps()
        # Positive control: the slicer finds the core manifest step and the
        # play build step, and each of them yields at least one tag.
        self.assertEqual(len(steps), 2, "expected the core manifest and play main build steps")
        for step in steps:
            self.assertTrue(_published_tags(step), step.splitlines()[0])
        published = set().union(*map(_published_tags, steps))
        for module_set, tag in registry.IMAGE_FLAVOURS.items():
            with self.subTest(modules=sorted(module_set)):
                # The registry default CI publishes. The legacy Docker Hub
                # name is no longer published (task 01a14afe).
                ghcr = f"ghcr.io/getburrowing/{registry.REGISTRY_IMAGES['core']}:{tag}"
                self.assertIn(ghcr, published)
        # `:latest` is the play image (ci.yml's play main step), not a
        # flavour, so the loop above never asks for it. Pin the play main
        # step's whole GHCR tag set as raw literals, mirroring
        # ci_build_identity_test.exs's @ghcr_play_main_tags (task 01a14afe
        # stage 4: deleting `:latest` used to leave this test green).
        play = [s for s in steps if s.startswith("      - name: Build and push play (main)")]
        self.assertEqual(len(play), 1, "expected exactly one play main build step")
        self.assertIn("ghcr.io/getburrowing/core:latest", _ci_publish_refs(play[0]))
        self.assertEqual(
            _ci_publish_refs(play[0]),
            [
                "ghcr.io/getburrowing/core:play",
                "ghcr.io/getburrowing/core:play-${{ github.sha }}",
                "ghcr.io/getburrowing/core:play-${{ steps.vars.outputs.short_sha }}",
                "ghcr.io/getburrowing/core:latest",
                "ghcr.io/getburrowing/core:${{ github.sha }}",
                "ghcr.io/getburrowing/core:${{ steps.vars.outputs.short_sha }}",
            ],
        )

    def test_ci_publishes_no_docker_hub_ref(self):
        # Task 01a14afe: no step in ci.yml tags or pushes a docker.io ref. The
        # `registry: docker.io` logins that remain are pull auth only.
        with open(CI_WORKFLOW, encoding="utf-8") as handle:
            refs = _ci_publish_refs(handle.read())
        self.assertTrue(
            any(r.startswith("ghcr.io/getburrowing/") for r in refs),
            f"positive control: the extractor must see CI's GHCR refs, got {refs}",
        )
        self.assertEqual([r for r in refs if "docker.io" in r], [])

    def test_ci_publish_ref_extractor_sees_a_planted_docker_hub_ref(self):
        # Positive control for the guard above, one planted ref per form.
        planted = (
            "    steps:\n"
            "      - name: Build\n"
            "        with:\n"
            '          outputs: type=image,"name=docker.io/acme/core,ghcr.io/x/core",push=true\n'
            "          tags: |\n"
            "            docker.io/acme/core:${{ github.sha }}\n"
            "            ghcr.io/x/core:play\n"
            "      - name: Manifest\n"
            "        run: |\n"
            "          docker buildx imagetools create \\\n"
            "            -t docker.io/acme/core:core \\\n"
            "            ${{ steps.digests.outputs.ghcr_refs }}\n"
        )
        self.assertEqual(
            [r for r in _ci_publish_refs(planted) if "docker.io" in r],
            [
                "docker.io/acme/core",
                "docker.io/acme/core:${{ github.sha }}",
                "docker.io/acme/core:core",
            ],
        )

    def test_the_registry_reaches_every_burrow_image(self):
        # Task 01a14dd8: every Burrow default is <images.registry>/<name>.
        def burrow_images(path, **refs):
            raw = load(path)
            raw["images"].pop("image_namespace", None)
            raw["images"]["registry"] = "registry.example.com/acme"
            raw["images"]["refs"] = refs
            services = plan(valid(raw)).services
            return {
                n: svc.image
                for n, svc in services.items()
                if svc.image.startswith("registry.example.com/")
            }

        contained = os.path.join(RENDER_FIXTURES, "single-host-agents-contained.toml")
        self.assertEqual(
            burrow_images(contained),
            {
                "agent-host": "registry.example.com/acme/burrow-agent-host:latest",
                "core-platform": "registry.example.com/acme/core:core",
                "files-service": "registry.example.com/acme/files-service:latest",
                "memory-service": "registry.example.com/acme/memory-service:latest",
            },
        )
        full = plan(manifest_from(os.path.join(RENDER_FIXTURES, "single-host-agents-full.toml")))
        self.assertEqual(full.agent_host_image, "ghcr.io/example/burrow-agent-host:latest")
        # meeting-transcriber has no registry build yet: its ref is pinned.
        pinned = "registry.example.com/acme/meeting-transcriber:v0-pinned"
        self.assertEqual(
            burrow_images(MAC_MEETINGS, **{"meeting-transcriber": pinned})["meeting-transcriber"],
            pinned,
        )

    def test_the_legacy_namespace_reaches_every_legacy_image(self):
        # Task 01a14b9e: every legacy default is docker.io/<image_namespace>/.
        def legacy_images(path):
            raw = load(path)
            raw["images"].pop("registry", None)
            raw["images"]["image_namespace"] = "acme-images"
            services = plan(valid(raw)).services
            return {n: svc.image for n, svc in services.items() if "/acme-images/" in svc.image}

        contained = os.path.join(RENDER_FIXTURES, "single-host-agents-contained.toml")
        expected = {
            "agent-host": "agent-host",
            "core-platform": "core",
            "files-service": "files-service",
            "memory-service": "memory-service",
        }
        self.assertEqual(
            legacy_images(contained),
            {
                c: f"docker.io/acme-images/{registry.LEGACY_HUB_IMAGES[k]}:"
                + ("core" if k == "core" else "latest")
                for c, k in expected.items()
            },
        )
        self.assertEqual(
            legacy_images(MAC_MEETINGS)["meeting-transcriber"],
            f"docker.io/acme-images/{registry.LEGACY_HUB_IMAGES['meeting-transcriber']}:latest",
        )


class ImageSourceRequiredTest(unittest.TestCase):
    """Exactly one of images.registry and the legacy images.image_namespace,
    with no default (tasks 01a14b9e, 01a14dd8)."""

    def _manifest_without_a_source(self):
        work = tempfile.mkdtemp(prefix="burrow-images-01a14dd8-")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        path = os.path.join(work, "install.toml")
        with open(EXAMPLE, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn('registry = "ghcr.io/example"\n', text)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace('registry = "ghcr.io/example"\n', ""))
        self.assertNotIn("registry", load(path)["images"])
        return work, path

    def test_render_without_it_refuses_naming_the_input_and_writes_nothing(self):
        work, path = self._manifest_without_a_source()
        out = os.path.join(work, "out")
        code, stdout = run_cli("render", path, "--out", out)
        self.assertEqual(code, 2)
        self.assertEqual(
            stdout,
            "error missing_required at images.registry: registry is required and has no "
            "default: the registry path the Burrow images are pulled from, e.g. "
            "ghcr.io/<owner> (<registry>/core)\n",
        )
        self.assertFalse(os.path.exists(out))

    def test_render_with_it_uses_it(self):
        work = tempfile.mkdtemp(prefix="burrow-images-01a14dd8-")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        out = os.path.join(work, "out")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, stdout = run_cli("render", EXAMPLE, "--out", out)
        self.assertEqual(code, 0, stdout)
        self.assertEqual(err.getvalue(), "")
        with open(os.path.join(out, "user-data"), encoding="utf-8") as handle:
            self.assertIn("image='ghcr.io/example/core:core'", handle.read())

    def test_legacy_namespace_renders_the_old_refs_and_warns(self):
        _work, path = self._manifest_without_a_source()
        raw = load(path)
        raw["images"]["image_namespace"] = "example"
        legacy = valid(raw)
        self.assertEqual(plan(legacy).core_image, "docker.io/example/suite-core:core")
        # The CLI says so on stderr; stdout keeps its contract.
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace("[images]\n", '[images]\nimage_namespace = "example"\n'))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, stdout = run_cli("validate", path)
        self.assertEqual((code, stdout), (0, "ok\n"))
        self.assertEqual(
            err.getvalue(),
            "warning deprecated at images.image_namespace: image_namespace (the legacy Docker "
            "Hub images) is deprecated; those images are no longer published and stay frozen "
            "at their last push; set images.registry instead, e.g. ghcr.io/<owner>\n",
        )

    def test_an_unvalidated_manifest_cannot_reach_a_default_image(self):
        m = manifest_from(EXAMPLE)
        m["images"]["registry"] = None
        m["images"]["image_namespace"] = None
        with self.assertRaises(RenderError) as ctx:
            build(m)
        self.assertEqual(ctx.exception.code, "missing_required")
        self.assertEqual(ctx.exception.path, "images.registry")


class FreshRenderNamesTest(TempDirMixin, unittest.TestCase):
    """A fresh render (images.registry set) carries no pre-01a14dd8 name (task 01a14dd8)."""

    LEGACY = re.compile(r"/opt/suite\b|suite-[a-z@-]+\.service|docker\.io/\S*suite-")

    def renders(self):
        # The mac target's renders: test_mac_render.MacFreshRenderNamesTest.
        cases = {
            "single-host": manifest_from(EXAMPLE),
            "single-host-agents-full": manifest_from(
                os.path.join(RENDER_FIXTURES, "single-host-agents-full.toml")
            ),
            "single-host-agents-contained": manifest_from(
                os.path.join(RENDER_FIXTURES, "single-host-agents-contained.toml")
            ),
        }
        out = {}
        for name, m in cases.items():
            self.assertIsNotNone(m["images"]["registry"], name)
            out[name] = build(m).redacted()
        return out

    def test_positive_control_the_pattern_finds_each_legacy_form(self):
        for text in (
            "WorkingDirectory=/opt/suite",
            "systemctl enable suite-stack.service",
            "/etc/systemd/system/suite-agent@.service",
            'image: "docker.io/example/suite-core:core"',
        ):
            self.assertTrue(self.LEGACY.search(text), text)
        self.assertIsNone(self.LEGACY.search("WorkingDirectory=/opt/burrow burrow-stack.service"))

    @staticmethod
    def without_migrate_script(user_data):
        return cut_migrate_script(user_data)

    def test_no_legacy_path_unit_or_image(self):
        for name, files in self.renders().items():
            self.assertTrue(files, name)
            for rel, text in files.items():
                with self.subTest(case=name, file=rel):
                    if rel == "user-data":
                        self.assertIn('path: "/opt/burrow/bin/burrow-migrate"', text)
                        text, cut = self.without_migrate_script(text)
                        self.assertEqual(cut, 1, "the script body is embedded exactly once")
                    self.assertEqual(self.LEGACY.findall(rel + "\n" + text), [])

    def test_the_cut_is_needed_positive_control(self):
        # Without the cut the scan finds the script's legacy names: the cut is
        # what the test above relies on, so it must be shown to matter.
        user_data = self.renders()["single-host"]["user-data"]
        self.assertTrue(self.LEGACY.findall(user_data))
        self.assertEqual(self.LEGACY.findall(self.without_migrate_script(user_data)[0]), [])

    def test_single_host_installs_under_opt_burrow_with_the_burrow_stack(self):
        user_data = self.renders()["single-host"]["user-data"]
        self.assertIn('path: "/opt/burrow/compose.yaml"', user_data)
        self.assertIn("/etc/systemd/system/burrow-stack.service", user_data)
        self.assertIn('["systemctl", "enable", "burrow-stack.service"]', user_data)
        self.assertIn("WorkingDirectory=/opt/burrow", user_data)

    def test_the_two_image_sources_change_only_image_refs(self):
        # The legacy key is an image input only: paths and units are the same.
        legacy_raw = load(EXAMPLE)
        legacy_raw["images"].pop("registry")
        legacy_raw["images"]["image_namespace"] = "example"
        fresh = build(manifest_from(EXAMPLE)).redacted()
        legacy = build(valid(legacy_raw)).redacted()
        self.assertEqual(sorted(fresh), sorted(legacy))
        mapping = {
            f"ghcr.io/example/{registry.REGISTRY_IMAGES[k]}": (
                f"docker.io/example/{registry.LEGACY_HUB_IMAGES[k]}"
            )
            for k in registry.REGISTRY_IMAGES
        }
        changed = 0
        for rel in fresh:
            mapped = fresh[rel]
            for new, old in mapping.items():
                mapped = mapped.replace(new + ":", old + ":")
            changed += mapped != fresh[rel]
            self.assertEqual(mapped, legacy[rel], rel)
        self.assertTrue(changed, "positive control: the two sources must differ somewhere")


class ModuleProjectTest(unittest.TestCase):
    def test_every_module_names_a_project_with_its_own_mix_file(self):
        for name, project in registry.MODULES.items():
            with self.subTest(module=name):
                self.assertTrue(os.path.isfile(os.path.join(REPO, project, "mix.exs")))
