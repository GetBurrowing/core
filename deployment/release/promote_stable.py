#!/usr/bin/env python3
"""Release observer/promoter.

Default HOLD freezes all work. Explicit held bootstrap records candidate-only
health in an atomic UTC ledger and has no stable mutation authority. Activated
batches require >=24 actual elapsed hours, independent hourly observations,
verified fixed identity and no failed probes, gaps or rollback. Legacy non-batch
observations retain their separate compatibility refs. See BATCHES.md.

PROMOTE_GIT/CURL/IMAGETOOLS select external commands for deterministic tests;
PROMOTE_NOW is the UTC clock override. Production uses GitHub runner time.
"""

import argparse
import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
from urllib.parse import urlsplit

import soak_state

DEFAULT_REPO = "ghcr.io/getburrowing/core"
REVISION_LABEL = "org.opencontainers.image.revision"
IRREVERSIBLE_PATH = "deployment/release/irreversible-migrations.txt"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HOUR_FMT = "%Y%m%dT%HZ"
STAMP_FMT = "%Y%m%dT%H%MZ"
PRUNE_DAYS = 14
INSTALLS = ("prod", "canary")
HELD_BOOTSTRAP = False


def held_bootstrap_config():
    """Opt-in exception to full freeze; never an exception for stable writes."""
    global HELD_BOOTSTRAP
    HELD_BOOTSTRAP = True
    url = urlsplit((os.environ.get("STABLE_CANARY_HEALTH_URL") or "").strip())
    try:
        hours = int(os.environ.get("STABLE_SOAK_HOURS") or "24")
    except ValueError:
        hours = 0
    if (not truthy(os.environ.get("STABLE_HOLD"))
            or not truthy(os.environ.get("STABLE_BATCH_ENABLED"))
            or os.environ.get("STABLE_SOAK_MODE") != "canary"
            or url.scheme != "https" or not url.hostname or url.username or url.password
            or url.fragment or hours < 24
            or truthy(os.environ.get("PROMOTE_FORCE"))
            or (os.environ.get("PROMOTE_SHA") or "").strip()):
        raise ValueError("held bootstrap requires HOLD, batches, canary mode, HTTPS health, >=24h and no force/SHA")


def entrypoint(main):
    parser = argparse.ArgumentParser()
    parser.add_argument("--held-bootstrap", action="store_true",
                        help="explicit held candidate bootstrap/observation; stable writes forbidden")
    return main(held_bootstrap=parser.parse_args().held_bootstrap)

SOAK_RE = re.compile(r"^refs/soak/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
FAIL_RE = re.compile(r"^refs/soak-fail/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
SEEN_RE = re.compile(r"^refs/soak-seen/(prod|canary)$")
STABLE_TAG_RE = re.compile(r"^refs/tags/stable/(\d{8}T\d{4}Z)-[0-9a-f]+$")


def log(msg):
    print(msg, flush=True)


def cmd(var, default):
    return shlex.split(os.environ.get(var) or default)


def run(argv, input=None):
    env = dict(os.environ)
    for key, value in {"GIT_AUTHOR_NAME": "Release observer", "GIT_AUTHOR_EMAIL": "release@localhost",
                       "GIT_COMMITTER_NAME": "Release observer", "GIT_COMMITTER_EMAIL": "release@localhost"}.items():
        env.setdefault(key, value)
    proc = subprocess.run(argv, input=input, env=env, capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout, proc.stderr


def git(*args):
    if HELD_BOOTSTRAP:
        if args and args[0] == "push":
            # Literal namespaces, not a denylist of known stable tag names.
            allowed = re.compile(
                r"^refs/(release-candidate/(current|pending|cut/\d{8})|"
                r"soak-state/(canary|both)/[0-9a-f]{40}|soak-seen/canary|soak(-fail)?-canary/[0-9a-f]{40}/\d{8}T\d{2}Z)$"
            )
            specs = [a for a in args[1:] if a != "origin" and not a.startswith("--")]
            flags = [a for a in args[1:] if a.startswith("--")]
            lease = re.compile(r"^--force-with-lease=refs/(release-candidate/(current|pending)|soak-state/(canary|both)/[0-9a-f]{40}):([0-9a-f]{40})?$")
            if (args.count("origin") != 1 or "--atomic" not in flags
                    or any(f != "--atomic" and not lease.fullmatch(f) for f in flags)
                    or not specs or any(":" not in s
                                        or not allowed.fullmatch(s.split(":", 1)[1])
                                        or (s.split(":", 1)[0] and not SHA_RE.fullmatch(s.split(":", 1)[0]))
                                        for s in specs)):
                raise RuntimeError("held bootstrap refused Git mutation outside candidate state")
            if any(s.startswith((":refs/soak-fail", ":refs/soak-state")) for s in specs):
                raise RuntimeError("held bootstrap must preserve failure evidence")
        elif not args or args[0] not in ("ls-remote", "cat-file", "show", "commit-tree"):
            raise RuntimeError("held bootstrap refused non-observation Git command")
    return run([*cmd("PROMOTE_GIT", "git"), *args])


def imagetools(*args):
    if HELD_BOOTSTRAP and args and args[0] != "inspect":
        repo = os.environ.get("PROMOTE_REPO") or DEFAULT_REPO
        if (len(args) != 4 or args[:2] != ("create", "-t")
                or args[2] not in (f"{repo}:core-candidate", f"{repo}:play-candidate")
                or not re.fullmatch(re.escape(repo) + r":(core|play)-[0-9a-f]{40}", args[3])
                or args[2].rsplit(":", 1)[1].split("-")[0] != args[3].rsplit(":", 1)[1].split("-")[0]):
            raise RuntimeError("held bootstrap refused registry mutation outside candidate tags")
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

    def __init__(self, lines, mode="both"):
        self.mode = mode
        self.soak_kind = "soak" if mode == "both" else "soak-canary"
        self.fail_kind = "soak-fail" if mode == "both" else "soak-fail-canary"
        self.candidate = None
        self.pending = None
        self.cuts = set()
        self.ledgers = {}
        self.failed_any = set()
        soak_re = re.compile(r"^refs/" + self.soak_kind + r"/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
        fail_re = re.compile(r"^refs/" + self.fail_kind + r"/([0-9a-f]{40})/(\d{8}T\d{2}Z)$")
        self.soak = {}  # S -> set(hours)
        self.fail = {}  # S -> set(hours)
        self.seen = {}  # install -> S
        self.stable_tags = []  # datetimes
        for line in lines:
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            sha, ref = parts[0].strip(), parts[1].strip()
            failure = re.fullmatch(r"refs/soak-fail(?:-canary)?/([0-9a-f]{40})/\d{8}T\d{2}Z", ref)
            if failure:
                self.failed_any.add(failure[1])
            if ref.startswith(f"refs/soak-state/{mode}/"):
                self.ledgers[ref.rsplit("/", 1)[1]] = sha
            elif ref == "refs/release-candidate/current":
                self.candidate = sha
            elif ref == "refs/release-candidate/pending":
                self.pending = sha
            elif ref.startswith("refs/release-candidate/cut/"):
                self.cuts.add(ref.rsplit("/", 1)[1])
            elif m := soak_re.match(ref):
                self.soak.setdefault(m[1], set()).add(m[2])
            elif m := fail_re.match(ref):
                self.fail.setdefault(m[1], set()).add(m[2])
            elif m := SEEN_RE.match(ref):
                self.seen[m[1]] = sha
            elif m := STABLE_TAG_RE.match(ref):
                stamp = dt.datetime.strptime(m[1], STAMP_FMT).replace(tzinfo=dt.UTC)
                self.stable_tags.append(stamp)


def list_refs(mode="both"):
    rc, out, err = git("ls-remote", "--refs", "origin")
    if rc != 0:
        raise SystemExit(f"error: git ls-remote failed: {err.strip()}")
    return Refs(out.splitlines(), mode)


def known_commit(sha):
    rc, _, _ = git("cat-file", "-e", f"{sha}^{{commit}}")
    return rc == 0


def observe(refs, prod_url, canary_url, hour):
    """Probe both installs; return the push refspecs and update `refs` in place."""
    specs = []
    results = {}
    targets = (("prod", prod_url), ("canary", canary_url)) if refs.mode == "both" else (("canary", canary_url),)
    for install, url in targets:
        healthy, commit, body = probe(url)
        results[install] = (healthy, commit, body)
        log(f"{install}: healthy={healthy} commit={commit or '-'}")

    def add(ref, sha):
        if not known_commit(sha):
            log(f"warning: {sha} is not a commit in this repository; {ref} not written")
            return False
        specs.append(f"{sha}:{ref}")
        return True

    for install, (healthy, commit, _) in results.items():
        if commit and refs.seen.get(install) != commit and add(f"refs/soak-seen/{install}", commit):
            refs.seen[install] = commit
        if not healthy:
            blamed = commit or refs.seen.get(install)
            if blamed is None:
                log(f"warning: {install} failed its probe and has never reported a commit")
            elif add(f"refs/{refs.fail_kind}/{blamed}/{hour}", blamed):
                refs.fail.setdefault(blamed, set()).add(hour)

    rolled_from = canary_rollback_from(results["canary"][2])
    if rolled_from and add(f"refs/{refs.fail_kind}/{rolled_from}/{hour}", rolled_from):
        log(f"canary rolled back from {rolled_from}")
        refs.fail.setdefault(rolled_from, set()).add(hour)

    if refs.mode == "canary":
        c_ok, c_sha, _ = results["canary"]
        if c_ok and c_sha and add(f"refs/{refs.soak_kind}/{c_sha}/{hour}", c_sha):
            refs.soak.setdefault(c_sha, set()).add(hour)
        return specs

    (p_ok, p_sha, _), (c_ok, c_sha, _) = results["prod"], results["canary"]
    if p_ok and c_ok and p_sha and p_sha == c_sha:
        if add(f"refs/soak/{p_sha}/{hour}", p_sha):
            refs.soak.setdefault(p_sha, set()).add(hour)
    elif p_ok and c_ok:
        log(f"mismatched commits: prod {p_sha or '-'} canary {c_sha or '-'}; no soak hour")
    return specs


def state_ref(candidate, mode):
    return f"refs/soak-state/{mode}/{candidate}"


def state_commit(state):
    # Empty-tree commit carries a JSON message, parented to candidate for reachability.
    rc, tree, err = run([*cmd("PROMOTE_GIT", "git"), "hash-object", "-t", "tree", "-w", "--stdin"], input="")
    if rc:
        raise RuntimeError(f"cannot store soak tree: {err}")
    rc, oid, err = git("commit-tree", tree.strip(), "-p", state["candidate"],
                       "-m", json.dumps(state, sort_keys=True))
    if rc or not SHA_RE.fullmatch(oid.strip()):
        raise RuntimeError(f"cannot store soak ledger: {err}")
    return oid.strip()


def candidate_observation(refs, repo, prod_url, canary_url, now, hours):
    candidate = refs.candidate
    previous = refs.ledgers.get(candidate)
    if not candidate or not previous:
        raise RuntimeError("candidate generation ledger missing; reconcile, never recreate observation history")
    # ls-remote does not download ledger objects on fresh workflow checkouts.
    rc, _, err = run([*cmd("PROMOTE_GIT", "git"), "fetch", "--no-tags", "origin", state_ref(candidate, refs.mode)])
    if rc:
        raise RuntimeError(f"cannot fetch soak ledger: {err}")
    rc, body, err = git("show", "-s", "--format=%B", previous)
    if rc:
        raise RuntimeError(f"cannot read soak ledger: {err}")
    state = json.loads(body)
    healthy = all(stable_revision(repo, f"{flavour}-candidate") == candidate
                  for flavour in ("core", "play"))
    reason = "registry candidate identity mismatch"
    for url in ([prod_url, canary_url] if refs.mode == "both" else [canary_url]):
        ok, revision, response = probe(url)
        rollback = canary_rollback_from(response)
        if not ok or revision != candidate or rollback == candidate:
            healthy, reason = False, "unavailable/malformed health, candidate identity mismatch or rollback"
    if candidate in refs.failed_any:
        healthy, reason = False, "existing failed candidate evidence"
    ref = state_ref(candidate, refs.mode)
    hour = now.strftime(HOUR_FMT)
    for attempt in range(3):
        next_state = soak_state.observe(state, candidate, refs.mode, now, healthy, reason)
        oid = state_commit(next_state)
        kind = refs.fail_kind if next_state["failures"] else refs.soak_kind
        # Commit ledger and hourly evidence together, pinned to publication identity.
        rc, _, err = git("push", "--atomic", f"--force-with-lease={ref}:{previous}",
                         f"--force-with-lease=refs/release-candidate/current:{candidate}",
                         "--force-with-lease=refs/release-candidate/pending:", "origin",
                         f"{oid}:{ref}", f"{candidate}:refs/{kind}/{candidate}/{hour}",
                         f"{candidate}:refs/release-candidate/current", ":refs/release-candidate/pending")
        if not rc:
            break
        fresh = list_refs(refs.mode)
        replacement = fresh.ledgers.get(candidate)
        if (fresh.candidate != candidate or fresh.pending or not replacement
                or attempt == 2):
            raise RuntimeError(f"soak ledger CAS failed; no success committed: {err}")
        previous = replacement
        rc, _, err = run([*cmd("PROMOTE_GIT", "git"), "fetch", "--no-tags", "origin", ref])
        if rc:
            raise RuntimeError(f"cannot fetch concurrent soak ledger: {err}")
        rc, body, err = git("show", "-s", "--format=%B", previous)
        if rc:
            raise RuntimeError(f"cannot read concurrent soak ledger: {err}")
        state = json.loads(body)
    accepted = soak_state.complete(next_state, hours)
    log(f"candidate {candidate}: soak_complete={accepted} failures={len(next_state['failures'])}")
    return accepted


def prune_specs(refs, now):
    cutoff = now - dt.timedelta(days=PRUNE_DAYS)
    specs = []
    for kind, table in ((refs.soak_kind, refs.soak),):
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


def stable_revision(repo, channel="core-stable"):
    """Verified channel revision, or None if absent/missing/mixed labels."""
    rc, out, _ = imagetools("inspect", f"{repo}:{channel}", "--format", "{{json .Image}}")
    if rc != 0:
        return None
    try:
        image = json.loads(out)
    except ValueError:
        return None
    configs = [image] if isinstance(image, dict) and "config" in image else []
    if not configs and isinstance(image, dict):
        configs = [v for v in image.values() if isinstance(v, dict)]
    revisions = set()
    for config in configs:
        labels = (config.get("config") or {}).get("Labels") or {}
        rev = labels.get(REVISION_LABEL)
        if not isinstance(rev, str) or not SHA_RE.fullmatch(rev):
            return None
        revisions.add(rev)
    return revisions.pop() if len(revisions) == 1 else None


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
    if HELD_BOOTSTRAP:
        raise RuntimeError("held bootstrap has no stable promotion authority")
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


def main(held_bootstrap=False):
    if held_bootstrap:
        try:
            held_bootstrap_config()
        except ValueError as exc:
            log(f"error: {exc}")
            return 1
    if truthy(os.environ.get("STABLE_HOLD")) and not held_bootstrap:
        log("STABLE_HOLD is set: holding, nothing probed or promoted")
        return 0
    prod_url = (os.environ.get("STABLE_PROD_HEALTH_URL") or "").strip()
    canary_url = (os.environ.get("STABLE_CANARY_HEALTH_URL") or "").strip()
    mode = os.environ.get("STABLE_SOAK_MODE") or "both"
    if mode not in ("both", "canary"):
        log("error: STABLE_SOAK_MODE must be both or canary")
        return 1
    batch = truthy(os.environ.get("STABLE_BATCH_ENABLED"))
    if (mode == "both" and not prod_url) or not canary_url:
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
    if soak_hours < 1 or (batch and soak_hours < 24):
        log("error: batch releases need at least 24 observed soak hours")
        return 1
    force = truthy(os.environ.get("PROMOTE_FORCE"))
    forced_sha = (os.environ.get("PROMOTE_SHA") or "").strip()
    if batch and (force or forced_sha):
        log("error: batch observation refuses force/SHA inputs")
        return 1
    if force and not SHA_RE.match(forced_sha):
        log("error: force needs sha = a full 40-hex commit")
        return 1
    repo = os.environ.get("PROMOTE_REPO") or DEFAULT_REPO
    now = now_utc()
    hour = now.strftime(HOUR_FMT)

    refs = list_refs(mode)
    if refs.pending or (held_bootstrap and not refs.candidate):
        log("error: candidate absent or publication pending; reconcile before observation")
        return 1
    if batch:
        try:
            accepted = candidate_observation(refs, repo, prod_url, canary_url, now, soak_hours)
        except (ValueError, KeyError, TypeError, RuntimeError) as exc:
            log(f"error: {exc}")
            return 1
        if held_bootstrap:
            log("held bootstrap: durable observations committed; stable remains held")
            return 0
        if not accepted:
            log("candidate has not passed its full elapsed soak")
            return 0
        current = stable_revision(repo)
        if refs.candidate == current:
            return 0
        return promote(repo, refs.candidate, current, now)
    specs = observe(refs, prod_url, canary_url, hour)
    specs += prune_specs(refs, now)
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
    sys.exit(entrypoint(main))
