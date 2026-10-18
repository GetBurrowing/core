"""Fakes for the setup CLI tests (task 01a0d6ab stage 4).

- ``FakeHost``: records every subprocess (argv AND stdin separately) and
  answers from a script of ``(argv prefix, Result)`` rules. It subclasses the
  real Host so ``open_url`` runs the production code path (osascript on stdin).
- ``FakeKeychain``: an in-memory login Keychain with a scripted dialog.
- ``FakeCloudflare`` / ``FakePocketId`` / ``FakeDockerHub`` / ``FakeEdge``:
  stdlib ``http.server`` fakes on 127.0.0.1. Request and response shapes
  follow Cloudflare's API v4 docs and pocket-id v2.16.0's controllers/DTOs
  (the paths are cited in burrow_install/setup/pocketid.py). Each records
  ``(method, path)`` so tests count POSTs.
"""

import contextlib
import io
import json
import os
import re
import secrets
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from burrow_install.setup import cli
from burrow_install.setup.host import Host, Result


class FakeHost(Host):
    def __init__(self, home, platform="darwin", rules=None):
        super().__init__(environ={"PATH": "/usr/bin:/bin"})
        self._home = home
        self.platform = platform
        self.rules = list(rules or [])
        self.calls = []  # [(argv list, stdin or None)]

    def home(self):
        return self._home

    def which(self, name):
        return None

    def add(self, prefix, result):
        self.rules.insert(0, (tuple(prefix), result))

    def run(self, argv, input=None, env=None, cwd=None, timeout=600):
        argv = [str(a) for a in argv]
        self.calls.append((argv, input))
        for prefix, result in self.rules:
            if tuple(argv[: len(prefix)]) == prefix or _contains(argv, prefix):
                return result(argv, input) if callable(result) else result
        return Result(0, "", "")


def _contains(argv, prefix):
    """Match a rule written against a compose subcommand (``compose-sub``, ...)."""
    if not prefix or prefix[0] != "compose-sub":
        return False
    wanted = list(prefix[1:])
    if argv[:2] != ["docker", "compose"]:
        return False
    rest = argv[6:]  # after: docker compose --project-directory D -f F
    return rest[: len(wanted)] == wanted


class FakeKeychain:
    def __init__(self, dialog_values=None, available=True):
        self.items = {}
        self.dialog_values = dict(dialog_values or {})
        self._available = available

    def available(self):
        return self._available

    def read(self, service, item):
        return self.items.get((service, item))

    def store(self, service, item, value):
        self.items[(service, item)] = value

    def delete(self, service, item):
        self.items.pop((service, item), None)

    def prompt(self, name, install_name):
        return self.dialog_values[name]


class _Server:
    """A ThreadingHTTPServer on 127.0.0.1 with a JSON dispatch method."""

    def __init__(self):
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                data = json.loads(body) if body else None
                outer.requests.append((self.command, self.path))
                status, payload, headers = outer.dispatch(
                    self.command, self.path, dict(self.headers.items()), data
                )
                raw = (
                    payload
                    if isinstance(payload, bytes)
                    else json.dumps(payload).encode("utf-8")
                    if payload is not None
                    else b""
                )
                self.send_response(status)
                headers = dict(headers or {})
                headers.setdefault("Content-Type", "application/json")
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(raw)

            do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _handle

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def count(self, method):
        return sum(1 for m, _p in self.requests if m == method)

    def dispatch(self, method, path, headers, data):  # pragma: no cover - overridden
        return 404, None, None


def _ok(result):
    return 200, {"success": True, "errors": [], "messages": [], "result": result}, None


class FakeCloudflare(_Server):
    """Cloudflare API v4, the subset the setup CLI calls."""

    def __init__(self, token, zone="example.com", tunnel_token="eyFAKE-tunnel-token-01a0d6ab"):
        super().__init__()
        self.token = token
        self.zone = {"id": "z" * 32, "name": zone, "account": {"id": "a" * 32, "name": "acct"}}
        self.tunnels = []
        self.configs = {}
        self.records = []
        self.tunnel_token = tunnel_token

    def dispatch(self, method, path, headers, data):
        if headers.get("Authorization") != f"Bearer {self.token}":
            return 401, {"success": False, "errors": [{"code": 10000, "message": "auth"}]}, None
        parsed = urllib.parse.urlparse(path)
        q = dict(urllib.parse.parse_qsl(parsed.query))
        p = parsed.path.removeprefix("/client/v4")
        acct = f"/accounts/{self.zone['account']['id']}"
        zone = f"/zones/{self.zone['id']}"
        if p == "/zones" and method == "GET":
            return _ok([self.zone] if q.get("name") == self.zone["name"] else [])
        if p == "/user/tokens/verify":
            return _ok({"id": "t" * 32, "status": "active"})
        if p == f"{acct}/cfd_tunnel" and method == "GET":
            return _ok([t for t in self.tunnels if t["name"] == q.get("name")])
        if p == f"{acct}/cfd_tunnel" and method == "POST":
            tunnel = {"id": str(uuid.uuid4()), "name": data["name"], "deleted_at": None}
            self.tunnels.append(tunnel)
            return _ok(dict(tunnel, token=self.tunnel_token))
        for t in list(self.tunnels):
            base = f"{acct}/cfd_tunnel/{t['id']}"
            if p == f"{base}/configurations" and method == "GET":
                return _ok({"tunnel_id": t["id"], "config": self.configs.get(t["id"], {})})
            if p == f"{base}/configurations" and method == "PUT":
                self.configs[t["id"]] = data["config"]
                return _ok({"tunnel_id": t["id"], "config": data["config"]})
            if p == f"{base}/token" and method == "GET":
                return _ok(self.tunnel_token)
            if p == f"{base}/connections" and method == "DELETE":
                return _ok(None)
            if p == base and method == "DELETE":
                self.tunnels.remove(t)
                return _ok(t)
        if p == f"{zone}/dns_records" and method == "GET":
            return _ok(
                [
                    r
                    for r in self.records
                    if r["name"] == q.get("name") and (not q.get("type") or r["type"] == q["type"])
                ]
            )
        if p == f"{zone}/dns_records" and method == "POST":
            record = dict(data, id=uuid.uuid4().hex)
            self.records.append(record)
            return _ok(record)
        for r in list(self.records):
            if p == f"{zone}/dns_records/{r['id']}":
                if method == "PATCH":
                    r.update(data)
                    return _ok(r)
                if method == "DELETE":
                    self.records.remove(r)
                    return _ok({"id": r["id"]})
        return 404, {"success": False, "errors": [{"code": 7003, "message": p}]}, None


_GO_UNITS = {"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}
_GO_PART = re.compile(r"(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)")


def go_duration_seconds(text):
    """Parse a Go ``time.ParseDuration`` string ("30m", "1h30m", "90s") to seconds.

    pocket-id parses the one-time-access ``ttl`` with Go's parser, so the
    installer's LOGIN_TTL is checked the same way rather than by string compare.
    Raises ValueError on anything Go would also reject (empty, unitless, junk).
    """
    if not isinstance(text, str) or not text:
        raise ValueError(f"not a Go duration: {text!r}")
    pos, total = 0, 0.0
    for match in _GO_PART.finditer(text):
        if match.start() != pos:
            break
        total += float(match.group(1)) * _GO_UNITS[match.group(2)]
        pos = match.end()
    if pos != len(text):
        raise ValueError(f"not a Go duration: {text!r}")
    return total


# pocket-id v2.18.0 backend/internal/onetimeaccess/service.go:26-27,271-274.
POCKETID_SHORT_CODE_TTL_MAX = 15 * 60
_UNAMBIGUOUS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


class FakePocketId(_Server):
    """pocket-id v2.16.0: users, webauthn credentials, one-time tokens, clients, secrets.

    One-time tokens follow pocket-id's length rule (service.go:271-274): 6
    characters when ttl <= 15m, 12 otherwise, so the fake cannot hide the
    short-code sign-in failure the real server produces.
    """

    def __init__(self, api_key, auto_create_secret=True):
        super().__init__()
        self.api_key = api_key
        self.auto_create_secret = auto_create_secret
        self.users = [
            {
                "id": "00000000-0000-0000-0000-000000000000",
                "username": "static-api-user",
                "isAdmin": True,
            }
        ]
        self.passkeys = {}
        self.clients = {}
        self.secrets = {}
        self.tokens = []

    def dispatch(self, method, path, headers, data):
        if headers.get("X-Api-Key", headers.get("X-API-Key")) != self.api_key:
            return 401, {"error": "unauthorized"}, None
        parsed = urllib.parse.urlparse(path)
        p = parsed.path
        q = dict(urllib.parse.parse_qsl(parsed.query))
        if p == "/api/users" and method == "GET":
            term = q.get("search", "")
            data_ = [u for u in self.users if term in u["username"]]
            return 200, {"data": data_, "pagination": {"totalItems": len(data_)}}, None
        if p == "/api/users" and method == "POST":
            user = dict(data, id=str(uuid.uuid4()))
            self.users.append(user)
            return 201, user, None
        for u in self.users:
            if p == f"/api/users/{u['id']}/webauthn-credentials":
                return 200, self.passkeys.get(u["id"], []), None
            if p == f"/api/users/{u['id']}/one-time-access-token" and method == "POST":
                ttl = go_duration_seconds((data or {}).get("ttl", ""))
                length = 6 if ttl <= POCKETID_SHORT_CODE_TTL_MAX else 12
                token = "".join(secrets.choice(_UNAMBIGUOUS) for _ in range(length))
                self.tokens.append(token)
                return 201, {"token": token}, None
        if p == "/api/oidc/clients" and method == "POST":
            client = dict(data)
            self.clients[client["id"]] = client
            self.secrets[client["id"]] = []
            if not self.auto_create_secret:
                return 201, client, None
            # pocket-id v2.17.0+ (commit d259a15): an active secret is generated
            # with the client and revealed once as createdSecret.
            generated = uuid.uuid4().hex
            item = {"id": str(uuid.uuid4()), "prefix": generated[:4], "isActive": True}
            self.secrets[client["id"]].append(dict(item, secret=generated))
            return 201, dict(client, createdSecret=dict(item, secret=generated)), None
        for cid, client in self.clients.items():
            if p == f"/api/oidc/clients/{cid}" and method == "GET":
                return 200, client, None
            if p == f"/api/oidc/clients/{cid}" and method == "PUT":
                client.update(data)
                return 200, client, None
            if p == f"/api/oidc/clients/{cid}/secrets" and method == "GET":
                return (
                    200,
                    [{k: v for k, v in s.items() if k != "secret"} for s in self.secrets[cid]],
                    None,
                )
            if p == f"/api/oidc/clients/{cid}/secrets" and method == "POST":
                secret = data.get("secret") or uuid.uuid4().hex
                item = {
                    "id": str(uuid.uuid4()),
                    "prefix": secret[:4],
                    "isActive": True,
                    "secret": secret,
                }
                self.secrets[cid].append(item)
                return 201, dict(item), None
            for item in list(self.secrets[cid]):
                if p == f"/api/oidc/clients/{cid}/secrets/{item['id']}" and method == "DELETE":
                    self.secrets[cid].remove(item)
                    return 204, None, None
        if p.startswith("/api/oidc/clients/"):
            return 404, {"error": "Client not found"}, None
        return 404, {"error": p}, None


class FakeDockerHub(_Server):
    def __init__(self, basic):
        super().__init__()
        self.basic = basic

    def dispatch(self, method, path, headers, data):
        if path.startswith("/token"):
            if headers.get("Authorization") != f"Basic {self.basic}":
                return 401, {"details": "incorrect username or password"}, None
            return 200, {"token": "hub-bearer-01a0d6ab-fake"}, None
        if path.startswith("/v2/") and headers.get("Authorization") == (
            "Bearer hub-bearer-01a0d6ab-fake"
        ):
            return 200, None, None
        return 401, None, None


class FakeEdge(_Server):
    """core behind the tunnel, as verify sees it. URLs are /<host><path>."""

    def __init__(self, primary, auth_host, login_status=302):
        super().__init__()
        self.primary = primary
        self.auth_host = auth_host
        self.login_status = login_status

    def url_for(self, host, path):
        return f"{self.url}/{host}{path}"

    def dispatch(self, method, path, headers, data):
        if path == f"/{self.primary}/health":
            return 200, {"status": "ok", "commit": "f00dfeed"}, None
        if path == f"/{self.primary}/auth/login":
            if self.login_status != 302:
                return self.login_status, {"error": "boom"}, None
            return 302, b"", {"Location": self.url_for(self.auth_host, "/authorize?client_id=x")}
        if path.startswith(f"/{self.auth_host}/authorize"):
            return 200, b"<html></html>", {"Content-Type": "text/html; charset=utf-8"}
        if path.startswith(f"/{self.auth_host}/.well-known"):
            return 200, {"issuer": "x"}, None
        return 404, None, None


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
EXAMPLES = os.path.join(REPO, "deployment", "examples")
MAC = os.path.join(EXAMPLES, "mac.install.toml")
MAC_LITE = os.path.join(EXAMPLES, "mac-lite.install.toml")


def run_cli(env, *argv):
    """Run ``setup <argv>`` in-process; return (exit code, parsed JSON, stdout+stderr text)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err):
        code = cli.main(list(argv), env=env, out=out)
    text = out.getvalue()
    return code, json.loads(text), text + err.getvalue()


def write_secret_file(directory, name, value, mode=0o600):
    path = os.path.join(directory, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as handle:
        handle.write(value + "\n")
    os.chmod(path, mode)
    return path
