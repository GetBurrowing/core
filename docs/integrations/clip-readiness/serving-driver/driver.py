#!/usr/bin/env python3
"""clip-runner-moon driver: the MCP-calling half of the burrow-clip-runner skill loop.

Implements the skill's loop (helper 0.5.0) and nothing more:
  1. startup reclaim  2. poll queued -> order -> claim  3. build run context
  4. run the helper, forward every {"tool","args"} line to Burrow MCP, answer
     reply_file requests via <path>.tmp + rename.

Logs are content-free: tool names, job/profile id prefixes, counts and codes.
Never logs the token, tool args, tool results, URLs, titles or transcripts.
"""

from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from burrow_mcp import McpClient, ToolError  # noqa: E402

HELPER = Path(os.environ.get("CLIP_RUNNER_HELPER", "/opt/clip-runner/bin/clip_runner.py"))
HELPER_SHA256 = "c55f6ceb913004ddfc3e947407847c2d768d78d4a40c081106fba97a8a066999"  # helper 0.7.0
CONFIG = Path(os.environ.get("CLIP_RUNNER_CONFIG", "/etc/clip-runner/runner.json"))
STATE_DIR = Path(os.environ.get("CLIP_RUNNER_HOME", "~/.clip-runner")).expanduser()
EXIT_BUSY = 75
PAGE = 100

_stop = False
_child: subprocess.Popen | None = None


def log(msg: str) -> None:
    sys.stderr.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + "driver: " + msg + "\n")
    sys.stderr.flush()


def short(i: object) -> str:
    return str(i)[:8] if i else "-"


def _on_signal(signum, _frame):
    global _stop
    _stop = True
    if _child is not None and _child.poll() is None:
        _child.send_signal(signum)  # the helper turns it into a RUNNER_SIG* fail line


# ── MCP helpers ───────────────────────────────────────────────────────────


def transient(code: str) -> bool:
    return code in ("MCP_UNREACHABLE", "MCP_NO_RESPONSE", "MCP_BAD_JSON", "MCP_INIT_FAILED") \
        or code.startswith("MCP_HTTP_5") or code == "MCP_HTTP_429"


def call_retry(mcp: McpClient, tool: str, args: dict, attempts: int = 4) -> dict:
    """Transport failures retry with backoff; tool refusals raise immediately."""
    delay = 2.0
    for n in range(attempts):
        try:
            return mcp.call(tool, args)
        except ToolError as e:
            if not transient(e.code) or n == attempts - 1:
                raise
            log(f"transport {e.code} on {tool}; retry {n + 1}")
            time.sleep(delay)
            delay *= 2
    raise ToolError("MCP_UNREACHABLE")


def list_all(mcp: McpClient, tool: str, key: str, args: dict) -> list[dict]:
    rows: list[dict] = []
    offset = 0
    while True:
        doc = call_retry(mcp, tool, {**args, "limit": PAGE, "offset": offset})
        page = doc.get(key) or []
        rows.extend(page)
        if not doc.get("has_more") or not page:
            return rows
        offset += len(page)


def list_jobs(mcp: McpClient, profile_id: str, status: str) -> list[dict]:
    return list_all(mcp, "social_clip_job_list", "jobs", {"profile_id": profile_id, "status": status})


# ── helper subprocess ───────────────────────────────────────────────────


def helper_cmd(*args: str) -> list[str]:
    return [sys.executable, "-I", str(HELPER), "--state-dir", str(STATE_DIR), *args]


def child_env() -> dict:
    """`run` gets the token (its upload POST needs it); nothing else does."""
    return dict(os.environ)


def no_token_env() -> dict:
    return {k: v for k, v in os.environ.items() if k != "CLIP_RUNNER_TOKEN"}


def write_reply(path: str, doc: dict) -> None:
    p = Path(path)
    replies = (STATE_DIR / "replies").resolve()
    if p.resolve().parent != replies:
        log("reply_file outside state replies dir; refused")
        return
    tmp = p.with_name(p.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(doc, fh)
    os.replace(tmp, p)


def forward(mcp: McpClient, line: str, parent_job_id: str | None) -> None:
    try:
        msg = json.loads(line)
    except ValueError:
        log("helper emitted a non-JSON line; ignored")
        return
    if not isinstance(msg, dict) or "tool" not in msg:
        return  # e.g. {"busy": true}
    tool, args, reply = msg["tool"], msg.get("args") or {}, msg.get("reply_file")
    job = short(args.get("job_id"))
    terminal = tool in ("social_clip_job_complete", "social_clip_job_fail")
    try:
        result = call_retry(mcp, tool, args, attempts=6 if (terminal or reply) else 2)
    except ToolError as e:
        log(f"{tool} job={job} refused code={e.code}")
        if reply:
            write_reply(reply, {"error": True, "code": e.code})
        elif tool == "social_clip_job_complete" and args.get("job_id") == parent_job_id \
                and not transient(e.code):
            # Skill: "When the job tool refuses complete, the job fails with that tool's code, upper-cased."
            try:
                call_retry(mcp, "social_clip_job_fail", {"job_id": parent_job_id, "error": "complete refused",
                                                         "code": e.code.upper()}, attempts=6)
                log(f"social_clip_job_fail job={job} code={e.code.upper()} (after complete refusal)")
            except ToolError as e2:
                log(f"social_clip_job_fail job={job} refused code={e2.code}")
        return
    if reply:
        write_reply(reply, result)
    if tool != "social_clip_job_progress" or reply or "picks" in args:
        log(f"{tool} job={job} ok" + (" (reply)" if reply else ""))


def run_helper(mcp: McpClient, argv: list[str], stdin_doc: dict, env: dict, parent_job_id: str | None) -> int:
    global _child
    _child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True,
                              bufsize=1)
    try:
        assert _child.stdin is not None and _child.stdout is not None
        _child.stdin.write(json.dumps(stdin_doc))
        _child.stdin.close()
        for line in _child.stdout:
            if line.strip():
                forward(mcp, line, parent_job_id)
        return _child.wait()
    finally:
        _child = None


# ── the loop ────────────────────────────────────────────────────────────


def verify_helper() -> None:
    digest = hashlib.sha256(HELPER.read_bytes()).hexdigest()
    if digest != HELPER_SHA256:
        log("helper sha256 mismatch; refusing to start")
        sys.exit(2)
    log(f"helper sha256 ok {digest[:12]} (0.7.0)")


def resolve_projects(mcp: McpClient, profile_ids: list[str], configured: dict) -> dict[str, str]:
    """social_profile_get proves access; on core 1f0f4486b it carries no project_id,
    so the Files project id comes from config when the tool does not return one."""
    projects = {}
    for pid in profile_ids:
        doc = call_retry(mcp, "social_profile_get", {"profile_id": pid})
        prof = doc.get("profile") if isinstance(doc.get("profile"), dict) else doc
        project_id = prof.get("project_id") or configured.get(pid)
        if prof.get("project_id") and configured.get(pid) and prof["project_id"] != configured[pid]:
            raise ToolError("PROFILE_PROJECT_CONFLICT")
        if not project_id:
            raise ToolError("PROFILE_NO_PROJECT")
        projects[pid] = project_id
        log(f"profile={short(pid)} project={short(project_id)} resolved")
    return projects


def startup_reclaim(mcp: McpClient, profile_ids: list[str], agent_id: str) -> None:
    jobs: list[dict] = []
    for pid in profile_ids:
        for status in ("claimed", "running"):
            jobs.extend(list_jobs(mcp, pid, status))
    log(f"startup reclaim: {len(jobs)} claimed/running job(s) seen")
    rc = run_helper(mcp, helper_cmd("reclaim", "--agent-id", agent_id), {"jobs": jobs}, no_token_env(), None)
    if rc == EXIT_BUSY:
        log("startup reclaim: busy (a run holds the lock); skipped")
    else:
        log(f"startup reclaim: done exit={rc}")


def find_clip(mcp: McpClient, profile_id: str, clip_id: str) -> dict | None:
    offset = 0
    while True:
        doc = call_retry(mcp, "social_clip_list", {"profile_id": profile_id, "limit": PAGE, "offset": offset})
        page = doc.get("clips") or []
        for c in page:
            if c.get("id") == clip_id:
                return c
        if not doc.get("has_more") or not page:
            return None
        offset += len(page)


def build_context(mcp: McpClient, job: dict, cfg: dict, projects: dict[str, str]) -> dict:
    ctx: dict = {"project_id": projects.get(job.get("profile_id"))}
    voice = cfg.get("headline_voice")
    if isinstance(voice, dict):
        ctx["headline_voice"] = {"revision": voice.get("revision"), "direction": voice.get("direction")}
    payload = job.get("payload") or {}
    clip_id = job.get("clip_id") or payload.get("clip_id")
    if clip_id:
        clip = find_clip(mcp, job["profile_id"], clip_id)
        if clip is not None:
            if isinstance(clip.get("rev"), int):
                ctx["clip_rev"] = clip["rev"]
            if isinstance(clip.get("next_rev"), int):  # 0.7.0: tombstones can leave revision gaps
                ctx["clip_next_rev"] = clip["next_rev"]
            versions = clip.get("versions") or []
            current = [v for v in versions if v.get("rev") == clip.get("rev")] or versions[:1]
            if current and current[0].get("id"):
                ctx["base_render_id"] = current[0]["id"]
    kind = job.get("kind") or payload.get("kind")
    episode = payload.get("episode") or {}
    if kind in ("new_clip", "rerender") and episode.get("source_file_id") and not payload.get("episode_job_id"):
        try:
            src = call_retry(mcp, "social_clip_job_source", {"job_id": job["id"]})
            if isinstance(src.get("url"), str):
                ctx["episode_url"] = src["url"]
        except ToolError as e:
            log(f"social_clip_job_source job={short(job['id'])} refused code={e.code}")
    return {k: v for k, v in ctx.items() if v is not None}


def poll_once(mcp: McpClient, cfg: dict, projects: dict[str, str]) -> bool:
    queued: list[dict] = []
    for pid in cfg["profile_ids"]:
        queued.extend(list_jobs(mcp, pid, "queued"))
    if not queued:
        return False
    out = subprocess.run(helper_cmd("order"), input=json.dumps({"jobs": queued}), capture_output=True,
                         text=True, env=no_token_env(), check=False)
    order = (json.loads(out.stdout or "{}") or {}).get("claim_order") or []
    log(f"poll: {len(queued)} queued")
    for job_id in order:
        try:
            doc = call_retry(mcp, "social_clip_job_claim", {"job_id": job_id})
        except ToolError as e:
            if e.code != "already_claimed":
                log(f"social_clip_job_claim job={short(job_id)} refused code={e.code}")
            continue
        job = doc.get("job") if isinstance(doc.get("job"), dict) else doc
        log(f"claimed job={short(job_id)} kind={job.get('kind')}")
        ctx = build_context(mcp, job, cfg, projects)
        rc = run_helper(mcp, helper_cmd("run"), {"job": job, "context": ctx}, child_env(), job["id"])
        log(f"run job={short(job_id)} exit={rc}")
        return True
    return False


def main() -> int:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    for name in ("CLIP_RUNNER_TOKEN", "CLIP_RUNNER_BASE_URL"):
        if not os.environ.get(name):
            log(f"missing env {name}")
            return 2
    cfg = json.loads(CONFIG.read_text())
    poll_s = float(cfg.get("poll_s", 45))
    verify_helper()
    mcp = McpClient.from_env()
    projects: dict[str, str] | None = None
    reclaimed = False
    while not _stop:
        try:
            if projects is None:
                projects = resolve_projects(mcp, cfg["profile_ids"], cfg.get("project_ids") or {})
            if not reclaimed:
                startup_reclaim(mcp, cfg["profile_ids"], cfg["agent_id"])
                reclaimed = True
            if poll_once(mcp, cfg, projects):
                continue  # served a job: poll again right away
            log(f"poll: idle ({len(cfg['profile_ids'])} profile(s))")
        except ToolError as e:
            log(f"loop error code={e.code}")
        except Exception as e:  # noqa: BLE001 - keep serving; content-free
            log(f"loop exception {type(e).__name__}")
        for _ in range(int(poll_s)):
            if _stop:
                break
            time.sleep(1)
    log("stopping")
    return 0


if __name__ == "__main__":
    sys.exit(main())
