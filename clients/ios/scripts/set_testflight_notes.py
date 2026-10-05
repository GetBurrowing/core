#!/usr/bin/env python3
"""Set TestFlight "What to Test" for a Suite build and add it to "Suite internal".

Adapted from cloudplay's apple-tv/scripts/set_testflight_notes.py. Differences:
the app is looked up by bundle ID instead of a hard-coded app id, the build is
polled until processing finishes (a build must be VALID before it can join a
beta group), and the build is added to the internal group "Suite internal",
which is created if missing.

Reads (never prints):
  clients/ios/WHATSNEW.md                 top "## vX.Y" section = the notes
  ~/.config/suite-ios-build/asc.env       ASC_API_KEY_ID, ASC_API_ISSUER
  ~/private_keys/AuthKey_<KEY_ID>.p8      ASC API private key (ES256)

Usage (testflight.sh calls it after the upload):
  /usr/bin/python3 set_testflight_notes.py <marketing_version> <build_number>
  /usr/bin/python3 set_testflight_notes.py --check <marketing_version>

`--check` only parses WHATSNEW.md (no network); the build uses it to fail
before spending an upload. Needs pyjwt + cryptography, which rock's
/usr/bin/python3 has and Homebrew's python3 does not.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parent.parent
WHATSNEW = IOS_ROOT / "WHATSNEW.md"
HOME = Path.home()
ENV_FILE = Path(os.environ.get("ASC_ENV_FILE", HOME / ".config" / "suite-ios-build" / "asc.env"))

BUNDLE_ID = "com.kobo-ai.burrow"
GROUP_NAME = "Burrow internal"
ASC_BASE = "https://api.appstoreconnect.apple.com"
MAX_NOTES = 4000  # betaBuildLocalizations.whatsNew limit
PROCESSING_TIMEOUT_S = 30 * 60


def load_env() -> dict:
    env = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip("\"'")
    return env


def parse_whatsnew(version: str, text: str | None = None) -> str:
    text = WHATSNEW.read_text() if text is None else text
    sections = re.findall(r"^## v([\d.]+)[^\n]*\n(.*?)(?=^## v|\Z)", text, re.M | re.S)
    if not sections:
        sys.exit("WHATSNEW.md: no '## vX.Y' sections found")
    top_ver, top_body = sections[0]
    if top_ver != version:
        sys.exit(
            f"WHATSNEW.md top section is v{top_ver}, but the build is v{version}. "
            f"Add a '## v{version}' section at the top."
        )
    notes = top_body.strip()
    if not notes:
        sys.exit(f"WHATSNEW.md: v{version} section is empty")
    if len(notes) > MAX_NOTES:
        sys.exit(f"WHATSNEW.md: v{version} notes are {len(notes)} chars; the limit is {MAX_NOTES}")
    return notes


def make_token(env: dict) -> str:
    import jwt  # pyjwt + cryptography (ES256)

    key_id = env["ASC_API_KEY_ID"]
    key = (HOME / "private_keys" / f"AuthKey_{key_id}.p8").read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": env["ASC_API_ISSUER"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


class Api:
    """ES256 JWTs last 20 min; refresh before each call so a 30 min poll works."""

    def __init__(self, env: dict):
        self.env = env
        self.token = make_token(env)
        self.minted = time.time()

    def __call__(self, method: str, path: str, body: dict | None = None) -> dict:
        if time.time() - self.minted > 900:
            self.token, self.minted = make_token(self.env), time.time()
        req = urllib.request.Request(
            f"{ASC_BASE}{path}",
            data=json.dumps(body).encode() if body else None,
            method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            # The error body is Apple's JSON:API errors list; it holds no secrets.
            sys.exit(f"ASC API {method} {path} failed: {e.code}\n{e.read().decode()}")


def find_app_id(api: Api) -> str:
    resp = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    if not resp.get("data"):
        sys.exit(f"no App Store Connect app record for {BUNDLE_ID}; create app 'Suite' first")
    return resp["data"][0]["id"]


def wait_for_build(api: Api, app_id: str, build_number: str) -> str:
    deadline = time.time() + PROCESSING_TIMEOUT_S
    state = "not yet visible"
    while time.time() < deadline:
        resp = api("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={build_number}")
        if resp.get("data"):
            build = resp["data"][0]
            state = build["attributes"].get("processingState")
            if state == "VALID":
                return build["id"]
            if state in ("FAILED", "INVALID"):
                sys.exit(f"build {build_number} processing ended {state}")
        time.sleep(30)
    sys.exit(f"build {build_number} still {state} after {PROCESSING_TIMEOUT_S // 60} min")


def apply_notes(api: Api, build_id: str, notes: str) -> None:
    resp = api("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    existing = next(
        (loc for loc in resp.get("data", []) if loc.get("attributes", {}).get("locale") == "en-US"),
        None,
    )
    if existing:
        api("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": existing["id"],
            "attributes": {"whatsNew": notes},
        }})
        print(">>> patched the en-US What to Test")
    else:
        api("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})
        print(">>> created the en-US What to Test")


def ensure_group(api: Api, app_id: str) -> str:
    resp = api("GET", f"/v1/apps/{app_id}/betaGroups?limit=200")
    for group in resp.get("data", []):
        if group["attributes"].get("name") == GROUP_NAME:
            return group["id"]
    resp = api("POST", "/v1/betaGroups", {"data": {
        "type": "betaGroups",
        "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": False},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    print(f">>> created beta group {GROUP_NAME!r}")
    return resp["data"]["id"]


def main() -> None:
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--check":
        notes = parse_whatsnew(args[1])
        print(f">>> WHATSNEW.md v{args[1]}: {len(notes)} chars")
        return
    if len(args) != 2:
        sys.exit("usage: set_testflight_notes.py <marketing_version> <build_number>")
    version, build_number = args
    notes = parse_whatsnew(version)
    api = Api(load_env())
    app_id = find_app_id(api)
    print(f">>> waiting for build {build_number} (v{version}) to finish processing")
    build_id = wait_for_build(api, app_id, build_number)
    apply_notes(api, build_id, notes)
    group_id = ensure_group(api, app_id)
    api("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
        {"data": [{"type": "builds", "id": build_id}]})
    print(f">>> build {build_number} added to {GROUP_NAME!r}")
    print(f">>> https://appstoreconnect.apple.com/apps/{app_id}/testflight/ios")


if __name__ == "__main__":
    main()
