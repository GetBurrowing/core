"""Cloudflare: zone lookup, the Universal SSL depth rule, a remotely-managed tunnel.

Mac target, ``[access] mode = "cloudflare-tunnel"``. API v4 shapes follow
Cloudflare's docs (developers.cloudflare.com/api): every response is
``{"success": bool, "errors": [...], "result": ...}``.

- ``domain``: ``GET /zones?name=`` walking up from ``[domain] primary`` finds
  the zone; the zone object carries ``account.id``. Universal SSL covers the
  apex and ONE label below it, so a hostname two labels deep gets no edge
  certificate: ``hostname_too_deep``, whose remediation names the flat
  alternative (``auth.suite.example.com`` -> ``auth-suite.example.com``).
  The token is checked with ``GET /user/tokens/verify`` (account-owned tokens:
  ``/accounts/{id}/tokens/verify``).
- ``tunnel``: find-or-create tunnel ``suite-<install.name>`` with
  ``config_src = "cloudflare"``; PUT its ingress only when it differs (each
  hostname -> ``http://caddy:80``, then ``http_status:404``); find-or-create a
  proxied CNAME ``<host> -> <tunnel id>.cfargotunnel.com`` per hostname,
  refusing to touch any other record at that name; then
  ``GET .../token`` straight into secrets.env. A second run makes no POST.

The tunnel is outbound-only: no port-forward and no dynamic DNS for the web,
auth or signalling hostnames.
"""

from . import web
from .state import SetupError

API = "https://api.cloudflare.com/client/v4"
TOKEN_SCOPES = "Zone:Read, DNS:Edit and Account: Cloudflare Tunnel:Edit"
CADDY = "http://caddy:80"


class Client:
    def __init__(self, token, base=API):
        self.token = token
        self.base = base.rstrip("/")

    def call(self, method, path, body=None, allow=()):
        try:
            resp = web.request(
                method,
                self.base + path,
                headers={"Authorization": f"Bearer {self.token}"},
                body=body,
            )
        except web.WebError as exc:
            raise SetupError(
                "cloudflare_unreachable",
                f"{method} {path}: {exc.kind}: {exc.detail}",
                "check this machine's internet connection and re-run",
            ) from exc
        if resp.status in allow:
            return None
        if resp.status in (401, 403):
            raise SetupError(
                "cloudflare_auth_failed",
                f"{method} {path}: HTTP {resp.status}",
                f"the Cloudflare API token needs {TOKEN_SCOPES} on the zone and its account",
            )
        try:
            doc = resp.json() or {}
        except ValueError:
            doc = {}
        if resp.status >= 400 or not doc.get("success", False):
            errors = "; ".join(
                f"{e.get('code')}: {e.get('message')}" for e in doc.get("errors", [])
            )
            raise SetupError(
                "cloudflare_api_error",
                f"{method} {path}: HTTP {resp.status} {errors}".strip(),
                "see Cloudflare's error code; re-run once fixed",
            )
        return doc.get("result")


def hostnames(manifest):
    """The public hostnames of this install, in route order (flag, host)."""
    from .. import registry

    ctx = registry.Ctx(manifest)
    out = [("--domain", ctx.primary)]
    if manifest["auth"]["mode"] == "bundled-pocket-id":
        out.append(("--auth-host", ctx.auth_host))
    if manifest["services"].get("meetings"):
        out.append(("--livekit-host", ctx.livekit_host))
    return out


def every_hostname(manifest):
    """Every hostname this install can route, whatever its knobs say today.

    `hostnames` drops the livekit host while meetings are off, so a record
    created while they were on would outlive the flip (and teardown) unless
    cleanup looks at this wider set. Measured on rock, 2026-10-05: after the
    meetings-off flip and `setup teardown`, livekit-<tag>.<zone> was still a
    CNAME to the deleted tunnel.
    """
    from .. import registry

    ctx = registry.Ctx(manifest)
    out = [h for _flag, h in hostnames(manifest)]
    if ctx.livekit_host and ctx.livekit_host not in out:
        out.append(ctx.livekit_host)
    return out


def _delete_ours(client, zone, host, target):
    """Delete ``host``'s CNAMEs that point at ``target``; True if any were."""
    deleted = False
    for record in client.call("GET", f"/zones/{zone}/dns_records?name={host}") or []:
        if record.get("type") == "CNAME" and record.get("content") == target:
            client.call("DELETE", f"/zones/{zone}/dns_records/{record['id']}")
            deleted = True
    return deleted


def find_zone(client, primary):
    labels = primary.split(".")
    for i in range(len(labels) - 1):
        name = ".".join(labels[i:])
        result = client.call("GET", f"/zones?name={name}")
        if result:
            return result[0]
    raise SetupError(
        "zone_not_found",
        f"no Cloudflare zone this token can read contains {primary}",
        f"add the domain to Cloudflare, or grant the token Zone:Read on it ({TOKEN_SCOPES})",
    )


def depth_errors(zone_name, hosts):
    """``[(flag, host, flat alternative or None, reason)]`` for hosts that break the rule."""
    problems = []
    zone_labels = zone_name.split(".")
    for flag, host in hosts:
        if host != zone_name and not host.endswith("." + zone_name):
            problems.append((flag, host, None, "outside"))
            continue
        depth = len(host.split(".")) - len(zone_labels)
        if depth > 1:
            sub = host[: -(len(zone_name) + 1)]
            problems.append((flag, host, f"{sub.replace('.', '-')}.{zone_name}", "deep"))
    return problems


def domain(ctx, token):
    manifest = ctx.manifest
    client = Client(token, ctx.cloudflare_api)
    hosts = hostnames(manifest)
    zone = find_zone(client, hosts[0][1])
    problems = depth_errors(zone["name"], hosts)
    for flag, host, _flat, reason in problems:
        if reason == "outside":
            raise SetupError(
                "hostname_outside_zone",
                f"{host} is not in zone {zone['name']}",
                f"pick a hostname under {zone['name']}: setup init {flag} <name>.{zone['name']}",
            )
    if problems:
        fixes = " ".join(f"{flag} {flat}" for flag, _host, flat, _r in problems)
        raise SetupError(
            "hostname_too_deep",
            ", ".join(h for _f, h, _x, _r in problems)
            + f" {'is' if len(problems) == 1 else 'are'} more than one label below zone "
            f"{zone['name']}; Cloudflare Universal SSL covers only one level, so the edge "
            "would have no certificate",
            f"use flat names: setup init {fixes}",
        )
    account_id = zone["account"]["id"]
    verified = client.call("GET", "/user/tokens/verify", allow=(400, 401, 403))
    if verified is None:
        verified = client.call("GET", f"/accounts/{account_id}/tokens/verify")
    if (verified or {}).get("status") != "active":
        raise SetupError(
            "cloudflare_token_inactive",
            f"the token's status is {(verified or {}).get('status')!r}",
            "create a new API token and re-supply CLOUDFLARE_API_TOKEN",
        )
    ctx.state["ids"].update(
        {"zone_id": zone["id"], "zone_name": zone["name"], "account_id": account_id}
    )
    return {
        "zone": zone["name"],
        "zone_id": zone["id"],
        "account_id": account_id,
        "hostnames": [h for _f, h in hosts],
        "token_status": "active",
        "token_scopes_required": TOKEN_SCOPES,
    }


def tunnel_name(manifest):
    return f"suite-{manifest['install']['name']}"


def _ingress(hosts):
    return [{"hostname": h, "service": CADDY} for _f, h in hosts] + [{"service": "http_status:404"}]


def _normalize_ingress(rules):
    return [(r.get("hostname"), r.get("service")) for r in rules or []]


def tunnel(ctx, token):
    ids = ctx.state["ids"]
    if not ids.get("account_id") or not ids.get("zone_id"):
        raise SetupError("step_order", "the domain step has not run", "run `setup run domain`")
    manifest = ctx.manifest
    client = Client(token, ctx.cloudflare_api)
    account, zone = ids["account_id"], ids["zone_id"]
    name = tunnel_name(manifest)
    hosts = hostnames(manifest)
    outputs = {"tunnel_name": name}

    found = client.call("GET", f"/accounts/{account}/cfd_tunnel?name={name}&is_deleted=false")
    found = [t for t in found or [] if t.get("name") == name and not t.get("deleted_at")]
    if found:
        tunnel_id = found[0]["id"]
        outputs["tunnel"] = "present"
    else:
        created = client.call(
            "POST",
            f"/accounts/{account}/cfd_tunnel",
            body={"name": name, "config_src": "cloudflare"},
        )
        tunnel_id = created["id"]
        outputs["tunnel"] = "created"
    outputs["tunnel_id"] = tunnel_id
    ids["tunnel_id"] = tunnel_id
    ids["tunnel_name"] = name

    desired = _ingress(hosts)
    current = client.call("GET", f"/accounts/{account}/cfd_tunnel/{tunnel_id}/configurations")
    current_rules = ((current or {}).get("config") or {}).get("ingress")
    if _normalize_ingress(current_rules) != _normalize_ingress(desired):
        client.call(
            "PUT",
            f"/accounts/{account}/cfd_tunnel/{tunnel_id}/configurations",
            body={"config": {"ingress": desired}},
        )
        outputs["ingress"] = "updated"
    else:
        outputs["ingress"] = "unchanged"

    target = f"{tunnel_id}.cfargotunnel.com"
    dns = {}
    for _flag, host in hosts:
        records = client.call("GET", f"/zones/{zone}/dns_records?name={host}") or []
        ours = [r for r in records if r.get("type") == "CNAME" and r.get("content") == target]
        others = [r for r in records if r not in ours]
        if others:
            kinds = ", ".join(sorted({r.get("type", "?") for r in others}))
            raise SetupError(
                "dns_record_conflict",
                f"{host} already has a {kinds} record that does not point at this tunnel",
                "delete that record in the Cloudflare dashboard if it is unused, or choose "
                "another hostname with `setup init`; the CLI never overwrites a record it "
                "did not create",
            )
        if ours and ours[0].get("proxied"):
            dns[host] = "present"
            continue
        if ours:
            client.call(
                "PATCH", f"/zones/{zone}/dns_records/{ours[0]['id']}", body={"proxied": True}
            )
            dns[host] = "proxied"
            continue
        client.call(
            "POST",
            f"/zones/{zone}/dns_records",
            body={
                "type": "CNAME",
                "name": host,
                "content": target,
                "proxied": True,
                "comment": f"Burrow install {manifest['install']['name']} (setup tunnel)",
            },
        )
        dns[host] = "created"
    routed = {h for _flag, h in hosts}
    for host in every_hostname(manifest):
        if host not in routed and _delete_ours(client, zone, host, target):
            dns[host] = "deleted (no longer routed)"
    outputs["dns"] = dns

    value = client.call("GET", f"/accounts/{account}/cfd_tunnel/{tunnel_id}/token")
    ref = manifest["access"]["tunnel_token_ref"]
    if ctx.install.read_secret(ref) == value:
        outputs["tunnel_token"] = "unchanged"
    else:
        ctx.install.upsert_secret(ref, value)
        outputs["tunnel_token"] = f"written to secrets.env as {ref}"
    outputs["port_forward_needed"] = False
    return outputs


def teardown(ctx, token):
    """Delete this install's DNS records (only those pointing at its tunnel) and the tunnel."""
    ids = ctx.state["ids"]
    client = Client(token, ctx.cloudflare_api)
    account, zone = ids.get("account_id"), ids.get("zone_id")
    tunnel_id = ids.get("tunnel_id")
    if not (account and zone and tunnel_id):
        return {"tunnel": "none recorded"}
    target = f"{tunnel_id}.cfargotunnel.com"
    deleted = [h for h in every_hostname(ctx.manifest) if _delete_ours(client, zone, h, target)]
    client.call("DELETE", f"/accounts/{account}/cfd_tunnel/{tunnel_id}/connections", allow=(404,))
    client.call("DELETE", f"/accounts/{account}/cfd_tunnel/{tunnel_id}")
    for key in ("tunnel_id", "tunnel_name"):
        ids.pop(key, None)
    return {"dns_deleted": deleted, "tunnel": "deleted"}
