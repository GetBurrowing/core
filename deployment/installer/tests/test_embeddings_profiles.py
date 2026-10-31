"""Local embeddings (llama.cpp) sized by install tier (core task 01a18f76 stage 1).

Run: PYTHONPATH=deployment/installer python3 -m unittest discover -s deployment/installer/tests -v

registry.EMBEDDINGS_PROFILES holds one MEASURED row per size tier; a tier with
no row gets the "small" row. The renderer turns the install's row into:

- the embeddings container's model file, flags and compose mem_limit;
- memory-service's chunking/batching/clamp env (MEMORY_*);
- core-platform's MEMORY_SERVICE_INGEST_TIMEOUT_MS;
- the model the host downloads and sha256-checks (bin/burrow-fetch-model).

These tests pin the table's own rules (slot >= 1.25 x the largest input,
memory fit, timeouts above the measured worst request) and that every tier
renders exactly its row. The positive control renders a tier and finds the
embeddings block before any assertion reads it, so a renderer that drops the
service fails loudly rather than passing the flag checks vacuously.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(INSTALLER))
EXAMPLE = os.path.join(REPO, "deployment", "examples", "single-host.install.toml")
DO_DROPLET = os.path.join(HERE, "render_fixtures", "do-droplet.toml")
DO_AUTH = os.path.join(HERE, "render_fixtures", "do-droplet-registry-auth.json")

sys.path.insert(0, INSTALLER)

from burrow_install import registry  # noqa: E402 (after the sys.path insert)
from burrow_install.manifest import SIZE_TIERS, load  # noqa: E402 (after the sys.path insert)
from burrow_install.render import build  # noqa: E402 (after the sys.path insert)
from burrow_install.validate import validate  # noqa: E402 (after the sys.path insert)

PROFILES = registry.EMBEDDINGS_PROFILES
ROW_KEYS = {
    "model",
    "ctx",
    "parallel",
    "batch",
    "ubatch",
    "threads",
    "mem_limit",
    "host_ram_mb",
    "siblings_peak_mb",
    "embeddings_peak_mb",
    "max_input_tokens",
    "worst_request_secs",
    "memory_env",
    "core_ingest_timeout_ms",
}
# memory-service's hard-coded HTTP timeout to the embedder (memory-service
# src/memory_service/embedder.py:77, never passed by make_embedder): the one
# bound the installer cannot move.
MEMORY_SERVICE_EMBED_TIMEOUT_SECS = 30
# What never moves with the tier.
FIXED_FLAGS = ["--embedding", "--pooling", "last", "--host", "0.0.0.0", "--port", "8188"]


def normalized(raw):
    errors, manifest = validate(raw)
    if errors:
        raise AssertionError(f"manifest is invalid: {errors}")
    return manifest


def with_tier(path, tier):
    raw = load(path)
    if tier is None:
        raw["install"].pop("size_tier", None)
    else:
        raw["install"]["size_tier"] = tier
    return normalized(raw)


def service_block(text, name, indent):
    """The `<name>:` service block of a compose document, as lines."""
    lines = text.splitlines()
    start = lines.index(f"{indent}{name}:")
    block = []
    for line in lines[start + 1 :]:
        # The block ends at the next line indented no deeper than its head.
        if line.strip() and not line.startswith(indent + " "):
            break
        block.append(line)
    return block


def list_under(block, key):
    """The quoted list items under `key:` in a compose service block."""
    out, inside = [], False
    for line in block:
        stripped = line.strip()
        if stripped == f"{key}:":
            inside = True
            continue
        if inside:
            if stripped.startswith("- "):
                out.append(stripped[2:].strip('"'))
            else:
                break
    return out


def map_under(block, key):
    out, inside, depth = {}, False, None
    for line in block:
        stripped = line.strip()
        if stripped == f"{key}:":
            inside = True
            depth = len(line) - len(line.lstrip())
            continue
        if inside:
            if len(line) - len(line.lstrip()) <= depth:
                break
            k, _, v = stripped.partition(":")
            out[k] = v.strip().strip('"')
    return out


def scalar(block, key):
    for line in block:
        stripped = line.strip()
        if stripped.startswith(f"{key}:"):
            return stripped.split(":", 1)[1].strip().strip('"')
    return None


def expected_command(row):
    return [
        "-m",
        f"/models/{registry.EMBEDDINGS_MODELS[row['model']]['file']}",
        *FIXED_FLAGS,
        "-c",
        str(row["ctx"]),
        "-np",
        str(row["parallel"]),
        "--no-kv-unified",
        "-b",
        str(row["batch"]),
        "-ub",
        str(row["ubatch"]),
        "-t",
        str(row["threads"]),
    ]


def row_for(tier):
    return PROFILES.get(tier, PROFILES[registry.EMBEDDINGS_FALLBACK_TIER])


def render(path, tier, registry_auth=None):
    return build(with_tier(path, tier), registry_auth=registry_auth).files


class EmbeddingsProfileTableTest(unittest.TestCase):
    def test_rows_are_measured_tiers_with_every_field(self):
        self.assertIn(registry.EMBEDDINGS_FALLBACK_TIER, PROFILES)
        self.assertTrue(set(PROFILES) <= set(SIZE_TIERS))
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                self.assertEqual(set(row), ROW_KEYS)
                self.assertIn(row["model"], registry.EMBEDDINGS_MODELS)

    def test_every_slot_holds_the_largest_input_with_25_percent_margin(self):
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                slot = row["ctx"] // row["parallel"]
                self.assertGreaterEqual(slot, 1.25 * row["max_input_tokens"], f"{tier}: {slot}")

    def test_the_clamp_bounds_the_largest_input(self):
        # memory-service cuts every input at MEMORY_EMBEDDING_MAX_INPUT_TOKENS x
        # embedding_chars_per_token (3) chars and chunks at
        # MEMORY_CHUNK_MAX_TOKENS x 3; max_input_tokens is the measured worst
        # token count of an input that long.
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                env = row["memory_env"]
                clamp = int(env["MEMORY_EMBEDDING_MAX_INPUT_TOKENS"])
                chunk = int(env["MEMORY_CHUNK_MAX_TOKENS"])
                self.assertLessEqual(chunk, clamp)  # memory-service refuses to boot otherwise
                self.assertLessEqual(chunk, int(env["MEMORY_EMBEDDING_MAX_BATCH_TOKENS"]))
                self.assertLess(int(env["MEMORY_CHUNK_OVERLAP_TOKENS"]), chunk)

    def test_ubatch_below_the_largest_input_only_on_a_digest_pinned_image(self):
        pinned = "@sha256:" in registry.EMBEDDINGS_IMAGE
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                if row["ubatch"] < row["max_input_tokens"]:
                    self.assertTrue(pinned, "-ub below the largest input needs a pinned image")
                self.assertLessEqual(row["ubatch"], row["batch"])

    def test_the_embeddings_image_is_pinned_by_digest(self):
        image = registry.SERVICES["embeddings"].default_image(None)
        self.assertEqual(image, registry.EMBEDDINGS_IMAGE)
        self.assertRegex(image, r"^ghcr\.io/ggml-org/llama\.cpp:server@sha256:[0-9a-f]{64}$")

    def test_every_row_fits_its_host_under_85_percent(self):
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                need = row["embeddings_peak_mb"] + row["siblings_peak_mb"]
                self.assertLessEqual(need, 0.85 * row["host_ram_mb"], f"{tier}: {need} MB")

    def test_mem_limit_sits_above_the_measured_peak(self):
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                self.assertGreater(row["mem_limit"], row["embeddings_peak_mb"])
                self.assertLessEqual(row["mem_limit"], 1.3 * row["embeddings_peak_mb"])

    def test_the_worst_request_fits_memory_services_embed_timeout_with_margin(self):
        for tier, row in PROFILES.items():
            with self.subTest(tier=tier):
                self.assertLessEqual(
                    1.5 * row["worst_request_secs"], MEMORY_SERVICE_EMBED_TIMEOUT_SECS
                )
                # One slot: memory-service must not queue requests inside llama.cpp,
                # where the queue wait counts against its HTTP timeout.
                self.assertLessEqual(
                    int(row["memory_env"]["MEMORY_EMBEDDING_MAX_CONCURRENCY"]), row["parallel"]
                )

    def test_the_models_are_pinned_to_a_revision_and_a_sha256(self):
        for key, model in registry.EMBEDDINGS_MODELS.items():
            with self.subTest(model=key):
                self.assertIn(model["revision"], model["url"])
                self.assertTrue(model["url"].endswith("/" + model["file"]))
                self.assertRegex(model["sha256"], r"^[0-9a-f]{64}$")
                self.assertNotIn("/main/", model["url"])


class EmbeddingsRenderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Positive control: the block is found and carries a command at all.
        files = render(EXAMPLE, "small")
        if not list_under(service_block(files["compose.yaml"][0], "embeddings", "  "), "command"):
            raise AssertionError("positive control failed: no embeddings command rendered")

    def check(self, files, row):
        compose, user_data = files["compose.yaml"][0], files["user-data"][0]
        for text, indent in ((compose, "  "), (user_data, "        ")):
            emb = service_block(text, "embeddings", indent)
            self.assertEqual(list_under(emb, "command"), expected_command(row))
            self.assertEqual(scalar(emb, "mem_limit"), f"{row['mem_limit']}m")
            self.assertEqual(scalar(emb, "image"), registry.EMBEDDINGS_IMAGE)
            mem = map_under(service_block(text, "memory-service", indent), "environment")
            for key, value in row["memory_env"].items():
                self.assertEqual(mem.get(key), value, key)
            core = service_block(text, "core-platform", indent)
            self.assertEqual(
                map_under(core, "environment").get("MEMORY_SERVICE_INGEST_TIMEOUT_MS"),
                str(row["core_ingest_timeout_ms"]),
            )

    def test_each_tier_renders_its_row_or_the_small_row(self):
        for tier in SIZE_TIERS:
            for path, auth in ((EXAMPLE, None), (DO_DROPLET, DO_AUTH)):
                with self.subTest(tier=tier, manifest=os.path.basename(path)):
                    self.check(render(path, tier, auth), row_for(tier))

    def test_an_unmeasured_tier_never_renders_the_old_reference_flags(self):
        for tier in SIZE_TIERS:
            with self.subTest(tier=tier):
                emb = service_block(render(EXAMPLE, tier)["compose.yaml"][0], "embeddings", "  ")
                command = list_under(emb, "command")
                self.assertNotIn("32768", command)

    def test_a_manifest_without_size_tier_renders_small(self):
        raw = load(EXAMPLE)
        self.assertIn("size_tier", raw["install"])  # the removal below is real
        self.assertEqual(with_tier(EXAMPLE, None)["install"]["size_tier"], "small")
        self.check(render(EXAMPLE, None), PROFILES["small"])

    def test_the_droplet_downloads_and_checks_the_tiers_model(self):
        for tier in SIZE_TIERS:
            with self.subTest(tier=tier):
                model = registry.EMBEDDINGS_MODELS[row_for(tier)["model"]]
                user_data = render(DO_DROPLET, tier, DO_AUTH)["user-data"][0]
                self.assertIn(f"url={model['url']}\n", user_data)
                self.assertIn(f"sha={model['sha256']}\n", user_data)
                self.assertIn(f"dest=/opt/burrow/models/{model['file']}\n", user_data)
                self.assertIn(
                    f"ExecStartPre=/usr/bin/test -s /opt/burrow/models/{model['file']}", user_data
                )

    def test_endpoint_embeddings_get_no_local_sizing(self):
        raw = load(EXAMPLE)
        raw["embeddings"] = {"mode": "endpoint", "base_url": "https://emb.customer.example/v1"}
        compose = build(normalized(raw)).files["compose.yaml"][0]
        self.assertIn("memory-service:", compose)  # positive control: memory is on
        self.assertNotIn("  embeddings:", compose)
        self.assertNotIn("MEMORY_SERVICE_INGEST_TIMEOUT_MS", compose)
        for key in PROFILES["small"]["memory_env"]:
            self.assertNotIn(key, compose)

    def test_only_the_embeddings_service_gets_a_mem_limit(self):
        compose = render(EXAMPLE, "small")["compose.yaml"][0]
        self.assertEqual(compose.count("mem_limit:"), 1)


if __name__ == "__main__":
    unittest.main()
