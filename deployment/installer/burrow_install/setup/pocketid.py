"""pocket-id first-run bootstrap through its supported API (no database writes).

TARGET-AGNOSTIC: these functions take a base URL, the rendered install's
STATIC_API_KEY and OIDC_CLIENT_SECRET, and the install's hostnames, so a
single-host install can call them unchanged. Nothing here is Mac-specific.

Automation surface, verified against pocket-id's source at tag v2.16.0 and
re-checked at v2.18.0, the version the renderer pins
(``ghcr.io/pocket-id/pocket-id:v2.18.0``, registry.py; ``:v2`` resolved to the
same image digest on 2026-10-05):

- ``STATIC_API_KEY`` (backend/internal/common/env_config.go:64, min 16 chars)
  creates the synthetic admin "Static API User" (id 0000...0000,
  apikey/service.go:221); requests authenticate with the ``X-API-Key`` header
  (middleware/api_key_auth.go:38). pocket-id's docs describe it as "useful
  for declarative installations" (while preferring regular API keys, which
  need a signed-in admin to create, i.e. the thing being bootstrapped).
- ``GET/POST /api/users`` (controller/user_controller.go:30,33) find or create
  the first human admin; ``GET /api/users/:id/webauthn-credentials`` (:36)
  tells whether that user has enrolled a passkey.
- ``POST /api/users/:id/one-time-access-token`` {"ttl": LOGIN_TTL}
  (onetimeaccess/module.go:68) mints a sign-in code (see LOGIN_TTL for why
  the TTL must stay above 15 minutes); ``/lc/<code>``
  (frontend routes/lc/[code]) signs the user in, and
  ``?redirect=/settings/account`` lands them where a passkey is added.
- ``/setup`` is only offered while no user other than the static one exists
  (usersignup/service.go isInitialAdminSetupCompleted), so creating the admin
  here also closes it.
- ``GET/POST/PUT /api/oidc/clients[/:id]`` (controller/oidc_controller.go:28-32)
  with a caller-chosen ``id`` (dto/oidc_dto.go:68) and ``pkceEnabled``;
  ``GET/POST /api/oidc/clients/:id/secrets`` (:37-38) where POST accepts a
  caller-supplied ``secret`` (dto OidcClientSecretCreateDto.Secret, min 16).
  So the renderer's generated OIDC_CLIENT_SECRET, which core already reads
  from secrets.env, is registered as-is: nothing new is written to
  secrets.env and core-platform needs no restart. pocket-id stores only its
  sha256 and a 4-character prefix (model/oidc.go:43).

The one-time sign-in link is a credential until it is used or expires, so it
is never printed: the CLI opens it in the browser itself and writes it to a
0600 file for the human fallback.
"""

import re
import urllib.parse

from . import web
from .state import SetupError

# KEPT on purpose (task 01a14dd8): a row in the install's pocket-id database;
# renaming it breaks sign-in on every existing install.
CLIENT_ID = "suite-core"
CLIENT_NAME = "Burrow"
# The one-time sign-in code's lifetime. It MUST stay above 15 minutes.
# pocket-id v2.18.0 backend/internal/onetimeaccess/service.go:271-274 mints a
# 6-character code when ttl <= 15m and a 12-character code otherwise. Its
# frontend (routes/login/alternative/code/+page.svelte:24-29) expects 12
# characters whenever emailOneTimeAccessAsUnauthenticatedEnabled is false,
# which is the default and what this installer leaves it at. A 6-character
# code therefore never auto-submits from /lc/<code>, and Submit stays disabled:
# the first admin cannot sign in. "15m" sits exactly on that boundary and was
# the bug that task 01a0d6ab's behavioural gate caught. Pinned by
# tests/test_setup_pocketid.py LoginTtlTest.
LOGIN_TTL = "30m"
CALLBACK_PATH = "/auth/oidc/callback"  # core router.ex:332


def callback_url(primary):
    return f"https://{primary}{CALLBACK_PATH}"


class Client:
    def __init__(self, base, api_key):
        self.base = base.rstrip("/")
        self.api_key = api_key

    def call(self, method, path, body=None, allow=()):
        try:
            resp = web.request(
                method, self.base + path, headers={"X-API-Key": self.api_key}, body=body
            )
        except web.WebError as exc:
            raise SetupError(
                "pocketid_unreachable",
                f"{method} {path}: {exc.kind}: {exc.detail}",
                "check `docker compose ps pocket-id` and that the auth hostname resolves; "
                "re-run once pocket-id answers",
            ) from exc
        if resp.status in allow:
            return resp.status, None
        if resp.status in (401, 403):
            raise SetupError(
                "pocketid_auth_failed",
                f"{method} {path}: HTTP {resp.status}",
                "pocket-id did not accept STATIC_API_KEY; re-run `setup run render` and "
                "`setup run up` so pocket-id and secrets.env agree",
            )
        if resp.status >= 400:
            try:
                detail = (resp.json() or {}).get("error", "")
            except ValueError:
                detail = ""
            raise SetupError(
                "pocketid_api_error",
                f"{method} {path}: HTTP {resp.status} {detail}".strip(),
                "see pocket-id's logs: docker compose logs pocket-id",
            )
        try:
            return resp.status, resp.json()
        except ValueError:
            return resp.status, None


def default_username(email):
    local = email.split("@", 1)[0].lower()
    name = re.sub(r"[^a-z0-9_.-]", "", local)[:50]
    return name or "admin"


def find_user(client, username):
    query = urllib.parse.quote(username)
    _status, page = client.call("GET", f"/api/users?search={query}&pagination[limit]=100")
    for user in (page or {}).get("data") or []:
        if user.get("username") == username:
            return user
    return None


def ensure_admin(client, email, username):
    """Find or create the admin. Returns ``(user, "present"|"created")``."""
    user = find_user(client, username)
    if user:
        if not user.get("isAdmin"):
            raise SetupError(
                "pocketid_user_not_admin",
                f"pocket-id user {username} exists and is not an admin",
                "pick another ADMIN_USERNAME, or make that user an admin in pocket-id",
            )
        return user, "present"
    _status, user = client.call(
        "POST",
        "/api/users",
        body={
            "username": username,
            "email": email,
            "emailVerified": True,
            "firstName": username,
            "displayName": username,
            "isAdmin": True,
        },
    )
    return user, "created"


def passkey_count(client, user_id):
    _status, creds = client.call("GET", f"/api/users/{user_id}/webauthn-credentials")
    return len(creds or [])


def login_link(client, user_id, auth_host):
    _status, doc = client.call(
        "POST", f"/api/users/{user_id}/one-time-access-token", body={"ttl": LOGIN_TTL}
    )
    token = (doc or {}).get("token")
    if not token:
        raise SetupError(
            "pocketid_api_error",
            "one-time-access-token returned no token",
            "see pocket-id's logs: docker compose logs pocket-id",
        )
    return f"https://{auth_host}/lc/{token}?redirect=%2Fsettings%2Faccount"


def ensure_client(client, primary):
    """Find or create ``suite-core`` with the callback and PKCE. Returns (client, action)."""
    desired = {
        "name": CLIENT_NAME,
        "callbackURLs": [callback_url(primary)],
        "logoutCallbackURLs": [],
        "isPublic": False,
        "pkceEnabled": True,
    }
    status, current = client.call("GET", f"/api/oidc/clients/{CLIENT_ID}", allow=(404,))
    if status == 404:
        _s, created = client.call("POST", "/api/oidc/clients", body={"id": CLIENT_ID, **desired})
        return created, "created"
    if (
        current.get("callbackURLs") == desired["callbackURLs"]
        and bool(current.get("pkceEnabled"))
        and not current.get("isPublic")
    ):
        return current, "present"
    body = dict(desired)
    # PUT replaces the client; keep what an admin may have set in the UI.
    for key in ("description", "launchURL", "skipConsent", "isGroupRestricted"):
        if key in current and current[key] is not None:
            body[key] = current[key]
    _s, updated = client.call("PUT", f"/api/oidc/clients/{CLIENT_ID}", body=body)
    return updated, "updated"


def drop_created_secret(client, created):
    """Delete the secret pocket-id generated when it created the client.

    pocket-id v2.17.0+ (commit d259a15, "restore old behavior of automatically
    creating client secret"; AUTO_CREATE_OIDC_CLIENT_SECRET defaults to true)
    generates an active secret on POST /api/oidc/clients and reveals it once as
    ``createdSecret`` in that response. The installer registers its own
    OIDC_CLIENT_SECRET instead, so the generated one would be a second live
    credential nobody holds. It is deleted by the id from the create response,
    so a secret an admin added later is never touched. Measured on a real
    v2.18.0 container (task 01a0d6ab stage 6): without this, suite-core had two
    active secrets. v2.16.0 returns no ``createdSecret``: nothing is deleted.
    Returns the deleted secret id, or None.
    """
    secret_id = ((created or {}).get("createdSecret") or {}).get("id")
    if not secret_id:
        return None
    client.call("DELETE", f"/api/oidc/clients/{CLIENT_ID}/secrets/{secret_id}", allow=(404,))
    return secret_id


def ensure_secret(client, secret, known_id=None):
    """Register ``secret`` on the client unless it is already there.

    pocket-id keeps only a sha256 and a 4-character prefix, so "already there"
    is: the secret id this CLI registered is still listed, with our prefix.
    Returns ``(secret_id, "present"|"registered")``.
    """
    _s, listed = client.call("GET", f"/api/oidc/clients/{CLIENT_ID}/secrets")
    for item in listed or []:
        if (
            item.get("id") == known_id
            and item.get("prefix") == secret[:4]
            and item.get("isActive", True)
        ):
            return known_id, "present"
    _s, created = client.call(
        "POST", f"/api/oidc/clients/{CLIENT_ID}/secrets", body={"secret": secret}
    )
    return created["id"], "registered"
