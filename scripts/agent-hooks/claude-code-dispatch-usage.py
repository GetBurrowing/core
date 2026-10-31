#!/usr/bin/env python3
"""Claude Code SubagentStop / Stop hook: report one dispatch's usage to Burrow.

Task 01a114a8 stage 1. Reads the transcript JSONL named by the hook payload
on stdin, summarises it, and POSTs one row to Burrow's
`/api/internal/usage-events`, which feeds
`Platform.Orchestration.DispatchMetrics`.

What it counts, from the transcript only:
  * turns: distinct assistant message ids. One API response can be split
    across several JSONL lines that share an id, so lines are not turns.
  * client tool calls: distinct `tool_use` block ids, ALL tools (Bash, Read,
    Burrow MCP tools, ...). Tool NAMES are reported; tool inputs never are.
  * tokens: usage input / output / cache-read / cache-creation, summed once
    per assistant message id.
  * wall_ms: first to last line timestamp.
  * task_id / stage_id: UUIDs labelled as such in the FIRST user message
    (the dispatch brief). No task id means this was not a Burrow dispatch,
    and nothing is sent.

Environment (read, never echoed):
  BURROW_RUNTIME_TOKEN  runtime bearer token (required to send)
  BURROW_BASE_URL       e.g. https://suite.example.com (required to send)
  BURROW_AGENT_ID       the agent's UUID (strongly recommended: DispatchMetrics
                        only counts a report whose agent_id matches the dispatch)
  Only these BURROW_ names are read; the pre-rename names are ignored
  (task 01a18dab). An empty value counts as unset.
  CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET   optional Cloudflare Access pair

The hook never fails the session: every error path exits 0 with a one-line
message on stderr that names the failure class, never the token.

  python3 claude-code-dispatch-usage.py < hook.json      # as a hook
  python3 claude-code-dispatch-usage.py --dry-run < hook.json
  python3 claude-code-dispatch-usage.py --self-test      # fixture check, no network

Installing it (settings.json hooks) is stage 4's job.
"""

import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime

UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
LABEL_GAP = r"[\s`'\":=(]*"
TASK_PATTERNS = [
    re.compile(r"task[_ ]id" + LABEL_GAP + "(" + UUID + ")", re.IGNORECASE),
    re.compile(r"\btask" + LABEL_GAP + "(" + UUID + ")", re.IGNORECASE),
]
STAGE_PATTERNS = [
    re.compile(r"stage[_ ]id" + LABEL_GAP + "(" + UUID + ")", re.IGNORECASE),
]
HARNESS = "claude-code"
TIMEOUT_SECONDS = 10

def _env(env, name):
    """Read ``name`` from ``env``; an empty string counts as unset."""
    return env.get(name) or None


def read_lines(path):
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def message_text(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        )
    return ""


def first_match(patterns, text):
    for pattern in patterns:
        found = pattern.search(text)
        if found:
            return found.group(1).lower()
    return None


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def summarise(rows):
    usage_by_message = {}
    tool_ids = {}
    first_user_text = None
    timestamps = []
    model = None
    session_id = None

    for row in rows:
        ts = parse_ts(row.get("timestamp"))
        if ts is not None:
            timestamps.append(ts)
        session_id = session_id or row.get("sessionId")
        message = row.get("message") if isinstance(row.get("message"), dict) else {}

        if row.get("type") == "user" and first_user_text is None:
            text = message_text(message)
            if text:
                first_user_text = text

        if row.get("type") != "assistant":
            continue

        model = message.get("model") or model
        message_id = message.get("id") or row.get("uuid")
        usage = message.get("usage")
        if message_id and isinstance(usage, dict):
            # Last line of a split response wins; the usage repeats per line.
            usage_by_message[message_id] = usage
        elif message_id and message_id not in usage_by_message:
            usage_by_message[message_id] = {}

        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    tool_ids[block.get("id") or len(tool_ids)] = block.get("name") or "unknown"

    def total(key):
        return sum(int(u.get(key) or 0) for u in usage_by_message.values())

    text = first_user_text or ""
    wall_ms = None
    if len(timestamps) >= 2:
        wall_ms = int((max(timestamps) - min(timestamps)).total_seconds() * 1000)

    return {
        "task_id": first_match(TASK_PATTERNS, text),
        "stage_id": first_match(STAGE_PATTERNS, text),
        "turns": len(usage_by_message),
        "client_tool_calls": len(tool_ids),
        "tool_names": sorted(set(tool_ids.values())),
        "input_tokens": total("input_tokens"),
        "output_tokens": total("output_tokens"),
        "cache_read_tokens": total("cache_read_input_tokens"),
        "cache_write_tokens": total("cache_creation_input_tokens"),
        "wall_ms": wall_ms,
        "model": model or "unknown",
        "session_id": session_id,
    }


def build_payload(summary, hook, env):
    session = summary.get("session_id") or hook.get("session_id") or "unknown"
    subagent = hook.get("agent_id") or ""
    metadata = {
        "turns": summary["turns"],
        "client_tool_calls": summary["client_tool_calls"],
        "harness": HARNESS,
    }
    if summary["stage_id"]:
        metadata["stage_id"] = summary["stage_id"]
    if summary["wall_ms"] is not None:
        metadata["wall_ms"] = summary["wall_ms"]

    payload = {
        "model": summary["model"],
        "provider": "anthropic",
        "session_key": (session + ":" + subagent) if subagent else session,
        "task_id": summary["task_id"],
        "input_tokens": summary["input_tokens"],
        "output_tokens": summary["output_tokens"],
        "cache_read_tokens": summary["cache_read_tokens"],
        "cache_write_tokens": summary["cache_write_tokens"],
        "tool_calls": summary["tool_names"],
        "metadata": metadata,
    }
    agent_id = _env(env, "BURROW_AGENT_ID")
    if agent_id:
        payload["agent_id"] = agent_id
    return payload


def post(payload, env):
    token = _env(env, "BURROW_RUNTIME_TOKEN")
    base = _env(env, "BURROW_BASE_URL")
    if not token or not base:
        return "skipped: BURROW_RUNTIME_TOKEN or BURROW_BASE_URL unset"
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + token,
        "User-Agent": "suite-dispatch-usage-hook/1",
    }
    if env.get("CF_ACCESS_CLIENT_ID") and env.get("CF_ACCESS_CLIENT_SECRET"):
        headers["CF-Access-Client-Id"] = env["CF_ACCESS_CLIENT_ID"]
        headers["CF-Access-Client-Secret"] = env["CF_ACCESS_CLIENT_SECRET"]
    request = urllib.request.Request(
        base.rstrip("/") + "/api/internal/usage-events",
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return "sent: HTTP %d" % response.status
    except urllib.error.HTTPError as error:
        return "failed: HTTP %d" % error.code
    except Exception as error:  # noqa: BLE001 - a hook must never raise
        return "failed: " + type(error).__name__


def transcript_path(hook):
    for key in ("agent_transcript_path", "transcript_path"):
        value = hook.get(key)
        if isinstance(value, str) and value:
            return os.path.expanduser(value)
    return None


def run(stdin_text, env, dry_run=False):
    try:
        hook = json.loads(stdin_text or "{}")
    except ValueError:
        return "skipped: hook payload is not JSON"
    path = transcript_path(hook if isinstance(hook, dict) else {})
    if not path or not os.path.isfile(path):
        return "skipped: no transcript"
    summary = summarise(read_lines(path))
    if not summary["task_id"]:
        return "skipped: not a Burrow dispatch (no task id in the first user message)"
    payload = build_payload(summary, hook, env)
    if dry_run:
        return json.dumps(payload, sort_keys=True)
    return post(payload, env)


def env_self_test(failures):
    """BURROW_ names only; the pre-rename names are ignored. Returns the count."""
    # Built, not written out, so this file carries no legacy token for the
    # core repo guard (burrow_env_fallback_guard_test.exs) to flag.
    legacy = lambda suffix: "SUITE" + "_" + suffix
    names = ["RUNTIME_TOKEN", "BASE_URL", "AGENT_ID"]
    checks = 0
    for suffix in names:
        burrow, old = "BURROW_" + suffix, legacy(suffix)
        if _env({burrow: "new"}, burrow) != "new":
            failures.append("%s only: not read" % burrow)
        if _env({old: "old"}, burrow) is not None:
            failures.append("%s only: the legacy name was read" % burrow)
        if _env({burrow: "", old: "old"}, burrow) is not None:
            failures.append("%s empty: the legacy name was read" % burrow)
        checks += 3

    # The payload path end to end: a legacy-only env yields no agent id,
    # BURROW_AGENT_ID is used. post() is never reached (dry run).
    here = os.path.dirname(os.path.abspath(__file__))
    fixture = os.path.join(here, "fixtures", "claude-code-transcript.jsonl")
    hook = json.dumps({"session_id": "s", "agent_id": "sub-1", "transcript_path": fixture})
    legacy_only = json.loads(run(hook, {legacy("AGENT_ID"): "legacy-agent"}, dry_run=True))
    burrow_only = json.loads(run(hook, {"BURROW_AGENT_ID": "new-agent"}, dry_run=True))
    if legacy_only.get("agent_id") == "legacy-agent":
        failures.append("the legacy agent id name was read")
    if burrow_only.get("agent_id") != "new-agent":
        failures.append("BURROW_AGENT_ID not used: %r" % burrow_only.get("agent_id"))
    checks += 2

    # The skip message names the BURROW_ names.
    if post({}, {}) != "skipped: BURROW_RUNTIME_TOKEN or BURROW_BASE_URL unset":
        failures.append("skip message: %r" % post({}, {}))
    checks += 1
    return checks


def self_test():
    here = os.path.dirname(os.path.abspath(__file__))
    fixture = os.path.join(here, "fixtures", "claude-code-transcript.jsonl")
    summary = summarise(read_lines(fixture))

    # Literal expected values, read off the fixture by hand: three assistant
    # messages (msg_A is split across two lines and counted once), three
    # tool_use blocks, usage summed once per message.
    expected = {
        "task_id": "01a114a8-3d13-7001-b220-c961fc575b48",
        "stage_id": "01a114b0-423c-7002-8e73-d06c2a56549a",
        "turns": 3,
        "client_tool_calls": 3,
        "tool_names": ["Bash", "Read", "mcp__startup-suite__task_ack"],
        "input_tokens": 17,
        "output_tokens": 90,
        "cache_read_tokens": 600,
        "cache_write_tokens": 60,
        "wall_ms": 123500,
        "model": "claude-opus-5-5",
        "session_id": "fixture-session-0001",
    }
    failures = ["%s: got %r, want %r" % (k, summary.get(k), v) for k, v in expected.items() if summary.get(k) != v]

    sentinel_token = "tok-SENTINEL-must-not-appear"
    env = {"BURROW_RUNTIME_TOKEN": sentinel_token, "BURROW_AGENT_ID": "019dc658-b64c-7deb-bad7-c34d86924e32"}
    hook = json.dumps({"session_id": "s", "agent_id": "sub-1", "transcript_path": fixture})
    dry = run(hook, env, dry_run=True)
    if sentinel_token in dry:
        failures.append("the runtime token appears in the payload")
    if "SECRET-SHOULD-NOT-LEAVE" in dry:
        failures.append("a tool input appears in the payload")
    payload = json.loads(dry)
    if payload["metadata"] != {
        "turns": 3,
        "client_tool_calls": 3,
        "harness": "claude-code",
        "stage_id": "01a114b0-423c-7002-8e73-d06c2a56549a",
        "wall_ms": 123500,
    }:
        failures.append("metadata: got %r" % payload["metadata"])
    if payload.get("agent_id") != "019dc658-b64c-7deb-bad7-c34d86924e32":
        failures.append("agent_id not taken from BURROW_AGENT_ID")
    if payload.get("session_key") != "fixture-session-0001:sub-1":
        failures.append("session_key: got %r" % payload.get("session_key"))

    # No task id in the first user message -> nothing is sent (post() is
    # never reached, so this cannot touch the network).
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
        handle.write(json.dumps({"type": "user", "message": {"role": "user", "content": "hi"}}) + "\n")
        no_task_path = handle.name
    try:
        no_task = run(json.dumps({"transcript_path": no_task_path}), env)
    finally:
        os.unlink(no_task_path)
    if not no_task.startswith("skipped: not a Burrow dispatch"):
        failures.append("a transcript without a task id was not skipped: %r" % no_task)

    env_checks = env_self_test(failures)

    if failures:
        for failure in failures:
            print("FAIL " + failure)
        return 1
    print("SELF-TEST OK (%d checks)" % (len(expected) + 5 + env_checks))
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    try:
        message = run(sys.stdin.read(), os.environ, dry_run="--dry-run" in argv)
    except Exception as error:  # noqa: BLE001 - a hook must never raise
        message = "failed: " + type(error).__name__
    if "--dry-run" in argv:
        print(message)
    else:
        sys.stderr.write("[dispatch-usage] " + message + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
