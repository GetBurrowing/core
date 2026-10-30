#!/usr/bin/env python3
"""burrow-clip-runner helper: the deterministic half of the Burrow Clip Studio runner.

The agent running the `burrow-clip-runner` skill is the only MCP caller. This
helper never talks to Burrow's MCP. It reads job JSON on stdin and writes the
tool calls it wants made, one JSON object per line, on stdout:

    {"tool": "social_clip_job_progress", "args": {"job_id": ..., "progress": 0.4, "eta_s": 90}}

The agent forwards every line, in order, as the named MCP call. A line that
also carries "reply_file" is a request: the agent makes the call and writes
the tool's JSON result to that path (the helper waits for it). The last line
of `run` is always `social_clip_job_complete` or `social_clip_job_fail`.

Subcommands (all JSON on stdin, JSONL on stdout):
    version                              print {"version": ...}
    reclaim --agent-id ID                stdin {"jobs": [claimed + running jobs]};
                                         emits a fail (RUNNER_RESTARTED) for every job
                                         claimed by ID and every job the local journal
                                         records as in flight
    order                                stdin {"jobs": [queued jobs]}; prints
                                         {"claim_order": [job ids]} oldest first
    run                                  stdin {"job": <the job returned by claim>,
                                                "context": {"clip_rev": n, "project_id": id,
                                                            "episode_path"?: p, "episode_url"?: u}};
                                         runs it, emits progress, then complete or fail

Environment for `run` (never logged or stored): CLIP_RUNNER_TOKEN (the agent's
bearer token, sent only to CLIP_RUNNER_BASE_URL for the presigned upload POST),
CLIP_RUNNER_BASE_URL, optional CLIP_RUNNER_YTDLP (path of yt-dlp).

Rules this file keeps: only `clip` commands plus review.toml (and yt-dlp to
fetch an episode); never writes picks JSON; never writes the built-in
how-to-computer profile (looks go in user profiles that extend it); never
prints stderr, transcript text, titles or file names; error messages are
content-free (step name, exit code, error code only). Under the clip tool's
local privacy mode every clip command runs with CLIP_NO_CONTENT=1 and
complete/fail carry ids, numbers, codes and the file_id only.

Python 3.11+ stdlib only.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Protocol

VERSION = "0.9.1"

KINDS = ("new_clip", "rerender", "save_default", "episode")
RESULT_KEYS = (
    "file_id",
    "title",
    "caption",
    "speaker",
    "episode_code",
    "platforms",
    "duration_s",
    "width",
    "height",
    "source_label",
    "actual_in_s",
    "actual_out_s",
    "candidate_id",
    "alternate_id",
    "headline_applied",
)
META_KEYS = ("title", "caption", "speaker", "episode_code")
SOURCE_LABEL = "htc-clip-tool"
BASE_PROFILE = "how-to-computer"
LEGACY_CAPTION_STYLES = ("plain", "phrase-pop", "karaoke")
DYNAMIC_CAPTION_STYLES = ("type-on", "focus-word", "editorial-punch")
CAPTION_STYLES = LEGACY_CAPTION_STYLES + DYNAMIC_CAPTION_STYLES
# Pinned actual imported renderer sources, not the CLI's distribution label.
CAPTION_RENDERER_SHA256 = "9074e59c4c38ddcfafd804f66cd72958cb3e28e3a992426c10e0446de53dbdd4"
CAPTION_TEMPORAL_SHA256 = "385f5e446c09bd06bb5fb11aaa4228fa95e47fa808e1c1d750bf6633d039aee7"


def _qualify_caption_style(runner, style):
    if style not in CAPTION_STYLES:
        raise ClipError("CAPTION_STYLE_UNSUPPORTED", "captions")
    if style in DYNAMIC_CAPTION_STYLES:
        info = runner.clip("caption_capability", ["version", "--json"])
        renderer = info.get("caption_renderer") or {}
        styles = info.get("caption_styles")
        if (type(info.get("caption_treatments")) is not int or
                info["caption_treatments"] != 1 or
                not isinstance(styles, list) or
                not all(isinstance(s, str) for s in styles) or
                not set(CAPTION_STYLES).issubset(styles) or
                not isinstance(renderer, dict) or
                renderer.get("sha256") != CAPTION_RENDERER_SHA256 or
                renderer.get("temporal_sha256") != CAPTION_TEMPORAL_SHA256):
            raise ClipError("CAPTION_CLI_UNSUPPORTED", "captions")


MIN_CLIP_VERSION = (0, 9, 0)
MIN_CONTENT_FREE = 2
DEFAULT_STATE_DIR = Path(os.environ.get("CLIP_RUNNER_HOME", "~/.clip-runner")).expanduser()
DEFAULT_HEARTBEAT_S = 30.0  # contract: at least every 60s
DEFAULT_TIMEOUT_S = 3 * 3600.0
DEFAULT_REPLY_TIMEOUT_S = 900.0
EXIT_BUSY = 75

_CODE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,120}$")  # clip's own profile-name rule
_LOOK_KEY_RE = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")  # section.key, as ClipLook maps them


# ── Errors ──────────────────────────────────────────────────────────────


class JobToolError(Exception):
    """A job tool refused the call; `code` is the envelope's code."""

    def __init__(self, code: str, message: str = ""):
        super().__init__(message or code)
        self.code = code


class AlreadyClaimed(JobToolError):
    def __init__(self, message: str = "already_claimed"):
        super().__init__("already_claimed", message)


class ClipError(Exception):
    """A job step failed. `code` goes to social_clip_job_fail; the message is content-free."""

    def __init__(self, code: str, step: str, detail: str = ""):
        self.code = code
        self.step = step
        self.detail = detail
        super().__init__(f"{step} failed" + (f" ({detail})" if detail else ""))


class RunnerInterrupted(BaseException):
    """Raised from the SIGTERM/SIGINT handler so try/finally paths still run."""

    def __init__(self, signum: int):
        self.signum = signum
        self.code = {signal.SIGTERM: "RUNNER_SIGTERM", signal.SIGINT: "RUNNER_SIGINT"}.get(
            signum, f"RUNNER_SIGNAL_{signum}"
        )
        super().__init__(self.code)


def warn(code: str, detail: str = "") -> None:
    """A content-free warning on stderr (never forwarded to Burrow)."""
    sys.stderr.write(f"clip_runner: warning {code}" + (f" {detail}" if detail else "") + "\n")
    sys.stderr.flush()


# ── Job-tool client ─────────────────────────────────────────────────────


class JobClient(Protocol):
    """The five Burrow job tools (the claimer is always the calling agent), plus
    `request` for a call whose result the helper needs (file_add)."""

    def list_jobs(self, profile_id: str, status: str) -> list[dict]: ...

    def claim(self, job_id: str) -> dict: ...

    def progress(self, job_id: str, progress: float, eta_s: float | None = None) -> None: ...

    def complete(self, job_id: str, result: dict) -> None: ...

    def fail(self, job_id: str, error: str, code: str) -> None: ...

    def request(self, tool: str, args: dict, wait: Callable[[], None] | None = None) -> dict: ...


class OutboxClient:
    """The CLI's client: list_jobs reads a stdin snapshot, writes become JSONL lines.

    Claim is request/response, so the agent makes it itself (see `order`).
    `request` emits a line with "reply_file" and waits for the agent to write
    the tool's result there.
    """

    def __init__(
        self,
        out=None,
        snapshot: Iterable[dict] = (),
        outbox: Path | None = None,
        reply_dir: Path | None = None,
        reply_timeout_s: float = DEFAULT_REPLY_TIMEOUT_S,
    ):
        self.out = out or sys.stdout
        self.snapshot = list(snapshot)
        self.outbox = outbox
        self.reply_dir = reply_dir
        self.reply_timeout_s = reply_timeout_s
        self._seq = 0

    def list_jobs(self, profile_id: str, status: str) -> list[dict]:
        return [
            j
            for j in self.snapshot
            if j.get("status") == status and (profile_id is None or j.get("profile_id") == profile_id)
        ]

    def claim(self, job_id: str) -> dict:  # pragma: no cover - agent-side
        raise NotImplementedError("the agent claims with social_clip_job_claim")

    def _emit(self, tool: str, args: dict, extra: dict | None = None) -> None:
        line = json.dumps({"tool": tool, "args": args, **(extra or {})}, sort_keys=True)
        self.out.write(line + "\n")
        self.out.flush()
        if self.outbox is not None:
            self.outbox.parent.mkdir(parents=True, exist_ok=True)
            with self.outbox.open("a") as fh:
                fh.write(line + "\n")

    def progress(self, job_id: str, progress: float, eta_s: float | None = None) -> None:
        args: dict[str, Any] = {"job_id": job_id, "progress": progress}
        if eta_s is not None:
            args["eta_s"] = eta_s
        self._emit("social_clip_job_progress", args)

    def complete(self, job_id: str, result: dict) -> None:
        self._emit("social_clip_job_complete", {"job_id": job_id, **result})

    def fail(self, job_id: str, error: str, code: str) -> None:
        self._emit("social_clip_job_fail", {"job_id": job_id, "error": error, "code": code})

    def request(self, tool: str, args: dict, wait: Callable[[], None] | None = None) -> dict:
        if self.reply_dir is None:
            raise ClipError("REPLY_UNAVAILABLE", tool)
        self.reply_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.reply_dir.chmod(0o700)
        self._seq += 1
        reply = self.reply_dir / f"{os.getpid()}-{self._seq}-{tool}.json"
        with contextlib.suppress(FileNotFoundError):
            reply.unlink()
        try:
            self._emit(tool, args, {"reply_file": str(reply)})
            deadline = time.monotonic() + self.reply_timeout_s
            last_beat = time.monotonic()
            while time.monotonic() < deadline:
                if reply.exists():
                    try:
                        doc = json.loads(reply.read_text())
                    except ValueError:
                        time.sleep(0.1)  # agent mid-write
                        continue
                    reply.unlink()
                    if not isinstance(doc, dict):
                        raise ClipError("REPLY_INVALID", tool)
                    if doc.get("error") or doc.get("code"):
                        code = str(doc.get("code") or "REPLY_ERROR").upper()
                        raise ClipError(code if _CODE_RE.match(code) else "REPLY_ERROR", tool)
                    return doc
                if wait is not None and time.monotonic() - last_beat >= 20:
                    wait()
                    last_beat = time.monotonic()
                time.sleep(0.1)
            raise ClipError("REPLY_TIMEOUT", tool)
        finally:
            reply.unlink(missing_ok=True)
            reply.with_suffix(reply.suffix + ".tmp").unlink(missing_ok=True)



# ── Journal ─────────────────────────────────────────────────────────────


class Journal:
    """~/.clip-runner/jobs/<job_id>.json, written BEFORE every clip command."""

    def __init__(self, state_dir: Path):
        self.dir = Path(state_dir) / "jobs"

    def path(self, job_id: str) -> Path:
        if not _CODE_RE.match(job_id or ""):
            raise ValueError("bad job id")
        return self.dir / f"{job_id}.json"

    def write(self, job: dict, step: str) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        entry = {
            "job_id": job["id"],
            "kind": job.get("kind") or (job.get("payload") or {}).get("kind"),
            "profile_id": job.get("profile_id"),
            "step": step,
            "pid": os.getpid(),
            "at": time.time(),
        }
        tmp = self.path(job["id"]).with_suffix(".tmp")
        tmp.write_text(json.dumps(entry))
        os.replace(tmp, self.path(job["id"]))

    def read_all(self) -> list[dict]:
        if not self.dir.is_dir():
            return []
        entries = []
        for p in sorted(self.dir.glob("*.json")):
            try:
                entries.append(json.loads(p.read_text()))
            except (OSError, ValueError):
                entries.append({"job_id": p.stem, "step": "unknown"})
        return entries

    def clear(self, job_id: str) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.path(job_id).unlink()


class ClipMap:
    """~/.clip-runner/state.json: Burrow clip_id -> clip project + the tool's clip id.

    Ids and paths only (the project name is `burrow-<clip id>`, never a title).
    """

    def __init__(self, state_dir: Path):
        self.path = Path(state_dir) / "state.json"

    def _load(self) -> dict:
        try:
            doc = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {"clips": {}}
        return doc if isinstance(doc.get("clips"), dict) else {"clips": {}}

    def get(self, clip_id: str) -> dict | None:
        entry = self._load()["clips"].get(clip_id)
        return entry if isinstance(entry, dict) else None

    def put(self, clip_id: str, entry: dict) -> None:
        doc = self._load()
        doc["clips"][clip_id] = entry
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(doc, indent=1, sort_keys=True))
        os.replace(tmp, self.path)


@contextlib.contextmanager
def runner_lock(state_dir: Path):
    """One runner per state dir: reclaim must never fail a job a live `run` holds."""
    state_dir.mkdir(parents=True, exist_ok=True)
    fh = (state_dir / "runner.lock").open("w")
    try:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        fh.close()


# ── clip invocation ─────────────────────────────────────────────────────


def clip_error_code(stdout: str, returncode: int) -> str:
    """The clip tool's own error code from its --json output, else one from the exit."""
    try:
        doc = json.loads(stdout.strip().splitlines()[-1]) if stdout.strip() else None
    except (ValueError, IndexError):
        doc = None
    code = None
    if isinstance(doc, dict):
        err = doc.get("error")
        if isinstance(err, dict):
            code = err.get("code")
        code = code or doc.get("code") or doc.get("error_code")
    if isinstance(code, str) and _CODE_RE.match(code):
        return code
    if returncode < 0:
        return f"CLIP_SIGNAL_{-returncode}"
    return f"CLIP_EXIT_{returncode}"


def _parse_json(stdout: str) -> dict:
    text = stdout.strip()
    if not text:
        return {}
    for candidate in (text, text.splitlines()[-1]):
        try:
            doc = json.loads(candidate)
        except ValueError:
            continue
        return doc if isinstance(doc, dict) else {"value": doc}
    return {}


def _last_line(stdout: str) -> str:
    lines = [ln.strip() for ln in stdout.strip().splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def parse_version(text: Any) -> tuple[int, ...] | None:
    m = re.match(r"^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(text or ""))
    if not m:
        return None
    return tuple(int(x or 0) for x in m.groups())


# ── review.toml (start / end / decision of ONE entry; every other byte kept) ──


class ReviewEntry:
    def __init__(self, index: int, first: int, last: int, alternate: bool):
        self.index = index
        self.first = first  # line index of "[[clip]]"
        self.last = last  # exclusive
        self.alternate = alternate
        self.fields: dict[str, Any] = {}
        self.lines: dict[str, int] = {}
        self.file_stem: str | None = None

    @property
    def start(self) -> float | None:
        v = self.fields.get("start")
        return float(v) if isinstance(v, (int, float)) else None

    @property
    def end(self) -> float | None:
        v = self.fields.get("end")
        return float(v) if isinstance(v, (int, float)) else None


_FIELD_RE = re.compile(r"^(id|title|headline|decision|start|end|transcript|edl|captions|packaging)\s*=")
_FILE_RE = re.compile(r"^# file: (.+?) · rank ")


class ReviewFile:
    """A line-level view of clip's review.toml: `[[clip]]` tables, the ALTERNATES
    section after its marker. Edits replace whole `start`/`end`/`decision` lines of
    one table; nothing else is rewritten. The text is never printed or returned."""

    def __init__(self, text: str):
        self.lines = text.splitlines(keepends=True)
        self.entries: list[ReviewEntry] = []
        alternate = False
        current: ReviewEntry | None = None
        for i, raw in enumerate(self.lines):
            line = raw.rstrip("\r\n")
            if line.startswith("# ALTERNATES"):
                alternate = True
            if line.strip() == "[[clip]]":
                if current is not None:
                    current.last = i
                current = ReviewEntry(len(self.entries), i, len(self.lines), alternate)
                self.entries.append(current)
                continue
            if current is None:
                continue
            m = _FIELD_RE.match(line)
            if m and m.group(1) not in current.lines:
                try:
                    current.fields.update(tomllib.loads(line))
                except tomllib.TOMLDecodeError:
                    continue
                current.lines[m.group(1)] = i
                continue
            fm = _FILE_RE.match(line)
            if line.startswith('# transcript = ') and "transcript" not in current.lines:
                current.lines["transcript"] = i
            if line.startswith('# says: '):
                current.fields["said"] = line[len('# says: '):]
            if fm and current.file_stem is None and fm.group(1) != "(not cut)":
                current.file_stem = Path(fm.group(1)).stem

    def by_id(self, tool_id: str) -> ReviewEntry | None:
        for e in self.entries:
            if e.fields.get("id") == tool_id:
                return e
        return None

    def best_overlap(self, in_s: float, out_s: float) -> ReviewEntry | None:
        """The cut (non-alternate) clip that best overlaps [in_s, out_s]."""
        scored = []
        for e in self.entries:
            if e.alternate or e.start is None or e.end is None or not e.fields.get("id"):
                continue
            overlap = max(0.0, min(e.end, out_s) - max(e.start, in_s))
            distance = abs(e.start - in_s) + abs(e.end - out_s)
            scored.append((-overlap, distance, e.index, e))
        return min(scored)[3] if scored else None

    def set_fields(self, entry: ReviewEntry, **values: Any) -> None:
        for key, value in values.items():
            if key not in ("start", "end", "decision", "title", "transcript"):
                raise ValueError("only supported review fields are written")
            if key not in entry.lines:
                raise ClipError("REVIEW_FORMAT", "review_edit")
            i = entry.lines[key]
            raw = self.lines[i]
            ending = raw[len(raw.rstrip("\r\n")) :]
            text = json.dumps(value, ensure_ascii=True) if key in ("decision", "title", "transcript") else f"{float(value):.3f}"
            self.lines[i] = f"{key} = {text}{ending}"
            entry.fields[key] = value

    def text(self) -> str:
        return "".join(self.lines)


# ── Runner ──────────────────────────────────────────────────────────────

Hook = Callable[["Runner", dict], Any]


def _no_context(runner: Runner, job: dict) -> dict:
    return {}


class Runner:
    def __init__(
        self,
        client: JobClient,
        agent_id: str | None = None,
        state_dir: Path = DEFAULT_STATE_DIR,
        clip_bin: str = "clip",
        heartbeat_s: float = DEFAULT_HEARTBEAT_S,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        fetcher: Hook | None = None,
        uploader: Hook | None = None,
        context_for: Hook = _no_context,
        install_signal_handlers: bool = True,
    ):
        self.client = client
        self.agent_id = agent_id
        self.state_dir = Path(state_dir)
        self.journal = Journal(self.state_dir)
        self.clips = ClipMap(self.state_dir)
        self.clip_bin = clip_bin
        self.heartbeat_s = min(float(heartbeat_s), 60.0)
        self.timeout_s = float(timeout_s)
        self.fetcher = fetcher or fetch_episode
        self.uploader = uploader or upload_output
        self.context_for = context_for
        self.install_signal_handlers = install_signal_handlers
        self._job: dict | None = None
        self._progress = 0.0
        self._started = 0.0
        self.reset_job_state()

    def reset_job_state(self) -> None:
        self.context: dict = {}
        self.local = True  # fail closed until the privacy mode is read
        self.content_free = False  # CLIP_CONTENT_FREE: clip >= content_free 2
        self.clip_version: tuple[int, ...] | None = None
        self.headline_capability = False
        self.project_path: str | None = None
        self.output: Path | None = None
        self.review_entry: dict = {}

    # 1. startup reclaim ------------------------------------------------

    def startup_reclaim(self, profile_ids: Iterable[str | None]) -> list[str]:
        """Fail every job this agent left claimed/running, and every journalled job."""
        orphans: dict[str, str] = {}
        for profile_id in profile_ids:
            for status in ("claimed", "running"):
                for job in self.client.list_jobs(profile_id, status):
                    if self.agent_id and job.get("claimed_by_agent_id") == self.agent_id:
                        orphans.setdefault(job["id"], "unknown")
        for entry in self.journal.read_all():
            job_id = entry.get("job_id")
            if job_id:
                orphans[job_id] = entry.get("step") or "unknown"

        failed = []
        for job_id, step in orphans.items():
            try:
                self.client.fail(job_id, f"runner restarted mid-job; last step: {step}", "RUNNER_RESTARTED")
            except JobToolError:
                pass  # job_closed / not_claimer: nothing left to reclaim
            self._cleanup_orphan(job_id)
            self.journal.clear(job_id)
            failed.append(job_id)
        return failed

    def _cleanup_orphan(self, job_id: str) -> None:
        entry = next((e for e in self.journal.read_all() if e.get("job_id") == job_id), {})
        key = re.sub(r"[^a-z0-9-]", "-", str(job_id).lower())
        if not _CODE_RE.fullmatch(job_id):
            raise ClipError("BAD_PAYLOAD", "cleanup")
        folder = self.state_dir / "tmp" / ("closing-" + key)
        if folder.exists():
            for name in ("closing.video", "closing.part"):
                (folder / name).unlink(missing_ok=True)
            folder.rmdir()
        tmp = self.state_dir / "tmp"
        (tmp / "headline-request.json").unlink(missing_ok=True)
        music = tmp / "music"
        if music.is_dir():
            (music / "track.audio").unlink(missing_ok=True)
            (music / "track.part").unlink(missing_ok=True)
            music.rmdir()
        profile = entry.get("profile_id")
        if isinstance(profile, str) and _CODE_RE.fullmatch(profile):
            name = ("burrow-" + profile + "-job-" + key)[:120]
            _remove_profile(self, name)
            (self.state_dir / "tmp" / (name + ".toml")).unlink(missing_ok=True)
        # A reply can carry a signed URL. Reclaim runs under the existing state lock.
        replies = self.state_dir / "replies"
        if replies.is_dir():
            for reply in replies.iterdir():
                if reply.is_file() and re.fullmatch(r"[0-9]+-[0-9]+-[a-z_]+\.json(?:\.tmp)?", reply.name):
                    reply.unlink()

    # 2. poll -----------------------------------------------------------

    @staticmethod
    def claim_order(jobs: Iterable[dict]) -> list[dict]:
        queued = [j for j in jobs if j.get("status", "queued") == "queued"]
        return sorted(queued, key=lambda j: (j.get("inserted_at") or "", j.get("id") or ""))

    def poll_once(self, profile_ids: Iterable[str | None]) -> dict | None:
        """Claim the oldest queued job that nobody else wins, run it; None when idle."""
        queued: list[dict] = []
        for profile_id in profile_ids:
            queued.extend(self.client.list_jobs(profile_id, "queued"))
        for job in self.claim_order(queued):
            try:
                claimed = self.client.claim(job["id"])
            except AlreadyClaimed:
                continue
            return self.run_job(claimed or job)
        return None

    # 3-5. dispatch, progress, finish -----------------------------------

    def run_job(self, job: dict, context: dict | None = None) -> dict:
        job_id = job["id"]
        kind = job.get("kind") or (job.get("payload") or {}).get("kind")
        self._job, self._progress, self._started = job, 0.0, time.monotonic()
        self.reset_job_state()
        self.journal.write(job, "claimed")
        previous = self._install_handlers()
        terminal_sent = False
        outcome: dict = {"job_id": job_id, "kind": kind}
        try:
            try:
                self.context = dict(context if context is not None else self.context_for(self, job) or {})
                handler = HANDLERS.get(kind)
                if handler is None:
                    raise ClipError("UNKNOWN_KIND", "dispatch")
                result = handler(self, job)
                self.journal.write(job, "complete")
                self.client.complete(job_id, finish_result(result, local=self.local))
                terminal_sent = True
                outcome.update(status="done")
            except ClipError as exc:
                code, message = exc.code, str(exc)
            except JobToolError as exc:
                code, message = exc.code.upper(), "job tool refused the result"
            except RunnerInterrupted as exc:
                code, message = exc.code, f"runner stopped by signal during {self._step()}"
            except Exception as exc:
                code, message = "RUNNER_EXCEPTION", f"{type(exc).__name__} during {self._step()}"
            if not terminal_sent:
                self.client.fail(job_id, message, code)
                terminal_sent = True
                outcome.update(status="failed", code=code)
        finally:
            self._restore_handlers(previous)
            if terminal_sent:
                self.journal.clear(job_id)
            self._job = None
        return outcome

    def _step(self) -> str:
        entries = [e for e in self.journal.read_all() if self._job and e.get("job_id") == self._job["id"]]
        return entries[0].get("step", "unknown") if entries else "unknown"

    def _install_handlers(self):
        if not self.install_signal_handlers:
            return None

        def raise_interrupt(signum, _frame):
            raise RunnerInterrupted(signum)

        try:
            return {s: signal.signal(s, raise_interrupt) for s in (signal.SIGTERM, signal.SIGINT)}
        except ValueError:  # not the main thread
            return None

    @staticmethod
    def _restore_handlers(previous) -> None:
        for s, h in (previous or {}).items():
            signal.signal(s, h)

    def report(self, fraction: float) -> None:
        """Progress at a step boundary (also used by the heartbeat)."""
        if self._job is None:
            return
        self._progress = max(self._progress, min(max(fraction, 0.0), 0.99))
        eta = None
        elapsed = time.monotonic() - self._started
        if self._progress > 0.0:
            eta = round(elapsed * (1.0 - self._progress) / self._progress)
        try:
            self.client.progress(self._job["id"], round(self._progress, 3), eta)
        except JobToolError:
            pass  # a refused progress must not abort a render

    def heartbeat(self) -> None:
        self.report(self._progress)

    def clip(
        self,
        step: str,
        args: list[str],
        fraction: float | None = None,
        env: dict | None = None,
        raw: bool = False,
    ) -> Any:
        """Run one `clip` command: journal first, heartbeat while it runs, parse --json.

        Local privacy mode (and every call before the mode is known) adds
        CLIP_NO_CONTENT=1. stderr is discarded; stdout is parsed, never printed.
        """
        job = self._job
        if job is not None:
            self.journal.write(job, step)
        proc_env = dict(os.environ)
        proc_env.pop("CLIP_RUNNER_TOKEN", None)  # clip never needs the agent token
        for key in ("BURROW_TOKEN", "BURROW_API_TOKEN", "CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"):
            proc_env.pop(key, None)
        proc_env.pop("CLIP_NO_CONTENT", None)
        proc_env["CLIP_NO_CONTENT"] = "1"
        proc_env.update(env or {})
        deadline = time.monotonic() + self.timeout_s
        try:
            proc = subprocess.Popen(
                [self.clip_bin, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                env=proc_env,
                text=True,
                umask=0o077,
            )
        except FileNotFoundError as exc:
            raise ClipError("CLIP_NOT_INSTALLED", step) from exc
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    proc.kill()
                    proc.communicate()
                    raise ClipError("CLIP_TIMEOUT", step)
                try:
                    stdout, _ = proc.communicate(timeout=min(self.heartbeat_s, remaining))
                    break
                except subprocess.TimeoutExpired:
                    self.heartbeat()
        except BaseException:
            if proc.poll() is None:
                proc.kill()
                with contextlib.suppress(Exception):
                    proc.communicate(timeout=5)
            raise
        if proc.returncode != 0:
            raise ClipError(clip_error_code(stdout, proc.returncode), step, f"exit {proc.returncode}")
        if fraction is not None:
            self.report(fraction)
        return stdout if raw else _parse_json(stdout)

    def project_name(self, job: dict) -> str:
        """The clip project NAME for a Burrow clip (clip keeps projects under its clips folder)."""
        key = job.get("clip_id") or (job.get("payload") or {}).get("clip_id") or job["id"]
        if not _CODE_RE.match(key):
            raise ClipError("BAD_PAYLOAD", "dispatch")
        name = "burrow-" + re.sub(r"[^a-z0-9-]", "-", key.lower())
        return name[:120]

    def tmp_dir(self) -> Path:
        d = self.state_dir / "tmp"
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        d.chmod(0o700)
        return d


def finish_result(result: dict | None, local: bool = False) -> dict:
    """Only ClipJobs.result_keys; source_label defaults to the clip tool.

    Local privacy mode: title, caption, speaker and episode_code are null and
    nothing else but ids, numbers and the source label survives.
    """
    out = {k: v for k, v in (result or {}).items() if k in RESULT_KEYS}
    if local:
        out = {k: v for k, v in out.items() if k not in META_KEYS and k != "platforms"}
        out.update(dict.fromkeys(META_KEYS))
    out.setdefault("source_label", SOURCE_LABEL)
    return out


# ── Episode fetch and upload (the helper's only non-clip I/O) ─────────────


def _download(url: str, dest: Path, step: str) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, tmp.open("wb") as fh:
            shutil.copyfileobj(resp, fh, 1 << 20)
    except urllib.error.HTTPError as exc:
        tmp.unlink(missing_ok=True)
        raise ClipError(f"FETCH_HTTP_{exc.code}", step) from None
    except (urllib.error.URLError, OSError, ValueError):
        tmp.unlink(missing_ok=True)
        raise ClipError("FETCH_FAILED", step) from None
    os.replace(tmp, dest)


def fetch_episode(runner: Runner, job: dict) -> str:
    """The episode as a local file named by id/hash (never by title).

    context.episode_path (a file the agent already has), else context.episode_url
    (a signed download URL for payload.episode.source_file_id), else
    payload.episode.source_url via yt-dlp (or a direct media URL). Cached under
    <state>/episodes so a re-render does not fetch again.
    """
    payload = job.get("payload") or {}
    episode = payload.get("episode") or {}
    ctx = runner.context
    if ctx.get("episode_path"):
        p = Path(ctx["episode_path"]).expanduser()
        if not p.is_file():
            raise ClipError("SOURCE_MISSING", "fetch")
        return str(p)
    file_id = episode.get("source_file_id")
    url = episode.get("source_url")
    if file_id:
        key = "file-" + re.sub(r"[^A-Za-z0-9-]", "", str(file_id))[:64]
    elif url:
        key = "url-" + hashlib.sha256(str(url).encode()).hexdigest()[:24]
    else:
        raise ClipError("SOURCE_UNAVAILABLE", "fetch")
    folder = runner.state_dir / "episodes"
    folder.mkdir(parents=True, exist_ok=True)
    cached = sorted(p for p in folder.glob(key + ".*") if not p.name.endswith(".part"))
    if cached:
        return str(cached[0])
    runner.journal.write(job, "fetch")
    if file_id:
        if not ctx.get("episode_url"):
            raise ClipError("SOURCE_FILE_NO_DOWNLOAD", "fetch")
        dest = folder / f"{key}.mp4"
        _download(ctx["episode_url"], dest, "fetch")
        return str(dest)
    ytdlp = os.environ.get("CLIP_RUNNER_YTDLP") or shutil.which("yt-dlp")
    if ytdlp:
        proc = subprocess.run(
            [
                ytdlp,
                "--quiet",
                "--no-progress",
                "--no-playlist",
                "-f",
                "mp4/best",
                "-o",
                str(folder / f"{key}.%(ext)s"),
                url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            check=False,
            timeout=runner.timeout_s,
        )
        got = sorted(p for p in folder.glob(key + ".*") if not p.name.endswith(".part"))
        if proc.returncode != 0 or not got:
            raise ClipError(f"FETCH_YTDLP_EXIT_{proc.returncode}", "fetch")
        return str(got[0])
    ext = Path(urllib.parse.urlparse(str(url)).path).suffix.lower()
    if ext in (".mp4", ".mov", ".m4v", ".mkv", ".webm") and str(url).startswith(("http://", "https://")):
        dest = folder / f"{key}{ext}"
        _download(str(url), dest, "fetch")
        return str(dest)
    raise ClipError("SOURCE_NEEDS_YTDLP", "fetch")


def upload_output(runner: Runner, job: dict) -> str:
    """Presigned upload of runner.output into the Burrow profile's project Files.

    1. request file_add (byte_size) through the agent; 2. POST the bytes with the
    agent bearer token (env, never logged) to the base URL; 3. check the hash.
    """
    path = runner.output
    if path is None or not path.is_file():
        raise ClipError("OUTPUT_MISSING", "upload")
    project_id = runner.context.get("project_id")
    token = os.environ.get("CLIP_RUNNER_TOKEN")
    base = (os.environ.get("CLIP_RUNNER_BASE_URL") or "").rstrip("/")
    secure = base.startswith("https://") or base.startswith("http://127.0.0.1")
    if not project_id or not token or not secure:
        raise ClipError("UPLOAD_UNAVAILABLE", "upload")
    size = path.stat().st_size
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    sha = digest.hexdigest()
    payload = job.get("payload") or {}
    clip_key = re.sub(r"[^A-Za-z0-9-]", "", str(job.get("clip_id") or payload.get("clip_id") or job["id"]))
    rev = payload.get("expected_rev")
    filename = f"clip-{clip_key}-r{rev}.mp4" if isinstance(rev, int) else f"clip-{clip_key}.mp4"
    runner.journal.write(job, "file_add")
    reply = runner.client.request(
        "file_add",
        {"project_id": project_id, "filename": filename, "content_type": "video/mp4", "byte_size": size},
        wait=runner.heartbeat,
    )
    upload_url = reply.get("upload_url")
    file_id = reply.get("id") or reply.get("file_id")
    if not upload_url or not file_id:
        raise ClipError("UPLOAD_NO_URL", "file_add")
    url = upload_url if "://" in upload_url else base + upload_url
    if not url.startswith(base + "/"):
        raise ClipError("UPLOAD_HOST_MISMATCH", "upload")  # the token goes to the base URL only
    runner.journal.write(job, "upload")
    with path.open("rb") as fh:
        req = urllib.request.Request(
            url,
            data=fh,
            method="POST",
            headers={
                "Content-Type": "video/mp4",
                "Content-Length": str(size),
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                body = resp.read()
        except urllib.error.HTTPError as exc:
            raise ClipError(f"UPLOAD_HTTP_{exc.code}", "upload") from None
        except (urllib.error.URLError, OSError):
            raise ClipError("UPLOAD_FAILED", "upload") from None
    try:
        doc = json.loads(body or b"{}")
    except ValueError:
        doc = {}
    got = doc.get("content_hash") if isinstance(doc, dict) else None
    if got and got.lower() != sha:
        raise ClipError("UPLOAD_HASH_MISMATCH", "upload")
    runner.report(0.97)
    return str(doc.get("id") or file_id) if isinstance(doc, dict) else str(file_id)


# ── Preflight, privacy, profiles ─────────────────────────────────────────


def _preflight(runner: Runner) -> None:
    info = runner.clip("version", ["version", "--json"])
    version = parse_version(info.get("version"))
    if version is None:
        raise ClipError("CLIP_VERSION_UNKNOWN", "version")
    if version < MIN_CLIP_VERSION:
        raise ClipError("CLIP_TOO_OLD", "version", ".".join(map(str, version)))
    runner.clip_version = version
    runner.headline_capability = type(info.get("headline_review")) is int and info["headline_review"] == 1
    cf = info.get("content_free")
    runner.content_free = isinstance(cf, int) and not isinstance(cf, bool) and cf >= MIN_CONTENT_FREE
    doctor = runner.clip("doctor", ["doctor", "--json"], fraction=0.05)
    code = None
    if doctor.get("ok") is False:
        code = doctor.get("code") or (doctor.get("error") or {}).get("code") or "CLIP_DOCTOR"
    summary = doctor.get("summary") if isinstance(doctor.get("summary"), dict) else {}
    if code is None and isinstance(summary.get("fix"), int) and summary["fix"] > 0:
        failing = [c.get("check") for c in doctor.get("checks") or [] if c.get("status") == "fix"]
        names = ",".join(n for n in failing if isinstance(n, str) and _CODE_RE.match(n))
        raise ClipError("CLIP_DOCTOR_FIX", "doctor", names)
    if code is not None:
        raise ClipError(code if _CODE_RE.match(str(code)) else "CLIP_DOCTOR", "doctor")


def _is_local(mode: Any, inferred: Any) -> bool:
    """preflight.sh semantics: only an explicit "cloud" counts as cloud; a mode
    inferred from the AI backend, or anything unreadable, is local."""
    return not (mode == "cloud" and inferred in (False, 0, "false", "0", None))


def _project_info(runner: Runner, project: str, fraction: float) -> dict:
    info = runner.clip("project_info", ["project", "info", "--json", project], fraction=fraction)
    path = info.get("path")
    if not isinstance(path, str) or not Path(path).is_dir():
        raise ClipError("PROJECT_NOT_FOUND", "project_info")
    runner.local = _is_local(info.get("privacy_mode"), info.get("privacy_mode_inferred"))
    runner.project_path = path
    return info


def _profile_privacy(runner: Runner, profile: str) -> None:
    """No project yet: the mode the profile would process with (clip config get)."""
    mode = _last_line(
        runner.clip("config_get", ["config", "get", "effective_privacy_mode", "--profile", profile], raw=True)
    )
    explicit = _last_line(
        runner.clip("config_get", ["config", "get", "privacy.mode", "--profile", profile], raw=True)
    )
    runner.local = _is_local(mode, explicit not in ("local", "cloud"))


def _check_profile_name(name: Any) -> str:
    if not isinstance(name, str) or not _PROFILE_RE.match(name) or name == BASE_PROFILE:
        raise ClipError("BAD_PAYLOAD", "dispatch")
    return name


def _toml_value(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    raise ValueError("unsupported look value")


def profile_toml(extends: str, mapped: dict) -> str:
    """A user profile: `extends` plus the mapped clip keys ("captions.size_frac" -> [captions] size_frac)."""
    sections: dict[str, dict] = {}
    for key, value in sorted((mapped or {}).items()):
        if not _LOOK_KEY_RE.match(str(key)):
            raise ClipError("LOOK_KEY_INVALID", "profile")
        section, name = key.split(".", 1)
        try:
            _toml_value(value)
        except ValueError:
            raise ClipError("LOOK_VALUE_INVALID", "profile") from None
        sections.setdefault(section, {})[name] = value
    out = [f"extends = {json.dumps(extends)}", ""]
    for section, values in sections.items():
        out.append(f"[{section}]")
        out += [f"{k} = {_toml_value(v)}" for k, v in values.items()]
        out.append("")
    text = "\n".join(out)
    tomllib.loads(text)  # must parse
    return text


def _overrides(payload: dict) -> dict:
    co = payload.get("clip_overrides") or {}
    unmapped = co.get("unmapped") or []
    if unmapped:
        keys = ",".join(k for k in unmapped if isinstance(k, str) and _CODE_RE.match(k))
        warn("LOOK_KEYS_UNMAPPED", keys)
    mapped = co.get("mapped") or {}
    return mapped if isinstance(mapped, dict) else {}


def _import_profile(runner: Runner, name: str, extends: str, mapped: dict, step: str) -> None:
    src = runner.tmp_dir() / f"{name}.toml"
    with open(src, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as fh:
        fh.write(profile_toml(extends, mapped))
    src.chmod(0o600)
    try:
        runner.clip(step, ["profile", "import", str(src), "--name", name, "--force", "--yes"])
    finally:
        src.unlink(missing_ok=True)


def _ensure_user_profile(runner: Runner, profile: str) -> None:
    """burrow-<profile id> exists before a render (a profile that never saved a default)."""
    try:
        runner.clip("profile_path", ["profile", "path", profile], raw=True)
        return
    except ClipError:
        pass
    _import_profile(runner, profile, BASE_PROFILE, {}, "profile_import")


def _remove_profile(runner: Runner, name: str, required: bool = False) -> None:
    """Delete a per-job derived profile (clip has no `profile delete`): resolve its file with
    `clip profile path` and unlink it only if it is that user profile, never a built-in."""
    if "-job-" not in name or not name.startswith("burrow-"):
        raise ValueError("only derived profiles are removed")
    try:
        out = runner.clip("profile_remove", ["profile", "path", name], raw=True)
    except ClipError:
        if required:
            raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup") from None
        return  # never created
    path = Path(_last_line(out))
    if path.name != f"{name}.toml" or "clip_agent" in path.parts or path.stem == BASE_PROFILE:
        raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup")
    path.unlink(missing_ok=True)


@contextlib.contextmanager
def derived_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """`burrow-<profile id>-job-<job id>` extending the user profile, for this render only.
    Removed afterwards on every path (success, failure, signal)."""
    if not mapped:
        yield None
        return
    job_key = re.sub(r"[^a-z0-9-]", "-", str(job["id"]).lower())
    name = f"{base}-job-{job_key}"[:120]
    created = False
    try:
        _import_profile(runner, name, base, mapped, "profile_derive")
        created = True
        yield name
    finally:
        try:
            _remove_profile(runner, name, required=created)
        except Exception:
            raise ClipError("PROFILE_CLEANUP_FAILED", "profile_cleanup") from None


# ── review.toml + render ────────────────────────────────────────────────


def _edit_review(runner: Runner, job: dict, project: Path, tool_id: str | None) -> str:
    """Edit only the target review entry through supported fields; preserve its base hashes."""
    payload = job.get("payload") or {}
    path = project / "review.toml"
    try:
        review = ReviewFile(path.read_text())
    except OSError:
        raise ClipError("REVIEW_MISSING", "review_edit") from None
    in_s, out_s = payload.get("in_s"), payload.get("out_s")
    entry = review.by_id(tool_id) if tool_id else None
    if entry is None and tool_id and (payload.get("fix") or payload.get("appearance")):
        raise ClipError("BASE_CANDIDATE_MISSING", "review_edit")
    if entry is None:
        if not isinstance(in_s, (int, float)) or not isinstance(out_s, (int, float)):
            raise ClipError("BAD_PAYLOAD", "review_edit")
        entry = review.best_overlap(float(in_s), float(out_s))
    if entry is None:
        raise ClipError("NO_CANDIDATE", "review_edit")
    fix = payload.get("fix") or {}
    operation = fix.get("operation")
    if operation == "alternate_cut":
        eligible = [e for e in review.entries if e.alternate and e.fields.get("id") != tool_id
                    and e.start is not None and e.end is not None and e.end > e.start]
        if not eligible:
            raise ClipError("NO_ALTERNATE", "review_edit")
        entry = eligible[0]
        in_s, out_s = entry.start, entry.end
    elif entry.alternate:
        raise ClipError("CANDIDATE_NOT_CUT", "review_edit")
    if fix:
        if operation not in ("nudge", "caption_word", "regenerate_headline", "alternate_cut"):
            raise ClipError("UNSUPPORTED_FIX", "review_edit")
        if any(not entry.fields.get(k) for k in ("edl", "captions", "packaging")):
            raise ClipError("REVIEW_CONTRACT_UNSUPPORTED", "review_edit")

    values: dict[str, Any] = {"decision": "approve"}
    if isinstance(in_s, (int, float)):
        values["start"] = float(in_s)
    if isinstance(out_s, (int, float)):
        values["end"] = float(out_s)
    if operation == "caption_word":
        correction = fix.get("caption_fixes") or {}
        text = entry.fields.get("transcript") or entry.fields.get("said")
        if not isinstance(text, str) or text.endswith("…"):
            raise ClipError("CAPTION_CONTRACT_UNSUPPORTED", "review_edit")
        words = text.split()
        pos = correction.get("position")
        if type(pos) is not int or pos < 0 or pos >= len(words) or words[pos] != correction.get("original"):
            raise ClipError("STALE_CAPTION_WORD", "review_edit")
        replacement = correction.get("replacement")
        if not isinstance(replacement, str) or not replacement or len(replacement.split()) != 1:
            raise ClipError("BAD_CAPTION_WORD", "review_edit")
        words[pos] = replacement
        values["transcript"] = " ".join(words)
    review.set_fields(entry, **values)
    runner.journal.write(job, "review_edit")
    tmp = path.with_suffix(".toml.tmp")
    tmp.write_text(review.text())
    os.replace(tmp, path)
    runner.review_entry = {
        "id": entry.fields.get("id"),
        "file_stem": entry.file_stem,
        "title": entry.fields.get("title"),
        "start": entry.start,
        "end": entry.end,
        "alternate": entry.alternate,
    }
    return str(entry.fields["id"])


def _find_output(runner: Runner, project: Path) -> Path:
    final = project / "final"
    stem = runner.review_entry.get("file_stem")
    if stem and (final / f"{stem}.mp4").is_file():
        return final / f"{stem}.mp4"
    videos = [p for p in final.glob("*.mp4") if not p.stem.endswith("_clean")] if final.is_dir() else []
    if not videos:
        raise ClipError("OUTPUT_MISSING", "finalize")
    return max(videos, key=lambda p: p.stat().st_mtime)


def _headline_intent(job: dict) -> str | None:
    payload = job.get("payload") or {}
    explicit = payload.get("headline")
    if explicit is not None:
        if not isinstance(explicit, dict) or explicit.get("consumer") not in ("edit", "episode", "regenerate"):
            raise ClipError("HEADLINE_REQUEST_UNSUPPORTED", "headline")
        return explicit["consumer"]
    if (payload.get("fix") or {}).get("operation") == "regenerate_headline":
        return "regenerate"
    return "episode" if job.get("kind") == "new_clip" else None


def _headline_request(runner: Runner, job: dict, consumer: str) -> dict:
    if not runner.headline_capability:
        raise ClipError("HEADLINE_CLI_UNSUPPORTED", "headline")
    payload = job.get("payload") or {}
    options = payload.get("headline") or {}
    if options.get("export_text"):
        raise ClipError("HEADLINE_PRIVACY_EXPORT_REFUSED", "headline")
    voice = runner.context.get("headline_voice")
    if not isinstance(voice, dict) or not all(isinstance(voice.get(k), str) and voice[k].strip()
                                             for k in ("revision", "direction")):
        raise ClipError("HEADLINE_VOICE_MISSING", "headline")
    base = payload.get("base_render_id")
    if consumer != "episode":
        if not isinstance(base, str) or not base:
            raise ClipError("HEADLINE_BASE_MISSING", "headline")
        if base != runner.context.get("base_render_id"):
            raise ClipError("HEADLINE_BASE_STALE", "headline")
    source_id = payload.get("source_id") or (payload.get("episode") or {}).get("source_file_id")
    if source_id is None:
        url = (payload.get("episode") or {}).get("source_url")
        if isinstance(url, str) and url:
            source_id = "url-" + hashlib.sha256(url.encode()).hexdigest()
    if not isinstance(source_id, str) or not source_id:
        raise ClipError("HEADLINE_SOURCE_MISSING", "headline")
    requested = options.get("requested_headline")
    if consumer == "edit" and (not isinstance(requested, str) or not requested.strip()):
        raise ClipError("HEADLINE_EMPTY", "headline")
    if consumer != "edit" and requested is not None:
        raise ClipError("HEADLINE_REQUEST_UNSUPPORTED", "headline")
    return {"version": 1, "consumer": consumer, "candidate_id": runner.review_entry["id"],
            "source": {"id": source_id, "start": runner.review_entry["start"],
                       "end": runner.review_entry["end"]},
            "voice": voice, "base_render_id": base,
            "requested_headline": requested, "export_text": False}


def _headline_receipt(receipt: dict, request: dict, status: str) -> None:
    expected = {"version": 1, "candidate_id": request["candidate_id"],
                "source_id": request["source"]["id"], "start": request["source"]["start"],
                "end": request["source"]["end"], "voice_revision": request["voice"]["revision"],
                "base_render_id": request["base_render_id"], "status": status, "backed": True}
    if (not isinstance(receipt, dict) or type(receipt.get("version")) is not int
            or receipt.get("backed") is not True or receipt != expected):
        raise ClipError("HEADLINE_OUTPUT_UNSUPPORTED", "headline")


def _apply_headline(runner: Runner, job: dict, project: Path, profile: str, consumer: str) -> dict:
    request = _headline_request(runner, job, consumer)
    path = runner.tmp_dir() / "headline-request.json"
    # O_EXCL avoids symlink following; a crash-left file is safely replaced by
    # unlinking only this private request under the existing runner lock.
    path.unlink(missing_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(request, stream)
        args = ["hooks", "prepare-review", str(project), "--request", str(path), "--profile", profile]
        prepared = runner.clip("headline_prepare", args, fraction=0.75)
        _headline_receipt(prepared, request, "prepared")
        entry = ReviewFile((project / "review.toml").read_text()).by_id(request["candidate_id"])
        if not entry or not isinstance(entry.fields.get("headline"), str) or not entry.fields["headline"].strip():
            raise ClipError("HEADLINE_OUTPUT_UNSUPPORTED", "headline")
        if consumer == "edit" and entry.fields["headline"] != " ".join(request["requested_headline"].split()):
            raise ClipError("HEADLINE_APPLIED_MISMATCH", "headline")
        runner.clip("headline_apply", ["review", str(project), "--apply", "--profile", profile], fraction=0.78)
        receipt = runner.clip("headline_verify", [*args, "--check-applied"], fraction=0.8)
        _headline_receipt(receipt, request, "applied")
        return receipt
    finally:
        path.unlink(missing_ok=True)


@contextlib.contextmanager
def music_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """Resolve only the selected persisted asset, into a private disposable profile.
    URLs never enter clip argv/environment, logs, context or durable runner state.
    """
    music = (job.get("payload") or {}).get("music")
    mapped = dict(mapped)
    if music is None:  # legacy jobs retain their previous behavior
        yield mapped
        return
    enabled = music.get("enabled") is True
    gain = music.get("level_db")
    if type(gain) not in (int, float) or not -60 <= gain <= 0:
        raise ClipError("MUSIC_GAIN_INVALID", "music")
    try:
        supported = _last_line(runner.clip("music_capability", ["config", "get", "music.enabled", "--profile", base], raw=True)).lower() in ("true", "false")
    except ClipError:
        supported = False
    if not supported:
        if enabled:
            raise ClipError("MUSIC_CLI_UNSUPPORTED", "music")
        yield {k: v for k, v in mapped.items() if not k.startswith("music.")}
        return
    mapped.update({"music.enabled": enabled, "music.level_db": gain, "music.path": ""})
    if not enabled:
        yield mapped
        return
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"], "asset": "music"}, wait=runner.heartbeat)
    if (not isinstance(source, dict) or source.get("file_id") != music.get("file_id") or
        source.get("project_id") != runner.context.get("project_id") or
        source.get("content_type") not in ("audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav", "audio/mp4", "audio/ogg", "audio/flac") or
        type(source.get("byte_size")) is not int or not 0 < source["byte_size"] <= 25 * 1024 * 1024):
        raise ClipError("MUSIC_ASSET_INVALID", "music")
    url = source.get("url")
    if not isinstance(url, str) or urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ClipError("MUSIC_URL_INVALID", "music")
    folder = runner.tmp_dir() / "music"
    folder.mkdir(mode=0o700, exist_ok=True)
    folder.chmod(0o700)
    path = folder / "track.audio"
    part = folder / "track.part"
    try:
        try:
            with urllib.request.urlopen(url, timeout=120) as response, part.open("wb") as output:
                part.chmod(0o600)
                remaining = source["byte_size"]
                while chunk := response.read(min(1 << 20, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ClipError("MUSIC_DOWNLOAD_SIZE", "music")
                    output.write(chunk)
                if remaining != 0:
                    raise ClipError("MUSIC_DOWNLOAD_SIZE", "music")
            os.replace(part, path)
        except (urllib.error.URLError, OSError, ValueError):
            raise ClipError("MUSIC_DOWNLOAD_FAILED", "music") from None
        mapped["music.path"] = str(path)
        yield mapped
    finally:
        path.unlink(missing_ok=True)
        part.unlink(missing_ok=True)
        folder.rmdir()



class _MediaRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _media_url(newurl)
        # Build a fresh credential-free request rather than forwarding headers.
        return urllib.request.Request(newurl)


def _media_url(url):
    if not isinstance(url, str):
        raise ClipError("CLOSING_URL_INVALID", "closing_video")
    try:
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
            raise ValueError()
        if u.scheme == "http" and u.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError()
    except ValueError:
        raise ClipError("CLOSING_URL_INVALID", "closing_video") from None
    return url


@contextlib.contextmanager
def closing_profile(runner: Runner, job: dict, base: str, mapped: dict):
    """Pinned video only, one disposable profile, never a rendered output as source.
    The server contract owns the byte cap; it must match this protocol revision.
    Absent legacy contracts mean disabled, explicitly clearing inherited outro.
    """
    closing = (job.get("payload") or {}).get("closing_video")
    if closing is not None and (not isinstance(closing, dict) or
            type(closing.get("enabled")) is not bool or closing.get("audio") not in ("keep", "mute")):
        raise ClipError("CLOSING_CONTRACT_INVALID", "closing_video")
    closing = closing or {"enabled": False, "audio": "mute"}
    mapped = {k: v for k, v in mapped.items() if not k.startswith("outro.")}
    enabled = closing["enabled"]
    if enabled and ((closing.get("profile_id") is not None and closing["profile_id"] != job.get("profile_id")) or
            (runner.context.get("org_id") is not None and closing.get("org_id") != runner.context["org_id"])):
        raise ClipError("CLOSING_ASSET_INVALID", "closing_video")
    try:
        supported = _last_line(runner.clip("closing_capability", ["config", "get", "outro.audio", "--profile", base], raw=True)) in ("keep", "mute")
    except ClipError:
        supported = False
    if not supported:
        if enabled:
            raise ClipError("CLOSING_CLI_UNSUPPORTED", "closing_video")
        yield mapped
        return
    try:
        runner.clip("closing_path_capability", ["config", "get", "outro.path", "--profile", base], raw=True)
    except ClipError:
        raise ClipError("CLOSING_CLI_UNSUPPORTED", "closing_video") from None
    mapped.update({"outro.path": "", "outro.audio": closing["audio"]})
    if not enabled:
        yield mapped
        return
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"], "asset": "closing_video"}, wait=runner.heartbeat)
    cap = source.get("max_bytes") if isinstance(source, dict) else None
    if (not isinstance(source, dict) or type(cap) is not int or cap <= 0 or
        source.get("file_id") != closing.get("file_id") or not closing.get("file_id") or
        source.get("project_id") != runner.context.get("project_id") or
        source.get("project_id") != closing.get("project_id") or
        source.get("content_type") != closing.get("content_type") or
        source.get("content_type") not in ("video/mp4", "video/quicktime", "video/webm") or
        type(source.get("byte_size")) is not int or not 0 < source["byte_size"] <= cap or
        source.get("byte_size") != closing.get("byte_size") or
        not isinstance(source.get("content_hash"), str) or
        not re.fullmatch(r"[0-9a-f]{64}", source["content_hash"]) or
        source.get("content_hash") != closing.get("content_hash")):
        raise ClipError("CLOSING_ASSET_INVALID", "closing_video")
    url = _media_url(source.get("url"))
    key = re.sub(r"[^a-z0-9-]", "-", str(job["id"]).lower())
    folder = runner.tmp_dir() / ("closing-" + key)
    folder.mkdir(mode=0o700, exist_ok=True)
    folder.chmod(0o700)
    path, part = folder / "closing.video", folder / "closing.part"
    try:
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _MediaRedirect())
            with opener.open(url, timeout=120) as response, open(part, "wb", opener=lambda p, flags: os.open(p, flags | os.O_NOFOLLOW, 0o600)) as output:
                part.chmod(0o600)
                remaining = source["byte_size"]
                digest = hashlib.sha256()
                while chunk := response.read(min(1 << 20, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ClipError("CLOSING_DOWNLOAD_SIZE", "closing_video")
                    digest.update(chunk)
                    output.write(chunk)
                    runner.heartbeat()
                if remaining != 0:
                    raise ClipError("CLOSING_DOWNLOAD_SIZE", "closing_video")
                if digest.hexdigest() != source["content_hash"]:
                    raise ClipError("CLOSING_HASH_MISMATCH", "closing_video")
            os.replace(part, path)
        except (urllib.error.URLError, OSError, ValueError):
            raise ClipError("CLOSING_DOWNLOAD_FAILED", "closing_video") from None
        # Real-video probing already happened twice in Core; the supported CLI's
        # finish_for decodes/probes again before rendering and fails closed.
        mapped["outro.path"] = str(path)
        yield mapped
    finally:
        try:
            path.unlink(missing_ok=True)
            part.unlink(missing_ok=True)
            folder.rmdir()
        except OSError:
            raise ClipError("CLOSING_CLEANUP_FAILED", "closing_cleanup") from None

def _render(runner: Runner, job: dict, project: Path, tool_id: str | None, regenerate: bool) -> dict:
    payload = job.get("payload") or {}
    base = _check_profile_name(payload.get("clip_user_profile"))
    runner.clip("review", ["review", str(project), "--overwrite"], fraction=0.55)
    tool_id = _edit_review(runner, job, project, tool_id)
    clip_id = job.get("clip_id") or payload.get("clip_id")
    runner.clips.put(
        clip_id,
        {
            "project": project.name,
            "path": str(project),
            "tool_clip_id": tool_id,
            "profile_id": job.get("profile_id"),
        },
    )
    consumer = _headline_intent(job)
    appearance = payload.get("appearance") is True
    mapped = dict(_overrides(payload))
    explicit_style = ((payload.get("look") or {}).get("cap") or {}).get("style")
    if explicit_style is not None:
        mapped["captions.style"] = explicit_style
    if consumer:
        mapped["captions.hook_title"] = True
        style = mapped.get("captions.style")
        if style is None:
            style = _last_line(runner.clip("caption_style", ["config", "get", "captions.style", "--profile", base], raw=True))
        if style not in ("none", *CAPTION_STYLES):
            raise ClipError("HEADLINE_CAPTION_STYLE_UNSUPPORTED", "headline")
        mapped["captions.style"] = "phrase-pop" if style == "none" else style
    if appearance or "captions.style" in mapped:
        _qualify_caption_style(runner, mapped.get("captions.style"))
    receipt = None
    with music_profile(runner, job, base, mapped) as mapped, closing_profile(runner, job, base, mapped) as mapped, derived_profile(runner, job, base, mapped) as look_profile:
        profile_args = ["--profile", look_profile or base] if consumer or appearance or look_profile else []
        runner.clip("review_apply", ["review", str(project), "--apply", *profile_args], fraction=0.6)
        if payload.get("fix") or consumer or appearance:
            alternate = runner.review_entry.get("alternate")
            if alternate:
                video = runner.fetcher(runner, job)
                runner.clip("process", ["process", str(video), "--project", project.name,
                            "--profile", base, "--resume"], fraction=0.65)
            runner.clip("review", ["review", str(project), "--overwrite", *profile_args], fraction=0.7)
            refreshed = ReviewFile((project / "review.toml").read_text())
            applied = refreshed.by_id(tool_id)
            # A trim may change the tool's safe title overlay. Approve the newly
            # exported target/base once; never forge its hashes or bypass the gate.
            if applied and applied.fields.get("decision") == "pending" and applied.file_stem:
                refreshed.set_fields(applied, decision="approve")
                (project / "review.toml").write_text(refreshed.text())
                runner.clip("review_apply", ["review", str(project), "--apply", *profile_args], fraction=0.72)
                runner.clip("review", ["review", str(project), "--overwrite", *profile_args], fraction=0.74)
                applied = ReviewFile((project / "review.toml").read_text()).by_id(tool_id)
            if not applied or applied.fields.get("decision") != "approve" or not applied.file_stem:
                raise ClipError("REVIEW_NOT_APPLIED", "review_apply")
            runner.review_entry.update(start=applied.start, end=applied.end,
                                      file_stem=applied.file_stem, title=applied.fields.get("title"))
        if consumer:
            receipt = _apply_headline(runner, job, project, look_profile or base, consumer)
        render_started = time.time_ns()
        args = ["finalize", str(project)]
        if look_profile:
            args += ["--profile", look_profile]
        if consumer or appearance or "captions.style" in mapped:
            # Explicit CLI style overrides a saved process-time --captions none.
            args += ["--captions", mapped["captions.style"]]
        if regenerate or consumer:
            args.append("--regenerate")
        runner.clip("finalize", args, fraction=0.85)
    runner.output = _find_output(runner, project)
    if consumer or appearance or mapped.get("captions.style") in DYNAMIC_CAPTION_STYLES:
        stem = runner.review_entry.get("file_stem")
        expected_output = project / "final" / f"{stem}.mp4"
        if runner.output != expected_output or runner.output.stat().st_mtime_ns < render_started:
            raise ClipError("APPEARANCE_RENDER_MISSING" if appearance else
                            "HEADLINE_RENDER_MISSING" if consumer else "CAPTION_RENDER_MISSING", "finalize")
    file_id = runner.uploader(runner, job)
    result: dict[str, Any] = {"file_id": file_id, "candidate_id": tool_id}
    if receipt and payload.get("episode_job_id"):
        result["headline_applied"] = True
    if receipt:
        # Content-free receipt remains local; existing completion schema stays compatible.
        runner.clips.put(clip_id, {**runner.clips.get(clip_id), "headline_receipt": receipt})
    if (payload.get("fix") or {}).get("operation") == "alternate_cut":
        result["alternate_id"] = tool_id
    start, end = runner.review_entry.get("start"), runner.review_entry.get("end")
    if isinstance(start, float) and isinstance(end, float) and end > start:
        if not (payload.get("closing_video") or {}).get("enabled"):
            result["duration_s"] = round(end - start, 3)
        # Enabled closing totals come only from Core's uploaded-file probe.
        if payload.get("fix"):
            result.update(actual_in_s=start, actual_out_s=end)
    if not consumer and not runner.local and (payload.get("fix") or not payload.get("title")) and isinstance(runner.review_entry.get("title"), str):
        result["title"] = runner.review_entry["title"][:200]
    return result


def _process(runner: Runner, job: dict, fraction: float) -> Path:
    payload = job.get("payload") or {}
    profile = _check_profile_name(payload.get("clip_user_profile"))
    _ensure_user_profile(runner, profile)
    _profile_privacy(runner, profile)
    video = runner.fetcher(runner, job)
    runner.report(0.1)
    name = runner.project_name(job)
    runner.clip(
        "process", ["process", str(video), "--project", name, "--profile", profile], fraction=fraction
    )
    _project_info(runner, name, fraction + 0.02)  # the authoritative privacy mode from here on
    return Path(runner.project_path or "")


def _check_rev(runner: Runner, job: dict, bump: int) -> None:
    """Burrow bumps rev on a re-render's complete: expected_rev must be current rev + bump."""
    expected = (job.get("payload") or {}).get("expected_rev")
    current = runner.context.get("clip_rev")
    if bump and not isinstance(current, int):
        raise ClipError("REV_UNKNOWN", "dispatch")
    next_rev = runner.context.get("clip_next_rev", current + bump if isinstance(current, int) else None) if bump else current
    if isinstance(current, int) and isinstance(expected, int) and (next_rev != expected or (bump and expected <= current)):
        raise ClipError("REV_MISMATCH", "dispatch", f"expected {expected}, clip at {current}")


# ── Per-kind handlers ───────────────────────────────────────────────────


def handle_new_clip(runner: Runner, job: dict) -> dict:
    _check_rev(runner, job, 0)
    _preflight(runner)
    payload = job.get("payload") or {}
    if payload.get("episode_job_id"):
        mapping = runner.clips.get(job.get("clip_id") or "")
        if not mapping or not Path(mapping.get("path", "")).is_dir():
            raise ClipError("EPISODE_PROJECT_MISSING", "process")
        _project_info(runner, mapping["path"], 0.45)
        project = Path(mapping["path"])
        return _render(runner, job, project, payload.get("candidate_id"), regenerate=True)
    project = _process(runner, job, 0.45)
    return _render(runner, job, project, None, regenerate=False)


def handle_rerender(runner: Runner, job: dict) -> dict:
    """Re-render and trim (a trim is a rerender with new in_s/out_s and no look change)."""
    _check_rev(runner, job, 1)
    _preflight(runner)
    payload = job.get("payload") or {}
    _check_profile_name(payload.get("clip_user_profile"))
    mapping = runner.clips.get(job.get("clip_id") or payload.get("clip_id") or "")
    tool_id = None
    if mapping and mapping.get("path") and Path(mapping["path"]).is_dir():
        _project_info(runner, mapping["path"], 0.1)
        project = Path(runner.project_path or mapping["path"])
        tool_id = mapping.get("tool_clip_id")
    else:
        # Appearance needs the original project's applied headline/transcript edits.
        # Never fall back to the submitted, already captioned render as source.
        if payload.get("appearance"):
            raise ClipError("APPEARANCE_PROJECT_MISSING", "project_info")
        project = _process(runner, job, 0.45)  # mapping lost: re-process from the episode
    tool_id = payload.get("candidate_id") or tool_id
    return _render(runner, job, project, tool_id, regenerate=True)


class _ConfirmedChildClient:
    """Wait for each child completion before allowing the parent to finish."""
    def __init__(self, parent):
        self.parent = parent
    def __getattr__(self, name):
        return getattr(self.parent.client, name)
    def progress(self, job_id, progress, eta_s=None):
        self.parent.client.progress(job_id, progress, eta_s)
        self.parent.heartbeat()
    def complete(self, job_id, result):
        self.parent.client.request("social_clip_job_complete", {"job_id": job_id, **result},
                                   wait=self.parent.heartbeat)
    def fail(self, job_id, error, code):
        self.parent.client.request("social_clip_job_fail", {"job_id": job_id, "error": error, "code": code},
                                   wait=self.parent.heartbeat)


def handle_episode(runner: Runner, job: dict) -> dict:
    """Process once; persist stable picks, then reuse the canonical headline/render handler.

    Generated headline text never leaves the tool. MCP carries ids/bounds and
    an applied receipt only. A partial failure preserves completed children.
    """
    _preflight(runner)
    source = runner.client.request("social_clip_job_source", {"job_id": job["id"]}, wait=runner.heartbeat)
    if not isinstance(source.get("url"), str):
        raise ClipError("SOURCE_FILE_NO_DOWNLOAD", "fetch")
    runner.context["episode_url"] = source["url"]
    key = "episode:" + job["id"]
    cached = runner.clips.get(key)
    if cached and Path(cached.get("path", "")).is_dir():
        _project_info(runner, cached["path"], 0.3)
        project = Path(cached["path"])
    else:
        project = _process(runner, job, 0.35)
        runner.clips.put(key, {"path": str(project)})
    runner.clip("proposal_review", ["review", str(project), "--overwrite"], fraction=0.4)
    review = ReviewFile((project / "review.toml").read_text())
    picks = [{"candidate_id": e.fields["id"], "in_s": e.start, "out_s": e.end}
             for e in review.entries if not e.alternate and e.file_stem and e.fields.get("decision") != "reject"]
    planned = runner.client.request("social_clip_job_progress", {
        "job_id": job["id"], "progress": 0.4, "picks": picks}, wait=runner.heartbeat)
    children = planned.get("jobs")
    if not isinstance(children, list) or len(children) != len(picks):
        raise ClipError("EPISODE_PLAN_INVALID", "proposal")
    for child in children:
        if child.get("status") == "done":
            continue
        child_id = child.get("id")
        pay = child.get("payload") or {}
        if pay.get("episode_job_id") != job["id"] or pay.get("candidate_id") not in {p["candidate_id"] for p in picks}:
            raise ClipError("EPISODE_PLAN_INVALID", "proposal")
        runner.clips.put(child["clip_id"], {"path": str(project), "tool_clip_id": pay["candidate_id"]})
        reply = runner.client.request("social_clip_job_claim", {"job_id": child_id}, wait=runner.heartbeat)
        claimed = reply.get("job")
        if not isinstance(claimed, dict) or claimed.get("id") != child_id:
            raise ClipError("EPISODE_PLAN_INVALID", "claim")
        context = {**runner.context, "clip_rev": 1}
        worker = Runner(_ConfirmedChildClient(runner), agent_id=runner.agent_id, state_dir=runner.state_dir,
                        clip_bin=runner.clip_bin, heartbeat_s=runner.heartbeat_s,
                        timeout_s=runner.timeout_s, fetcher=runner.fetcher, uploader=runner.uploader,
                        install_signal_handlers=runner.install_signal_handlers)
        outcome = worker.run_job(claimed, context)
        if outcome.get("status") != "done":
            raise ClipError("EPISODE_CHILD_FAILED", "render")
    # Do not expose generated text or source download URL in the parent result.
    return {}


def handle_save_default(runner: Runner, job: dict) -> dict:
    payload = job.get("payload") or {}
    profile = _check_profile_name(payload.get("clip_user_profile"))
    if profile == payload.get("base_profile"):
        raise ClipError("BAD_PAYLOAD", "dispatch")
    mapped = _overrides(payload)
    _preflight(runner)
    if "captions.style" in mapped:
        _qualify_caption_style(runner, mapped["captions.style"])
    _import_profile(runner, profile, BASE_PROFILE, mapped, "profile_import")
    runner.report(0.6)
    runner.clip("profile_use", ["profile", "use", profile], fraction=0.9)
    return {}


HANDLERS: dict[str, Callable[[Runner, dict], dict]] = {
    "episode": handle_episode,
    "new_clip": handle_new_clip,
    "rerender": handle_rerender,
    "save_default": handle_save_default,
}


# ── CLI ─────────────────────────────────────────────────────────────────


def _stdin_json() -> dict:
    data = sys.stdin.read()
    doc = json.loads(data) if data.strip() else {}
    if not isinstance(doc, dict):
        raise SystemExit("stdin must be a JSON object")
    return doc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="clip_runner")
    ap.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("version")
    rc = sub.add_parser("reclaim")
    rc.add_argument("--agent-id", required=True)
    sub.add_parser("order")
    rn = sub.add_parser("run")
    rn.add_argument("--heartbeat-s", type=float, default=DEFAULT_HEARTBEAT_S)
    rn.add_argument("--timeout-s", type=float, default=DEFAULT_TIMEOUT_S)
    rn.add_argument("--reply-timeout-s", type=float, default=DEFAULT_REPLY_TIMEOUT_S)
    rn.add_argument("--clip-bin", default=os.environ.get("CLIP_BIN", "clip"))
    args = ap.parse_args(argv)
    state_dir = args.state_dir.expanduser()

    if args.cmd == "version":
        print(json.dumps({"version": VERSION}))
        return 0

    if args.cmd == "order":
        jobs = _stdin_json().get("jobs") or []
        print(json.dumps({"claim_order": [j["id"] for j in Runner.claim_order(jobs)]}))
        return 0

    with runner_lock(state_dir) as held:
        if not held:
            print(json.dumps({"busy": True}))
            return EXIT_BUSY
        if args.cmd == "reclaim":
            client = OutboxClient(snapshot=_stdin_json().get("jobs") or [])
            Runner(client, agent_id=args.agent_id, state_dir=state_dir).startup_reclaim([None])
            return 0
        doc = _stdin_json()
        job = doc.get("job")
        if not isinstance(job, dict) or not job.get("id"):
            raise SystemExit('stdin must be {"job": {...}, "context": {...}}')
        context = doc.get("context") if isinstance(doc.get("context"), dict) else {}
        client = OutboxClient(
            outbox=state_dir / "outbox" / f"{job['id']}.jsonl",
            reply_dir=state_dir / "replies",
            reply_timeout_s=args.reply_timeout_s,
        )
        runner = Runner(
            client,
            state_dir=state_dir,
            clip_bin=args.clip_bin,
            heartbeat_s=args.heartbeat_s,
            timeout_s=args.timeout_s,
        )
        outcome = runner.run_job(job, context)
        return 0 if outcome.get("status") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
