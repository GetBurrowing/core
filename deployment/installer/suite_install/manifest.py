"""Install manifest schema v1: shape, defaults and loading.

The schema is data (``SCHEMA``) so that the validator's unknown-key check and
the reference in ``deployment/schema/install-manifest.md`` describe the same
set of keys. Cross-field rules live in ``validate.py``.
"""

import tomllib

from . import registry


class Field:
    """A leaf key: its TOML type, allowed values and default."""

    def __init__(self, kind, default=None, choices=None):
        self.kind = kind  # "str" | "bool" | "int" | "enum" | "set"
        self.default = default
        self.choices = choices


class ArrayOf:
    """An array of tables (``[[models.endpoints]]``)."""

    def __init__(self, item):
        self.item = item


def _str():
    return Field("str")


def _bool(default=False):
    return Field("bool", default=default)


def _enum(choices, default=None):
    return Field("enum", default=default, choices=tuple(choices))


def _set(choices):
    """An array of distinct strings, each one of ``choices``; default empty."""
    return Field("set", default=(), choices=tuple(choices))


SIZE_TIERS = ("small", "medium", "large")
TLS_MODES = ("acme", "internal")
ACCELERATORS = ("cpu", "cuda")
EMBEDDINGS_MODES = ("local", "endpoint")
ENDPOINT_KINDS = ("local", "hosted", "byo")
AUTH_MODES = tuple(registry.AUTH_CONTAINERS)
BACKUP_TARGETS = ("none", "local-path", "s3-compatible")
IMAGE_SOURCES = ("registry", "preloaded")
UPGRADE_CHANNELS = ("stable", "edge", "pinned")
# Render targets (task 01a0d6ab). ``single-host`` is ADR 0053's VM target and
# the default, so a manifest without ``install.target`` renders unchanged.
TARGETS = ("single-host", "mac")
ACCESS_MODES = ("cloudflare-tunnel", "tailscale")
MEDIA_REACH = ("lan", "tailnet", "public")

# Every key the manifest may contain, at every depth. A key outside this tree
# is `unknown_key` (or `unknown_service` under [services]), so a typo can never
# silently leave a knob at its default.
SCHEMA = {
    "schema_version": Field("int"),
    "install": {
        "name": _str(),
        "size_tier": _enum(SIZE_TIERS, "small"),
        "target": _enum(TARGETS, "single-host"),
        # Build-time modules (ADR 0055): selects the core image flavour.
        "modules": _set(registry.MODULES),
    },
    "domain": {
        "primary": _str(),
        "tls": _enum(TLS_MODES, "acme"),
        "acme_email": _str(),
        # Defaults: auth.<primary> and livekit.<primary>. Overridable so a
        # non-apex primary can use flat names (one label below the zone).
        "auth_host": _str(),
        "livekit_host": _str(),
    },
    "host": {
        "gpu": _bool(False),
    },
    "services": {knob: _bool(False) for knob in registry.OPTIONAL_SERVICES},
    "voice": {
        "accelerator": _enum(ACCELERATORS, "cpu"),
    },
    "embeddings": {
        "mode": _enum(EMBEDDINGS_MODES, "local"),
        "base_url": _str(),
        "api_key_ref": _str(),
        # mode = "endpoint" only. Unset model keeps the literal "embeddings"
        # (the llama.cpp alias); unset query_prefix keeps memory-service's
        # BGE prefix, and "" sends queries unprefixed (hosted OpenAI).
        "model": _str(),
        "query_prefix": _str(),
    },
    "models": {
        "endpoints": ArrayOf(
            {
                "name": _str(),
                "kind": _enum(ENDPOINT_KINDS),
                "base_url": _str(),
                "api_key_ref": _str(),
            }
        ),
    },
    "auth": {
        "mode": _enum(AUTH_MODES, "bundled-pocket-id"),
        "issuer": _str(),
        "client_id": _str(),
        "client_secret_ref": _str(),
    },
    "backup": {
        "target": _enum(BACKUP_TARGETS, "none"),
        "path": _str(),
        "bucket": _str(),
        "endpoint": _str(),
        "region": _str(),
        "access_key_ref": _str(),
        "secret_key_ref": _str(),
    },
    "images": {
        "source": _enum(IMAGE_SOURCES, "registry"),
        "refs": {container: _str() for container in registry.ALL_CONTAINERS},
    },
    # target = "mac" only: how the public hostnames reach this machine.
    "access": {
        "mode": _enum(ACCESS_MODES, "cloudflare-tunnel"),
        "tunnel_token_ref": _str(),
        "tailscale_authkey_ref": _str(),
    },
    # services.meetings = true only; ignored while it is off, so flipping the
    # knob back is a one-field change.
    "meetings": {
        "media_reach": _enum(MEDIA_REACH),
        "node_ip": _str(),
        # media_reach = "public" only: an optional DNS-only (grey-cloud) A
        # record the setup CLI's ddns job keeps pointed at the public IP.
        "media_host": _str(),
        "transcription": _bool(False),
        "stt_endpoint": _str(),
        "stt_model": _str(),
    },
    # Reserved for day-2 operations (ADR 0053). Validated, not yet acted on.
    "day2": {
        "upgrade_channel": _enum(UPGRADE_CHANNELS, "stable"),
        "phone_home": _bool(False),
    },
}


class ManifestLoadError(Exception):
    """The file could not be read or is not TOML."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def load(path):
    """Read and parse a manifest file into a plain dict."""
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except OSError as exc:
        raise ManifestLoadError("unreadable_manifest", exc.strerror or str(exc)) from exc
    except tomllib.TOMLDecodeError as exc:
        raise ManifestLoadError("invalid_toml", str(exc)) from exc


def _defaults(spec):
    if isinstance(spec, Field):
        return spec.default
    if isinstance(spec, ArrayOf):
        return []
    return {key: _defaults(child) for key, child in spec.items()}


def normalize(raw, spec=SCHEMA):
    """Overlay ``raw`` on the schema defaults. Unknown keys are dropped.

    Only meaningful for a manifest that ``validate.validate`` accepted; it does
    not re-check types.
    """
    if isinstance(spec, Field):
        return raw
    if isinstance(spec, ArrayOf):
        return [normalize(item, spec.item) for item in raw]
    out = {}
    for key, child in spec.items():
        if isinstance(raw, dict) and key in raw:
            out[key] = normalize(raw[key], child)
        else:
            out[key] = _defaults(child)
    return out
