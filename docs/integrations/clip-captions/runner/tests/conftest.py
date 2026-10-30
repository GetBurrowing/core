import json
import os
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import clip_runner

AGENT = "agent-self"
OTHER = "agent-other"
PROFILE = "profile-1"


class FakeJobClient:
    """In-memory job list with ClipJobs' semantics: conditional claim, claimer-only writes."""

    def __init__(self, agent_id=AGENT, jobs=(), lose_claims=()):
        self.agent_id = agent_id
        self.jobs = {j["id"]: dict(j) for j in jobs}
        self.lose_claims = set(lose_claims)  # another runner wins these
        self.calls = []
        self.replies = {}

    def request(self, tool, args, wait=None):
        self.calls.append(("request", tool, dict(args)))
        reply = self.replies.get(tool, {"id": "file-777", "upload_url": "/chat/attachments/upload/tok"})
        if isinstance(reply, Exception):
            raise reply
        return dict(reply)

    def _open_mine(self, job_id):
        job = self.jobs.get(job_id)
        if job is None:
            raise clip_runner.JobToolError("not_found")
        if job.get("claimed_by_agent_id") != self.agent_id:
            raise clip_runner.JobToolError("not_claimer")
        if job["status"] not in ("claimed", "running"):
            raise clip_runner.JobToolError("job_closed")
        return job

    def list_jobs(self, profile_id, status):
        self.calls.append(("list", profile_id, status))
        rows = [j for j in self.jobs.values() if j["status"] == status]
        if profile_id is not None:
            rows = [j for j in rows if j["profile_id"] == profile_id]
        return [dict(j) for j in sorted(rows, key=lambda j: j["inserted_at"])]

    def claim(self, job_id):
        self.calls.append(("claim", job_id))
        job = self.jobs[job_id]
        if job_id in self.lose_claims:
            job.update(status="claimed", claimed_by_agent_id=OTHER)
        if job["status"] != "queued":
            raise clip_runner.AlreadyClaimed()
        job.update(status="claimed", claimed_by_agent_id=self.agent_id)
        return dict(job)

    def progress(self, job_id, progress, eta_s=None):
        self.calls.append(("progress", job_id, progress, eta_s))
        job = self._open_mine(job_id)
        assert 0 <= progress <= 1
        assert eta_s is None or eta_s >= 0
        job.update(status="running", progress=progress)

    def complete(self, job_id, result):
        self.calls.append(("complete", job_id, dict(result)))
        job = self._open_mine(job_id)
        job.update(status="done", result=result)

    def fail(self, job_id, error, code):
        self.calls.append(("fail", job_id, error, code))
        job = self._open_mine(job_id)
        job.update(status="failed", error=f"{code}: {error}")

    def named(self, name):
        return [c for c in self.calls if c[0] == name]


def make_job(job_id, kind="new_clip", status="queued", claimed_by=None, inserted_at=None, **payload):
    clip_id = None if kind == "save_default" else f"clip-{job_id}"
    body = {
        "kind": kind,
        "clip_id": clip_id,
        "profile_id": PROFILE,
        "clip_user_profile": f"burrow-{PROFILE}",
        "base_profile": "how-to-computer",
        "in_s": 10.0,
        "out_s": 40.0,
        "look_delta": {},
        "expected_rev": 2 if kind == "rerender" else 1,
        "clip_overrides": {"mapped": {}, "unmapped": []},
        "episode": {"source_url": None, "source_file_id": "file-episode-1", "transcript_file_id": None},
    }
    body.update(payload)
    return {
        "id": job_id,
        "profile_id": PROFILE,
        "clip_id": clip_id,
        "kind": kind,
        "status": status,
        "payload": body,
        "claimed_by_agent_id": claimed_by,
        "inserted_at": inserted_at or f"2026-10-23T00:00:{job_id[-2:]}Z",
    }


@pytest.fixture
def shim(tmp_path, monkeypatch):
    """`clip` on PATH -> fake_clip.py; returns a controller."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    wrapper = bin_dir / "clip"
    wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "tests" / "fake_clip.py"}" "$@"\n')
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "clip_calls.jsonl"
    script = tmp_path / "clip_script.json"
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_CLIP_LOG", str(log))
    monkeypatch.setenv("FAKE_CLIP_SCRIPT", str(script))
    clip_home = tmp_path / "cliphome"
    (clip_home / "builtin").mkdir(parents=True)
    (clip_home / "profiles").mkdir()
    (clip_home / "builtin" / "how-to-computer.toml").write_text(
        'extends = "podcast"\n[captions]\npreset = "htc"\n'
    )
    (clip_home / "builtin" / "podcast.toml").write_text('[privacy]\nmode = "cloud"\n')
    monkeypatch.setenv("FAKE_CLIP_HOME", str(clip_home))
    for var in ("FAKE_PRIVACY", "FAKE_PRIVACY_INFERRED", "FAKE_PRIVACY_EXPLICIT", "CLIP_NO_CONTENT"):
        monkeypatch.delenv(var, raising=False)

    class Shim:
        def script(self, **spec):
            script.write_text(json.dumps(spec))

        def calls(self):
            if not log.exists():
                return []
            return [json.loads(line) for line in log.read_text().splitlines()]

        def argvs(self):
            return [c["argv"] for c in self.calls()]

        home = clip_home

    return Shim()


@pytest.fixture
def state_dir(tmp_path):
    return tmp_path / "state"


def default_context(runner, job):
    payload = job.get("payload") or {}
    rev = payload.get("expected_rev")
    if isinstance(rev, int) and (job.get("kind") or payload.get("kind")) == "rerender":
        rev -= 1
    return {"clip_rev": rev, "project_id": "project-files-1",
            "headline_voice": {"revision": "fixture-8", "direction": "Comedy and positivity; incomplete."},
            "base_render_id": payload.get("base_render_id")}


def make_runner(client, state_dir, **kw):
    kw.setdefault("fetcher", lambda r, j: "/episodes/ep.mp4")
    kw.setdefault("uploader", lambda r, j: "file-123")
    kw.setdefault("context_for", default_context)
    return clip_runner.Runner(client, agent_id=client.agent_id, state_dir=state_dir, **kw)
