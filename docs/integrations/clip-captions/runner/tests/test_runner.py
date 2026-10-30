import itertools
import json
import os
import signal
import subprocess
import sys
import time

import pytest
from conftest import AGENT, OTHER, PROFILE, ROOT, FakeJobClient, make_job, make_runner

import clip_runner


def journal_files(state_dir):
    d = state_dir / "jobs"
    return sorted(p.name for p in d.glob("*.json")) if d.exists() else []


# ── poll / claim race ────────────────────────────────────────────────────


def test_claim_race_already_claimed_is_skipped_silently(shim, state_dir):
    client = FakeJobClient(
        jobs=[make_job("job-01", "rerender"), make_job("job-02", "rerender")],
        lose_claims={"job-01"},
    )
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome == {"job_id": "job-02", "kind": "rerender", "status": "done"}
    assert [c[1] for c in client.named("claim")] == ["job-01", "job-02"]
    touched = {c[1] for c in client.calls if c[0] in ("progress", "complete", "fail")}
    assert touched == {"job-02"}
    assert client.jobs["job-01"]["claimed_by_agent_id"] == OTHER
    assert client.jobs["job-01"]["status"] == "claimed"


def test_poll_claims_oldest_first_and_idles_when_empty(shim, state_dir):
    client = FakeJobClient(
        jobs=[
            make_job("job-09", "rerender", inserted_at="2026-10-23T09:00:00Z"),
            make_job("job-03", "rerender", inserted_at="2026-10-23T03:00:00Z"),
        ]
    )
    runner = make_runner(client, state_dir)
    assert runner.poll_once([PROFILE])["job_id"] == "job-03"
    assert runner.poll_once([PROFILE])["job_id"] == "job-09"
    assert runner.poll_once([PROFILE]) is None


def test_poll_returns_none_when_every_claim_is_lost(shim, state_dir):
    client = FakeJobClient(jobs=[make_job("job-01")], lose_claims={"job-01"})
    assert make_runner(client, state_dir).poll_once([PROFILE]) is None
    assert shim.calls() == []


# ── dispatch per kind ─────────────────────────────────────────────────────


P = f"burrow-{PROFILE}"


def _process_argv(state_dir, name):
    return [
        ["profile", "path", P],
        ["profile", "import", str(state_dir / "tmp" / f"{P}.toml"), "--name", P, "--force", "--yes"],
        ["config", "get", "effective_privacy_mode", "--profile", P],
        ["config", "get", "privacy.mode", "--profile", P],
        ["process", "/episodes/ep.mp4", "--project", name, "--profile", P],
        ["project", "info", "--json", name],
    ]


# Stage 2 (0.2.0) replaced the stage-1 placeholder sequences: the real clip CLI takes
# --project NAME (not a dir), has no --json on process/review/finalize, and needs
# review.toml created (`review --overwrite`) before it is edited and applied.
EXPECTED_ARGV = {
    "new_clip": lambda proj, sd: [
        ["version", "--json"], ["doctor", "--json"],
        *_process_argv(sd, "burrow-clip-job-01"),
        ["review", proj, "--overwrite"],
        ["config", "get", "captions.style", "--profile", P],
        ["config", "get", "outro.audio", "--profile", P],
        ["profile", "import", str(sd / "tmp" / f"{P}-job-job-01.toml"), "--name", f"{P}-job-job-01", "--force", "--yes"],
        ["review", proj, "--apply", "--profile", f"{P}-job-job-01"], ["review", proj, "--overwrite", "--profile", f"{P}-job-job-01"],
        ["hooks", "prepare-review", proj, "--request", str(sd / "tmp" / "headline-request.json"), "--profile", f"{P}-job-job-01"],
        ["review", proj, "--apply", "--profile", f"{P}-job-job-01"],
        ["hooks", "prepare-review", proj, "--request", str(sd / "tmp" / "headline-request.json"), "--profile", f"{P}-job-job-01", "--check-applied"],
        ["finalize", proj, "--profile", f"{P}-job-job-01", "--captions", "phrase-pop", "--regenerate"],
        ["profile", "path", f"{P}-job-job-01"],
    ],
    "rerender": lambda proj, sd: [
        ["version", "--json"],
        ["doctor", "--json"],
        *_process_argv(sd, "burrow-clip-job-01"),
        ["review", proj, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        ["review", proj, "--apply"],
        ["finalize", proj, "--regenerate"],
    ],
    "save_default": lambda proj, sd: [
        ["version", "--json"],
        ["doctor", "--json"],
        ["profile", "import", str(sd / "tmp" / f"{P}.toml"), "--name", P, "--force", "--yes"],
        ["profile", "use", P],
    ],
}


@pytest.mark.parametrize("kind", ["new_clip", "rerender", "save_default"])
def test_each_kind_is_dispatched_and_completed(shim, state_dir, kind):
    job = make_job("job-01", kind)
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome["status"] == "done"
    proj = str(shim.home / "clips" / "burrow-clip-job-01")
    assert shim.argvs() == EXPECTED_ARGV[kind](proj, state_dir)

    [complete] = client.named("complete")
    result = complete[2]
    assert set(result) <= set(clip_runner.RESULT_KEYS)
    assert result["source_label"] == "htc-clip-tool"
    if kind == "save_default":
        assert "file_id" not in result
        # privacy mode never read for a profile-only job: fail closed (local), meta keys null
        assert all(result[k] is None for k in clip_runner.META_KEYS)
    else:
        # cloud mode (the fake's default): the tool's title may come back (payload had none);
        # make_job's 10..40 overlaps only the alternate, so the nearest CUT clip (c1) is chosen
        assert result == {
            "file_id": "file-123",
            "duration_s": 30.0,
            **({"title": "Secret Title One"} if kind == "rerender" else {}),
            "candidate_id": "c1aaaaaaaa",
            "source_label": "htc-clip-tool",
        }
    assert client.named("fail") == []
    assert client.jobs["job-01"]["status"] == "done"
    assert journal_files(state_dir) == []
    # progress at step boundaries, monotonic, within 0..1
    progress = [c[2] for c in client.named("progress")]
    assert progress and progress == sorted(progress) and all(0 <= p < 1 for p in progress)


def test_trim_is_a_rerender_not_its_own_kind(shim, state_dir):
    job = make_job("job-01", "rerender", in_s=12.0, out_s=33.0, look_delta={})
    client = FakeJobClient(jobs=[job])
    assert make_runner(client, state_dir).poll_once([PROFILE])["status"] == "done"
    assert "trim" not in clip_runner.HANDLERS


def test_unknown_kind_fails_without_running_clip(shim, state_dir):
    job = make_job("job-01", "trim")
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome["status"] == "failed" and outcome["code"] == "UNKNOWN_KIND"
    assert client.named("fail")[0][3] == "UNKNOWN_KIND"
    assert shim.calls() == []
    assert journal_files(state_dir) == []


def test_save_default_never_targets_the_built_in_profile(shim, state_dir):
    job = make_job("job-01", "save_default", clip_user_profile="how-to-computer")
    client = FakeJobClient(jobs=[job])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])
    assert outcome["code"] == "BAD_PAYLOAD"
    assert shim.calls() == []


def test_complete_sends_only_result_keys():
    assert clip_runner.finish_result({"file_id": "f", "transcript": "x", "picks": [], "title": None}) == {
        "file_id": "f",
        "title": None,
        "source_label": "htc-clip-tool",
    }


# ── startup reclaim ───────────────────────────────────────────────────────


def test_startup_reclaim_fails_own_orphans_and_ignores_other_agents(state_dir):
    client = FakeJobClient(
        jobs=[
            make_job("job-01", status="claimed", claimed_by=AGENT),
            make_job("job-02", status="running", claimed_by=AGENT),
            make_job("job-03", status="claimed", claimed_by=OTHER),
            make_job("job-04", status="running", claimed_by=OTHER),
            make_job("job-05", status="queued"),
            make_job("job-06", status="done", claimed_by=AGENT),
        ]
    )
    journal = clip_runner.Journal(state_dir)
    journal.write(client.jobs["job-02"], "finalize")

    failed = make_runner(client, state_dir).startup_reclaim([PROFILE])

    assert sorted(failed) == ["job-01", "job-02"]
    fails = {c[1]: c for c in client.named("fail")}
    assert set(fails) == {"job-01", "job-02"}
    assert all(c[3] == "RUNNER_RESTARTED" for c in fails.values())
    assert fails["job-02"][2].endswith("last step: finalize")
    assert client.jobs["job-03"]["status"] == "claimed"
    assert client.jobs["job-04"]["status"] == "running"
    assert client.jobs["job-05"]["status"] == "queued"
    assert {("list", PROFILE, "claimed"), ("list", PROFILE, "running")} <= set(client.calls)
    assert journal_files(state_dir) == []


def test_startup_reclaim_fails_journalled_job_and_tolerates_closed(state_dir):
    # job-07 is journalled but already closed server-side: fail is refused, journal still cleared
    closed = make_job("job-07", status="failed", claimed_by=AGENT)
    client = FakeJobClient(jobs=[closed])
    clip_runner.Journal(state_dir).write(closed, "process")
    assert make_runner(client, state_dir).startup_reclaim([PROFILE]) == ["job-07"]
    assert client.named("fail")[0][3] == "RUNNER_RESTARTED"
    assert journal_files(state_dir) == []


# ── failure paths ─────────────────────────────────────────────────────────


def test_crash_mid_finalize_fails_with_clip_error_code_and_clears_journal(shim, state_dir):
    shim.script(
        finalize={
            "exit": 3,
            "stdout": {"ok": False, "title": "Secret Episode Title", "error": {"code": "FFMPEG_FAILED"}},
        }
    )
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    outcome = make_runner(client, state_dir).poll_once([PROFILE])

    assert outcome == {"job_id": "job-01", "kind": "rerender", "status": "failed", "code": "FFMPEG_FAILED"}
    [fail] = client.named("fail")
    assert fail[3] == "FFMPEG_FAILED"
    assert "Secret" not in fail[2] and "finalize" in fail[2]
    assert client.named("complete") == []
    assert client.jobs["job-01"]["status"] == "failed"
    assert journal_files(state_dir) == []


def test_non_zero_exit_without_json_code_uses_exit_code(shim, state_dir):
    shim.script(review_apply={"exit": 4, "stdout": "not json"})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "CLIP_EXIT_4"


def test_doctor_not_ok_fails_with_its_code(shim, state_dir):
    shim.script(doctor={"stdout": {"ok": False, "code": "NO_FFMPEG"}})
    client = FakeJobClient(jobs=[make_job("job-01", "save_default")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "NO_FFMPEG"


def test_timeout_kills_command_and_fails(shim, state_dir):
    shim.script(finalize={"sleep": 5})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    start = time.monotonic()
    outcome = make_runner(client, state_dir, timeout_s=0.5, heartbeat_s=0.2).poll_once([PROFILE])
    assert outcome["code"] == "CLIP_TIMEOUT"
    assert time.monotonic() - start < 4


def test_python_exception_in_a_step_still_ends_failed(shim, state_dir):
    def boom(runner, job):
        raise RuntimeError("Secret Episode Title")

    client = FakeJobClient(jobs=[make_job("job-01", "new_clip")])
    outcome = make_runner(client, state_dir, uploader=boom).poll_once([PROFILE])
    assert outcome["code"] == "RUNNER_EXCEPTION"
    [fail] = client.named("fail")
    assert "Secret" not in fail[2] and "RuntimeError" in fail[2]
    assert journal_files(state_dir) == []


def test_refused_complete_becomes_a_fail_with_the_tool_code(shim, state_dir):
    class Refusing(FakeJobClient):
        def complete(self, job_id, result):
            self.calls.append(("complete", job_id, result))
            raise clip_runner.JobToolError("file_not_in_project")

    client = Refusing(jobs=[make_job("job-01", "rerender")])
    assert make_runner(client, state_dir).poll_once([PROFILE])["code"] == "FILE_NOT_IN_PROJECT"
    assert client.jobs["job-01"]["status"] == "failed"


def test_journal_survives_when_the_fail_call_itself_errors(shim, state_dir):
    class Down(FakeJobClient):
        def fail(self, job_id, error, code):
            raise ConnectionError("tool unreachable")

    shim.script(finalize={"exit": 2})
    client = Down(jobs=[make_job("job-01", "rerender")])
    with pytest.raises(ConnectionError):
        make_runner(client, state_dir).poll_once([PROFILE])
    assert journal_files(state_dir) == ["job-01.json"]  # next startup reclaim fails it


def test_journal_is_written_before_each_clip_command(shim, state_dir):
    seen = []

    class Watching(FakeJobClient):
        def progress(self, job_id, progress, eta_s=None):
            seen.append(json.loads((state_dir / "jobs" / f"{job_id}.json").read_text())["step"])
            super().progress(job_id, progress, eta_s)

    client = Watching(jobs=[make_job("job-01", "rerender")])
    make_runner(client, state_dir).poll_once([PROFILE])
    assert seen == ["doctor", "config_get", "process", "project_info", "review", "review_apply", "finalize"]


# ── heartbeat ─────────────────────────────────────────────────────────────


def test_heartbeat_fires_during_a_long_command(shim, state_dir):
    shim.script(finalize={"sleep": 1.3})
    client = FakeJobClient(jobs=[make_job("job-01", "rerender")])
    marks = []
    orig = client.progress

    def progress(job_id, progress, eta_s=None):
        marks.append(time.monotonic())
        orig(job_id, progress, eta_s)

    client.progress = progress
    outcome = make_runner(client, state_dir, heartbeat_s=0.2).poll_once([PROFILE])
    assert outcome["status"] == "done"
    gaps = [b - a for a, b in itertools.pairwise(marks)]
    assert len(marks) >= 8  # 4 boundaries + >= 4 heartbeats during the 1.3s finalize
    assert max(gaps) < 0.6


def test_heartbeat_interval_is_capped_at_60s():
    assert clip_runner.Runner(FakeJobClient(), heartbeat_s=600).heartbeat_s == 60.0


# ── CLI (the agent-facing surface) ──────────────────────────────────────


def cli(state_dir, *args, stdin=None, env=None):
    return subprocess.run(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), *args],
        input=json.dumps(stdin) if stdin is not None else "",
        capture_output=True,
        check=False,
        text=True,
        env=env,
        timeout=30,
    )


def lines(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.strip()]


def test_cli_order_is_oldest_queued_first(state_dir):
    jobs = [
        make_job("job-09", inserted_at="2026-10-23T09:00:00Z"),
        make_job("job-03", inserted_at="2026-10-23T03:00:00Z"),
        make_job("job-05", status="claimed", claimed_by=OTHER),
    ]
    out = cli(state_dir, "order", stdin={"jobs": jobs})
    assert json.loads(out.stdout) == {"claim_order": ["job-03", "job-09"]}


def test_cli_run_emits_progress_then_one_terminal_call(shim, state_dir):
    job = make_job("job-01", "save_default", status="claimed", claimed_by=AGENT)
    out = cli(state_dir, "run", stdin={"job": job}, env=dict(os.environ))
    calls = lines(out.stdout)
    assert out.returncode == 0
    assert [c["tool"] for c in calls[:-1]] == ["social_clip_job_progress"] * (len(calls) - 1)
    assert calls[-1] == {
        "tool": "social_clip_job_complete",
        "args": {
            "job_id": "job-01",
            "source_label": "htc-clip-tool",
            "title": None,
            "caption": None,
            "speaker": None,
            "episode_code": None,
        },
    }
    outbox = (state_dir / "outbox" / "job-01.jsonl").read_text().splitlines()
    assert [json.loads(x) for x in outbox] == calls


def episode(tmp_path):
    p = tmp_path / "episode.mp4"
    p.write_bytes(b"EPISODE")
    return p


def wait_for_step(state_dir, job_id, step, timeout=10):
    path = state_dir / "jobs" / f"{job_id}.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if json.loads(path.read_text())["step"] == step:
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    raise AssertionError(f"never reached {step}")


def spawn_run(state_dir, job, episode):
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), "run"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    context = {"clip_rev": 1, "project_id": "project-files-1", "episode_path": str(episode)}
    proc.stdin.write(json.dumps({"job": job, "context": context}))
    proc.stdin.close()
    return proc


def test_cli_sigterm_mid_finalize_fails_job_and_clears_journal(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    wait_for_step(state_dir, "job-01", "finalize")
    time.sleep(0.3)
    proc.send_signal(signal.SIGTERM)
    stdout = proc.stdout.read()
    assert proc.wait(timeout=10) == 1
    last = lines(stdout)[-1]
    assert last["tool"] == "social_clip_job_fail"
    assert last["args"]["code"] == "RUNNER_SIGTERM"
    assert "finalize" in last["args"]["error"]
    assert journal_files(state_dir) == []


def test_cli_sigkill_mid_finalize_is_failed_by_next_startup_reclaim(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    wait_for_step(state_dir, "job-01", "finalize")
    proc.kill()
    proc.wait(timeout=10)
    assert journal_files(state_dir) == ["job-01.json"]

    server_view = [dict(job, status="running"), make_job("job-02", status="claimed", claimed_by=OTHER)]
    out = cli(state_dir, "reclaim", "--agent-id", AGENT, stdin={"jobs": server_view})
    assert out.returncode == 0
    assert lines(out.stdout) == [
        {
            "tool": "social_clip_job_fail",
            "args": {
                "job_id": "job-01",
                "code": "RUNNER_RESTARTED",
                "error": "runner restarted mid-job; last step: finalize",
            },
        }
    ]
    assert journal_files(state_dir) == []


def test_cli_reclaim_refuses_while_a_run_holds_the_lock(shim, state_dir, tmp_path):
    shim.script(finalize={"sleep": 30})
    job = make_job("job-01", "rerender", status="claimed", claimed_by=AGENT)
    proc = spawn_run(state_dir, job, episode(tmp_path))
    try:
        wait_for_step(state_dir, "job-01", "finalize")
        out = cli(state_dir, "reclaim", "--agent-id", AGENT, stdin={"jobs": [dict(job, status="running")]})
        assert out.returncode == clip_runner.EXIT_BUSY
        assert json.loads(out.stdout) == {"busy": True}
        assert journal_files(state_dir) == ["job-01.json"]
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)
