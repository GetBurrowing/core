"""``bootstrap-admin``: non-interactive pocket-id admin bootstrap (core task 01a10315).

    python3 -m burrow_install bootstrap-admin --base https://<auth host> \\
        --api-key-file <0600 file> --email <addr> [--username <u>] --link-file <path> \\
        [--primary <host> --oidc-secret-file <0600 file>]

For an install provisioned by someone else (a droplet), where the Mac-oriented
``setup`` CLI does not apply. It reuses ``setup/pocketid.py`` (target-agnostic)
unchanged:

1. ``pocketid.ensure_admin``: find or create the first human admin.
2. ``pocketid.login_link``: mint a one-time sign-in code with ``LOGIN_TTL``
   (30m; it must stay above 15m, see pocketid.py) and build
   ``https://<auth host>/lc/<code>?redirect=/settings/account``.
3. Write that link to ``--link-file`` with mode 0600.
4. With ``--primary`` and ``--oidc-secret-file`` (both or neither): register
   core's OIDC client the way the Mac setup CLI does (``ensure_client`` with
   the primary's callback and PKCE, ``drop_created_secret``), then the
   render's OIDC_CLIENT_SECRET as its secret unless an active secret with the
   same 4-character prefix is already listed. A single-host render has no
   other step that registers the client, so without this core's sign-in
   cannot complete on a droplet.

The link is a credential until it is used or expires, and the API key is the
pocket-id admin credential, so neither is EVER printed. stdout carries exactly
one JSON document: ``{"ok": true, "admin": "created"|"exists", "link_file": ...}``
or ``{"ok": false, "error": <code>, "kind": <kind>, "message": ...}``.

Idempotent: a re-run with the admin already there mints a fresh link (so an
expired 30-minute link never strands the customer).

Exit codes: 0 ok; 1 pocket-id unreachable or erroring (``kind`` is the
``setup/web.py`` WebError kind, or ``http`` for an HTTP-level refusal); 2 usage.
"""

import argparse
import json
import os
import stat
import sys
import urllib.parse

from .setup import pocketid, web
from .setup.state import SetupError

EXIT_OK = 0
EXIT_POCKETID = 1
EXIT_USAGE = 2

_LOOPBACK = ("127.0.0.1", "localhost", "::1")


class UsageError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError("usage", message)


def _parser():
    parser = _Parser(
        prog="burrow_install bootstrap-admin",
        description="create the first pocket-id admin and write a one-time sign-in link",
    )
    parser.add_argument("--base", required=True, help="https://<auth host> of pocket-id")
    parser.add_argument("--api-key-file", required=True, help="0600 file holding STATIC_API_KEY")
    parser.add_argument("--email", required=True)
    parser.add_argument("--username", default=None)
    parser.add_argument("--link-file", required=True, help="written with mode 0600")
    parser.add_argument("--primary", default=None, help="the install's primary host")
    parser.add_argument(
        "--oidc-secret-file", default=None, help="0600 file holding OIDC_CLIENT_SECRET"
    )
    return parser


def auth_host_of(base):
    """The auth host of ``--base``. https only, except a loopback host (tests)."""
    parsed = urllib.parse.urlparse(base)
    host = parsed.hostname
    if not host or parsed.scheme not in ("https", "http"):
        raise UsageError("invalid_base", "--base must be https://<auth host>")
    if parsed.scheme == "http" and host not in _LOOPBACK:
        raise UsageError("invalid_base", "--base must be https:// (http is loopback-only)")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise UsageError("invalid_base", "--base is the auth origin only, with no path")
    return parsed.netloc


def read_api_key(path, flag="--api-key-file", code="api_key_file"):
    """The value of a regular file readable by its owner only (never echoed)."""
    try:
        info = os.stat(path)
    except OSError as exc:
        raise UsageError(f"unreadable_{code}", f"{flag}: {exc.strerror}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise UsageError(f"unreadable_{code}", f"{flag} is not a regular file")
    if info.st_mode & 0o077:
        raise UsageError(
            f"{code}_mode",
            f"{flag} is mode {stat.S_IMODE(info.st_mode):04o}; chmod 0600 it",
        )
    with open(path, encoding="utf-8") as handle:
        key = handle.read().strip()
    if not key:
        raise UsageError(f"unreadable_{code}", f"{flag} is empty")
    return key


def ensure_oidc_client(client, primary, secret):
    """Register core's OIDC client and ``secret`` on it. Returns the client action."""
    record, action = pocketid.ensure_client(client, primary)
    if action == "created":
        pocketid.drop_created_secret(client, record)
    _status, listed = client.call("GET", f"/api/oidc/clients/{pocketid.CLIENT_ID}/secrets")
    present = any(
        item.get("prefix") == secret[:4] and item.get("isActive", True) for item in listed or []
    )
    if not present:
        client.call(
            "POST", f"/api/oidc/clients/{pocketid.CLIENT_ID}/secrets", body={"secret": secret}
        )
    return action


def _valid_host(value):
    labels = value.split(".")
    return len(labels) >= 2 and all(
        label and len(label) <= 63 and all(c.isalnum() or c == "-" for c in label)
        for label in labels
    )


def write_link(path, link):
    """Write ``link`` to ``path`` as a fresh 0600 file (replacing any earlier link)."""
    directory = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(link + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _emit(out, doc):
    out.write(json.dumps(doc, sort_keys=True) + "\n")


def run(args):
    """Return the success document; raises UsageError or SetupError."""
    auth_host = auth_host_of(args.base)
    if "@" not in args.email or any(c.isspace() for c in args.email):
        raise UsageError("invalid_email", "--email must be an email address")
    link_dir = os.path.dirname(os.path.abspath(args.link_file))
    if not os.path.isdir(link_dir):
        raise UsageError("invalid_link_file", "--link-file's directory does not exist")
    if (args.primary is None) != (args.oidc_secret_file is None):
        raise UsageError("usage", "--primary and --oidc-secret-file go together")
    if args.primary is not None and not _valid_host(args.primary):
        raise UsageError("invalid_primary", "--primary must be a host name")
    key = read_api_key(args.api_key_file)
    oidc_secret = None
    if args.oidc_secret_file is not None:
        oidc_secret = read_api_key(
            args.oidc_secret_file, "--oidc-secret-file", "oidc_secret_file"
        )
    client = pocketid.Client(args.base, key)
    username = args.username or pocketid.default_username(args.email)
    user, action = pocketid.ensure_admin(client, args.email, username)
    link = pocketid.login_link(client, user["id"], auth_host)
    write_link(args.link_file, link)
    extra = {}
    if oidc_secret is not None:
        action = ensure_oidc_client(client, args.primary, oidc_secret)
        extra["oidc_client"] = "created" if action == "created" else "exists"
    return extra | {
        "ok": True,
        "admin": "created" if action == "created" else "exists",
        "admin_username": username,
        "link_file": os.path.abspath(args.link_file),
        "link_expires_in": pocketid.LOGIN_TTL,
    }


def main(argv, out=None):
    out = sys.stdout if out is None else out
    try:
        doc = run(_parser().parse_args(argv))
    except UsageError as exc:
        _emit(out, {"ok": False, "error": exc.code, "kind": "usage", "message": exc.message})
        return EXIT_USAGE
    except SetupError as exc:
        cause = exc.__cause__
        kind = cause.kind if isinstance(cause, web.WebError) else "http"
        _emit(out, {"ok": False, "error": exc.code, "kind": kind, "message": exc.message})
        return EXIT_POCKETID
    _emit(out, doc)
    return EXIT_OK
