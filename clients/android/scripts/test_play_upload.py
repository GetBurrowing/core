#!/usr/bin/env python3
"""Unit tests for play_upload.py with the HTTP layer mocked.

    python3 -m unittest scripts/test_play_upload.py   (from clients/android)
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import play_upload  # noqa: E402

SECRET_KEY = "-----BEGIN PRIVATE KEY-----\nFAKEKEYMATERIAL\n-----END PRIVATE KEY-----\n"
ACCOUNT = {
    "client_email": "burrow-play-upload@example.iam.gserviceaccount.com",
    "private_key": SECRET_KEY,
    "token_uri": "https://oauth2.example/token",
}
ACCESS = "ya29.ACCESS-TOKEN-NEVER-PRINTED"


def fake_signer(_pem, message):
    return b"signature-over-" + message[:8]


class FakeHttp:
    """Answers the Play API; `commit_errors` are returned by commit in order."""

    def __init__(self, commit_errors=(), version_code=7):
        self.calls = []
        self.commit_errors = list(commit_errors)
        self.version_code = version_code
        self.edits = 0
        self.deleted = []
        self.track_bodies = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url))
        if url == ACCOUNT["token_uri"]:
            return 200, {"access_token": ACCESS, "expires_in": 3600}
        assert headers.get("Authorization") == "Bearer " + ACCESS
        if method == "POST" and url.endswith("/edits"):
            self.edits += 1
            return 200, {"id": f"edit{self.edits}"}
        if "/bundles?uploadType=media" in url:
            return 200, {"versionCode": self.version_code}
        if method == "PUT" and "/tracks/" in url:
            self.track_bodies.append(json.loads(body))
            return 200, json.loads(body)
        if url.endswith(":validate"):
            return 200, {}
        if url.endswith(":commit"):
            if self.commit_errors:
                status, message = self.commit_errors.pop(0)
                return status, {"error": {"code": status, "message": message}}
            return 200, {}
        if method == "DELETE":
            self.deleted.append(url.rsplit("/", 1)[1])
            return 204, {}
        if method == "GET" and "/tracks/" in url:
            status = self.track_bodies[-1]["releases"][0]["status"] if self.track_bodies else "completed"
            return 200, {"track": "internal", "releases": [{"status": status, "versionCodes": [str(self.version_code)]}]}
        raise AssertionError(f"unexpected call {method} {url}")


def steps(http):
    out = []
    for method, url in http.calls:
        if url == ACCOUNT["token_uri"]:
            out.append("token")
        elif url.endswith("/edits") and method == "POST":
            out.append("insert")
        elif "/bundles" in url:
            out.append("upload")
        elif method == "PUT":
            out.append("track")
        elif url.endswith(":validate"):
            out.append("validate")
        elif url.endswith(":commit"):
            out.append("commit")
        elif method == "DELETE":
            out.append("delete")
        elif method == "GET":
            out.append("get")
    return out


class PlayUploadTest(unittest.TestCase):
    def play(self, http, logs):
        return play_upload.Play(ACCOUNT, "com.koboai.burrow", http=http, clock=lambda: 1_800_000_000, signer=fake_signer, log=logs.append)

    def test_edit_flow_order_and_track_body(self):
        http, logs = FakeHttp(), []
        summary = play_upload.run(self.play(http, logs), b"AAB", "internal", "Notes", dry_run=False)
        self.assertEqual(steps(http), ["token", "insert", "upload", "track", "commit", "insert", "get", "delete"])
        self.assertEqual(summary["status"], "completed")
        self.assertEqual(summary["versionCode"], 7)
        self.assertEqual(
            http.track_bodies[0],
            {"track": "internal", "releases": [{"versionCodes": ["7"], "status": "completed", "releaseNotes": [{"language": "en-US", "text": "Notes"}]}]},
        )
        self.assertTrue(all("com.koboai.burrow" in url for _m, url in http.calls[1:]))

    def test_draft_app_falls_back_to_a_draft_release(self):
        http, logs = FakeHttp(commit_errors=[(400, "Only releases with status draft may be created on draft app.")]), []
        summary = play_upload.run(self.play(http, logs), b"AAB", "internal", "", dry_run=False)
        self.assertEqual(summary["status"], "draft")
        self.assertIn("Play Console", summary["action"])
        self.assertEqual([b["releases"][0]["status"] for b in http.track_bodies], ["completed", "draft"])
        self.assertEqual(steps(http).count("commit"), 2)

    def test_dry_run_validates_and_deletes_the_edit_never_commits(self):
        http, logs = FakeHttp(), []
        summary = play_upload.run(self.play(http, logs), b"AAB", "internal", "", dry_run=True)
        self.assertEqual(steps(http), ["token", "insert", "upload", "track", "validate", "delete"])
        self.assertNotIn("commit", steps(http))
        self.assertEqual(http.deleted, ["edit1"])
        self.assertFalse(summary["committed"])

    def test_another_commit_error_fails_and_the_edit_is_deleted(self):
        http, logs = FakeHttp(commit_errors=[(403, "The caller does not have permission")]), []
        with self.assertRaises(play_upload.PlayError) as ctx:
            play_upload.run(self.play(http, logs), b"AAB", "internal", "", dry_run=False)
        self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(http.deleted, ["edit1"])

    def test_the_jwt_claims_and_that_no_secret_is_printed(self):
        jwt = play_upload.make_jwt(ACCOUNT, 1_800_000_000, fake_signer)
        claims = json.loads(play_upload.base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
        self.assertEqual(claims["iss"], ACCOUNT["client_email"])
        self.assertEqual(claims["aud"], ACCOUNT["token_uri"])
        self.assertEqual(claims["scope"], play_upload.SCOPE)
        self.assertEqual(claims["exp"] - claims["iat"], 3600)

        # The whole CLI, stdout and stderr captured, on success and failure.
        with tempfile.TemporaryDirectory() as d:
            key = os.path.join(d, "key.json")
            aab = os.path.join(d, "a.aab")
            with open(key, "w") as f:
                json.dump(ACCOUNT, f)
            with open(aab, "wb") as f:
                f.write(b"AAB")
            for http in (FakeHttp(), FakeHttp(commit_errors=[(403, "denied")])):
                out, err = io.StringIO(), io.StringIO()
                original = play_upload.make_play
                try:
                    play_upload.make_play = lambda account, package, h=http: play_upload.Play(
                        account, package, http=h, signer=fake_signer
                    )
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        play_upload.main(["--key", key, "--aab", aab])
                finally:
                    play_upload.make_play = original
                printed = out.getvalue() + err.getvalue()
                self.assertTrue(printed)
                for secret in (ACCESS, "FAKEKEYMATERIAL", "BEGIN PRIVATE KEY", "signature-over"):
                    self.assertNotIn(secret, printed)

    def test_release_notes_take_the_top_section_capped(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "WHATSNEW.md")
            with open(path, "w") as f:
                f.write("# Title\n\nintro\n\n## v1.0\nFirst build.\n" + "x" * 600 + "\n\n## v0.9\nOld\n")
            notes = play_upload.release_notes(path)
        self.assertTrue(notes.startswith("First build."))
        self.assertNotIn("Old", notes)
        self.assertEqual(len(notes), play_upload.NOTES_LIMIT)


if __name__ == "__main__":
    unittest.main()
