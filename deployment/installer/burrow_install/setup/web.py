"""Minimal HTTP for the setup CLI (stdlib ``urllib``), with failure classes.

Public TLS verification is always on (the default SSL context); there is no
insecure switch. A connection failure is classified so the caller can tell a
certificate problem from a name that does not resolve from a refused port:

- ``tls_verify_failed``   the peer's certificate did not verify;
- ``dns_unresolved``      the hostname did not resolve;
- ``connection_refused``  nothing listened;
- ``timeout``             no answer in time;
- ``unreachable``         anything else below HTTP.

Header values (API keys) go into the request object only; nothing here logs.
"""

import json
import socket
import ssl
import urllib.error
import urllib.request


class WebError(Exception):
    def __init__(self, kind, url, detail):
        super().__init__(f"{kind}: {url}: {detail}")
        self.kind = kind
        self.url = url
        self.detail = detail


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        if not self.body:
            return None
        return json.loads(self.body.decode("utf-8"))

    def header(self, name):
        return self.headers.get(name)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _classify(exc):
    reason = getattr(exc, "reason", exc)
    if isinstance(reason, ssl.SSLCertVerificationError) or isinstance(
        exc, ssl.SSLCertVerificationError
    ):
        return "tls_verify_failed", getattr(reason, "verify_message", None) or str(reason)
    if isinstance(reason, ssl.SSLError):
        return "tls_error", str(reason)
    if isinstance(reason, socket.gaierror):
        return "dns_unresolved", str(reason)
    if isinstance(reason, ConnectionRefusedError):
        return "connection_refused", str(reason)
    if isinstance(reason, TimeoutError | socket.timeout):
        return "timeout", str(reason)
    return "unreachable", str(reason)


def request(method, url, headers=None, body=None, timeout=30, follow_redirects=True):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    hdrs.setdefault("Accept", "application/json")
    hdrs.setdefault("User-Agent", "burrow-install-setup/1")
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    handlers = [] if follow_redirects else [_NoRedirect()]
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return Response(resp.status, dict(resp.headers.items()), resp.read())
    except urllib.error.HTTPError as exc:
        return Response(exc.code, dict(exc.headers.items()) if exc.headers else {}, exc.read())
    except (urllib.error.URLError, OSError) as exc:
        kind, detail = _classify(exc)
        raise WebError(kind, url, detail) from exc
