#!/usr/bin/env python3
"""Held canary acceptance/outbox; no stable mutation or task-completion authority."""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import promote_stable as release
import soak_state

TASK = "01a1c3fe-2cb1-7000-b780-30e8324bf73e"
SPACE = "01a1b1fc-8d83-7000-8028-a2f0d630638a"
PREFIX = f"refs/canary-acceptance/{TASK}/"


def https(url):
    parsed = urlsplit(url)
    return (parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment)


def activation(data):
    """Explicit non-secret schema; unknown fields cannot smuggle credentials."""
    if set(data) != {"install_id", "health_url", "config", "stable_before", "workflow_run"}:
        raise ValueError("activation schema mismatch")
    if (not re.fullmatch(r"[0-9a-f-]{36}", data["install_id"])
            or not https(data["health_url"]) or urlsplit(data["health_url"]).path != "/health"
            or not re.fullmatch(r"https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+", data["workflow_run"])
            or set(data["config"]) != {"purpose", "channel", "feedback", "modules", "extensions", "kobo_parity_verified"}
            or data["config"]["purpose"] != "vendor_canary" or data["config"]["channel"] != "candidate"
            or data["config"]["feedback"] is not True or data["config"]["kobo_parity_verified"] is not True
            or data["config"]["modules"] not in ("core", "play")
            or not isinstance(data["config"]["extensions"], list)
            or not data["config"]["extensions"]
            or any(not re.fullmatch(r"[a-z0-9_-]+", x) for x in data["config"]["extensions"])
            or set(data["stable_before"]) != {"core-stable", "play-stable"}
            or any(not release.SHA_RE.fullmatch(x or "") for x in data["stable_before"].values())):
        raise ValueError("unverified dedicated canary configuration")
    return data


class GitStore:
    """JSON commit messages, exact namespace and compare-and-swap only."""
    def command(self, *args, input=None):
        env = dict(os.environ)
        for key in ("AUTHOR", "COMMITTER"):
            env.setdefault(f"GIT_{key}_NAME", "Canary acceptance")
            env.setdefault(f"GIT_{key}_EMAIL", "canary@localhost")
        result = subprocess.run(["git", *args], input=input, env=env, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError("acceptance state operation failed (details withheld)")
        return result.stdout.strip()

    def read(self, ref):
        if not (ref.startswith(PREFIX) or re.fullmatch(r"refs/soak-state/canary/[0-9a-f]{40}", ref)):
            raise ValueError("ref outside readable acceptance state")
        remote = self.command("ls-remote", "--refs", "origin", ref)
        if not remote:
            return None, None
        oid = remote.split()[0]
        self.command("fetch", "--no-tags", "origin", ref)
        return oid, json.loads(self.command("show", "-s", "--format=%B", oid))

    def write(self, ref, previous, data):
        if not re.fullmatch(re.escape(PREFIX) + r"(activation|[0-9a-f]{40})", ref):
            raise ValueError("acceptance writer refuses non-acceptance ref")
        tree = self.command("hash-object", "-t", "tree", "-w", "--stdin", input="")
        oid = self.command("commit-tree", tree, "-p", previous or "HEAD", "-m", json.dumps(data, sort_keys=True))
        self.command("push", "--atomic", f"--force-with-lease={ref}:{previous or ''}", "origin", f"{oid}:{ref}")
        return oid


def decide(config, candidate, state, stable_after, now, hours):
    activation(config)
    soak_state.validate(state)
    if state["candidate"] != candidate or state["mode"] != "canary":
        raise ValueError("candidate or policy mismatch")
    elapsed = 0 if not state["first"] else (dt.datetime.fromisoformat(state["last"]) - dt.datetime.fromisoformat(state["first"])).total_seconds()
    fresh = state["last"] and 0 <= (now - dt.datetime.fromisoformat(state["last"])).total_seconds() <= soak_state.GAP_SECONDS
    unchanged = stable_after == config["stable_before"]
    status = "rejected" if state["failures"] or not unchanged else "pending"
    if status == "pending" and fresh and soak_state.complete(state, hours):
        status = "accepted"
    return {"task_id": TASK, "space_id": SPACE, "candidate": candidate, "status": status,
            "activation": config, "first": state["first"], "last": state["last"],
            "elapsed_seconds": elapsed, "observations": state["hours"], "failures": state["failures"],
            "stable_after": stable_after, "hold_before": True, "hold_after": True,
            "candidate_images": {f"{f}-candidate": candidate for f in ("core", "play")}}


def event(kind, payload):
    identifier = hashlib.sha256(json.dumps([kind, payload], sort_keys=True).encode()).hexdigest()
    return {"id": identifier, "kind": kind, "payload": json.loads(json.dumps(payload)), "delivered": False}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("continuation redirects forbidden")


def deliver(item):
    """Optional authorized task bridge; no endpoint means durable pending delivery."""
    endpoint = os.environ.get("STABLE_CANARY_CONTINUATION_URL", "")
    token = os.environ.get("STABLE_CANARY_CONTINUATION_TOKEN", "")
    if not endpoint or not token:
        return False
    if not https(endpoint):
        raise ValueError("continuation bridge must be HTTPS without credentials/query")
    request = Request(endpoint, data=json.dumps(item).encode(), method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {token}", "Idempotency-Key": item["id"]})
    # Require explicit persisted receipt; HTTP 200 alone is not lifecycle evidence.
    with build_opener(NoRedirect()).open(request, timeout=20) as response:
        receipt = json.loads(response.read(4096))
    return receipt == {"event_id": item["id"], "persisted": True}


def continue_task(store, config, candidate, state, stable, now, hours, sender=deliver):
    ref = PREFIX + candidate
    previous, record = store.read(ref)
    evidence = decide(config, candidate, state, stable, now, hours)
    if record is None:
        record = {"version": 1, "evidence": evidence, "events": []}
    if record["evidence"]["candidate"] != candidate or record["evidence"]["activation"] != config:
        raise ValueError("acceptance identity/config changed")
    old = record["evidence"]
    if (old["first"] and old["first"] != evidence["first"]
            or old["last"] and (not evidence["last"] or evidence["last"] < old["last"])
            or not set(old["observations"]).issubset(evidence["observations"])):
        raise ValueError("candidate history regressed; reconcile without recreating evidence")
    if record["evidence"]["status"] == "rejected":
        evidence = record["evidence"]
    record["evidence"] = evidence
    run_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com") + "/" + os.environ.get("GITHUB_REPOSITORY", "GetBurrowing/core") + "/actions/runs/" + os.environ.get("GITHUB_RUN_ID", "")
    runs = record.setdefault("workflow_runs", [config["workflow_run"]])
    if os.environ.get("GITHUB_RUN_ID") and https(run_url) and run_url not in runs:
        runs.append(run_url)
    evidence["workflow_runs"] = list(runs)
    kinds = {item["kind"] for item in record["events"]}
    if "configured" not in kinds:
        record["events"].append(event("configured", {"task_id": TASK, "space_id": SPACE, "install_id": config["install_id"], "health_url": config["health_url"]}))
    if evidence["status"] in ("accepted", "rejected"):
        item = event(evidence["status"], evidence)
        if evidence["status"] not in kinds:
            record["events"].append(item)
    # Persist before external messages; crash retries carry identical idempotency key.
    previous = store.write(ref, previous, record)
    for item in record["events"]:
        if item["kind"] == "accepted" and evidence["status"] != "accepted":
            continue  # Retain superseded evidence but never send stale acceptance.
        if not item["delivered"]:
            item["delivered"] = sender(item)
            previous = store.write(ref, previous, record)
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--activate", action="store_true", help="read non-secret verified deployment config from stdin")
    args = parser.parse_args()
    # No accelerated clocks or injected tool commands in the real acceptance executable.
    if any(k in os.environ for k in ("PROMOTE_NOW", "PROMOTE_GIT", "PROMOTE_CURL", "PROMOTE_IMAGETOOLS")):
        raise ValueError("fixture overrides forbidden in live acceptance")
    if not release.truthy(os.environ.get("STABLE_HELD_BOOTSTRAP")):
        raise ValueError("explicit held bootstrap activation required")
    release.held_bootstrap_config()
    store = GitStore()
    ref = PREFIX + "activation"
    previous, config = store.read(ref)
    stable = {f"{f}-stable": release.stable_revision(release.DEFAULT_REPO, f"{f}-stable") for f in ("core", "play")}
    if args.activate:
        supplied = activation(json.load(sys.stdin))
        if config is not None and config != supplied:
            raise ValueError("activation immutable; operator reconciliation required")
        if supplied["stable_before"] != stable:
            raise ValueError("stable baseline differs from observed registry")
        store.write(ref, previous, supplied)
        config = supplied
    if config is None:
        print("acceptance pending: approved deployment/configuration not registered")
        return 0
    activation(config)
    if config["health_url"] != os.environ.get("STABLE_CANARY_HEALTH_URL"):
        raise ValueError("configured health URL differs from activation")
    refs = release.list_refs("canary")
    if not refs.candidate or refs.pending:
        print("acceptance pending: candidate absent or publication unreconciled")
        return 0
    if any(release.stable_revision(release.DEFAULT_REPO, f"{flavour}-candidate") != refs.candidate
           for flavour in ("core", "play")):
        raise ValueError("running candidate image channel identity changed")
    _, state = store.read(release.state_ref(refs.candidate, "canary"))
    if state is None:
        raise ValueError("candidate ledger missing")
    if refs.candidate in refs.failed_any and not state["failures"]:
        raise ValueError("failure refs inconsistent with ledger")
    record = continue_task(store, config, refs.candidate, state, stable, dt.datetime.now(dt.UTC), int(os.environ.get("STABLE_SOAK_HOURS") or 24))
    print(f"acceptance {record['evidence']['status']}; pending deliveries={sum(not x['delivered'] for x in record['events'])}; stable remains held")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never echo remote response bodies, URLs, credentials or raw exception text.
        print("acceptance failed closed; inspect durable state through authorized operator access", file=sys.stderr)
        sys.exit(1)
