#!/usr/bin/env python3
"""Cut an automatic delayed-release batch, never a manually supplied revision.

Run daily on a GitHub runner. An active candidate stays put until promoted
or failed. Selection requires first-attempt main CI and actual packaged
boot checks for both core architectures and Play. Activation is explicit.
"""

import json
import os

import promote_stable as release


def api(path):
    rc, out, _ = release.run(["gh", "api", path])
    if rc:
        raise RuntimeError("GitHub release-evidence lookup failed")
    return json.loads(out)


def boot_checked(jobs):
    required = {
        "Build and push image (amd64)": "Boot packaged core against a fresh database",
        "Build and push image (arm64)": "Boot packaged core against a fresh database",
        "Build and push image (play)": "Boot packaged Play against a fresh database",
    }
    passed = set()
    for job in jobs:
        for step in job.get("steps", []):
            if (step.get("conclusion") == "success"
                    and step.get("name") == required.get(job.get("name"))):
                passed.add(job["name"])
    return passed == set(required)


def latest_verified(refs, current, repository):
    data = api(
        f"repos/{repository}/actions/workflows/ci.yml/runs"
        "?branch=main&event=push&status=success&per_page=30"
    )
    for run in data["workflow_runs"]:
        sha = run.get("head_sha", "")
        if (run.get("run_attempt") != 1 or not release.SHA_RE.fullmatch(sha)
                or sha == current or sha in refs.failed_any):
            continue
        jobs = api(f"repos/{repository}/actions/runs/{run['id']}/jobs?per_page=100")
        if boot_checked(jobs["jobs"]) and release.known_commit(sha):
            return sha
    return None


def main(held_bootstrap=False):
    if held_bootstrap:
        try:
            release.held_bootstrap_config()
        except ValueError as exc:
            release.log(f"error: {exc}")
            return 1
    if not release.truthy(os.environ.get("STABLE_BATCH_ENABLED")):
        release.log("batch cutting is not activated; no channels changed")
        return 0
    if release.truthy(os.environ.get("STABLE_HOLD")) and not held_bootstrap:
        release.log("stable hold is set; candidate stays put")
        return 0
    mode = os.environ.get("STABLE_SOAK_MODE") or "both"
    if mode not in ("both", "canary"):
        release.log("error: invalid soak mode")
        return 1
    refs = release.list_refs(mode)
    if refs.pending:
        release.log("error: candidate publication pending; reconcile registry and Git state before another cut")
        return 1
    now = release.now_utc()
    day = now.strftime("%Y%m%d")
    if day in refs.cuts:
        release.log("a batch was already cut today")
        return 0
    repo = os.environ.get("PROMOTE_REPO") or release.DEFAULT_REPO
    current = release.stable_revision(repo)
    if refs.candidate:
        for flavour in ("core", "play"):
            if release.stable_revision(repo, f"{flavour}-candidate") != refs.candidate:
                release.log("error: candidate registry/Git mismatch; reconciliation required")
                return 1
    if refs.candidate and refs.candidate != current and refs.candidate not in refs.failed_any:
        release.log("candidate is still soaking; not replacing it with a moving main")
        return 0
    sha = latest_verified(refs, current, os.environ["GITHUB_REPOSITORY"])
    if sha is None:
        release.log("no first-attempt, boot-checked main release is available")
        return 0
    # Require BOTH flavours. A canary must test the flavour customers run.
    for flavour in ("core", "play"):
        rc, _, _err = release.imagetools("inspect", f"{repo}:{flavour}-{sha}")
        if rc:
            release.log(f"error: {flavour} candidate image unavailable")
            return 1
    # Durable intent first: a crash/partial registry publication remains visibly
    # pending, including to the observer. CAS prevents competing candidate identities taking intent.
    rc, _, _ = release.git(
        "push", "--atomic", "--force-with-lease=refs/release-candidate/pending:",
        "origin", f"{sha}:refs/release-candidate/pending",
    )
    if rc:
        release.log("error: candidate publication intent not recorded; no registry writes")
        return 1
    for flavour in ("core", "play"):
        rc, _, _err = release.imagetools(
            "create", "-t", f"{repo}:{flavour}-candidate", f"{repo}:{flavour}-{sha}"
        )
        if rc:
            release.log(f"error: {flavour} candidate tag did not move")
            return 1
    for flavour in ("core", "play"):
        if release.stable_revision(repo, f"{flavour}-candidate") != sha:
            release.log("error: registry publication identity unverified; candidate remains pending")
            return 1
    ledger = release.state_commit(release.soak_state.initial(sha, mode))
    ledger_ref = release.state_ref(sha, mode)
    rc, _, _ = release.git(
        "push", "--atomic", f"--force-with-lease={ledger_ref}:", f"--force-with-lease=refs/release-candidate/pending:{sha}",
        f"--force-with-lease=refs/release-candidate/current:{refs.candidate or ''}", "origin",
        f"{ledger}:{ledger_ref}",
        f"{sha}:refs/release-candidate/current",
        f"{sha}:refs/release-candidate/cut/{day}",
        ":refs/release-candidate/pending",
    )
    if rc:
        release.log("error: candidate state not recorded; no stable promotion")
        return 1
    release.log(f"cut automatic candidate {sha}; stable unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(release.entrypoint(main))
