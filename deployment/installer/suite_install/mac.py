"""Output layer for the ``mac`` target: docker compose + Caddy behind an edge.

Task 01a0d6ab. The install runs in Docker Desktop (or OrbStack) on a Mac that
has no public TLS of its own, so:

- TLS ends at the EDGE, not on the Mac. ``[access] mode = "cloudflare-tunnel"``
  runs ``cloudflared`` (a remotely-managed tunnel; its ingress points every
  public hostname at ``http://caddy:80``). ``mode = "tailscale"`` runs one
  ``tailscale/tailscale`` sidecar per hostname, each serving HTTPS on its
  ts.net name and proxying to ``http://caddy:80``. Both certificates chain to
  a public root.
- Caddy routes by Host with ``auto_https off`` and ``http://`` site blocks, and
  publishes no host port.
- Consequence: NO compose alias for the auth host and NO CA-bundle mount over
  CAStore (the single-host ``tls = "internal"`` mechanism). core reaches its
  issuer at ``https://<auth_host>`` through public DNS and the edge, whose
  certificate CAStore already trusts. An alias would send core to Caddy's
  plain-http listener and break OIDC discovery.
- The only host ports are LiveKit's single-port media listeners (7881/tcp,
  7882/udp), and only with meetings on.
- No cloud-init: the files are the install directory itself.

A target class exposes
``files(plan, secret_lines, customer_secrets, registry_auth) -> {path: (text, mode)}``.
"""

from . import registry, templates
from .templates import FILE_MODE, SECRET_MODE, yaml_doc

HEADER = templates.HEADER


def _service(plan, svc):
    out = templates._compose_service(plan, svc)
    # The single-host layer aliases every routed host to Caddy. Here that
    # would point core's OIDC discovery at Caddy's plain-http listener.
    out.pop("networks", None)
    health = out.get("healthcheck")
    if health and health["test"][:2] == ["CMD", "pg_isready"]:
        # First boot runs initdb plus the postgres-init scripts, then a
        # restart. On rock (8 GB, under memory pressure, 2026-10-05) that
        # checkpoint's fsync alone took 22 s and postgres was marked unhealthy
        # after the 5 x 10 s retries, failing `up`. A start period lets the
        # first boot finish; afterwards the check is as tight as before.
        health["start_period"] = PG_START_PERIOD
    return out


# How long a first boot of the bundled postgres may take before failed
# healthchecks count (Docker's `start_period`).
PG_START_PERIOD = "180s"


def compose(plan):
    doc = {
        "name": plan.name,
        "services": {c: _service(plan, plan.services[c]) for c in plan.containers},
    }
    volumes = sorted({v for svc in plan.services.values() for v in svc.volumes})
    if volumes:
        doc["volumes"] = {v: {} for v in volumes}
    return yaml_doc(
        doc,
        [
            HEADER.format(name=plan.name),
            (
                f"Target mac, access mode {plan.manifest['access']['mode']}: TLS ends at that "
                "edge; Caddy is plain http."
            ),
        ],
    )


def caddyfile(plan):
    lines = [
        f"# {HEADER.format(name=plan.name)}",
        f"# Target mac, access mode {plan.manifest['access']['mode']}: that edge terminates",
        "# TLS and dials http://caddy:80; Caddy routes by Host. No certificate is issued here.",
        "{",
        "\tauto_https off",
        "\tservers {",
        "\t\t# Keep the edge's X-Forwarded-Proto (https) and client address.",
        "\t\ttrusted_proxies static private_ranges",
        "\t}",
        "}",
    ]
    for host, port in plan.routes().items():
        container = next(s.container for s in plan.services.values() if host in s.routes)
        lines += ["", f"http://{host} {{", f"\treverse_proxy {container}:{port}", "}"]
    lines += [
        "",
        "# Any other Host on :80 (the tunnel's ingress also ends in http_status:404).",
        "http:// {",
        "\trespond 404",
        "}",
    ]
    if "livekit" in plan.services:
        lines += [
            "",
            "# INTERNAL only (no host port): LiveKit's webhook and the transcriber's",
            "# segment sink reach core here. core forces https (prod.exs force_ssl,",
            "# rewrite_on x_forwarded_proto), so a plain internal POST would be redirected.",
            f"http://:{registry.CORE_INTERNAL_PORT} {{",
            "\treverse_proxy core-platform:4000 {",
            "\t\theader_up X-Forwarded-Proto https",
            "\t}",
            "}",
        ]
    return "\n".join(lines) + "\n"


class Mac:
    name = "mac"

    @staticmethod
    def files(plan, secret_lines, customer_secrets, registry_auth):
        files = {
            "compose.yaml": (compose(plan), FILE_MODE),
            "Caddyfile": (caddyfile(plan), FILE_MODE),
            "secrets.env": (templates.secrets_env(plan, secret_lines), SECRET_MODE),
            "services.txt": ("\n".join(plan.containers) + "\n", FILE_MODE),
        }
        if customer_secrets:
            files["customer-secrets.env"] = (
                templates.secrets_env(plan, customer_secrets, customer=True),
                SECRET_MODE,
            )
        for name, sql in sorted(plan.init_sql.items()):
            files[f"postgres-init/{name}"] = (sql, FILE_MODE)
        for rel, text in sorted(plan.config_files.items()):
            files[rel] = (text, FILE_MODE)
        for rel, value in sorted(plan.secret_file_values.items()):
            files[rel] = (value, SECRET_MODE)
        if plan.endpoints:
            files["models.json"] = (templates.models_json(plan), FILE_MODE)
        if registry_auth is not None:
            files["registry-auth.json"] = (templates._ensure_newline(registry_auth), SECRET_MODE)
        return files
