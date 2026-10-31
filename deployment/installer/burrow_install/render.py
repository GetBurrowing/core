"""Render a validated manifest into a deployable install directory.

Two layers:

1. ``plan(manifest)`` is target-independent. It walks ``registry.SERVICES``
   for the enabled containers and resolves each one's image, env (own +
   injected by others), volumes, host mounts, routes, depends_on (own +
   injected, filtered to running containers), init SQL, GPU flag, and the
   generated and customer secrets the install needs. Nothing it returns says
   how the install is started.
2. A TARGET turns a plan plus secret values into files. ``TARGETS`` maps a
   target name to its output layer: ``single-host`` (``templates.py``) emits
   docker compose + Caddy + cloud-init; ``mac`` (``mac.py``, task 01a0d6ab)
   emits docker compose + Caddy behind a tunnel or tailnet and no cloud-init.
   A manifest names its target in ``install.target``. A new target is a new
   module registered here; a new service is a new registry entry. Neither
   edits the other.

The renderer refuses an output directory inside a git work tree
(``output_inside_git_worktree``) so rendered secrets cannot be ``git add``-ed
by accident, and refuses a non-empty one (``output_not_empty``) so a file from
an earlier render with more services on cannot survive into this one.
"""

import json
import os

from . import mac, registry, templates
from .secrets import (
    SecretsError,
    markers,
    parse_env_file,
    redact,
    resolve_customer,
    resolve_generated,
    substitute,
)


class RenderError(Exception):
    def __init__(self, code, path, message):
        super().__init__(message)
        self.code = code
        self.path = path
        self.message = message

    def line(self):
        return f"error {self.code} at {self.path}: {self.message}"


TARGETS = {
    "single-host": templates.SingleHost,
    "mac": mac.Mac,
}
DEFAULT_TARGET = "single-host"


class ResolvedService:
    def __init__(self, container):
        self.container = container
        self.image = None
        self.pull_never = False
        self.command = None
        self.mem_limit = None
        self.env = {}
        self.volumes = {}
        self.host_mounts = []
        self.routes = {}
        self.depends_on = {}
        self.config_files = {}
        self.secret_files = {}
        self.ports = ()
        self.gpu = False
        self.healthcheck = None
        self.networks = ()
        self.systemd_init = False
        self.own_env_file = False

    def secret_env(self):
        return {k: v for k, v in self.env.items() if markers(v)}

    def plain_env(self):
        return {k: v for k, v in self.env.items() if not markers(v)}


class Plan:
    """A target-independent description of one install."""

    def __init__(self, manifest):
        self.manifest = manifest
        self.name = manifest["install"]["name"]
        self.target = manifest["install"]["target"]
        self.primary = manifest["domain"]["primary"]
        self.tls = manifest["domain"]["tls"]
        self.acme_email = manifest["domain"]["acme_email"]
        self.images_preloaded = manifest["images"]["source"] == "preloaded"
        self.containers = registry.enabled_containers(manifest)
        self.services = {}
        self.init_sql = {}
        self.host_files = []
        self.config_files = {}
        self.secret_files = {}
        self.secret_file_values = {}  # filled by build(): {path: substituted value}
        self.generated_secrets = []
        self.customer_refs = {}
        self.endpoints = manifest["models"]["endpoints"]
        self.core_image = None
        self.agent_host_image = None
        # Native agents' capability profile (task 01a10322): "off",
        # "full_machine" (an agent host on the HOST, target layer) or
        # "contained" (the agent-host container, a registry service).
        self.agents = manifest["agents"]["profile"]
        # [backup] (task 01a17b10 stage 5): None when target = "none".
        self.backup = None if manifest["backup"]["target"] == "none" else manifest["backup"]
        self.full_root = self.agents != "off" and manifest["agents"].get("full_root") is True
        # Task 01a10315: VAPID keys generated on the host at stack start, and
        # one SSH key for the cloud image's default user. Both off by default.
        self.vapid_on_host = manifest.get("push", {}).get("vapid") == "generate-on-host"
        self.ssh_authorized_key = manifest["host"].get("ssh_authorized_key")
        # Stage 6: the host downloads the local embeddings model at first boot.
        self.model_download = manifest["embeddings"].get("model_source") == "download"
        # The local embeddings model this install's size tier runs
        # (registry.EMBEDDINGS_PROFILES, task 01a18f76).
        self.embeddings_model = registry.embeddings_model(manifest)

    def routes(self):
        out = {}
        for svc in self.services.values():
            out.update(svc.routes)
        return dict(sorted(out.items()))

    def secret_env_lines(self):
        """``{env name: template}`` across every service, checked consistent."""
        lines = {}
        for svc in self.services.values():
            for name, template in svc.secret_env().items():
                if lines.setdefault(name, template) != template:
                    raise ValueError(f"{name} resolves differently in two services")
        for secret in self.generated_secrets:
            lines.setdefault(secret.name, f"{{secret:{secret.name}}}")
        return dict(sorted(lines.items()))

    def consumed_customer_refs(self):
        """Customer refs some running container reads (e.g. OIDC_CLIENT_SECRET)."""
        templates_ = [t for svc in self.services.values() for t in svc.env.values()]
        templates_ += list(self.secret_files.values())
        return {ref for t in templates_ for kind, ref in markers(t) if kind == "customer"}


def _customer_refs(m):
    refs = {}
    for index, endpoint in enumerate(m["models"]["endpoints"]):
        if endpoint["api_key_ref"]:
            refs[endpoint["api_key_ref"]] = f"models.endpoints[{index}].api_key_ref"
    emb = m["embeddings"]
    if (
        (m["services"]["embeddings"] or m["services"]["memory"])
        and emb["mode"] == "endpoint"
        and emb["api_key_ref"]
    ):
        refs[emb["api_key_ref"]] = "embeddings.api_key_ref"
    if m["install"]["target"] == "mac":
        access = m["access"]
        key = (
            "tunnel_token_ref" if access["mode"] == "cloudflare-tunnel" else "tailscale_authkey_ref"
        )
        refs[access[key]] = f"access.{key}"
    if m["auth"]["client_secret_ref"]:
        refs[m["auth"]["client_secret_ref"]] = "auth.client_secret_ref"
    for key in ("access_key_ref", "secret_key_ref"):
        if m["backup"][key]:
            refs[m["backup"][key]] = f"backup.{key}"
    return refs


def plan(manifest):
    """Resolve a normalized, VALID manifest into a Plan."""
    ctx = registry.Ctx(manifest)
    result = Plan(manifest)
    overrides = manifest["images"]["refs"]
    enabled = result.containers

    for container in enabled:
        entry = registry.SERVICES[container]
        svc = ResolvedService(container)
        svc.image = overrides.get(container) or entry.default_image(ctx)
        svc.pull_never = result.images_preloaded
        svc.command = entry.command_for(ctx)
        svc.mem_limit = entry.mem_limit_for(ctx)
        svc.env = dict(entry.env(ctx))
        svc.volumes = dict(entry.volumes)
        svc.host_mounts = list(entry.host_mounts(ctx))
        svc.routes = dict(entry.routes(ctx))
        svc.depends_on = {d: c for d, c in entry.depends_on_for(ctx).items() if d in enabled}
        svc.config_files = dict(entry.config_files(ctx))
        svc.secret_files = dict(entry.secret_files(ctx))
        svc.ports = entry.ports_for(ctx)
        svc.gpu = entry.gpu(ctx)
        svc.healthcheck = entry.healthcheck
        svc.networks = tuple(entry.networks(ctx))
        svc.systemd_init = entry.systemd_init
        svc.own_env_file = entry.own_env_file
        result.services[container] = svc

    for container in enabled:
        entry = registry.SERVICES[container]
        for target, env in entry.injects(ctx).items():
            if target in result.services:
                result.services[target].env.update(env)
        for target, edges in entry.injects_depends_on(ctx).items():
            if target in result.services:
                result.services[target].depends_on.update(
                    {d: c for d, c in edges.items() if d in enabled}
                )
        result.init_sql.update(entry.init_sql(ctx))
        result.host_files.extend(entry.host_files(ctx))
        result.config_files.update(result.services[container].config_files)
        result.secret_files.update(result.services[container].secret_files)
        result.generated_secrets.extend(entry.secrets_for(ctx))

    for svc in result.services.values():
        svc.env = dict(sorted(svc.env.items()))
        svc.depends_on = dict(sorted(svc.depends_on.items()))

    result.customer_refs = _customer_refs(manifest)
    result.core_image = result.services["core-platform"].image
    # full_machine copies the daemon out of the agent-host image on the host.
    result.agent_host_image = overrides.get(registry.AGENT_HOST) or registry.agent_host_image(
        manifest
    )
    _check_references(result)
    return result


def _check_references(p):
    """Every secret marker has an owner in this plan; every edge a target."""
    owned = {s.name for s in p.generated_secrets}
    for rel, text in p.config_files.items():
        if markers(text):
            raise ValueError(f"config file {rel} carries a secret marker")
    for svc in p.services.values():
        for name, template in list(svc.env.items()) + list(svc.secret_files.items()):
            for kind, ref in markers(template):
                if kind == "secret" and ref not in owned:
                    raise ValueError(
                        f"{svc.container}.{name} uses {ref}, owned by no enabled service"
                    )
                if kind == "customer" and ref not in p.customer_refs:
                    raise ValueError(f"{svc.container}.{name} uses customer ref {ref} not declared")
        for dep in svc.depends_on:
            if dep not in p.services:
                raise ValueError(f"{svc.container} depends on {dep}, which is not running")


def inside_git_worktree(path):
    """True if ``path`` or any ancestor holds a ``.git`` dir or file."""
    current = os.path.abspath(path)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return False
        current = parent


def _check_out_dir(out):
    if inside_git_worktree(out):
        raise RenderError(
            "output_inside_git_worktree",
            out,
            "refusing to write rendered secrets inside a git work tree; pick a directory "
            "outside any repository",
        )
    if os.path.exists(out) and (not os.path.isdir(out) or os.listdir(out)):
        raise RenderError(
            "output_not_empty",
            out,
            "the output directory must not exist or be empty, so no file from an earlier "
            "render survives",
        )


def _read(path, flag):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise RenderError("unreadable_file", flag, exc.strerror or str(exc)) from exc


class Rendered:
    """The files of one render plus the secret values that went into them."""

    def __init__(self, files, generated, customer, registry_auth):
        self.files = files  # {relative path: (text, mode)}
        self.generated = generated
        self.customer = customer
        self.registry_auth = registry_auth

    def secret_values(self):
        values = dict(self.generated)
        values.update(self.customer)
        if self.registry_auth:
            values["registry-auth"] = self.registry_auth
        return values

    def redacted(self):
        values = self.secret_values()
        return {path: redact(text, values) for path, (text, _mode) in self.files.items()}


def build(
    manifest,
    target=None,
    reuse_secrets=None,
    customer_secrets=None,
    registry_auth=None,
):
    """Return a ``Rendered`` for a valid manifest without touching the disk.

    ``target`` defaults to the manifest's ``install.target``; naming a different
    one is ``target_mismatch`` (the validator's per-target rules ran against
    the manifest's). ``reuse_secrets`` / ``customer_secrets`` /
    ``registry_auth`` are paths.
    """
    declared = manifest["install"]["target"]
    if target is not None and target != declared:
        raise RenderError(
            "target_mismatch",
            "--target",
            f"the manifest declares install.target = {declared!r}; set it there instead",
        )
    target = declared
    try:
        p = plan(manifest)
    except registry.MediaIpUndetected as exc:
        raise RenderError(
            "media_ip_undetected",
            "meetings.node_ip",
            f"media_reach = {exc.reach!r} could not detect this machine's address; "
            "set [meetings] node_ip",
        ) from exc
    except registry.ImageNamespaceMissing as exc:
        raise RenderError("missing_required", registry.IMAGE_REGISTRY_INPUT, str(exc)) from exc
    except registry.ImageUnpublished as exc:
        raise RenderError("missing_required", f"images.refs.{exc.container}", str(exc)) from exc

    private_defaults = [
        c
        for c in p.containers
        if registry.SERVICES[c].private_image and not manifest["images"]["refs"].get(c)
    ]
    if p.agents == "full_machine" and not manifest["images"]["refs"].get(registry.AGENT_HOST):
        # Not a container here, but the host pulls the image at first boot.
        private_defaults.append(registry.AGENT_HOST)
    if (
        not p.images_preloaded
        and private_defaults
        and registry_auth is None
        and not manifest["images"]["public"]
    ):
        raise RenderError(
            "registry_auth_required",
            "images.source",
            'images.source = "registry" pulls private images ('
            + ", ".join(private_defaults)
            + '); pass --registry-auth <docker config.json> or use source = "preloaded"',
        )

    try:
        reuse = parse_env_file(reuse_secrets) if reuse_secrets else None
        supplied = parse_env_file(customer_secrets) if customer_secrets else None
        generated = resolve_generated(p.generated_secrets, reuse)
        customer = resolve_customer(p.customer_refs, supplied, set(generated))
    except SecretsError as exc:
        raise RenderError(exc.code, exc.path, exc.message) from exc

    auth_text = _read(registry_auth, "--registry-auth") if registry_auth else None
    if auth_text is not None:
        try:
            json.loads(auth_text)
        except ValueError as exc:
            raise RenderError(
                "invalid_value", "--registry-auth", "must be a docker config.json"
            ) from exc

    secret_lines = {
        name: substitute(template, generated, customer)
        for name, template in p.secret_env_lines().items()
    }
    p.secret_file_values = {
        rel: substitute(template, generated, customer)
        for rel, template in sorted(p.secret_files.items())
    }
    # A customer secret no container reads (a model API key, a backup key) is
    # kept apart from secrets.env: every container that reads secrets.env sees
    # all of it, and e.g. files-service would take an OPENAI_API_KEY it finds
    # there as its STT credential (files-service app/stt.py:92).
    consumed = p.consumed_customer_refs()
    unconsumed = {k: v for k, v in sorted(customer.items()) if k not in consumed}
    files = TARGETS[target].files(p, secret_lines, unconsumed, auth_text)
    return Rendered(files, generated, customer, auth_text)


def write(rendered, out):
    """Write a Rendered to ``out`` (must not exist or be empty)."""
    _check_out_dir(out)
    os.makedirs(out, mode=0o700, exist_ok=True)
    os.chmod(out, 0o700)
    for rel, (text, mode) in sorted(rendered.files.items()):
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(path, mode)


def render(manifest, out, **kwargs):
    """Check ``out`` first (nothing is generated for a refused dir), then build and write."""
    _check_out_dir(out)
    rendered = build(manifest, **kwargs)
    write(rendered, out)
    return rendered


def redact_dir(src, out):
    """Copy a render dir to ``out`` with every secret value replaced by a placeholder.

    Values come from ``src/secrets.env`` and, if present, ``src/customer-secrets.env``
    and ``src/registry-auth.json``.
    Lets an operator diff two renders without printing a secret.
    """
    _check_out_dir(out)
    try:
        values = parse_env_file(os.path.join(src, "secrets.env"))
        customer_path = os.path.join(src, "customer-secrets.env")
        customer = parse_env_file(customer_path) if os.path.exists(customer_path) else {}
    except SecretsError as exc:
        raise RenderError(exc.code, exc.path, exc.message) from exc
    # Generated secrets keep their registry name. An alias (MEMORY_API_KEY) or
    # a derived line (DATABASE_URL) embeds one of those values and is redacted
    # through it; what is left is a customer-supplied value.
    canonical = {k: v for k, v in values.items() if k in registry.SECRETS}
    known = set(canonical.values())
    for name, value in sorted(values.items()):
        if name in canonical or any(k in value for k in known if k):
            continue
        canonical[name] = value
    canonical.update(customer)
    # Customer keys mounted into one container (*_FILE) live only in secrets/.
    secret_dir = os.path.join(src, "secrets")
    if os.path.isdir(secret_dir):
        for name in sorted(os.listdir(secret_dir)):
            value = _read(os.path.join(secret_dir, name), f"secrets/{name}").strip()
            canonical.setdefault(name, value)
    auth_path = os.path.join(src, "registry-auth.json")
    if os.path.exists(auth_path):
        canonical["registry-auth"] = _read(auth_path, auth_path)
    os.makedirs(out, mode=0o700, exist_ok=True)
    for root, _dirs, names in os.walk(src):
        for name in sorted(names):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, src)
            text = redact(_read(path, rel), canonical)
            dest = os.path.join(out, rel)
            os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
            with open(dest, "w", encoding="utf-8") as handle:
                handle.write(text)
