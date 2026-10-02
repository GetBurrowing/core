"""Service registry: the single source of what each manifest knob turns on.

Every service a Suite install can run is declared here ONCE, independent of
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
- host mounts are paths relative to the install root (``/opt/suite`` on a
  single host).

Container names mirror the live moon quadlets so that a rendered stack and an
operator's mental model of moon use the same names. Default image refs mirror
the moon quadlets read on 2026-09-25 (task 01a0d69d stage 2).
"""

import base64
import secrets as _random

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
}

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

CORE_IMAGE_REPO = "docker.io/example/suite-core"

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


def core_image(ctx):
    """The core image for the install's module set, e.g. ``suite-core:play``."""
    return f"{CORE_IMAGE_REPO}:{IMAGE_FLAVOURS[frozenset(ctx.m['install']['modules'])]}"


ALL_CONTAINERS = tuple(
    sorted(
        set(IMPLICIT_CONTAINERS)
        | set(OPTIONAL_SERVICES.values())
        | {c for c in AUTH_CONTAINERS.values() if c}
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
    auth_container = AUTH_CONTAINERS[manifest["auth"]["mode"]]
    if auth_container:
        names.add(auth_container)
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
# throwaway container castore-01a0d69d on moon, image
# docker.io/example/suite-core:latest, image id sha256:42600a534f02b6f5...,
# repo digests sha256:843a721c0dc11992... and sha256:a59c99b6a090aa05...
# (castore 1.0.17). The path carries the castore VERSION, so a castore bump in
# core moves it. The single-host CA-bundle script fails loudly (never silently)
# when the file is gone; ADR 0053 follow-up 10 retires this mount.
CASTORE_PATH = "/app/lib/castore-1.0.17/priv/cacerts.pem"

# The embeddings model. Must stay Qwen3-Embedding-0.6B f16: a different model
# silently invalidates every stored vector (moon embeddings.container header).
EMBEDDINGS_MODEL_FILE = "Qwen3-Embedding-0.6B-f16.gguf"

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
            "the same env name hive's pocket-id runs with)",
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
            "MEMORY_DB_PASSWORD",
            _hex(24),  # hex: safe inside MEMORY_DATABASE_URL and a SQL literal
            "memory init SQL (psql \\getenv) and memory-service MEMORY_DATABASE_URL, "
            "src/memory_service/config.py:49",
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
        self.primary = manifest["domain"]["primary"]
        self.auth_host = f"auth.{self.primary}"
        self.tls_internal = manifest["domain"]["tls"] == "internal"
        self.bundled_auth = manifest["auth"]["mode"] == "bundled-pocket-id"
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
        env=_nothing,
        injects=_nothing,
        injects_depends_on=_nothing,
        secrets=(),
        init_sql=_nothing,
        volumes=None,
        host_mounts=lambda ctx: [],
        host_files=lambda ctx: [],
        routes=_nothing,
        depends_on=None,
        ports=(),
        gpu=lambda ctx: False,
        healthcheck=None,
    ):
        self.container = container
        self._image = image
        self.private_image = private_image
        self.command = command
        self.env = env
        self.injects = injects
        self.injects_depends_on = injects_depends_on
        self.secrets = tuple(secrets)
        self.init_sql = init_sql
        self.volumes = volumes or {}
        self.host_mounts = host_mounts
        self.host_files = host_files
        self.routes = routes
        self.depends_on = depends_on or {}
        self.ports = tuple(ports)
        self.gpu = gpu
        self.healthcheck = healthcheck

    def default_image(self, ctx):
        return self._image(ctx) if callable(self._image) else self._image


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
    for module in sorted(ctx.m["install"]["modules"]):
        env.update(MODULE_CORE_ENV.get(module, {}))
    auth = ctx.m["auth"]
    if not ctx.bundled_auth:
        env["OIDC_ISSUER"] = auth["issuer"]
        env["OIDC_CLIENT_ID"] = auth["client_id"]
        env["OIDC_CLIENT_SECRET"] = f"{{customer:{auth['client_secret_ref']}}}"
    return env


def _core_mounts(ctx):
    if not ctx.tls_internal:
        return []
    return [("tls/ca-bundle.pem", CASTORE_PATH, True)]


def _postgres_injects(ctx):
    url = f"ecto://{POSTGRES_USER}:{{secret:POSTGRES_PASSWORD}}@core-postgres:5432/{POSTGRES_DB}"
    return {"core-platform": {"DATABASE_URL": url}}


def _pocket_id_injects(ctx):
    return {
        "core-platform": {
            "OIDC_ISSUER": f"https://{ctx.auth_host}",
            "OIDC_CLIENT_ID": "suite-core",
            "OIDC_CLIENT_SECRET": "{secret:OIDC_CLIENT_SECRET}",
        }
    }


def _memory_env(ctx):
    emb = ctx.m["embeddings"]
    if emb["mode"] == "local":
        embedding_url = "http://embeddings:8188"
    else:
        embedding_url = emb["base_url"]
    return {
        "MEMORY_HOST": "0.0.0.0",
        "MEMORY_PORT": "8100",
        "MEMORY_EMBEDDING_BACKEND": "http",
        "MEMORY_EMBEDDING_URL": embedding_url,
        "MEMORY_EMBEDDING_MODEL": "embeddings",
        "MEMORY_DATABASE_URL": "postgresql://memory:{secret:MEMORY_DB_PASSWORD}"
        "@core-postgres:5432/memory",
        "MEMORY_API_KEY": "{secret:MEMORY_SERVICE_API_KEY}",
    }


_MEMORY_INIT_SQL = """\
-- memory-service database (registry service: memory-service).
-- Runs once, on an EMPTY core-postgres data volume. A fresh postgres has none of
-- this; moon's did because its data was restored from hive.
\\getenv memory_db_password MEMORY_DB_PASSWORD
CREATE ROLE memory LOGIN PASSWORD :'memory_db_password';
CREATE DATABASE memory OWNER memory;
\\connect memory
CREATE EXTENSION IF NOT EXISTS vector;
"""


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
            ports=("80:80", "443:443"),
        ),
        Service(
            "core-platform",
            # The flavour of the install's `install.modules` (ADR 0055):
            # `suite-core:core` with none, `suite-core:play` with Play. Never
            # `latest`, which is a moving tag kept for the hand-maintained
            # moon quadlets (deployment/schema/install-modules.md).
            core_image,
            private_image=True,
            env=_core_env,
            secrets=[
                SECRETS[n]
                for n in (
                    "SECRET_KEY_BASE",
                    "VAULT_MASTER_KEY",
                    "ATTACHMENT_SIGNING_KEY",
                    "MEETING_GUEST_SIGNING_KEY",
                    "MEETING_CALENDAR_SIGNING_KEY",
                )
            ],
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
            "ghcr.io/pocket-id/pocket-id:v2",
            env=lambda ctx: {
                "APP_URL": f"https://{ctx.auth_host}",
                "TRUST_PROXY": "true",
                # Data sovereignty: no third-party heartbeat by default.
                "ANALYTICS_DISABLED": "true",
                "ENCRYPTION_KEY": "{secret:ENCRYPTION_KEY}",
            },
            injects=_pocket_id_injects,
            secrets=[SECRETS["ENCRYPTION_KEY"], SECRETS["OIDC_CLIENT_SECRET"]],
            volumes={"pocket-id-data": "/app/data"},
            routes=lambda ctx: {ctx.auth_host: 1411},
        ),
        Service(
            "files-service",
            "docker.io/example/suite-files-service:latest",
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
            "docker.io/example/suite-memory-service:latest",
            private_image=True,
            env=_memory_env,
            injects=lambda ctx: {
                "core-platform": {
                    "MEMORY_SERVICE_URL": "http://memory-service:8100",
                    "MEMORY_SERVICE_API_KEY": "{secret:MEMORY_SERVICE_API_KEY}",
                },
                "core-postgres": {"MEMORY_DB_PASSWORD": "{secret:MEMORY_DB_PASSWORD}"},
            },
            injects_depends_on=lambda ctx: {"core-platform": {"memory-service": "service_started"}},
            secrets=[SECRETS["MEMORY_SERVICE_API_KEY"], SECRETS["MEMORY_DB_PASSWORD"]],
            init_sql=lambda ctx: {"10-memory.sql": _MEMORY_INIT_SQL},
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
            "ghcr.io/ggml-org/llama.cpp:server",
            # Flags copied from core-ops targets/moon-production/quadlets/
            # embeddings.container Exec= (measured 2026-09-24, task 01a0d403).
            command=[
                "-m",
                f"/models/{EMBEDDINGS_MODEL_FILE}",
                "--embedding",
                "--pooling",
                "last",
                "--host",
                "0.0.0.0",
                "--port",
                "8188",
                "-c",
                "32768",
                "-np",
                "4",
                "--no-kv-unified",
                "-b",
                "8192",
                "-ub",
                "8192",
                "-t",
                "6",
            ],
            host_mounts=lambda ctx: [("models", "/models", True)],
            host_files=lambda ctx: [f"models/{EMBEDDINGS_MODEL_FILE}"],
            # The image's own HEALTHCHECK probes llama.cpp's default port 8080;
            # this server listens on --port 8188, so the stock check reported a
            # healthy server unhealthy (throwaway-VM proof, task 01a0d69d stage 3).
            healthcheck=["CMD", "curl", "-f", "http://localhost:8188/health"],
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
    own.update(s.name for s in service.secrets)
    own.update(service.volumes)
    own.update(service.init_sql(ctx))
    own.update(service.host_files(ctx))
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
