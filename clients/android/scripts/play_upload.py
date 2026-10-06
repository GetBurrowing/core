#!/usr/bin/env python3
"""Upload a Burrow AAB to a Google Play track with the Play Developer API v3.

Task 01a10d8e stage 5. Called by scripts/release.sh --upload ON MOON, with the
service-account key in a trap-cleaned mktemp dir:

    play_upload.py --key <service-account.json> --package com.koboai.burrow \\
        --aab <file.aab> --track internal --notes WHATSNEW.md [--dry-run]

The flow is the Edits API:
    edits.insert -> edits.bundles.upload -> edits.tracks.update -> edits.commit
then a fresh edit reads the track back (edits.tracks.get) and is deleted.

--dry-run runs every step up to edits.commit, validates the edit
(edits.validate), then DELETES it: nothing is published.

A draft app (never rolled out) refuses a `completed` release. On that refusal
the release is retried with status `draft` and the script says the first
rollout has to be pressed in the Play Console.

Secrets: the private key, the signed JWT and the access token are never
printed, logged or put in argv. Error output carries the HTTP status and
Google's error message only.

Needs `cryptography` (present on moon) for RS256.
"""

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"
NOTES_LIMIT = 500  # Play's per-language release-notes cap


class PlayError(Exception):
    """An API failure: HTTP status and Google's message, never a credential."""

    def __init__(self, step, status, message):
        super().__init__(f"{step}: HTTP {status}: {message}")
        self.step = step
        self.status = status
        self.message = message


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign_rs256(private_key_pem, message):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    key = serialization.load_pem_private_key(private_key_pem.encode("utf-8"), password=None)
    return key.sign(message, padding.PKCS1v15(), hashes.SHA256())


def make_jwt(account, now, signer=sign_rs256):
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": account["client_email"],
        "scope": SCOPE,
        "aud": account["token_uri"],
        "iat": int(now),
        "exp": int(now) + 3600,
    }
    signing_input = (b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(claims).encode())).encode("ascii")
    return signing_input.decode("ascii") + "." + b64url(signer(account["private_key"], signing_input))


def urllib_http(method, url, headers, body):
    """(status, parsed JSON or {}). The default transport; tests replace it."""
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {}


def error_message(payload):
    if isinstance(payload, dict):
        err = payload.get("error")
        if isinstance(err, dict):
            return str(err.get("message", ""))[:500]
        if isinstance(err, str):
            return (err + " " + str(payload.get("error_description", ""))).strip()[:500]
    return ""


class Play:
    def __init__(self, account, package, http=urllib_http, clock=time.time, signer=sign_rs256, log=None):
        self.account = account
        self.package = package
        self.http = http
        self.clock = clock
        self.signer = signer
        self.log = log or (lambda msg: print(msg, file=sys.stderr))
        self._token = None

    def token(self):
        if self._token is None:
            assertion = make_jwt(self.account, self.clock(), self.signer)
            body = urllib.parse.urlencode({"grant_type": JWT_BEARER, "assertion": assertion}).encode()
            status, payload = self.http(
                "POST", self.account["token_uri"], {"Content-Type": "application/x-www-form-urlencoded"}, body
            )
            if status != 200 or "access_token" not in payload:
                raise PlayError("token", status, error_message(payload))
            self._token = payload["access_token"]
        return self._token

    def call(self, step, method, url, body=None, content_type="application/json"):
        headers = {"Authorization": "Bearer " + self.token()}
        data = None
        if body is not None:
            headers["Content-Type"] = content_type
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
        status, payload = self.http(method, url, headers, data)
        if status not in (200, 204):
            raise PlayError(step, status, error_message(payload))
        return payload

    def base(self):
        return f"{API}/{urllib.parse.quote(self.package)}/edits"

    def insert_edit(self):
        return self.call("edits.insert", "POST", self.base(), {})["id"]

    def upload_bundle(self, edit, aab_bytes):
        url = f"{UPLOAD_API}/{urllib.parse.quote(self.package)}/edits/{edit}/bundles?uploadType=media"
        return int(self.call("edits.bundles.upload", "POST", url, aab_bytes, "application/octet-stream")["versionCode"])

    def update_track(self, edit, track, version_code, status, notes):
        release = {"versionCodes": [str(version_code)], "status": status}
        if notes:
            release["releaseNotes"] = [{"language": "en-US", "text": notes}]
        body = {"track": track, "releases": [release]}
        return self.call("edits.tracks.update", "PUT", f"{self.base()}/{edit}/tracks/{track}", body)

    def validate(self, edit):
        return self.call("edits.validate", "POST", f"{self.base()}/{edit}:validate")

    def commit(self, edit):
        return self.call("edits.commit", "POST", f"{self.base()}/{edit}:commit")

    def delete(self, edit):
        return self.call("edits.delete", "DELETE", f"{self.base()}/{edit}")

    def get_track(self, track):
        edit = self.insert_edit()
        try:
            return self.call("edits.tracks.get", "GET", f"{self.base()}/{edit}/tracks/{track}")
        finally:
            self.delete(edit)


def is_draft_refusal(error):
    text = error.message.lower()
    return error.status == 400 and "draft" in text


def release_notes(path):
    """The top `## ` section of WHATSNEW.md, capped at Play's 500 characters."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out, inside = [], False
    for line in lines:
        if line.startswith("## "):
            if inside:
                break
            inside = True
            continue
        if inside:
            out.append(line)
    text = "\n".join(out).strip()
    return text[:NOTES_LIMIT]


def run(play, aab_bytes, track, notes, dry_run):
    """The whole flow. Returns a summary dict; raises PlayError."""
    edit = play.insert_edit()
    play.log(f"edit opened; uploading bundle ({len(aab_bytes)} bytes)")
    try:
        version_code = play.upload_bundle(edit, aab_bytes)
        play.log(f"bundle accepted: versionCode {version_code}")
        play.update_track(edit, track, version_code, "completed", notes)
        if dry_run:
            play.validate(edit)
            play.log("dry run: edit validated; deleting it (nothing published)")
            play.delete(edit)
            edit = None
            return {"versionCode": version_code, "track": track, "status": "dry-run", "committed": False}
        status = "completed"
        try:
            play.commit(edit)
        except PlayError as e:
            if not is_draft_refusal(e):
                raise
            play.log("Play refused a completed release (the app is still a draft); retrying as a draft release")
            play.update_track(edit, track, version_code, "draft", notes)
            play.commit(edit)
            status = "draft"
        edit = None
    finally:
        if edit is not None:
            try:
                play.delete(edit)
            except PlayError:
                pass
    track_state = play.get_track(track)
    releases = [
        {"status": r.get("status"), "versionCodes": r.get("versionCodes", [])} for r in track_state.get("releases", [])
    ]
    summary = {"versionCode": version_code, "track": track, "status": status, "committed": True, "releases": releases}
    if status == "draft":
        summary["action"] = "The first rollout must be pressed in the Play Console (Testing > Internal testing)."
    return summary


def make_play(account, package):
    """The Play client main() uses; tests replace this to mock the HTTP layer."""
    return Play(account, package)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--key", required=True, help="service-account JSON path (never printed)")
    parser.add_argument("--package", default="com.koboai.burrow")
    parser.add_argument("--aab", required=True)
    parser.add_argument("--track", default="internal")
    parser.add_argument("--notes", help="WHATSNEW.md path")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    with open(args.key, encoding="utf-8") as f:
        account = json.load(f)
    for field in ("client_email", "private_key", "token_uri"):
        if not account.get(field):
            print(f"play_upload: the key file lacks {field}", file=sys.stderr)
            return 3
    with open(args.aab, "rb") as f:
        aab = f.read()
    notes = release_notes(args.notes) if args.notes else ""
    play = make_play(account, args.package)
    try:
        summary = run(play, aab, args.track, notes, args.dry_run)
    except PlayError as e:
        print(f"play_upload: {e}", file=sys.stderr)
        return 1
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
