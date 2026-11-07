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

from . import SCHEMA_VERSION, registry
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
    "backup_required_hosted",
    "duplicate_endpoint_name",
    "invalid_org_name",
    "invalid_ssh_authorized_key",
)

# Rules of install.target = "mac" (task 01a0d6ab). Kept apart from
# ERROR_CODES because their one-field fixtures differ from the MAC example
# (tests/fixtures/mac/), not from the single-host good.toml.
MAC_ERROR_CODES = (
    "mac_voice_unsupported",
    "mac_local_embeddings_unsupported",
    "hosted_embeddings_required",
    "tunnel_token_ref_missing",
    "tailscale_authkey_ref_missing",
    "meetings_media_reach_required",
    "stt_endpoint_unknown",
    "vapid_requires_single_host",
)

# The [agents] table is absent from every manifest written before task
# 01a10322; absent means no native agents at all.
AGENTS_ABSENT_PROFILE = "off"

# A hosted install with no [backup] target gets this one.
HOSTED_BACKUP_TARGET = "local-path"
HOSTED_BACKUP_PATH = "/var/backups/burrow"

_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
# A Docker Hub namespace (user or organisation): lowercase alphanumerics,
# single separators between them.
_IMAGE_NAMESPACE_RE = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$")
# [images] registry: a registry host (with a dot, or localhost; optional port)
# and at least one lowercase path component, e.g. ghcr.io/example.
_IMAGE_REGISTRY_RE = re.compile(
    r"^(?:localhost|[a-z0-9-]+(?:\.[a-z0-9-]+)+)(?::[0-9]{1,5})?"
    r"(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)+$"
)
_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_SECRET_REF_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
_URL_RE = re.compile(r"^https?://[^/\s:]+(:[0-9]{1,5})?(/\S*)?$")
# install.org_name lands in core-platform's env (ROOT_ORG_NAME): no newline,
# and none of the characters a shell or compose would interpolate or unquote.
ORG_NAME_MAX = 80
_ORG_NAME_FORBIDDEN = ('"', "$", "`")
# host.ssh_authorized_key: one OpenSSH public key of a modern type, optional comment.
_SSH_KEY_RE = re.compile(r"(ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+( [^\n]*)?")
_IPV4_RE = re.compile(
    r"^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$"
)

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


def _present(clean, prefix=""):
    """Every dotted leaf path the manifest SET explicitly (after pass 1)."""
    out = set()
    for key, value in clean.items():
        path = _join(prefix, key)
        if isinstance(value, dict):
            out |= _present(value, path)
        else:
            out.add(path)
    return out


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


def valid_org_name(value):
    return (
        0 < len(value) <= ORG_NAME_MAX
        and value.isprintable()
        and value == value.strip()
        and not any(c in value for c in _ORG_NAME_FORBIDDEN)
    )


def valid_domain(value):
    if len(value) > 253 or value.endswith("."):
        return False
    labels = value.lower().split(".")
    if len(labels) < 2 or not all(_LABEL_RE.match(label) for label in labels):
        return False
    # An all-numeric last label is an IP literal, not a DNS name.
    return not labels[-1].isdigit()


def _rules(m, bad, errors, present=frozenset()):
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

    org_name = m["install"]["org_name"]
    if org_name is not None and not valid_org_name(org_name):
        add(
            "invalid_org_name",
            "install.org_name",
            f"must be 1-{ORG_NAME_MAX} printable characters with no leading or trailing "
            'space and no ", $ or backtick',
        )
    ssh_key = m["host"]["ssh_authorized_key"]
    if ssh_key is not None and not _SSH_KEY_RE.fullmatch(ssh_key):
        add(
            "invalid_ssh_authorized_key",
            "host.ssh_authorized_key",
            "must be one OpenSSH public key: ssh-ed25519 or ecdsa-sha2-nistp256, the "
            "base64 key, then an optional comment",
        )

    if _is_bad("install.target", bad):
        # Every rule below depends on the target; an unknown one is its one line.
        return

    # [domain]
    domain = m["domain"]
    if domain["primary"] is None:
        if not _is_bad("domain.primary", bad):
            add("missing_domain", "domain.primary", "the install's public FQDN is required")
    elif not valid_domain(domain["primary"]):
        add("invalid_domain", "domain.primary", f"{domain['primary']!r} is not a DNS name")
    mac = m["install"]["target"] == "mac"
    for key in ("auth_host", "livekit_host"):
        value = domain[key]
        if value is not None:
            if not valid_domain(value):
                add("invalid_domain", f"domain.{key}", f"{value!r} is not a DNS name")
            elif value == domain["primary"]:
                add("invalid_value", f"domain.{key}", "must differ from domain.primary")
    if mac:
        # TLS ends at the tunnel's or the tailnet's edge; nothing here issues a cert.
        for key in ("tls", "acme_email"):
            if f"domain.{key}" in present:
                add(
                    "field_not_applicable",
                    f"domain.{key}",
                    'target = "mac" terminates TLS at the edge (cloudflared or tailscale)',
                )
    elif domain["tls"] == "acme":
        if domain["acme_email"] is None:
            if not _is_bad("domain.acme_email", bad) and not _is_bad("domain.tls", bad):
                add("acme_email_required", "domain.acme_email", 'tls = "acme" needs acme_email')
        elif not _EMAIL_RE.match(domain["acme_email"]):
            add("invalid_value", "domain.acme_email", "must be an email address")
    else:
        not_applicable("domain", "tls", ["acme_email"], 'only used with tls = "acme"')

    services = m["services"]

    if mac:
        _mac_rules(m, bad, present, add, check_url, check_ref)
        if m["push"]["vapid"] == "generate-on-host":
            add(
                "vapid_requires_single_host",
                "push.vapid",
                "generate-on-host runs bin/burrow-vapid from the stack unit, which only "
                'target = "single-host" renders',
            )
        if "host.ssh_authorized_key" in present:
            add(
                "field_not_applicable",
                "host.ssh_authorized_key",
                'only used with target = "single-host" (cloud-config ssh_authorized_keys)',
            )
    elif services["meetings"]:
        _single_host_meetings(m, bad, add)
    if not mac:
        for key in ("mode", "tunnel_token_ref", "tailscale_authkey_ref"):
            if f"access.{key}" in present:
                add("field_not_applicable", f"access.{key}", 'only used with target = "mac"')

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
    mac_local = mac and _mac_local_embeddings(m, present)
    if mac_local:
        pass  # one line: mac_local_embeddings_unsupported, from _mac_rules
    elif emb["mode"] == "endpoint":
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
            "embeddings",
            "mode",
            ["base_url", "api_key_ref", "model", "query_prefix"],
            'only used with mode = "endpoint"',
        )
    if emb["model_source"] == "download" and (mac or emb["mode"] != "local"):
        add(
            "field_not_applicable",
            "embeddings.model_source",
            'model_source = "download" fetches the local model on a single-host server; '
            'only used with target = "single-host" and mode = "local"',
        )

    # memory vs embeddings (single-host; mac has hosted_embeddings_required)
    if (
        not mac
        and services["memory"]
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
        [
            k
            for k in SCHEMA["backup"]
            if k not in ("target", "keep", "hosted_opt_out") and k not in allowed
        ],
        f'not used with target = "{target}"',
    )
    if m["install"]["hosted"] is True and target == "none" and backup["hosted_opt_out"] is not True:
        add(
            "backup_required_hosted",
            "backup.target",
            "a hosted install needs a backup target; set one, or set backup.hosted_opt_out = true "
            "to run without backups on purpose",
        )
    if backup["hosted_opt_out"] is True and target != "none":
        add("invalid_value", "backup.hosted_opt_out", 'contradicts target = "' + target + '"')
    if type(backup["keep"]) is int and backup["keep"] < 1 and not _is_bad("backup.keep", bad):
        add("invalid_value", "backup.keep", "must be at least 1")
    if target == "local-path" and backup["path"] is not None and not backup["path"].startswith("/"):
        add("invalid_value", "backup.path", "must be an absolute path")
    if target == "s3-compatible":
        check_url("backup.endpoint", backup["endpoint"])
        check_ref("backup.access_key_ref", backup["access_key_ref"])
        check_ref("backup.secret_key_ref", backup["secret_key_ref"])

    # [images]: exactly one of `registry` and the legacy `image_namespace`,
    # with no default (tasks 01a14b9e, 01a14dd8).
    images = m["images"]
    registry_path = images["registry"]
    namespace = images["image_namespace"]
    registry_bad = _is_bad("images.registry", bad)
    namespace_bad = _is_bad("images.image_namespace", bad)
    if registry_path is not None and namespace is not None:
        add(
            "invalid_value",
            "images.image_namespace",
            "set exactly one of images.registry and the legacy images.image_namespace; "
            "remove image_namespace",
        )
    elif registry_path is None and namespace is None and not (registry_bad or namespace_bad):
        add(
            "missing_required",
            "images.registry",
            "registry is required and has no default: the registry path the Burrow images "
            "are pulled from, e.g. ghcr.io/<owner> (<registry>/core)",
        )
    if registry_path is not None and not _IMAGE_REGISTRY_RE.match(registry_path):
        add(
            "invalid_value",
            "images.registry",
            "must be a registry host and path in lowercase, e.g. ghcr.io/<owner>, "
            "with no scheme, tag or trailing /",
        )
    if namespace is not None and not _IMAGE_NAMESPACE_RE.match(namespace):
        add(
            "invalid_value",
            "images.image_namespace",
            "must be a Docker Hub namespace: lowercase letters and digits, "
            "with single . _ or - between them",
        )
    # An image with no build under a registry yet needs its ref pinned.
    if registry_path is not None and namespace is None:
        for key in sorted(registry.UNPUBLISHED_IN_REGISTRY):
            container = registry.IMAGE_CONTAINERS[key]
            if _runs(m, container) and not images["refs"].get(container):
                add(
                    "missing_required",
                    f"images.refs.{container}",
                    f"{key} has no published image under images.registry yet; pin "
                    f"images.refs.{container}, or use the legacy images.image_namespace",
                )

    # [images.refs]
    for container, ref in m["images"]["refs"].items():
        if ref is not None and not ref.strip():
            add("invalid_value", f"images.refs.{container}", "an image ref cannot be empty")

    # [agents] (task 01a10322): packaged for single-host only in v1.
    # An [agents] table that omits `profile` means full_machine, so it counts.
    if (
        mac
        and m["agents"]["profile"] != AGENTS_ABSENT_PROFILE
        and not _is_bad("agents.profile", bad)
    ):
        add(
            "field_not_applicable",
            "agents.profile",
            'native agents are packaged for target = "single-host" only in v1',
        )


def _mac_local_embeddings(m, present):
    """Would this mac manifest run embeddings locally?

    ``services.embeddings`` is not a mac knob at all, and an EXPLICIT
    ``embeddings.mode = "local"`` asks for a local model. The schema default
    (mode = "local" with no [embeddings] table) is not an ask; memory on without
    a hosted endpoint is ``hosted_embeddings_required`` instead.
    """
    return m["services"]["embeddings"] or (
        m["embeddings"]["mode"] == "local" and "embeddings.mode" in present
    )


def _mac_rules(m, bad, present, add, check_url, check_ref):
    services = m["services"]
    if services["voice"]:
        add(
            "mac_voice_unsupported",
            "services.voice",
            'local speech (speaches) is not supported on target = "mac"; '
            "use a hosted STT endpoint via [meetings] stt_endpoint",
        )
    if _mac_local_embeddings(m, present):
        path = "services.embeddings" if services["embeddings"] else "embeddings.mode"
        add(
            "mac_local_embeddings_unsupported",
            path,
            'target = "mac" runs no local model: set [embeddings] mode = "endpoint" '
            "with a hosted base_url and api_key_ref, and leave services.embeddings off",
        )
    elif services["memory"]:
        emb = m["embeddings"]
        # A missing base_url in mode "endpoint" is embeddings_endpoint_required.
        missing = [
            k
            for k in ("model", "api_key_ref")
            if emb[k] is None and not _is_bad(f"embeddings.{k}", bad)
        ]
        if emb["mode"] != "endpoint" or missing:
            add(
                "hosted_embeddings_required",
                "embeddings",
                'memory on target = "mac" needs [embeddings] mode = "endpoint" with '
                "base_url, model and api_key_ref",
            )

    _mac_access_and_meetings(m, bad, present, add, check_ref)


def _mac_access_and_meetings(m, bad, present, add, check_ref):
    services = m["services"]
    access = m["access"]
    if not _is_bad("access.mode", bad):
        tunnel = access["mode"] == "cloudflare-tunnel"
        need, other = (
            ("tunnel_token_ref", "tailscale_authkey_ref")
            if tunnel
            else ("tailscale_authkey_ref", "tunnel_token_ref")
        )
        if access[need] is None and not _is_bad(f"access.{need}", bad):
            add(
                "tunnel_token_ref_missing" if tunnel else "tailscale_authkey_ref_missing",
                f"access.{need}",
                f'access mode = "{access["mode"]}" needs {need} (the secret\'s NAME)',
            )
        elif access[other] is not None:
            # One line per [access] mistake: a mode switched without its ref
            # reports the missing ref, not also the leftover one.
            add(
                "field_not_applicable",
                f"access.{other}",
                f'not used with mode = "{access["mode"]}"',
            )
        check_ref(f"access.{need}", access[need])

    if not services["meetings"]:
        return  # [meetings] is ignored while the knob is off (one-field flip back)
    meetings = m["meetings"]
    reach = meetings["media_reach"]
    if reach is None:
        if not _is_bad("meetings.media_reach", bad):
            add(
                "meetings_media_reach_required",
                "meetings.media_reach",
                'meetings need media_reach = "lan", "tailnet" or "public" '
                "(where LiveKit's 7881/tcp + 7882/udp are reachable from)",
            )
    elif reach == "public" and meetings["node_ip"] is not None:
        add(
            "field_not_applicable",
            "meetings.node_ip",
            'media_reach = "public" discovers it by STUN',
        )
    if reach in ("lan", "tailnet") and meetings["media_host"] is not None:
        add(
            "field_not_applicable",
            "meetings.media_host",
            'only used with media_reach = "public" (the ddns job keeps it current)',
        )
    if meetings["node_ip"] is not None and not _IPV4_RE.match(meetings["node_ip"]):
        add("invalid_value", "meetings.node_ip", "must be an IPv4 address")
    _stt_endpoint_rule(m, bad, add)


def _single_host_meetings(m, bad, add):
    """``services.meetings`` on target single-host (task 01a19505).

    A droplet has a public IPv4 and LiveKit learns it by STUN
    (``use_external_ip: true``), so ``media_reach = "public"`` is the only
    reach; lan/tailnet and a pinned node_ip are mac's.
    """
    meetings = m["meetings"]
    reach = meetings["media_reach"]
    if reach is None:
        if not _is_bad("meetings.media_reach", bad):
            add(
                "meetings_media_reach_required",
                "meetings.media_reach",
                'meetings on target = "single-host" need media_reach = "public" '
                "(LiveKit's 7881/tcp + 7882/udp on the host's public IP)",
            )
    elif reach != "public":
        add(
            "field_not_applicable",
            "meetings.media_reach",
            f'media_reach = "{reach}" is target = "mac" only; single-host is "public"',
        )
    if meetings["node_ip"] is not None:
        add(
            "field_not_applicable",
            "meetings.node_ip",
            'target = "single-host" discovers its public IP by STUN',
        )
    _stt_endpoint_rule(m, bad, add)


def _stt_endpoint_rule(m, bad, add):
    meetings = m["meetings"]
    if meetings["transcription"]:
        names = {e["name"] for e in m["models"]["endpoints"]}
        if meetings["stt_endpoint"] not in names and not _is_bad("meetings.stt_endpoint", bad):
            add(
                "stt_endpoint_unknown",
                "meetings.stt_endpoint",
                f"{meetings['stt_endpoint']!r} names no [[models.endpoints]] entry",
            )


def _runs(m, container):
    """Whether a manifest that passed the rules above runs ``container``."""
    if container == registry.TRANSCRIBER:
        return bool(m["services"]["meetings"] and m["meetings"]["transcription"])
    # A new UNPUBLISHED_IN_REGISTRY entry must say here when it runs.
    raise AssertionError(f"_runs does not know {container}")


class ValidationWarning:
    """A manifest that is valid but uses a deprecated input."""

    def __init__(self, code, path, message):
        self.code = code
        self.path = path
        self.message = message

    def __repr__(self):
        return f"ValidationWarning({self.code!r}, {self.path!r})"

    def line(self):
        return f"warning {self.code} at {self.path}: {self.message}"


def warnings(normalized):
    """Deprecation warnings for a VALID, normalized manifest (never errors)."""
    out = []
    if normalized["images"]["image_namespace"] is not None:
        out.append(
            ValidationWarning(
                "deprecated",
                "images.image_namespace",
                "image_namespace (the legacy Docker Hub images) is deprecated; "
                "those images are no longer published and stay frozen at their last push; "
                "set images.registry instead, e.g. ghcr.io/<owner>",
            )
        )
    return out


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
    if "agents" not in clean:
        normalized["agents"]["profile"] = AGENTS_ABSENT_PROFILE
    if normalized["install"]["hosted"] is True and "backup.target" not in _present(clean):
        # A hosted install defaults to a real backup target (stage 5).
        normalized["backup"]["target"] = HOSTED_BACKUP_TARGET
        if "backup.path" not in _present(clean):
            normalized["backup"]["path"] = HOSTED_BACKUP_PATH
    _rules(normalized, bad, errors, _present(clean))
    return errors, (None if errors else normalized)
