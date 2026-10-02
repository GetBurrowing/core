"""Validate an install manifest against schema v1.

Two passes:

1. Structure: every key is in ``manifest.SCHEMA`` (``unknown_key`` /
   ``unknown_service``), every value has its declared type (``invalid_type``)
   and every enum holds an allowed value (``invalid_enum``).
2. Rules: required fields and the cross-field constraints that a JSON Schema
   cannot express readably (voice.accelerator vs host.gpu, memory vs
   embeddings, auth mode vs its fields, ...).

A value that failed pass 1 is treated as absent in pass 2 *without* raising a
second error for it, so one wrong field yields exactly one error line.
"""

import re

from . import SCHEMA_VERSION
from .manifest import SCHEMA, ArrayOf, Field, normalize


class ValidationError:
    def __init__(self, code, path, message):
        self.code = code
        self.path = path
        self.message = message

    def __repr__(self):
        return f"ValidationError({self.code!r}, {self.path!r})"

    def line(self):
        return f"error {self.code} at {self.path}: {self.message}"


ERROR_CODES = (
    "unsupported_schema_version",
    "unknown_key",
    "unknown_service",
    "unknown_module",
    "invalid_type",
    "invalid_enum",
    "invalid_value",
    "missing_required",
    "missing_domain",
    "invalid_domain",
    "acme_email_required",
    "field_not_applicable",
    "gpu_required",
    "memory_requires_embeddings",
    "embeddings_endpoint_required",
    "external_oidc_incomplete",
    "backup_incomplete",
    "duplicate_endpoint_name",
)

_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_SECRET_REF_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
_URL_RE = re.compile(r"^https?://[^/\s:]+(:[0-9]{1,5})?(/\S*)?$")

_TYPE_NAMES = {
    "str": "a string",
    "bool": "a boolean",
    "int": "an integer",
    "set": "an array of strings",
}


def _type_ok(kind, value):
    if kind == "set":
        return isinstance(value, list) and all(isinstance(item, str) for item in value)
    if kind in ("str", "enum"):
        return isinstance(value, str)
    if kind == "bool":
        return type(value) is bool
    if kind == "int":
        return type(value) is int
    raise ValueError(kind)


def _join(path, key):
    return f"{path}.{key}" if path else key


def _structure(raw, spec, path, errors, bad):
    """Return a copy of ``raw`` holding only well-formed values."""
    clean = {}
    for key, value in raw.items():
        child_path = _join(path, key)
        if key not in spec:
            if path == "services":
                errors.append(
                    ValidationError(
                        "unknown_service",
                        child_path,
                        f"unknown service {key!r}; known services: {', '.join(spec)}",
                    )
                )
            else:
                errors.append(
                    ValidationError("unknown_key", child_path, f"key {key!r} is not in schema v1")
                )
            continue
        child = spec[key]
        if isinstance(child, Field):
            if not _type_ok(child.kind, value):
                expected = "a string" if child.kind == "enum" else _TYPE_NAMES[child.kind]
                errors.append(ValidationError("invalid_type", child_path, f"must be {expected}"))
                bad.add(child_path)
                continue
            if child.kind == "enum" and value not in child.choices:
                errors.append(
                    ValidationError(
                        "invalid_enum",
                        child_path,
                        f"{value!r} is not one of: {', '.join(child.choices)}",
                    )
                )
                bad.add(child_path)
                continue
            if child.kind == "set" and not _set_ok(child, value, child_path, errors):
                bad.add(child_path)
                continue
            clean[key] = value
        elif isinstance(child, ArrayOf):
            if not isinstance(value, list) or not all(isinstance(i, dict) for i in value):
                errors.append(
                    ValidationError("invalid_type", child_path, "must be an array of tables")
                )
                bad.add(child_path)
                continue
            clean[key] = [
                _structure(item, child.item, f"{child_path}[{index}]", errors, bad)
                for index, item in enumerate(value)
            ]
        else:
            if not isinstance(value, dict):
                errors.append(ValidationError("invalid_type", child_path, "must be a table"))
                bad.add(child_path)
                continue
            clean[key] = _structure(value, child, child_path, errors, bad)
    return clean


def _set_ok(field, value, path, errors):
    """``install.modules``: every entry known, none repeated. One error per field."""
    unknown = [item for item in value if item not in field.choices]
    if unknown:
        errors.append(
            ValidationError(
                "unknown_module",
                path,
                f"unknown module(s) {', '.join(map(repr, unknown))}; "
                f"known modules: {', '.join(field.choices)}",
            )
        )
        return False
    repeated = sorted({item for item in value if value.count(item) > 1})
    if repeated:
        errors.append(
            ValidationError("invalid_value", path, f"lists {', '.join(map(repr, repeated))} twice")
        )
        return False
    return True


def _is_bad(path, bad):
    return any(path == b or path.startswith((b + ".", b + "[")) for b in bad)


def valid_domain(value):
    if len(value) > 253 or value.endswith("."):
        return False
    labels = value.lower().split(".")
    if len(labels) < 2 or not all(_LABEL_RE.match(label) for label in labels):
        return False
    # An all-numeric last label is an IP literal, not a DNS name.
    return not labels[-1].isdigit()


def _rules(m, bad, errors):
    def add(code, path, message):
        errors.append(ValidationError(code, path, message))

    def check_url(path, value, https_only=False):
        if value is None or _is_bad(path, bad):
            return
        if not _URL_RE.match(value) or (https_only and not value.startswith("https://")):
            scheme = "an https:// URL" if https_only else "an http(s):// URL"
            add("invalid_value", path, f"must be {scheme}")

    def check_ref(path, value):
        if value is not None and not _SECRET_REF_RE.match(value):
            add("invalid_value", path, "a secret ref is an UPPER_SNAKE_CASE name, not a value")

    def not_applicable(section, mode_key, keys, reason):
        # A mode that failed pass 1 reads as its default; do not blame its fields.
        if _is_bad(f"{section}.{mode_key}", bad):
            return
        for key in keys:
            if m[section][key] is not None:
                add("field_not_applicable", f"{section}.{key}", reason)

    # [install]
    name = m["install"]["name"]
    if name is None:
        if not _is_bad("install.name", bad):
            add("missing_required", "install.name", "every install needs a name")
    elif not _NAME_RE.match(name):
        add("invalid_value", "install.name", "must match [a-z][a-z0-9-]{0,62}")

    # [domain]
    domain = m["domain"]
    if domain["primary"] is None:
        if not _is_bad("domain.primary", bad):
            add("missing_domain", "domain.primary", "the install's public FQDN is required")
    elif not valid_domain(domain["primary"]):
        add("invalid_domain", "domain.primary", f"{domain['primary']!r} is not a DNS name")
    if domain["tls"] == "acme":
        if domain["acme_email"] is None:
            if not _is_bad("domain.acme_email", bad) and not _is_bad("domain.tls", bad):
                add("acme_email_required", "domain.acme_email", 'tls = "acme" needs acme_email')
        elif not _EMAIL_RE.match(domain["acme_email"]):
            add("invalid_value", "domain.acme_email", "must be an email address")
    else:
        not_applicable("domain", "tls", ["acme_email"], 'only used with tls = "acme"')

    services = m["services"]

    # [voice] vs [host]
    if (
        services["voice"]
        and m["voice"]["accelerator"] == "cuda"
        and not m["host"]["gpu"]
        and not _is_bad("host.gpu", bad)
    ):
        add(
            "gpu_required",
            "voice.accelerator",
            'accelerator = "cuda" with voice on needs host.gpu = true',
        )

    # [embeddings]
    emb = m["embeddings"]
    if emb["mode"] == "endpoint":
        if emb["base_url"] is None and not _is_bad("embeddings.base_url", bad):
            add(
                "embeddings_endpoint_required",
                "embeddings.base_url",
                'mode = "endpoint" needs base_url',
            )
        check_url("embeddings.base_url", emb["base_url"])
        check_ref("embeddings.api_key_ref", emb["api_key_ref"])
    else:
        not_applicable(
            "embeddings", "mode", ["base_url", "api_key_ref"], 'only used with mode = "endpoint"'
        )

    # memory vs embeddings
    if (
        services["memory"]
        and not services["embeddings"]
        and not _is_bad("services.embeddings", bad)
    ):
        add(
            "memory_requires_embeddings",
            "services.memory",
            "memory-service needs embeddings (services.embeddings = true, local or endpoint)",
        )

    # [[models.endpoints]]
    seen = {}
    for index, endpoint in enumerate(m["models"]["endpoints"]):
        base = f"models.endpoints[{index}]"
        for key in ("name", "kind", "base_url"):
            if endpoint[key] is None and not _is_bad(f"{base}.{key}", bad):
                add("missing_required", f"{base}.{key}", f"every endpoint needs {key}")
        ep_name = endpoint["name"]
        if ep_name is not None:
            if not _NAME_RE.match(ep_name):
                add("invalid_value", f"{base}.name", "must match [a-z][a-z0-9-]{0,62}")
            elif ep_name in seen:
                add(
                    "duplicate_endpoint_name",
                    f"{base}.name",
                    f"{ep_name!r} is already used by models.endpoints[{seen[ep_name]}]",
                )
            else:
                seen[ep_name] = index
        check_url(f"{base}.base_url", endpoint["base_url"])
        check_ref(f"{base}.api_key_ref", endpoint["api_key_ref"])

    # [auth]
    auth = m["auth"]
    if auth["mode"] == "external-oidc":
        missing = [
            k
            for k in ("issuer", "client_id", "client_secret_ref")
            if auth[k] is None and not _is_bad(f"auth.{k}", bad)
        ]
        if missing:
            add(
                "external_oidc_incomplete",
                "auth",
                f'mode = "external-oidc" needs: {", ".join(missing)}',
            )
        check_url("auth.issuer", auth["issuer"], https_only=True)
        check_ref("auth.client_secret_ref", auth["client_secret_ref"])
    else:
        not_applicable(
            "auth",
            "mode",
            ["issuer", "client_id", "client_secret_ref"],
            'only used with mode = "external-oidc"',
        )

    # [backup]
    backup = m["backup"]
    needs = {
        "none": (),
        "local-path": ("path",),
        "s3-compatible": ("bucket", "endpoint", "access_key_ref", "secret_key_ref"),
    }
    optional = {"s3-compatible": ("region",)}
    target = backup["target"]
    required = needs[target]
    missing = [k for k in required if backup[k] is None and not _is_bad(f"backup.{k}", bad)]
    if missing:
        add("backup_incomplete", "backup", f'target = "{target}" needs: {", ".join(missing)}')
    allowed = set(required) | set(optional.get(target, ()))
    not_applicable(
        "backup",
        "target",
        [k for k in SCHEMA["backup"] if k != "target" and k not in allowed],
        f'not used with target = "{target}"',
    )
    if target == "local-path" and backup["path"] is not None and not backup["path"].startswith("/"):
        add("invalid_value", "backup.path", "must be an absolute path")
    if target == "s3-compatible":
        check_url("backup.endpoint", backup["endpoint"])
        check_ref("backup.access_key_ref", backup["access_key_ref"])
        check_ref("backup.secret_key_ref", backup["secret_key_ref"])

    # [images.refs]
    for container, ref in m["images"]["refs"].items():
        if ref is not None and not ref.strip():
            add("invalid_value", f"images.refs.{container}", "an image ref cannot be empty")


def validate(raw):
    """Return ``(errors, normalized)``; ``normalized`` is None when invalid."""
    if not isinstance(raw, dict):
        return [ValidationError("invalid_type", "", "manifest must be a table")], None
    version = raw.get("schema_version")
    if type(version) is not int or version != SCHEMA_VERSION:
        shown = "missing" if version is None else repr(version)
        return [
            ValidationError(
                "unsupported_schema_version",
                "schema_version",
                f"got {shown}; this tool reads schema_version = {SCHEMA_VERSION}",
            )
        ], None

    errors = []
    bad = set()
    clean = _structure(raw, SCHEMA, "", errors, bad)
    normalized = normalize(clean)
    _rules(normalized, bad, errors)
    return errors, (None if errors else normalized)
