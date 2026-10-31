"""Service registry: the single source of what each manifest knob turns on.

Every service a Burrow install can run is declared here ONCE, independent of
any render target. An entry says which container the service is, which image
it runs, the env it receives, the env and ``depends_on`` edges it INJECTS INTO
OTHER services, the secrets it owns, the postgres init SQL it needs, its
volumes and host mounts, and the HTTPS routes it serves.

Renderers (``render.py`` + one output layer per target, e.g. ``templates.py``
for ``single-host``) compose their output only from this registry and the
manifest. Turning a service off therefore drops its container and every env
var, secret, init SQL file, volume, mount, route and ``depends_on`` edge it
declares; an injection whose target is not running is dropped too, so nothing
can dangle.

Nothing here is specific to a target. Values are target-neutral:

- env values are plain strings, or contain ``{secret:NAME}`` (a generated
  secret, see ``SECRETS``) or ``{customer:NAME}`` (a customer-supplied secret
  named by a manifest ``*_ref`` field). A target decides how secrets reach a
  container; the single-host target writes every secret-bearing env line to
  ``secrets.env``.
- host mounts are paths relative to the install root (``/opt/burrow`` on a
  single host).

Target-aware entries (task 01a0d6ab). ``Ctx.target`` exists for the mac
target's additions to shared services (pocket-id on the bundled postgres,
core's TRUST_PROXY_HEADERS). They are gated on ``target == "mac"`` ONLY because
every single-host golden file must stay byte-identical; single-host adopts them
by deleting the gate and regenerating its goldens. pocket-id's STATIC_API_KEY
was adopted that way (task 01a113ea stage 4): every bundled-pocket-id install
generates it, because core's Users page (/admin/sign-in-users) calls pocket-id's
admin API with it.
Target-only containers (cloudflared, the tailscale sidecars) are added by
``enabled_containers`` from the manifest's ``[access]`` table.

Container names mirror the live reference-install quadlets so that a rendered stack and an
operator's mental model of that install use the same names. Default image refs mirror
the reference-install quadlets read on 2026-09-25 (task 01a0d69d stage 2).
"""

import base64
import os
import secrets as _random
import shutil
import socket
import subprocess

# ---------------------------------------------------------------------------
# Service set (stage 1). `services` prints exactly this set.
# ---------------------------------------------------------------------------

# Always present in every install, whatever the manifest says.
IMPLICIT_CONTAINERS = ("caddy", "core-platform", "core-postgres")

# `[services]` knob -> container it adds. These four keys are the whole
# `[services]` vocabulary; anything else is `unknown_service`.
OPTIONAL_SERVICES = {
    "files": "files-service",
    "memory": "memory-service",
    "voice": "speaches",
    "embeddings": "embeddings",
    "meetings": "livekit",
}

# The `[services]` knobs each target can run. A knob outside its target's set
# is a validator error (single-host: field_not_applicable for meetings; mac:
# mac_voice_unsupported / mac_local_embeddings_unsupported), never ignored.
TARGET_KNOBS = {
    "single-host": ("files", "memory", "voice", "embeddings"),
    "mac": ("files", "memory", "meetings"),
}

# `[meetings] transcription = true` (meetings on) adds this container.
TRANSCRIBER = "meeting-transcriber"

# target = "mac": `[access] mode` -> the containers that carry the public
# hostnames to Caddy. Tailscale runs one sidecar per hostname, because one
# ts.net node has one name and pocket-id cannot be served under a path.
ACCESS_CONTAINERS = {
    "cloudflare-tunnel": ("cloudflared",),
    "tailscale": ("tailscale-primary", "tailscale-auth", "tailscale-livekit"),
}

# `[agents] profile = "contained"` adds this container (task 01a10322 stage 3).
# `full_machine` adds none: its agent host is a service on the HOST, rendered
# by the target layer (templates.py + agents.py).
AGENT_HOST = "agent-host"


# ---------------------------------------------------------------------------
# Where the Burrow images come from (task 01a14b9e; registry: task 01a14dd8).
# ---------------------------------------------------------------------------

# A manifest names exactly ONE image source, with no default (a default would
# name one publisher; validate.py refuses neither-or-both, and image_repo
# raises if an unvalidated manifest gets this far):
#
#   [images] registry         `<registry>/<name>`, e.g. ghcr.io/example/core.
#                             The source for every new install.
#   [images] image_namespace  LEGACY (deprecated, validate warns): the Docker
#                             Hub refs every install used before task 01a14dd8,
#                             rendered unchanged (LEGACY_HUB_IMAGES below).
#                             CI stopped publishing them with task 01a14afe:
#                             the Docker Hub repos stay (for rollback), but
#                             every tag is frozen at its last push, so a legacy
#                             install receives no new images.
IMAGE_REGISTRY_INPUT = "images.registry"
IMAGE_NAMESPACE_INPUT = "images.image_namespace"

# Image key -> repository name under [images] registry.
REGISTRY_IMAGES = {
    "core": "core",
    "files-service": "files-service",
    "memory-service": "memory-service",
    "meeting-transcriber": "meeting-transcriber",
    "agent-host": "burrow-agent-host",
}

# Image key -> legacy repository name: docker.io/<image_namespace>/suite-core and
# the rest, exactly as rendered before task 01a14dd8. No longer published
# (task 01a14afe); these refs resolve to images frozen at their last push.
LEGACY_HUB_IMAGES = {
    "core": "suite-core",
    "files-service": "suite-files-service",
    "memory-service": "suite-memory-service",
    "meeting-transcriber": "suite-meeting-transcriber",
    "agent-host": "suite-agent-host",
}

assert set(REGISTRY_IMAGES) == set(LEGACY_HUB_IMAGES), "every image needs both names"

# Images with no published build under [images] registry yet. Measured on
# 2026-10-18: meeting-transcriber publishes only on a `v*` tag and has no GHCR
# package, so a registry install that runs it must pin images.refs for it
# (validate.py), and its default stays the legacy Docker Hub ref only.
# Delete the entry once the package exists.
UNPUBLISHED_IN_REGISTRY = frozenset({"meeting-transcriber"})


class ImageNamespaceMissing(ValueError):
    """A render reached an image default with no image source in [images]."""


class ImageUnpublished(ValueError):
    """A render reached a registry default for an image that has no build there."""

    def __init__(self, key, container):
        super().__init__(
            f"{key} has no published image under images.registry yet; "
            f"pin images.refs.{container} or use the legacy images.image_namespace"
        )
        self.key = key
        self.container = container


# Image key -> the container whose images.refs entry overrides it.
IMAGE_CONTAINERS = {
    "core": "core-platform",
    "files-service": "files-service",
    "memory-service": "memory-service",
    "meeting-transcriber": "meeting-transcriber",
    "agent-host": "agent-host",
}


def image_namespace(manifest):
    """The legacy Docker Hub namespace, or None."""
    return manifest["images"].get("image_namespace")


def image_registry(manifest):
    """The ``[images] registry`` path, or None."""
    return manifest["images"].get("registry")


def image_repo(manifest, key):
    """The repository of image ``key`` for this install, without a tag."""
    registry = image_registry(manifest)
    if registry:
        if key in UNPUBLISHED_IN_REGISTRY:
            raise ImageUnpublished(key, IMAGE_CONTAINERS[key])
        return f"{registry}/{REGISTRY_IMAGES[key]}"
    namespace = image_namespace(manifest)
    if namespace:
        return f"docker.io/{namespace}/{LEGACY_HUB_IMAGES[key]}"
    raise ImageNamespaceMissing(
        f"{IMAGE_REGISTRY_INPUT} is required and has no default: the registry path "
        "the Burrow images are pulled from (e.g. ghcr.io/<owner>)"
    )


def default_image(manifest, key):
    """``<repo>:latest`` for the images that publish one tag."""
    return f"{image_repo(manifest, key)}:latest"


def agent_host_image(manifest):
    """The agent-host image's default ref for this install."""
    return default_image(manifest, "agent-host")


# `[auth] mode` -> container it adds (None: the identity provider is external).
AUTH_CONTAINERS = {
    "bundled-pocket-id": "pocket-id",
    "external-oidc": None,
}

# ---------------------------------------------------------------------------
# Build-time modules (ADR 0055, task 01a0ee08 stage 4).
# ---------------------------------------------------------------------------

# `install.modules` vocabulary -> the Mix project under apps/ that implements
# it. A module is not a container: it is compiled into core-platform's image,
# so selecting one changes WHICH core image the install runs, plus the env in
# MODULE_CORE_ENV below, and nothing else in the render.
MODULES = {
    "play": "apps/game_stream",
}

# Env a selected module needs on core-platform. Play still gates itself on
# GAME_STREAM_ENABLED inside the module until every install runs an explicit
# flavour tag (ADR 0055 § 9, follow-up 1), so a with-Play install without it
# would run the with-Play image with Play inert. Delete the entry with that
# follow-up; selecting the module is then the image alone.
MODULE_CORE_ENV = {
    "play": {"GAME_STREAM_ENABLED": "true"},
}

# Module set -> the image flavour tag CI publishes for it
# (.github/workflows/ci.yml, `build-and-push`). One release host is built per
# supported set, so every set an install may select must be listed here; the
# assertion below makes adding a module without deciding its flavours an
# import error rather than a render that names an image nobody builds.
IMAGE_FLAVOURS = {
    frozenset(): "core",
    frozenset({"play"}): "play",
}


def _subsets(names):
    names = sorted(names)
    for mask in range(1 << len(names)):
        yield frozenset(n for i, n in enumerate(names) if mask >> i & 1)


assert set(MODULE_CORE_ENV) <= set(MODULES), "MODULE_CORE_ENV names an unknown module"
assert set(IMAGE_FLAVOURS) == set(_subsets(MODULES)), (
    "every subset of MODULES needs an image flavour"
)


def core_image_repo(manifest):
    """``<registry>/core`` (legacy: ``docker.io/<image_namespace>/<LEGACY_HUB_IMAGES["core"]>``)."""
    return image_repo(manifest, "core")


def core_image(ctx):
    """The core image for the install's module set, e.g. ``<registry>/core:play``."""
    return f"{core_image_repo(ctx.m)}:{IMAGE_FLAVOURS[frozenset(ctx.m['install']['modules'])]}"


ALL_CONTAINERS = tuple(
    sorted(
        set(IMPLICIT_CONTAINERS)
        | set(OPTIONAL_SERVICES.values())
        | {c for c in AUTH_CONTAINERS.values() if c}
        | {TRANSCRIBER}
        | {c for cs in ACCESS_CONTAINERS.values() for c in cs}
        | {AGENT_HOST}
    )
)


def enabled_containers(manifest):
    """Return the sorted container names a normalized, valid manifest runs.

    `embeddings` only adds a container in `mode = "local"`; in
    `mode = "endpoint"` the capability is on but served remotely.
    """
    services = manifest["services"]
    names = set(IMPLICIT_CONTAINERS)
    for knob, container in OPTIONAL_SERVICES.items():
        if not services[knob]:
            continue
        if knob == "embeddings" and manifest["embeddings"]["mode"] != "local":
            continue
        names.add(container)
    if services["meetings"] and manifest["meetings"]["transcription"]:
        names.add(TRANSCRIBER)
    auth_container = AUTH_CONTAINERS[manifest["auth"]["mode"]]
    if auth_container:
        names.add(auth_container)
    if manifest["agents"]["profile"] == "contained":
        names.add(AGENT_HOST)
    if manifest["install"]["target"] == "mac":
        mode = manifest["access"]["mode"]
        if mode == "cloudflare-tunnel":
            names.add("cloudflared")
        else:
            names.add("tailscale-primary")
            if auth_container:
                names.add("tailscale-auth")
            if services["meetings"]:
                names.add("tailscale-livekit")
    return sorted(names)


# ---------------------------------------------------------------------------
# Measured facts the registry depends on.
# ---------------------------------------------------------------------------

# Where CAStore's bundle lives inside the core image. It is core's trust store:
# apps/platform/config/runtime.exs:3-10 loads it for :ssl and :public_key, and
# Platform.OIDC.http_adapter/1 points sign-in at it (Assent's Httpc adapter would
# otherwise use certifi's compiled-in list; ADR 0053 section 4). So a
# `tls = "internal"` install bind-mounts a combined bundle (this file + the
# install's own root) over it; without that, core's OIDC discovery to
# https://auth.<primary> fails.
# Measured 2026-09-25 with `find / -path '*castore*' -name '*.pem'` inside the
# throwaway container castore-01a0d69d on the test host, image
# suite-core:latest, image id sha256:42600a534f02b6f5...,
# repo digests sha256:843a721c0dc11992... and sha256:a59c99b6a090aa05...
# (castore 1.0.17). The path carries the castore VERSION, so a castore bump in
# core moves it. The single-host CA-bundle script fails loudly (never silently)
# when the file is gone; ADR 0053 follow-up 10 retires this mount.
CASTORE_PATH = "/app/lib/castore-1.0.17/priv/cacerts.pem"

# The embeddings models, by key. Both are the official Qwen files on Hugging
# Face at a FIXED revision commit, never a branch, each checked against its
# sha256 at download (bin/burrow-fetch-model). A model change re-embeds:
# vectors from one model are not interchangeable with another's, so an install
# keeps the model it was first rendered with (its size tier).
#
# "f16": the reference install's model. Measured 2026-10-30: the Hugging Face
# API tree at this revision lists it with size 1197629632 and the LFS sha256
# below, and `sha256sum` of the reference install's own copy
# (embeddings.container's /models/Qwen3-Embedding-0.6B-f16.gguf) prints the
# same sha256.
# "q8_0" (core task 01a18f76, a declared model change for the 4 GB tier):
# same repo and revision; the Hugging Face tree lists size 639150592 and the
# LFS sha256 below, and `sha256sum` of the file downloaded on moon and on two
# s-2vcpu-4gb droplets printed it (2026-10-31). Its vectors against f16 on 23
# real inputs (20 chunks of the largest org page and a day's journal, 2
# queries, 1 CJK chunk): cosine min 0.99747, mean 0.99914; both queries'
# top-5 over the 20 chunks were the same set.
_HF_REVISION = "370f27d7550e0def9b39c1f16d3fbaa13aa67728"
_HF_BASE = "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/" + _HF_REVISION + "/"
EMBEDDINGS_MODELS = {
    "f16": {
        "file": "Qwen3-Embedding-0.6B-f16.gguf",
        "url": _HF_BASE + "Qwen3-Embedding-0.6B-f16.gguf",
        "revision": _HF_REVISION,
        "sha256": "421a27e58d165478cc7acb984a688c2aa41404968b0203e7cd743ece44c54340",
        "size": 1197629632,
    },
    "q8_0": {
        "file": "Qwen3-Embedding-0.6B-Q8_0.gguf",
        "url": _HF_BASE + "Qwen3-Embedding-0.6B-Q8_0.gguf",
        "revision": _HF_REVISION,
        "sha256": "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439",
        "size": 639150592,
    },
}
# The reference install's model file (f16). Kept for callers that name it.
EMBEDDINGS_MODEL_FILE = EMBEDDINGS_MODELS["f16"]["file"]
EMBEDDINGS_MODEL_SOURCE = {k: v for k, v in EMBEDDINGS_MODELS["f16"].items() if k != "file"}

# The llama.cpp server image, pinned BY DIGEST (core task 01a18f76): the
# profiles below run -ub smaller than the largest input, which needs a build
# whose server splits one pooled embedding across ubatches. Measured on this
# digest (build 12004, commit 3c809f443) on moon 2026-10-31: a 5569-token
# input at -ub 1024 embedded with 200; a floating tag could move to a build
# that answers "input is too large to process" instead.
EMBEDDINGS_IMAGE = (
    "ghcr.io/ggml-org/llama.cpp:server"
    "@sha256:b32890309c1a33a534a01b0b461e953dc2c5a6bac20213abcf48e22847a19c85"
)

# memory-service's largest SINGLE input to POST /v1/embeddings on the local
# profiles, in llama.cpp tokens. llama.cpp runs each element of `input` as its
# own task on its own slot, so a slot (-c / -np, --no-kv-unified) must hold the
# largest single input, never the request total.
#
# Before this table (memory-service defaults, measured 2026-10-31 on moon
# behind a logging proxy counting with llama.cpp's own POST /tokenize): the
# largest input was a search query at the wire clamp, embedding_max_input_tokens
# x embedding_chars_per_token = 6000 x 3 = 18000 chars (memory-service
# config.py:38-39, embedder.py:104): 5569 tokens of the largest org page, 26630
# of CJK + emoji. Chunks were at most 2400 chars (config.py:56 x :39): 823
# tokens of English, 3571 of a CJK + emoji mix.
#
# The local profiles now set the clamp and the chunk size through
# memory_env, so every input (chunk or query, the 58-char query prefix
# included) is at most MEMORY_EMBEDDING_MAX_INPUT_TOKENS x 3 chars. A char is
# at most 4 UTF-8 bytes and llama.cpp's byte-level BPE emits at most one token
# per byte, so `max_input_tokens` below is that byte bound plus the special
# token, not a sample: 600 chars -> 2401. Measured on the same 600 chars: 179
# tokens (English), 905 (CJK + emoji mix).
#
# Local embeddings profiles, keyed by the manifest's `[install] size_tier`
# (core task 01a18f76). Only MEASURED rows are here; a tier without one
# (EMBEDDINGS_FALLBACK_TIER) gets the "small" row, never unmeasured flags.
#
# Row fields: model (EMBEDDINGS_MODELS key), ctx (-c), parallel (-np), batch
# (-b), ubatch (-ub), threads (-t), mem_limit (compose mem_limit, MiB: 1.2 x
# embeddings_peak_mb, so a misfit kills llama.cpp and not Postgres),
# host_ram_mb (MemTotal), siblings_peak_mb, embeddings_peak_mb (llama-server
# VmHWM, model pages included), max_input_tokens (above), worst_request_secs
# (the slowest single request memory-service can send on this tier),
# memory_env (memory-service env) and core_ingest_timeout_ms (core-platform's
# MEMORY_SERVICE_INGEST_TIMEOUT_MS, config/runtime.exs). Rules, pinned by
# tests/test_embeddings_profiles.py:
#   ctx / parallel >= 1.25 x max_input_tokens
#   ubatch < max_input_tokens only with EMBEDDINGS_IMAGE pinned by digest
#   embeddings_peak_mb + siblings_peak_mb <= 0.85 x host_ram_mb
#   1.5 x worst_request_secs <= 30, memory-service's embedder HTTP timeout,
#     which is hard-coded (memory-service embedder.py:77; make_embedder never
#     passes one), so the request is sized to it, not the other way round
#
# "small" (s-2vcpu-4gb; measured 2026-10-31 on moon and on s-2vcpu-4gb
# droplets 614434112, 614442358 and 614446111 in nyc1, image above):
# - model q8_0 (a declared change from f16, see EMBEDDINGS_MODELS): f16 does
#   not fit. At these flags f16 peaks at 2185 MiB (moon) / 2157 (droplet);
#   q8_0 at 1645 (moon, worst-case inputs at concurrency 4) / 1639 (droplet).
# - host_ram_mb: droplet MemTotal 4009860 kB = 3915 MiB; 85% = 3327.
# - siblings_peak_mb 1412: docker stats after 10 idle minutes with embeddings
#   and memory-service stopped (core-platform 485, core-postgres 102,
#   files-service 93, pocket-id 64, caddy 35), plus memory-service 209 (moon,
#   image sha256:24b68f10eda1) and an agent-host allowance of 425 (the
#   reference agent-host container's cgroup memory.peak; the droplet's
#   native agent host idled at 28). DECLARED MARGIN: with the siblings' cgroup
#   memory.peak instead (core 566, core-postgres 147, files 120, pocket-id 82,
#   caddy 59, memory-service 293, agent-host 425 = 1692), the total is 3337
#   MiB, 9 MiB over the 85% line, which is a safety line, not the OOM point
#   (the proof run checks the kernel log under full ingest).
# - speed, -t 2 on the droplet: one request runs about 41-55 tokens/s. A
#   2400-char chunk took 12.3 s (English, 631 tokens) and 100.2 s (CJK,
#   3571); 600 chars took 2.96 s (English) and 17.4 s (CJK, 905). So chunks
#   and the clamp are 600 chars (200 x 3) and one chunk per request
#   (MEMORY_EMBEDDING_MAX_BATCH_TOKENS = MEMORY_CHUNK_MAX_TOKENS): the worst
#   measured request is the 17.4 s CJK chunk. Text of rarer scripts (CJK
#   Ext-B tokenizes at 3.03 tokens/char) can still exceed 30 s per chunk.
# - MEMORY_EMBEDDING_MAX_CONCURRENCY 1: one slot, so a second request would
#   wait inside llama.cpp, on memory-service's 30 s clock; at 1 it waits in
#   memory-service's own semaphore, off the clock. Searches queue behind an
#   ingest in progress.
# - core_ingest_timeout_ms 2_700_000 (45 min): proof droplet 614448430,
#   rendered from this table: the 120 KB org page and a 132 KB day's journal
#   ingested CONCURRENTLY through memory-service took 1626.9 s and 1701.9 s
#   (770 embed requests, 0 timeouts or retries, 0 restarts, no oom-kill in
#   journalctl -k, MemAvailable >= 1390 MiB, llama-server VmHWM 1591 MiB);
#   1.5 x 1701.9 s = 2553 s. A larger page can outlast it: memory-service
#   keeps embedding after core gives up, and its single-flight and content
#   hash keep a resend from embedding the entry twice.
EMBEDDINGS_FALLBACK_TIER = "small"
EMBEDDINGS_PROFILES = {
    "small": {
        "model": "q8_0",
        "ctx": 8192,
        "parallel": 1,
        "batch": 1024,
        "ubatch": 1024,
        "threads": 2,
        "mem_limit": 1974,
        "host_ram_mb": 3915,
        "siblings_peak_mb": 1412,
        "embeddings_peak_mb": 1645,
        "max_input_tokens": 2401,
        "worst_request_secs": 17.4,
        "memory_env": {
            "MEMORY_CHUNK_MAX_TOKENS": "200",
            "MEMORY_CHUNK_OVERLAP_TOKENS": "25",
            "MEMORY_EMBEDDING_MAX_BATCH_TOKENS": "200",
            "MEMORY_EMBEDDING_MAX_INPUT_TOKENS": "200",
            "MEMORY_EMBEDDING_MAX_CONCURRENCY": "1",
        },
        "core_ingest_timeout_ms": 2_700_000,
    },
}


def embeddings_profile(manifest):
    """The EMBEDDINGS_PROFILES row for this manifest's size tier.

    A tier with no measured row gets the "small" row, never unmeasured flags.
    """
    tier = manifest["install"]["size_tier"]
    return EMBEDDINGS_PROFILES.get(tier, EMBEDDINGS_PROFILES[EMBEDDINGS_FALLBACK_TIER])


def embeddings_model(manifest):
    """The EMBEDDINGS_MODELS entry this manifest's profile runs."""
    return EMBEDDINGS_MODELS[embeddings_profile(manifest)["model"]]


def _embeddings_command(ctx):
    p = embeddings_profile(ctx.m)
    return [
        "-m",
        f"/models/{embeddings_model(ctx.m)['file']}",
        "--embedding",
        "--pooling",
        "last",
        "--host",
        "0.0.0.0",
        "--port",
        "8188",
        "-c",
        str(p["ctx"]),
        "-np",
        str(p["parallel"]),
        "--no-kv-unified",
        "-b",
        str(p["batch"]),
        "-ub",
        str(p["ubatch"]),
        "-t",
        str(p["threads"]),
    ]


def _embeddings_mem_limit(ctx):
    return f"{embeddings_profile(ctx.m)['mem_limit']}m"


POSTGRES_USER = "core_platform"
POSTGRES_DB = "core_platform"


# ---------------------------------------------------------------------------
# Generated secrets. Each generator produces the format its consumer parses;
# the consumer is recorded next to it (file:line at core origin/main or the
# named service repo, read 2026-09-25).
# ---------------------------------------------------------------------------


def _urlsafe(nbytes):
    return lambda: _random.token_urlsafe(nbytes)


def _hex(nbytes):
    return lambda: _random.token_hex(nbytes)


def _b64_key(nbytes):
    return lambda: base64.b64encode(_random.token_bytes(nbytes)).decode("ascii")


class Secret:
    """A value generated at render time. ``name`` is also its env name."""

    def __init__(self, name, generate, consumer):
        self.name = name
        self.generate = generate
        self.consumer = consumer


SECRETS = {
    s.name: s
    for s in (
        Secret(
            "SECRET_KEY_BASE",
            _urlsafe(48),  # 64 chars; Phoenix wants >= 64 bytes
            "core apps/platform/config/runtime.exs:371-376 (raises at prod boot when unset)",
        ),
        Secret(
            "VAULT_MASTER_KEY",
            _b64_key(32),  # Base.decode64! -> 32-byte AES-256-GCM key
            "core apps/platform/config/runtime.exs:113-127 (raises at :116; "
            "Base.decode64! for Cloak.Ciphers.AES.GCM)",
        ),
        Secret(
            "ATTACHMENT_SIGNING_KEY",
            _urlsafe(48),  # raw key_base for Plug.Crypto.sign; 32+ bytes
            "core apps/platform/config/runtime.exs:241-243; "
            "lib/platform/chat/attachment_presigner.ex:22,52-60",
        ),
        Secret(
            "MEETING_GUEST_SIGNING_KEY",
            _urlsafe(48),
            "core apps/platform/config/runtime.exs:251-253; "
            "lib/platform/meetings/guest_invite.ex:132,251-259",
        ),
        Secret(
            "MEETING_CALENDAR_SIGNING_KEY",
            _urlsafe(48),
            "core apps/platform/config/runtime.exs:264-266; "
            "lib/platform/meetings/calendar_link.ex:66,93-107",
        ),
        Secret(
            "POSTGRES_PASSWORD",
            _hex(24),  # hex: safe unescaped inside the DATABASE_URL userinfo
            "pgvector/pgvector:pg16 entrypoint; core DATABASE_URL, "
            "apps/platform/config/runtime.exs:143-152 (raises at :145)",
        ),
        Secret(
            "ENCRYPTION_KEY",
            _urlsafe(32),
            "pocket-id v2 ENCRYPTION_KEY (at-rest key for its database; "
            "the same env name the reference install's pocket-id runs with)",
        ),
        Secret(
            "OIDC_CLIENT_SECRET",
            _urlsafe(32),
            "core apps/platform/config/runtime.exs:165; the matching pocket-id "
            "client is created at first-run bootstrap (ADR 0053 day-2)",
        ),
        Secret(
            "FILES_SERVICE_TOKEN",
            _urlsafe(32),
            "files-service app/auth.py:21 (refuses to boot unset; Bearer compare); "
            "core runtime.exs:553 and lib/platform/files/service_client.ex:147-149",
        ),
        Secret(
            "MEMORY_SERVICE_API_KEY",
            _urlsafe(32),
            "core runtime.exs:532 and lib/platform/memory/providers/startup_suite.ex:128-129 "
            "(x-api-key header); memory-service reads it as MEMORY_API_KEY, "
            "src/memory_service/config.py:52 (declared, not yet enforced at a24876a)",
        ),
        Secret(
            "LIVEKIT_API_SECRET",
            _urlsafe(32),
            "livekit-server LIVEKIT_KEYS ('<key>: <secret>'); core runtime.exs:490-497 "
            "(meetings are inert unless LIVEKIT_API_KEY and LIVEKIT_API_SECRET are set); "
            "meeting-transcriber config.py LIVEKIT_API_SECRET",
        ),
        Secret(
            "MEETING_AGENT_TOKEN",
            _urlsafe(32),
            "core lib/platform_web/controllers/meeting_agent_controller.ex:115-128 "
            "(Bearer compare, read per request); meeting-transcriber PERSIST_TOKEN",
        ),
        Secret(
            "STATIC_API_KEY",
            _urlsafe(32),
            "pocket-id v2 STATIC_API_KEY (admin API key, X-API-KEY header); used by "
            "the mac first-run bootstrap (task 01a0d6ab stage 4) and, aliased as "
            "POCKET_ID_API_KEY, by core's Users page lib/platform/sign_in_admin/config.ex "
            "(task 01a113ea). Every bundled-pocket-id install, any target",
        ),
        Secret(
            "POCKETID_DB_PASSWORD",
            _hex(24),  # hex: safe inside DB_CONNECTION_STRING and a SQL literal
            "pocket-id init SQL (psql \\getenv) and pocket-id v2 DB_CONNECTION_STRING "
            "(postgres DSN). Target mac only",
        ),
        Secret(
            "MEMORY_DB_PASSWORD",
            _hex(24),  # hex: safe inside MEMORY_DATABASE_URL and a SQL literal
            "memory init SQL (psql \\getenv) and memory-service MEMORY_DATABASE_URL, "
            "src/memory_service/config.py:49",
        ),
        Secret(
            "AGENT_HOST_TOKEN",
            _urlsafe(32),
            "core apps/platform/config/runtime.exs AGENT_HOST_TOKEN (task 01a10322: "
            "Plug.Crypto.secure_compare in PlatformWeb.AgentHostSocket) and the agent "
            "host's own env (services/agent-host/src/main.ts). [agents] on only",
        ),
    )
}


# ---------------------------------------------------------------------------
# Services.
# ---------------------------------------------------------------------------


class Ctx:
    """What a registry entry may read: the normalized manifest plus names."""

    def __init__(self, manifest):
        self.m = manifest
        self.target = manifest["install"]["target"]
        self.mac = self.target == "mac"
        domain = manifest["domain"]
        self.primary = domain["primary"]
        self.auth_host = domain["auth_host"] or f"auth.{self.primary}"
        self.livekit_host = domain["livekit_host"] or f"livekit.{self.primary}"
        # On mac TLS ends at the tunnel's or the tailnet's edge, whose
        # certificate chains to a public root, so there is no install CA.
        self.tls_internal = not self.mac and domain["tls"] == "internal"
        self.bundled_auth = manifest["auth"]["mode"] == "bundled-pocket-id"
        self.agents = manifest["agents"]["profile"]
        self.full_root = self.agents != "off" and manifest["agents"].get("full_root") is True
        self.enabled = set(enabled_containers(manifest))


def _nothing(ctx):
    return {}


class Service:
    """One container. Callables take a ``Ctx``; everything else is static."""

    def __init__(
        self,
        container,
        image,
        *,
        private_image=False,
        command=None,
        mem_limit=None,
        env=_nothing,
        injects=_nothing,
        injects_depends_on=_nothing,
        secrets=(),
        init_sql=_nothing,
        volumes=None,
        host_mounts=lambda ctx: [],
        host_files=lambda ctx: [],
        config_files=_nothing,
        secret_files=_nothing,
        routes=_nothing,
        depends_on=None,
        ports=(),
        gpu=lambda ctx: False,
        healthcheck=None,
        networks=lambda ctx: (),
        systemd_init=False,
        own_env_file=False,
    ):
        self.container = container
        self._image = image
        self.private_image = private_image
        # A list, or a callable taking a Ctx (the embeddings flags by size tier).
        self.command = command
        # Compose mem_limit: None, a string ("2600m") or a callable taking a Ctx.
        self.mem_limit = mem_limit
        self.env = env
        self.injects = injects
        self.injects_depends_on = injects_depends_on
        self.secrets = secrets if callable(secrets) else tuple(secrets)
        self.init_sql = init_sql
        self.volumes = volumes or {}
        self.host_mounts = host_mounts
        self.host_files = host_files
        # {install-relative path: text} rendered by the target (e.g. livekit.yaml).
        # Never a secret: config_files are 0644 and must hold no secret marker.
        self.config_files = config_files
        # {install-relative path: template with a {customer:..}/{secret:..}
        # marker}; written 0600 and mounted into this service only (*_FILE).
        self.secret_files = secret_files
        self.routes = routes
        self._depends_on = depends_on or {}
        self._ports = ports
        self.gpu = gpu
        self.healthcheck = healthcheck
        # Named networks beyond the target's default one (task 01a10322): ()
        # means "the default network only", which every service before the
        # agent host was. A non-empty tuple lists EVERY network, default
        # included if wanted.
        self.networks = networks
        # Runs systemd as PID 1 (the agent-host image).
        self.systemd_init = systemd_init
        # Its secret env goes in its OWN 0600 file holding only its lines, not
        # in the shared secrets.env, which every other reader sees whole.
        self.own_env_file = own_env_file

    def default_image(self, ctx):
        return self._image(ctx) if callable(self._image) else self._image

    def secrets_for(self, ctx):
        return tuple(self.secrets(ctx)) if callable(self.secrets) else self.secrets

    def depends_on_for(self, ctx):
        return dict(self._depends_on(ctx) if callable(self._depends_on) else self._depends_on)

    def ports_for(self, ctx):
        return tuple(self._ports(ctx) if callable(self._ports) else self._ports)

    def command_for(self, ctx):
        return self.command(ctx) if callable(self.command) else self.command

    def mem_limit_for(self, ctx):
        return self.mem_limit(ctx) if callable(self.mem_limit) else self.mem_limit


def _core_env(ctx):
    env = {
        "PHX_SERVER": "true",
        "PHX_HOST": ctx.primary,
        "PORT": "4000",
        "APP_URL": f"https://{ctx.primary}",
        "SECRET_KEY_BASE": "{secret:SECRET_KEY_BASE}",
        "VAULT_MASTER_KEY": "{secret:VAULT_MASTER_KEY}",
        "ATTACHMENT_SIGNING_KEY": "{secret:ATTACHMENT_SIGNING_KEY}",
        "MEETING_GUEST_SIGNING_KEY": "{secret:MEETING_GUEST_SIGNING_KEY}",
        "MEETING_CALENDAR_SIGNING_KEY": "{secret:MEETING_CALENDAR_SIGNING_KEY}",
        "OIDC_PKCE_ENABLED": "true",
    }
    if ctx.mac:
        # cloudflared / tailscale -> Caddy -> core: the client address is in
        # X-Forwarded-For (lib/platform_web/plugs/rewrite_remote_ip.ex).
        env["TRUST_PROXY_HEADERS"] = "true"
    if ctx.m["install"].get("org_name") is not None:
        # Task 01a10315: read once, by the first migrate (seed_root_orgs).
        env["ROOT_ORG_NAME"] = ctx.m["install"]["org_name"]
    for module in sorted(ctx.m["install"]["modules"]):
        env.update(MODULE_CORE_ENV.get(module, {}))
    if ctx.agents != "off":
        # Task 01a10322: without it core refuses every agent host.
        env["AGENT_HOST_TOKEN"] = "{secret:AGENT_HOST_TOKEN}"
        # Task 01a17b10: how native agents log in ([agents] login).
        env["NATIVE_AGENT_LOGIN"] = ctx.m["agents"]["login"]
    if ctx.agents == "contained":
        # Agents in the agent-host container reach core on the agents network,
        # not through the public URL (AgentHost.core_url/0's default).
        env["AGENT_HOST_CORE_URL"] = AGENT_HOST_CORE_URL
    auth = ctx.m["auth"]
    if not ctx.bundled_auth:
        env["OIDC_ISSUER"] = auth["issuer"]
        env["OIDC_CLIENT_ID"] = auth["client_id"]
        env["OIDC_CLIENT_SECRET"] = f"{{customer:{auth['client_secret_ref']}}}"
    return env


_CORE_SECRETS = (
    "SECRET_KEY_BASE",
    "VAULT_MASTER_KEY",
    "ATTACHMENT_SIGNING_KEY",
    "MEETING_GUEST_SIGNING_KEY",
    "MEETING_CALENDAR_SIGNING_KEY",
)


def _core_secrets(ctx):
    names = _CORE_SECRETS + (("AGENT_HOST_TOKEN",) if ctx.agents != "off" else ())
    return [SECRETS[n] for n in names]


def _core_networks(ctx):
    # contained: core-platform is the ONLY service on both networks, so the
    # agent host reaches it and nothing else (task 01a10322, architect note 2).
    return ("default", AGENTS_NETWORK) if ctx.agents == "contained" else ()


# The network the agent host and core-platform share, and the URL agents in
# the agent-host container reach core at over it.
AGENTS_NETWORK = "agents"
AGENT_HOST_CORE_URL = "http://core-platform:4000"


# The one container-runtime socket full_root mounts into the agent-host
# container (core task 01a17b10 stage 3). Nothing is mounted without it.
RUNTIME_SOCKET = "/var/run/docker.sock"


def _agent_host_env(ctx):
    env = {
        "BURROW_CORE_URL": AGENT_HOST_CORE_URL,
        "AGENT_HOST_PROFILE": "contained",
        "AGENT_HOST_TOKEN": "{secret:AGENT_HOST_TOKEN}",
    }
    if ctx.full_root:
        env["AGENT_HOST_FULL_ROOT"] = "true"
    return env


def _agent_host_mounts(ctx):
    return [(RUNTIME_SOCKET, RUNTIME_SOCKET, False)] if ctx.full_root else []


def _core_mounts(ctx):
    if not ctx.tls_internal:
        return []
    return [("tls/ca-bundle.pem", CASTORE_PATH, True)]


def _postgres_injects(ctx):
    url = f"ecto://{POSTGRES_USER}:{{secret:POSTGRES_PASSWORD}}@core-postgres:5432/{POSTGRES_DB}"
    return {"core-platform": {"DATABASE_URL": url}}


def _embedding_key_ref(ctx):
    """The customer ref memory-service authenticates to a hosted embeddings API with."""
    emb = ctx.m["embeddings"]
    return emb["api_key_ref"] if emb["mode"] == "endpoint" else None


def _secret_path(ref):
    return f"/run/secrets/{ref}"


def _memory_env(ctx):
    emb = ctx.m["embeddings"]
    if emb["mode"] == "local":
        embedding_url = "http://embeddings:8188"
    else:
        embedding_url = emb["base_url"]
    env = {
        "MEMORY_HOST": "0.0.0.0",
        "MEMORY_PORT": "8100",
        "MEMORY_EMBEDDING_BACKEND": "http",
        "MEMORY_EMBEDDING_URL": embedding_url,
        "MEMORY_EMBEDDING_MODEL": emb["model"] or "embeddings",
        "MEMORY_DATABASE_URL": "postgresql://memory:{secret:MEMORY_DB_PASSWORD}"
        "@core-postgres:5432/memory",
        "MEMORY_API_KEY": "{secret:MEMORY_SERVICE_API_KEY}",
    }
    # memory-service 2ef3312f (task 01a0d6ab stage 2): a key FILE sends
    # `Authorization: Bearer`, and "" as the prefix sends queries unprefixed.
    ref = _embedding_key_ref(ctx)
    if ref:
        env["MEMORY_EMBEDDING_API_KEY_FILE"] = _secret_path(ref)
    if emb["mode"] == "endpoint" and emb["query_prefix"] is not None:
        env["MEMORY_EMBEDDING_QUERY_PREFIX"] = emb["query_prefix"]
    if emb["mode"] == "local":
        # Chunking, batching and the wire clamp sized for the local llama.cpp
        # this tier runs (EMBEDDINGS_PROFILES, task 01a18f76).
        env.update(embeddings_profile(ctx.m)["memory_env"])
    return env


def _memory_injects(ctx):
    core = {
        "MEMORY_SERVICE_URL": "http://memory-service:8100",
        "MEMORY_SERVICE_API_KEY": "{secret:MEMORY_SERVICE_API_KEY}",
    }
    if ctx.m["embeddings"]["mode"] == "local":
        # core's bound on one POST /ingest (config/runtime.exs), sized for the
        # largest page this tier's local embeddings can take (task 01a18f76).
        core["MEMORY_SERVICE_INGEST_TIMEOUT_MS"] = str(
            embeddings_profile(ctx.m)["core_ingest_timeout_ms"]
        )
    return {
        "core-platform": core,
        "core-postgres": {"MEMORY_DB_PASSWORD": "{secret:MEMORY_DB_PASSWORD}"},
    }


def _memory_secret_files(ctx):
    ref = _embedding_key_ref(ctx)
    return {f"secrets/{ref}": f"{{customer:{ref}}}\n"} if ref else {}


def _memory_mounts(ctx):
    ref = _embedding_key_ref(ctx)
    return [(f"secrets/{ref}", _secret_path(ref), True)] if ref else []


_MEMORY_INIT_SQL = """\
-- memory-service database (registry service: memory-service).
-- Runs once, on an EMPTY core-postgres data volume. A fresh postgres has none of
-- this; the reference install's did because its data was restored from another host.
\\getenv memory_db_password MEMORY_DB_PASSWORD
CREATE ROLE memory LOGIN PASSWORD :'memory_db_password';
CREATE DATABASE memory OWNER memory;
\\connect memory
CREATE EXTENSION IF NOT EXISTS vector;
"""


_POCKET_ID_INIT_SQL = """\
-- pocket-id database (registry service: pocket-id, target mac). Runs once, on an
-- EMPTY core-postgres data volume, so one pg_dump of core-postgres covers sign-in.
\\getenv pocketid_db_password POCKETID_DB_PASSWORD
CREATE ROLE pocketid LOGIN PASSWORD :'pocketid_db_password';
CREATE DATABASE pocketid OWNER pocketid;
"""


def _pocket_id_env(ctx):
    env = {
        "APP_URL": f"https://{ctx.auth_host}",
        "TRUST_PROXY": "true",
        # Data sovereignty: no third-party heartbeat by default.
        "ANALYTICS_DISABLED": "true",
        "ENCRYPTION_KEY": "{secret:ENCRYPTION_KEY}",
        # Task 01a114c1: pocket-id's request log records the full URL path, and
        # one-time sign-in codes travel in it (GET /lc/<code>, POST
        # /api/one-time-access-token/<code>). Every response below 500 logs at
        # INFO, except a 429 at WARN, so "warn" would still print the code of a
        # rate-limited exchange. "error" keeps only 5xx request lines. Never
        # "debug": that also turns on SQL query logs.
        "LOG_LEVEL": "error",
    }
    if ctx.mac:
        env["DB_CONNECTION_STRING"] = (
            "postgres://pocketid:{secret:POCKETID_DB_PASSWORD}"
            "@core-postgres:5432/pocketid?sslmode=disable"
        )
    # Every bundled install (any target): core's Users page reaches pocket-id's
    # admin API with this key, aliased as POCKET_ID_API_KEY (_pocket_id_injects).
    env["STATIC_API_KEY"] = "{secret:STATIC_API_KEY}"
    return env


def _pocket_id_secrets(ctx):
    names = ["ENCRYPTION_KEY", "OIDC_CLIENT_SECRET", "STATIC_API_KEY"]
    if ctx.mac:
        names += ["POCKETID_DB_PASSWORD"]
    return [SECRETS[n] for n in names]


def _pocket_id_injects(ctx):
    out = {
        "core-platform": {
            "OIDC_ISSUER": f"https://{ctx.auth_host}",
            # KEPT on purpose (task 01a14dd8): the client id is a row in the
            # install's pocket-id database; renaming it breaks every sign-in.
            "OIDC_CLIENT_ID": "suite-core",
            "OIDC_CLIENT_SECRET": "{secret:OIDC_CLIENT_SECRET}",
            # core's Users page (Platform.SignInAdmin.Config, task 01a113ea). These
            # exist only because pocket-id is bundled: this inject is dropped with
            # the pocket-id container in external-OIDC mode. The key is a {secret:}
            # alias, so it lands in secrets.env (0600), never in compose.yaml.
            "POCKET_ID_ADMIN_ENABLED": "true",
            "POCKET_ID_ADMIN_URL": "http://pocket-id:1411",
            "POCKET_ID_API_KEY": "{secret:STATIC_API_KEY}",
        }
    }
    if ctx.mac:
        out["core-postgres"] = {"POCKETID_DB_PASSWORD": "{secret:POCKETID_DB_PASSWORD}"}
    return out


# LiveKit's API key id is NOT a secret (it travels in every token's `iss`), so
# it is a fixed literal and livekit.yaml can name it for the webhook while the
# secret stays in secrets.env (LIVEKIT_KEYS). KEPT on purpose (task 01a14dd8):
# paired with stored config, and renaming it buys nothing.
LIVEKIT_API_KEY = "suite"
LIVEKIT_SIGNAL_PORT = 7880
LIVEKIT_TCP_PORT = 7881
LIVEKIT_UDP_PORT = 7882
# Service-to-core calls (LiveKit's webhook, the transcriber's segment sink) go
# through an INTERNAL Caddy listener, never straight to core-platform:4000:
# core forces https (config/prod.exs force_ssl, rewrite_on: [:x_forwarded_proto],
# excluding only /health and the hosts localhost/127.0.0.1), so a plain internal
# POST is redirected. Measured on the smoke VM: 4 of 4 webhook POSTs to
# http://core-platform:4000 got "Plug.SSL is redirecting ... 307" (task 01a0d6ab).
# The listener publishes no host port; target layers that run meetings render it.
CORE_INTERNAL_PORT = 4080
CORE_INTERNAL_URL = f"http://caddy:{CORE_INTERNAL_PORT}"
# core router.ex:874-875 (scope "/api/webhooks", post "/livekit").
LIVEKIT_WEBHOOK_URL = f"{CORE_INTERNAL_URL}/api/webhooks/livekit"


def detect_lan_ip():
    """The address of the interface holding the default route (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect(("192.0.2.1", 9))  # RFC 5737 TEST-NET-1; a UDP connect sends nothing
        return sock.getsockname()[0]


TAILSCALE_CLIS = ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale")


def detect_tailnet_ip():
    """The Mac HOST's Tailscale IPv4 from the macOS app's CLI, or None.

    The host's, not a sidecar's: the published UDP port lives on the host.
    """
    for cli in TAILSCALE_CLIS:
        if not (shutil.which(cli) or os.path.exists(cli)):
            continue
        proc = subprocess.run([cli, "ip", "-4"], capture_output=True, text=True, check=False)
        if proc.returncode == 0 and proc.stdout.split():
            return proc.stdout.split()[0]
    return None


class MediaIpUndetected(Exception):
    def __init__(self, reach):
        super().__init__(reach)
        self.reach = reach


# Replaced by tests; the renderer calls these only when [meetings] node_ip is unset.
MEDIA_IP_DETECTORS = {"lan": detect_lan_ip, "tailnet": detect_tailnet_ip}


def media_node_ip(ctx):
    """rtc.node_ip for media_reach lan/tailnet; None for public (STUN at boot)."""
    meetings = ctx.m["meetings"]
    reach = meetings["media_reach"]
    if reach == "public":
        return None
    if meetings["node_ip"]:
        return meetings["node_ip"]
    try:
        ip = MEDIA_IP_DETECTORS[reach]()
    except OSError:
        ip = None
    if not ip:
        # Never fall back to use_external_ip: that would silently turn a LAN
        # install into one that needs a router forward.
        raise MediaIpUndetected(reach)
    return ip


def livekit_yaml(ctx):
    node_ip = media_node_ip(ctx)
    rtc = [
        f"  tcp_port: {LIVEKIT_TCP_PORT}",
        f"  udp_port: {LIVEKIT_UDP_PORT}",
    ]
    if node_ip is None:
        # media_reach = "public": LiveKit learns its public IP by STUN at boot;
        # stage 4's ddns step restarts it when that IP changes.
        rtc.append("  use_external_ip: true")
    else:
        rtc += ["  use_external_ip: false", f'  node_ip: "{node_ip}"']
    lines = [
        (
            f"# LiveKit for install {ctx.m['install']['name']!r} "
            f"(media_reach = {ctx.m['meetings']['media_reach']})."
        ),
        "# Generated by burrow_install; do not edit, re-render. Holds no secret: the",
        "# key pair arrives as LIVEKIT_KEYS from secrets.env.",
        f"port: {LIVEKIT_SIGNAL_PORT}",
        "rtc:",
        *rtc,
        "turn:",
        "  enabled: false",
        "webhook:",
        f'  api_key: "{LIVEKIT_API_KEY}"',
        "  urls:",
        f'    - "{LIVEKIT_WEBHOOK_URL}"',
    ]
    return "\n".join(lines) + "\n"


def _livekit_injects(ctx):
    return {
        "core-platform": {
            # The browser's signalling URL: tunnel/tailnet -> Caddy websocket.
            "LIVEKIT_URL": f"wss://{ctx.livekit_host}",
            "LIVEKIT_API_KEY": LIVEKIT_API_KEY,
            "LIVEKIT_API_SECRET": "{secret:LIVEKIT_API_SECRET}",
        }
    }


def _stt_endpoint(ctx):
    name = ctx.m["meetings"]["stt_endpoint"]
    return next(e for e in ctx.m["models"]["endpoints"] if e["name"] == name)


def _transcriber_env(ctx):
    endpoint = _stt_endpoint(ctx)
    env = {
        "LIVEKIT_URL": f"ws://livekit:{LIVEKIT_SIGNAL_PORT}",
        "LIVEKIT_API_KEY": LIVEKIT_API_KEY,
        "LIVEKIT_API_SECRET": "{secret:LIVEKIT_API_SECRET}",
        # OpenAI-compatible /audio/transcriptions; base_url ends at /v1
        # (meeting-transcriber src/meeting_transcriber/config.py).
        "STT_BASE_URL": endpoint["base_url"],
        "STT_MODEL": ctx.m["meetings"]["stt_model"] or "whisper-1",
        # Non-secret values mirror the workstation's running transcriber (read 2026-09-25).
        "ROOM_PATTERN": "space-*",
        "IDLE_TIMEOUT_S": "300",
        "EMPTY_GRACE_S": "20",
        "LOG_LEVEL": "INFO",
        # core router.ex scope "/api/meetings", post "/segments".
        "PERSIST_URL": f"{CORE_INTERNAL_URL}/api/meetings/segments",
        "PERSIST_TOKEN": "{secret:MEETING_AGENT_TOKEN}",
    }
    if endpoint["api_key_ref"]:
        env["STT_API_KEY"] = f"{{customer:{endpoint['api_key_ref']}}}"
    return env


def _tailscale_service(role):
    def host(ctx):
        return {
            "primary": ctx.primary,
            "auth": ctx.auth_host,
            "livekit": ctx.livekit_host,
        }[role]

    def serve_json(ctx):
        # TS_CERT_DOMAIN is expanded by containerboot, not by compose.
        return (
            '{"TCP": {"443": {"HTTPS": true}}, "Web": {"${TS_CERT_DOMAIN}:443": '
            '{"Handlers": {"/": {"Proxy": "http://caddy:80"}}}}}\n'
        )

    return Service(
        f"tailscale-{role}",
        "docker.io/tailscale/tailscale:stable",
        env=lambda ctx: {
            "TS_AUTHKEY": f"{{customer:{ctx.m['access']['tailscale_authkey_ref']}}}",
            "TS_HOSTNAME": host(ctx).split(".")[0],
            "TS_STATE_DIR": "/var/lib/tailscale",
            "TS_SERVE_CONFIG": "/config/serve.json",
            "TS_USERSPACE": "true",
        },
        volumes={f"tailscale-{role}-state": "/var/lib/tailscale"},
        config_files=lambda ctx: {f"tailscale/{role}.json": serve_json(ctx)},
        host_mounts=lambda ctx: [(f"tailscale/{role}.json", "/config/serve.json", True)],
        depends_on={"caddy": "service_started"},
    )


def _speaches_image(ctx):
    tag = "latest-cuda" if ctx.m["voice"]["accelerator"] == "cuda" else "latest-cpu"
    return f"ghcr.io/speaches-ai/speaches:{tag}"


SERVICES = {
    s.container: s
    for s in (
        # Edge proxy. Its config (Caddyfile) is written by the target layer
        # from every service's `routes`.
        Service(
            "caddy",
            "docker.io/library/caddy:2",
            volumes={"caddy-data": "/data", "caddy-config": "/config"},
            # mac: nothing reaches Caddy from the host; cloudflared / the
            # tailscale sidecars dial caddy:80 on the compose network.
            ports=lambda ctx: () if ctx.mac else ("80:80", "443:443"),
        ),
        Service(
            "core-platform",
            # The flavour of the install's `install.modules` (ADR 0055):
            # `core:core` with none, `core:play` with Play. Never
            # `latest`, which is a moving tag kept for the hand-maintained
            # reference-install quadlets (deployment/schema/install-modules.md).
            core_image,
            private_image=True,
            env=_core_env,
            secrets=_core_secrets,
            networks=_core_networks,
            # One volume at /data/platform: the image creates that dir owned by
            # the app user (uid 1000), so a fresh named volume inherits it.
            # Mounting at its subdirs would create them root-owned.
            volumes={"core-data": "/data/platform"},
            host_mounts=_core_mounts,
            routes=lambda ctx: {ctx.primary: 4000},
            depends_on={"core-postgres": "service_healthy"},
            healthcheck=[
                "CMD",
                "wget",
                "--no-verbose",
                "--tries=1",
                "--spider",
                "http://localhost:4000/health",
            ],
        ),
        Service(
            "core-postgres",
            "docker.io/pgvector/pgvector:pg16",
            env=lambda ctx: {
                "POSTGRES_USER": POSTGRES_USER,
                "POSTGRES_DB": POSTGRES_DB,
                "POSTGRES_PASSWORD": "{secret:POSTGRES_PASSWORD}",
            },
            injects=_postgres_injects,
            secrets=[SECRETS["POSTGRES_PASSWORD"]],
            volumes={"core-postgres-data": "/var/lib/postgresql/data"},
            host_mounts=lambda ctx: [("postgres-init", "/docker-entrypoint-initdb.d", True)],
            healthcheck=["CMD", "pg_isready", "-U", POSTGRES_USER],
        ),
        Service(
            "pocket-id",
            "ghcr.io/pocket-id/pocket-id:v2.18.0",  # pinned: see setup/pocketid.py LOGIN_TTL
            env=_pocket_id_env,
            injects=_pocket_id_injects,
            secrets=_pocket_id_secrets,
            init_sql=lambda ctx: {"20-pocket-id.sql": _POCKET_ID_INIT_SQL} if ctx.mac else {},
            volumes={"pocket-id-data": "/app/data"},
            routes=lambda ctx: {ctx.auth_host: 1411},
            depends_on=lambda ctx: {"core-postgres": "service_healthy"} if ctx.mac else {},
        ),
        Service(
            "files-service",
            lambda ctx: default_image(ctx.m, "files-service"),
            private_image=True,
            env=lambda ctx: {
                "PORT": "8200",
                "FILES_SERVICE_TOKEN": "{secret:FILES_SERVICE_TOKEN}",
            },
            injects=lambda ctx: {
                "core-platform": {
                    "FILES_SERVICE_URL": "http://files-service:8200",
                    "FILES_SERVICE_TOKEN": "{secret:FILES_SERVICE_TOKEN}",
                }
            },
            injects_depends_on=lambda ctx: {"core-platform": {"files-service": "service_started"}},
            secrets=[SECRETS["FILES_SERVICE_TOKEN"]],
        ),
        Service(
            "memory-service",
            lambda ctx: default_image(ctx.m, "memory-service"),
            private_image=True,
            env=_memory_env,
            injects=_memory_injects,
            injects_depends_on=lambda ctx: {"core-platform": {"memory-service": "service_started"}},
            secrets=[SECRETS["MEMORY_SERVICE_API_KEY"], SECRETS["MEMORY_DB_PASSWORD"]],
            init_sql=lambda ctx: {"10-memory.sql": _MEMORY_INIT_SQL},
            secret_files=_memory_secret_files,
            host_mounts=_memory_mounts,
            depends_on={"core-postgres": "service_healthy", "embeddings": "service_started"},
        ),
        Service(
            "speaches",
            _speaches_image,
            volumes={"speaches-data": "/home/ubuntu/.cache/huggingface/hub"},
            injects=lambda ctx: {"files-service": {"STT_BASE_URL": "http://speaches:8000/v1"}},
            gpu=lambda ctx: ctx.m["voice"]["accelerator"] == "cuda",
        ),
        Service(
            "embeddings",
            EMBEDDINGS_IMAGE,
            # Model, flags and memory limit by size tier: EMBEDDINGS_PROFILES
            # (task 01a18f76).
            command=_embeddings_command,
            mem_limit=_embeddings_mem_limit,
            host_mounts=lambda ctx: [("models", "/models", True)],
            host_files=lambda ctx: [f"models/{embeddings_model(ctx.m)['file']}"],
            # The image's own HEALTHCHECK probes llama.cpp's default port 8080;
            # this server listens on --port 8188, so the stock check reported a
            # healthy server unhealthy (throwaway-VM proof, task 01a0d69d stage 3).
            healthcheck=["CMD", "curl", "-f", "http://localhost:8188/health"],
        ),
        # Meetings (task 01a0d6ab). Signalling goes through the edge (Caddy
        # websocket on livekit_host); media goes straight to the two
        # single-port listeners, the only host ports the mac target publishes.
        Service(
            "livekit",
            "docker.io/livekit/livekit-server:v1.13",
            command=["--config", "/etc/livekit.yaml"],
            env=lambda ctx: {"LIVEKIT_KEYS": f"{LIVEKIT_API_KEY}: {{secret:LIVEKIT_API_SECRET}}"},
            injects=_livekit_injects,
            secrets=[SECRETS["LIVEKIT_API_SECRET"]],
            config_files=lambda ctx: {"livekit.yaml": livekit_yaml(ctx)},
            host_mounts=lambda ctx: [("livekit.yaml", "/etc/livekit.yaml", True)],
            routes=lambda ctx: {ctx.livekit_host: LIVEKIT_SIGNAL_PORT},
            ports=(
                f"{LIVEKIT_TCP_PORT}:{LIVEKIT_TCP_PORT}/tcp",
                f"{LIVEKIT_UDP_PORT}:{LIVEKIT_UDP_PORT}/udp",
            ),
        ),
        Service(
            TRANSCRIBER,
            lambda ctx: default_image(ctx.m, "meeting-transcriber"),
            private_image=True,
            env=_transcriber_env,
            injects=lambda ctx: {
                "core-platform": {"MEETING_AGENT_TOKEN": "{secret:MEETING_AGENT_TOKEN}"}
            },
            secrets=[SECRETS["MEETING_AGENT_TOKEN"]],
            depends_on={"livekit": "service_started", "caddy": "service_started"},
        ),
        # target = "mac", [access] mode = "cloudflare-tunnel": a remotely-managed
        # tunnel (ingress written through the API by stage 4); every public
        # hostname points at http://caddy:80 and TLS ends at Cloudflare's edge.
        Service(
            "cloudflared",
            "docker.io/cloudflare/cloudflared:2026.9.3",
            command=["tunnel", "--no-autoupdate", "run"],
            env=lambda ctx: {"TUNNEL_TOKEN": f"{{customer:{ctx.m['access']['tunnel_token_ref']}}}"},
            depends_on={"caddy": "service_started"},
        ),
        _tailscale_service("primary"),
        _tailscale_service("auth"),
        _tailscale_service("livekit"),
        # Native agents, `contained` profile (task 01a10322 stage 3): a
        # systemd-init container on the agents network ONLY, so it reaches
        # core-platform and the internet and not core-postgres or any other
        # service. Agents are root inside it (sudo), never on the host.
        # AGENT_HOST_TOKEN is owned by core-platform's secrets.
        Service(
            AGENT_HOST,
            lambda ctx: agent_host_image(ctx.m),
            private_image=True,
            env=_agent_host_env,
            host_mounts=_agent_host_mounts,
            # Persistent homes; users are re-created over them on image update.
            volumes={"agent-homes": "/home"},
            networks=lambda ctx: (AGENTS_NETWORK,),
            systemd_init=True,
            own_env_file=True,
        ),
    )
}

assert set(SERVICES) == set(ALL_CONTAINERS), "every container needs a registry entry"


def identifiers(container, ctx):
    """Every string a render carries only because ``container`` is on.

    Used by the knob tests: render(S on) must contain all of them, render(S
    off) none. Env names another running service also declares (e.g. PORT)
    are excluded because they are not S's to remove.
    """
    service = SERVICES[container]
    own = {container}
    own.update(s.name for s in service.secrets_for(ctx))
    own.update(service.volumes)
    own.update(service.init_sql(ctx))
    own.update(service.host_files(ctx))
    own.update(service.config_files(ctx))
    names = set(service.env(ctx))
    for target, env in service.injects(ctx).items():
        if target in ctx.enabled:
            names.update(env)
    shared = set()
    for other in ctx.enabled - {container}:
        shared.update(SERVICES[other].env(ctx))
        for target, env in SERVICES[other].injects(ctx).items():
            if target in ctx.enabled:
                shared.update(env)
    own.update(names - shared)
    return own
