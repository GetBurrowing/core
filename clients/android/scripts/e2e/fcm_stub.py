#!/usr/bin/env python3
"""Recording FCM HTTP v1 stub for Burrow Android end-to-end runs.

Task 01a10d8e stage 1. Python 3 standard library only.

Point a Burrow dev server at it with

    config :platform, :fcm,
      service_account: File.read!("<path written by --make-key>"),
      base_url: "http://127.0.0.1:<port>",
      token_url: "http://127.0.0.1:<port>/token"

(or FCM_SERVICE_ACCOUNT_JSON) and every push Burrow sends lands here instead
of Google.

Endpoints
  POST /token                          accepts any jwt-bearer assertion and
                                       returns a fake access token
  POST /v1/projects/<p>/messages:send  appends the JSON body (one line) to
                                       --record and returns {"name": ...}
  GET  /recorded                       every recorded body, as a JSON array

Failure modes
  --drop-first N             close the socket with no response for the first
                             N sends (a cold or reset connection)
  --unregistered-token PFX   a send whose message.token starts with PFX gets
                             404 NOT_FOUND / errorCode UNREGISTERED

  --make-key PATH            write a THROWAWAY service-account JSON with a
                             locally generated RSA key whose token_uri points
                             at this stub, then exit. A real Google key is
                             never needed or read.

Secrets: registration tokens, assertions and access tokens are never printed
to stdout. The request log names the method, path and status only.
"""

import argparse
import base64
import json
import secrets
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"

# ── Throwaway RSA key (stdlib only) ─────────────────────────────────────────

_SMALL_PRIMES = [p for p in range(3, 2000, 2) if all(p % d for d in range(3, int(p**0.5) + 1, 2))]


def _probable_prime(n, rounds=40):
    if n < 2:
        return False
    for p in _SMALL_PRIMES:
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = secrets.randbelow(n - 3) + 2
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits, e):
    while True:
        candidate = secrets.randbits(bits) | (1 << (bits - 1)) | (1 << (bits - 2)) | 1
        if _probable_prime(candidate) and (candidate - 1) % e != 0:
            return candidate


def _der_len(n):
    if n < 0x80:
        return bytes([n])
    out = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(out)]) + out


def _der(tag, body):
    return bytes([tag]) + _der_len(len(body)) + body


def _der_int(v):
    raw = v.to_bytes((v.bit_length() + 8) // 8 or 1, "big")
    return _der(0x02, raw)


def generate_rsa_pkcs8_pem(bits=2048):
    e = 65537
    while True:
        p, q = _prime(bits // 2, e), _prime(bits // 2, e)
        if p != q:
            break
    n = p * q
    d = pow(e, -1, (p - 1) * (q - 1))
    rsa = _der(
        0x30,
        b"".join(
            _der_int(x) for x in (0, n, e, d, p, q, d % (p - 1), d % (q - 1), pow(q, -1, p))
        ),
    )
    rsa_oid = _der(0x06, bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]))
    algorithm = _der(0x30, rsa_oid + _der(0x05, b""))
    pkcs8 = _der(0x30, _der_int(0) + algorithm + _der(0x04, rsa))
    b64 = base64.b64encode(pkcs8).decode()
    lines = [b64[i : i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END PRIVATE KEY-----\n"


def make_key(path, host, port, project):
    account = {
        "type": "service_account",
        "project_id": project,
        "private_key_id": secrets.token_hex(20),
        "private_key": generate_rsa_pkcs8_pem(),
        "client_email": f"fcm-stub@{project}.iam.gserviceaccount.com",
        "client_id": str(secrets.randbelow(10**20)),
        "token_uri": f"http://{host}:{port}/token",
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(account, fh)
    print(f"wrote throwaway service account for project {project} to {path}")


# ── Server ──────────────────────────────────────────────────────────────────


class State:
    def __init__(self, record, drop_first, unregistered_prefix):
        self.lock = threading.Lock()
        self.record = record
        self.drop_remaining = drop_first
        self.unregistered_prefix = unregistered_prefix
        self.recorded = []
        self.sends = 0


class Handler(BaseHTTPRequestHandler):
    server_version = "fcm-stub/1"
    protocol_version = "HTTP/1.1"

    # Method, path and status only: never a header or a body.
    def log_request(self, code="-", size="-"):
        sys.stdout.write(f"{self.command} {self.path.split('?')[0]} {code}\n")
        sys.stdout.flush()

    def log_message(self, fmt, *args):
        pass

    @property
    def state(self):
        return self.server.state

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=UTF-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        if self.path.split("?")[0] == "/recorded":
            with self.state.lock:
                recorded = list(self.state.recorded)
            self._json(200, recorded)
        else:
            self._json(404, {"error": {"code": 404, "status": "NOT_FOUND"}})

    def do_POST(self):
        path = self.path.split("?")[0]
        raw = self._body()

        if path == "/token":
            form = parse_qs(raw.decode("utf-8", "replace"))
            grant = (form.get("grant_type") or [""])[0]
            assertion = (form.get("assertion") or [""])[0]
            if grant != JWT_BEARER or assertion.count(".") != 2:
                self._json(400, {"error": "invalid_grant"})
                return
            self._json(
                200,
                {
                    "access_token": "stub-access-" + secrets.token_urlsafe(24),
                    "expires_in": 3599,
                    "token_type": "Bearer",
                },
            )
            return

        if path.startswith("/v1/projects/") and path.endswith("/messages:send"):
            project = path[len("/v1/projects/") : -len("/messages:send")]

            with self.state.lock:
                drop = self.state.drop_remaining > 0
                if drop:
                    self.state.drop_remaining -= 1

            if drop:
                # A cold connection: no status line at all.
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                sys.stdout.write(f"POST {path} dropped\n")
                sys.stdout.flush()
                return

            if not (self.headers.get("authorization") or "").startswith("Bearer "):
                self._json(401, {"error": {"code": 401, "status": "UNAUTHENTICATED"}})
                return

            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                self._json(400, {"error": {"code": 400, "status": "INVALID_ARGUMENT"}})
                return

            token = ((body.get("message") or {}).get("token")) or ""
            prefix = self.state.unregistered_prefix
            if prefix and token.startswith(prefix):
                self._json(
                    404,
                    {
                        "error": {
                            "code": 404,
                            "message": "Requested entity was not found.",
                            "status": "NOT_FOUND",
                            "details": [
                                {
                                    "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                                    "errorCode": "UNREGISTERED",
                                }
                            ],
                        }
                    },
                )
                return

            with self.state.lock:
                self.state.sends += 1
                n = self.state.sends
                self.state.recorded.append(body)
                if self.state.record:
                    with open(self.state.record, "a", encoding="utf-8") as fh:
                        fh.write(json.dumps(body) + "\n")

            self._json(200, {"name": f"projects/{project}/messages/{n}"})
            return

        self._json(404, {"error": {"code": 404, "status": "NOT_FOUND"}})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8089)
    parser.add_argument("--project", default="burrow-e2e")
    parser.add_argument("--record", help="append every sent message body here (JSON lines)")
    parser.add_argument("--drop-first", type=int, default=0, metavar="N")
    parser.add_argument("--unregistered-token", default=None, metavar="PREFIX")
    parser.add_argument("--make-key", metavar="PATH")
    args = parser.parse_args(argv)

    if args.make_key:
        make_key(args.make_key, args.host, args.port, args.project)
        return 0

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = State(args.record, args.drop_first, args.unregistered_token)
    print(f"fcm stub listening on http://{args.host}:{args.port}")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
