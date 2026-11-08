#!/usr/bin/env python3
"""Soak-gated promotion of core's `stable` channel (task 01a1b7b6 stage 2).

Run hourly by .github/workflows/promote-stable.yml on a GitHub runner, never
on a vendor host. Each run:

  1. STABLE_HOLD=true -> exit 0, nothing probed or moved.
  2. STABLE_PROD_HEALTH_URL or STABLE_CANARY_HEALTH_URL unset -> exit 1
     ("not configured"). An unconfigured job is red; it never promotes.
  3. Probes both /health URLs and records what it saw as custom refs on
     origin (refs, not tags, so nothing installs or lists them as releases):
       refs/soak/<S>/<hour>       both installs answered status ok and both
                                  reported commit S in that UTC hour;
       refs/soak-fail/<S>/<hour>  an install failed its probe (or answered
                                  non-ok) while last reporting S, or the
                                  canary's update.last_rollback.from is S;
       refs/soak-seen/<install>   the commit that install last reported,
                                  so a probe that gets no answer at all can
                                  still name the commit it failed on.
     Each ref points at the commit S itself.
  4. Prunes soak and soak-fail refs older than 14 days.
  5. Promotes S iff ALL of:
       * count(refs/soak/<S>/*) >= STABLE_SOAK_HOURS (default 24): real
         observed runtime on both installs, one per hour, not tag age;
       * no refs/soak-fail/<S>/*;
       * S is not the current stable revision (core-stable's label);
       * S was last observed after the previous promotion (so an older,
         once-eligible commit never flips stable back);
       * S is the newest such commit (latest observation).
     Promotion: `imagetools create` core-stable from core-<S>, and
     play-stable from play-<S> when that tag exists, then an annotated tag
     stable/<utc>-<short> on S whose message lists the irreversible
     migrations added since the previous stable.

  Dispatch with force=true and sha=<S> skips the soak COUNT only; HOLD,
  configuration, soak-fail and the current-stable no-op still apply.

Because main moves often, stable advances only after a stretch in which one
commit stays on both installs for STABLE_SOAK_HOURS. That is deliberate:
reliability over speed.

External commands come from the environment so tests point them at fakes:
PROMOTE_GIT (default `git`), PROMOTE_CURL (default `curl`),
PROMOTE_IMAGETOOLS (default `docker buildx imagetools`). PROMOTE_NOW
(ISO-8601 UTC) fixes the clock and PROMOTE_REPO the image repository.
"""

import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys

DEFAULT_REPO = "ghcr.io/getburrowing/core"
REVISION_LABEL = "org.opencontainers.image.revision"
IRREVERSIBLE_PATH = "deployment/release/irreversible-migrations.txt"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HOUR_FMT = "%Y%m%dT%HZ"
STAMP_FMT = "%Y%m%dT%H%MZ"
PRUNE_DAYS = 14
INSTALLS = ("prod", "canary")

SOAK_RE = re.compile(r"^refs/soak/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
FAIL_RE = re.compile(r"^refs/soak-fail/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
SEEN_RE = re.compile(r"^refs/soak-seen/(prod|canary)$")
STABLE_TAG_RE = re.compile(r"^refs/tags/stable/(\d{8}T\d{4}Z)-[0-9a-f]+$")


def log(msg):
    print(msg, flush=True)


def cmd(var, default):
    return shlex.split(os.environ.get(var) or default)


def run(argv):
    proc = subprocess.run(argv, capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout, proc.stderr


def git(*args):
    return run([*cmd("PROMOTE_GIT", "git"), *args])


def imagetools(*args):
    return run([*cmd("PROMOTE_IMAGETOOLS", "docker buildx imagetools"), *args])


def truthy(value):
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def now_utc():
    raw = os.environ.get("PROMOTE_NOW")
    if raw:
        return dt.datetime.fromisoformat(raw).astimezone(dt.UTC)
    return dt.datetime.now(dt.UTC)


def parse_hour(text):
    return dt.datetime.strptime(text, HOUR_FMT).replace(tzinfo=dt.UTC)


# --- observations ------------------------------------------------------------


def probe(url):
    """(healthy, reported_commit_or_None, body_or_None) for one /health URL."""
    rc, out, _ = run([*cmd("PROMOTE_CURL", "curl"), "-fsS", "--max-time", "20", url])
    if rc != 0:
        return False, None, None
    try:
        body = json.loads(out)
    except ValueError:
        return False, None, None
    if not isinstance(body, dict):
        return False, None, None
    commit = body.get("commit")
    commit = commit if isinstance(commit, str) and SHA_RE.match(commit) else None
    return body.get("status") == "ok", commit, body


def canary_rollback_from(body):
    update = body.get("update") if isinstance(body, dict) else None
    rollback = update.get("last_rollback") if isinstance(update, dict) else None
    frm = rollback.get("from") if isinstance(rollback, dict) else None
    return frm if isinstance(frm, str) and SHA_RE.match(frm) else None


class Refs:
    """The soak state on origin, read once with ls-remote."""

    def __init__(self, lines):
        self.soak = {}  # S -> set(hours)
        self.fail = {}  # S -> set(hours)
        self.seen = {}  # install -> S
        self.stable_tags = []  # datetimes
        for line in lines:
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            sha, ref = parts[0].strip(), parts[1].strip()
            if m := SOAK_RE.match(ref):
                self.soak.setdefault(m[1], set()).add(m[2])
            elif m := FAIL_RE.match(ref):
                self.fail.setdefault(m[1], set()).add(m[2])
            elif m := SEEN_RE.match(ref):
                self.seen[m[1]] = sha
            elif m := STABLE_TAG_RE.match(ref):
                stamp = dt.datetime.strptime(m[1], STAMP_FMT).replace(tzinfo=dt.UTC)
                self.stable_tags.append(stamp)


def list_refs():
    rc, out, err = git("ls-remote", "--refs", "origin")
    if rc != 0:
        raise SystemExit(f"error: git ls-remote failed: {err.strip()}")
    return Refs(out.splitlines())


def known_commit(sha):
    rc, _, _ = git("cat-file", "-e", f"{sha}^{{commit}}")
    return rc == 0


def observe(refs, prod_url, canary_url, hour):
    """Probe both installs; return the push refspecs and update `refs` in place."""
    specs = []
    results = {}
    for install, url in (("prod", prod_url), ("canary", canary_url)):
        healthy, commit, body = probe(url)
        results[install] = (healthy, commit, body)
        log(f"{install}: healthy={healthy} commit={commit or '-'}")

    def add(ref, sha):
        if not known_commit(sha):
            log(f"warning: {sha} is not a commit in this repository; {ref} not written")
            return False
        specs.append(f"{sha}:{ref}")
        return True

    for install in INSTALLS:
        healthy, commit, _ = results[install]
        if commit and refs.seen.get(install) != commit and add(f"refs/soak-seen/{install}", commit):
            refs.seen[install] = commit
        if not healthy:
            blamed = commit or refs.seen.get(install)
            if blamed is None:
                log(f"warning: {install} failed its probe and has never reported a commit")
            elif add(f"refs/soak-fail/{blamed}/{hour}", blamed):
                refs.fail.setdefault(blamed, set()).add(hour)

    rolled_from = canary_rollback_from(results["canary"][2])
    if rolled_from and add(f"refs/soak-fail/{rolled_from}/{hour}", rolled_from):
        log(f"canary rolled back from {rolled_from}")
        refs.fail.setdefault(rolled_from, set()).add(hour)

    (p_ok, p_sha, _), (c_ok, c_sha, _) = results["prod"], results["canary"]
    if p_ok and c_ok and p_sha and p_sha == c_sha:
        if add(f"refs/soak/{p_sha}/{hour}", p_sha):
            refs.soak.setdefault(p_sha, set()).add(hour)
    elif p_ok and c_ok:
        log(f"mismatched commits: prod {p_sha or '-'} canary {c_sha or '-'}; no soak hour")
    return specs


def prune_specs(refs, now):
    cutoff = now - dt.timedelta(days=PRUNE_DAYS)
    specs = []
    for kind, table in (("soak", refs.soak), ("soak-fail", refs.fail)):
        for sha, hours in table.items():
            for hour in sorted(hours):
                if parse_hour(hour) < cutoff:
                    specs.append(f":refs/{kind}/{sha}/{hour}")
                    hours.discard(hour)
    for table in (refs.soak, refs.fail):
        for sha in [s for s, h in table.items() if not h]:
            del table[sha]
    return specs


# --- promotion ----------------------------------------------------------------


def stable_revision(repo):
    """The commit core-stable currently carries, or None (no tag, no label)."""
    rc, out, _ = imagetools("inspect", f"{repo}:core-stable", "--format", "{{json .Image}}")
    if rc != 0:
        return None
    try:
        image = json.loads(out)
    except ValueError:
        return None
    configs = [image] if isinstance(image, dict) and "config" in image else []
    if not configs and isinstance(image, dict):
        configs = [v for v in image.values() if isinstance(v, dict)]
    for config in configs:
        labels = (config.get("config") or {}).get("Labels") or {}
        rev = labels.get(REVISION_LABEL)
        if isinstance(rev, str) and SHA_RE.match(rev):
            return rev
    return None


def soak_count(hours):
    """Observed hours: one per soak ref, never the age of the first one."""
    return len(set(hours))


def choose(refs, soak_hours, current):
    last_promotion = max(refs.stable_tags, default=None)
    eligible = []
    for sha, hours in refs.soak.items():
        newest = max(parse_hour(h) for h in hours)
        if soak_count(hours) < soak_hours:
            continue
        if refs.fail.get(sha):
            continue
        if sha == current:
            continue
        if last_promotion is not None and newest <= last_promotion:
            continue
        eligible.append((newest, sha))
    return max(eligible)[1] if eligible else None


def irreversible_at(rev):
    if rev is None:
        return set()
    rc, out, _ = git("show", f"{rev}:{IRREVERSIBLE_PATH}")
    if rc != 0:
        return set()
    return {ln.strip() for ln in out.splitlines() if ln.strip() and not ln.startswith("#")}


def promote(repo, sha, current, now):
    rc, _, err = imagetools("create", "-t", f"{repo}:core-stable", f"{repo}:core-{sha}")
    if rc != 0:
        log(f"error: core-stable not moved: {err.strip()}")
        return 1
    rc, _, _ = imagetools("inspect", f"{repo}:play-{sha}")
    if rc == 0:
        rc, _, err = imagetools("create", "-t", f"{repo}:play-stable", f"{repo}:play-{sha}")
        if rc != 0:
            log(f"error: play-stable not moved: {err.strip()}")
            return 1
    else:
        log(f"no play-{sha}; play-stable left where it is")

    added = sorted(irreversible_at(sha) - irreversible_at(current))
    lines = [f"stable: {sha}", f"previous: {current or 'none'}", "irreversible migrations added:"]
    lines += [f"  {v}" for v in added] or ["  none"]
    tag = f"stable/{now.strftime(STAMP_FMT)}-{sha[:7]}"
    rc, _, err = git("tag", "-a", tag, "-m", "\n".join(lines), sha)
    if rc == 0:
        rc, _, err = git("push", "origin", f"refs/tags/{tag}")
    if rc != 0:
        log(f"error: images promoted but tag {tag} not pushed: {err.strip()}")
        return 1
    log(f"promoted {sha} to stable ({tag})")
    return 0


def main():
    if truthy(os.environ.get("STABLE_HOLD")):
        log("STABLE_HOLD is set: holding, nothing probed or promoted")
        return 0
    prod_url = (os.environ.get("STABLE_PROD_HEALTH_URL") or "").strip()
    canary_url = (os.environ.get("STABLE_CANARY_HEALTH_URL") or "").strip()
    if not prod_url or not canary_url:
        log(
            "error: not configured: set the STABLE_PROD_HEALTH_URL and "
            "STABLE_CANARY_HEALTH_URL repository variables; nothing promotes until both are set"
        )
        return 1
    try:
        soak_hours = int(os.environ.get("STABLE_SOAK_HOURS") or "24")
    except ValueError:
        log("error: STABLE_SOAK_HOURS is not an integer")
        return 1
    force = truthy(os.environ.get("PROMOTE_FORCE"))
    forced_sha = (os.environ.get("PROMOTE_SHA") or "").strip()
    if force and not SHA_RE.match(forced_sha):
        log("error: force needs sha = a full 40-hex commit")
        return 1
    repo = os.environ.get("PROMOTE_REPO") or DEFAULT_REPO
    now = now_utc()
    hour = now.strftime(HOUR_FMT)

    refs = list_refs()
    specs = observe(refs, prod_url, canary_url, hour) + prune_specs(refs, now)
    if specs:
        rc, _, err = git("push", "--atomic", "origin", *specs)
        if rc != 0:
            log(f"error: soak refs not pushed: {err.strip()}")
            return 1

    current = stable_revision(repo)
    log(f"current stable: {current or 'none'}")
    if force:
        if forced_sha == current:
            log(f"{forced_sha} is already stable; nothing to do")
            return 0
        if refs.fail.get(forced_sha):
            log(f"refusing force: {forced_sha} has soak-fail refs")
            return 1
        log(f"force: promoting {forced_sha} without the soak count")
        return promote(repo, forced_sha, current, now)

    sha = choose(refs, soak_hours, current)
    if sha is None:
        log("no commit is eligible for stable this hour")
        return 0
    return promote(repo, sha, current, now)


if __name__ == "__main__":
    sys.exit(main())
