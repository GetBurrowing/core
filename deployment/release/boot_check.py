#!/usr/bin/env python3
"""Boot a packaged release on an isolated disposable database before tagging it.

Unlike the NIF eval smoke, this runs the image's real migrate-and-start CMD,
with feedback enabled so extension validation exercises the boot-order guard.
No customer credentials, host ports or persistent databases are used.
"""

import argparse
import base64
import json
import secrets
import subprocess
import time
import uuid

POSTGRES = "ghcr.io/getburrowing/postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab"


def docker(*args, check=True):
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, check=check, timeout=120
    )


def healthy(text, revision):
    try:
        body = json.loads(text)
        return body.get("status") == "ok" and body.get("commit") == revision
    except (ValueError, AttributeError):
        return False


def wait_for(check, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(2)
    raise RuntimeError(f"{label} did not become ready within {seconds}s")


def boot(image, revision):
    suffix = uuid.uuid4().hex[:12]
    network, db, app = (f"release-boot-{suffix}-{kind}" for kind in ("net", "db", "app"))
    password = secrets.token_hex(24)
    env = {
        "DATABASE_URL": f"ecto://postgres:{password}@{db}:5432/release_boot",
        "SECRET_KEY_BASE": secrets.token_hex(64),
        "VAULT_MASTER_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
        "ATTACHMENT_SIGNING_KEY": secrets.token_hex(48),
        "MEETING_GUEST_SIGNING_KEY": secrets.token_hex(48),
        "MEETING_CALENDAR_SIGNING_KEY": secrets.token_hex(48),
        "OIDC_ISSUER": "https://auth.example.invalid",
        "OIDC_CLIENT_ID": "release-boot",
        "OIDC_CLIENT_SECRET": secrets.token_hex(24),
        "APP_URL": "https://release.example.invalid",
        "PHX_HOST": "release.example.invalid",
        "PHX_SERVER": "true",
        "PORT": "4000",
        "FEEDBACK_POLICY": "trusted",
    }
    try:
        docker("network", "create", "--internal", network)
        docker(
            "run", "-d", "--name", db, "--network", network,
            "-e", f"POSTGRES_PASSWORD={password}", "-e", "POSTGRES_DB=release_boot", POSTGRES,
        )
        wait_for(
            lambda: docker("exec", db, "pg_isready", "-U", "postgres", check=False).returncode == 0,
            60, "database",
        )
        args = ["run", "-d", "--name", app, "--network", network]
        for key, value in env.items():
            args.extend(["-e", f"{key}={value}"])
        # No command override: test the shipped migration and application boot.
        docker(*args, image)

        def ready():
            running = docker("inspect", "--format", "{{.State.Running}}", app).stdout.strip()
            if running != "true":
                raise RuntimeError("release exited before reaching /health")
            reply = docker(
                "exec", app, "curl", "-fsS", "--max-time", "3",
                "http://127.0.0.1:4000/health", check=False,
            )
            return reply.returncode == 0 and healthy(reply.stdout, revision)

        wait_for(ready, 180, "release HTTP health with expected revision")
        print(f"RELEASE_BOOT_PASS: {revision}; fresh database; feedback enabled")
    except Exception:
        # The generated values are not useful credentials, but redact them anyway.
        logs = docker("logs", "--tail", "100", app, check=False)
        text = logs.stdout + logs.stderr
        for value in [password, *env.values()]:
            text = text.replace(value, "<redacted>")
        print(text)
        raise
    finally:
        docker("rm", "-fv", app, db, check=False)
        docker("network", "rm", network, check=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("revision")
    args = parser.parse_args()
    boot(args.image, args.revision)
