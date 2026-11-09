"""``bootstrap-admin``: non-interactive pocket-id admin bootstrap (core task 01a10315).

    python3 -m burrow_install bootstrap-admin --base https://<auth host> \\
        --api-key-file <0600 file> --email <addr> [--username <u>] --link-file <path> \\
        [--primary <host> [--oidc-secret-file <0600 file>]
         [--durable-link-file <path> [--core-base <url>]]] \\
        [--app-name <name>] [--accent-color <color>] [--logo-file <path>]

For an install provisioned by someone else (a droplet), where the Mac-oriented
``setup`` CLI does not apply. It reuses ``setup/pocketid.py`` (target-agnostic):

1. ``pocketid.ensure_admin``: find or create the first human admin.
2. Mint a one-time sign-in code with ``LOGIN_TTL`` (30m; it must stay above
   15m, see pocketid.py). With ``--primary`` the link is core's hand-over
   route, ``https://<primary>/auth/handover?code=<code>`` (core task 01a10315
   stage 6): core starts its OIDC login there, opens the matching pocket-id
   sign-in interaction and hands the code to pocket-id's ``/lc/<code>`` with
   ``redirect=`` that interaction, so after one "Sign in" click the owner
   lands back in Burrow at ``/setup/connect-ai``. Without it (a
   pocket-id-only bootstrap) the link is pocket-id's own
   ``https://<auth host>/lc/<code>?redirect=/settings/account``.
3. Write that link to ``--link-file`` with mode 0600.
4. With ``--oidc-secret-file`` (which needs ``--primary``): register core's
   OIDC client the way the Mac setup CLI does (``ensure_client`` with the
   primary's callback and PKCE, ``drop_created_secret``), plus
   ``skipConsent`` (the install's own first-party app: no consent step
   after that click, nor on any later sign-in) and
   ``launchURL`` (pocket-id's "My apps" tile opens Burrow), then the
   render's OIDC_CLIENT_SECRET as its secret unless an active secret with the
   same 4-character prefix is already listed. A single-host render has no
   other step that registers the client, so without this core's sign-in
   cannot complete on a droplet.

5. With ``--durable-link-file`` (needs ``--primary``): ask core for the owner's
   durable sign-in link, ``POST <core>/api/install/handover-link`` with
   ``Authorization: Bearer <the API key>`` and ``{"email", "sub"}`` (``sub`` is
   the pocket-id user id, so core can create the owner's Burrow user before
   the first login; see ``InstallHandoverLinkController``), and write the
   returned ``/auth/link?token=...`` URL there with mode 0600. Unlike the
   30-minute one-time link it works for 14 days and more than once, which is
   what the "ready" email needs. It goes in its OWN file so ``--link-file``
   keeps its one-line format for existing readers. ``<core>`` is
   ``https://<primary>`` unless ``--core-base`` says otherwise (https, or http
   on loopback for tests). Core may not be answering yet at bootstrap, so a
   failure here is NOT fatal: the one-time link is already written, and the
   JSON says ``"durable_link": "written"`` or ``"unavailable"`` with a
   ``durable_link_error`` code, so the caller can retry later.
6. Appearance (all optional, API only): ``--app-name`` (1-30 characters) and
   ``--accent-color`` set pocket-id's name and accent colour with
   ``pocketid.ensure_branding``; ``--logo-file`` (svg, png, jpg or webp, up to
   1 MB) uploads the logo with ``pocketid.ensure_logo``. This runs AFTER the
   link is written, and a failure does not fail the hand-over: the document
   says ``"branding": "failed"`` with ``branding_error`` instead, so a cosmetic
   problem never strands the customer. With none of the three flags the
   document has ``"branding": "skipped"`` and nothing is sent.

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
    parser.add_argument(
        "--durable-link-file", default=None, help="owner's durable link, written with mode 0600"
    )
    parser.add_argument(
        "--core-base", default=None, help="core's base URL (default https://<primary>)"
    )
    parser.add_argument("--app-name", default=None, help="pocket-id's app name, 1-30 characters")
    parser.add_argument("--accent-color", default=None, help="pocket-id's accent colour")
    parser.add_argument("--logo-file", default=None, help="svg, png, jpg or webp, up to 1 MB")
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


def handover_link(primary, code):
    """Core's hand-over sign-in route on ``primary`` for one-time ``code``."""
    return f"https://{primary}/auth/handover?" + urllib.parse.urlencode({"code": code})


def core_base_of(primary, override):
    """Core's origin: ``--core-base``, else ``https://<primary>``. http only on loopback."""
    if override is None:
        return f"https://{primary}"
    parsed = urllib.parse.urlparse(override)
    if not parsed.hostname or parsed.scheme not in ("https", "http"):
        raise UsageError("invalid_core_base", "--core-base must be https://<host>")
    if parsed.scheme == "http" and parsed.hostname not in _LOOPBACK:
        raise UsageError(
            "invalid_core_base", "--core-base must be https:// (http is loopback-only)"
        )
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise UsageError("invalid_core_base", "--core-base is the origin only, with no path")
    return f"{parsed.scheme}://{parsed.netloc}"


def fetch_durable_link(core_base, api_key, email, sub):
    """The owner's durable sign-in URL from core. Raises ``web.WebError`` or ``ValueError``."""
    resp = web.request(
        "POST",
        core_base + "/api/install/handover-link",
        headers={"Authorization": f"Bearer {api_key}"},
        body={"email": email, "sub": sub},
    )
    if resp.status != 200:
        raise ValueError(f"http_{resp.status}")
    try:
        url = (resp.json() or {}).get("url")
    except ValueError:
        url = None
    if not isinstance(url, str) or not url.startswith(("https://", "http://")):
        raise ValueError("bad_response")
    return url


def ensure_oidc_client(client, primary, secret):
    """Register core's OIDC client and ``secret`` on it. Returns the client action."""
    record, action = pocketid.ensure_client(
        client, primary, extra={"skipConsent": True, "launchURL": f"https://{primary}"}
    )
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


def read_logo(path):
    """``(file name, bytes)`` of a logo file, or raises UsageError."""
    name = os.path.basename(path)
    if not name.lower().endswith(pocketid.LOGO_EXTENSIONS):
        raise UsageError(
            "invalid_logo_file",
            "--logo-file must be " + ", ".join(pocketid.LOGO_EXTENSIONS),
        )
    try:
        info = os.stat(path)
    except OSError as exc:
        raise UsageError("invalid_logo_file", f"--logo-file: {exc.strerror}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise UsageError("invalid_logo_file", "--logo-file is not a regular file")
    if not 0 < info.st_size <= pocketid.LOGO_MAX_BYTES:
        raise UsageError(
            "invalid_logo_file", f"--logo-file must be 1 to {pocketid.LOGO_MAX_BYTES} bytes"
        )
    with open(path, "rb") as handle:
        return name, handle.read()


def apply_branding(client, args, logo):
    """Appearance after the hand-over link exists. Returns the document fields.

    A failure is reported, not raised: branding is cosmetic and must not strand
    the customer whose link is already written.
    """
    if args.app_name is None and args.accent_color is None and logo is None:
        return {"branding": "skipped"}
    try:
        names = pocketid.ensure_branding(client, args.app_name, args.accent_color)
        if logo is not None:
            pocketid.ensure_logo(client, *logo)
            names = "applied"
    except SetupError as exc:
        return {"branding": "failed", "branding_error": exc.code}
    return {"branding": names}


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
    if args.oidc_secret_file is not None and args.primary is None:
        raise UsageError("usage", "--oidc-secret-file needs --primary")
    if args.primary is not None and not _valid_host(args.primary):
        raise UsageError("invalid_primary", "--primary must be a host name")
    if args.durable_link_file is not None:
        if args.primary is None:
            raise UsageError("usage", "--durable-link-file needs --primary")
        if not os.path.isdir(os.path.dirname(os.path.abspath(args.durable_link_file))):
            raise UsageError(
                "invalid_durable_link_file", "--durable-link-file's directory does not exist"
            )
    if args.core_base is not None and args.durable_link_file is None:
        raise UsageError("usage", "--core-base needs --durable-link-file")
    core_base = core_base_of(args.primary, args.core_base) if args.durable_link_file else None
    if args.app_name is not None and not pocketid.valid_app_name(args.app_name):
        raise UsageError(
            "invalid_app_name",
            f"--app-name must be 1-{pocketid.APP_NAME_MAX} printable characters with no "
            "leading or trailing space",
        )
    if args.accent_color is not None and not pocketid.valid_accent_color(args.accent_color):
        raise UsageError(
            "invalid_accent_color", "--accent-color must be default, a hex colour or a colour name"
        )
    logo = read_logo(args.logo_file) if args.logo_file is not None else None
    key = read_api_key(args.api_key_file)
    oidc_secret = None
    if args.oidc_secret_file is not None:
        oidc_secret = read_api_key(args.oidc_secret_file, "--oidc-secret-file", "oidc_secret_file")
    client = pocketid.Client(args.base, key)
    username = args.username or pocketid.default_username(args.email)
    user, action = pocketid.ensure_admin(client, args.email, username)
    if args.primary is not None:
        link = handover_link(args.primary, pocketid.mint_code(client, user["id"]))
    else:
        link = pocketid.login_link(client, user["id"], auth_host)
    write_link(args.link_file, link)
    extra = {}
    if core_base is not None:
        try:
            durable = fetch_durable_link(core_base, key, args.email, user["id"])
        except web.WebError as exc:
            extra["durable_link"] = "unavailable"
            extra["durable_link_error"] = exc.kind
        except ValueError as exc:
            extra["durable_link"] = "unavailable"
            extra["durable_link_error"] = str(exc)
        else:
            write_link(args.durable_link_file, durable)
            extra["durable_link"] = "written"
            extra["durable_link_file"] = os.path.abspath(args.durable_link_file)
    if oidc_secret is not None:
        oidc_action = ensure_oidc_client(client, args.primary, oidc_secret)
        extra["oidc_client"] = "created" if oidc_action == "created" else "exists"
    extra |= apply_branding(client, args, logo)
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
