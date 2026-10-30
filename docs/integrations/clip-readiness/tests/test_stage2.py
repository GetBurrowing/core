"""Stage 2: per-kind clip sequences, review.toml edit, looks, upload and privacy."""

import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from typing import ClassVar

import pytest
from conftest import AGENT, PROFILE, ROOT, FakeJobClient, make_job, make_runner

import clip_runner

P = f"burrow-{PROFILE}"
LOOK = {"captions.size_frac": 0.07, "captions.primary_color": "#FFEE00", "captions.hook_title": True}
SECRET_WORDS = ("Secret", "secret", "01_", "02_", "final/", "review.toml", ".srt", "transcript")


def proj(shim, clip="clip-job-01"):
    return shim.home / "clips" / f"burrow-{clip}"


def run(client, state_dir, **kw):
    return make_runner(client, state_dir, **kw).poll_once([PROFILE])


def first_new_clip(shim, state_dir, **payload):
    """A done new_clip for clip-job-01 (leaves the clip mapping in state.json)."""
    payload.setdefault("in_s", 305.0)
    payload.setdefault("out_s", 340.0)
    client = FakeJobClient(jobs=[make_job("job-01", "new_clip", **payload)])
    assert run(client, state_dir)["status"] == "done"
    return client


def rerender_job(job_id="job-02", **payload):
    job = make_job(job_id, "rerender", **payload)
    job["clip_id"] = job["payload"]["clip_id"] = "clip-job-01"
    return job


def logged(shim, key):
    return [c for c in shim.calls() if key in c]


# ── exact argv per kind ─────────────────────────────────────────────────


def test_rerender_reuses_the_mapped_project(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[rerender_job(in_s=306.0, out_s=338.0)])
    assert run(client, state_dir)["status"] == "done"
    d = str(proj(shim))
    assert shim.argvs()[n:] == [
        ["version", "--json"],
        ["profile", "path", P],
        ["doctor", "--json", "--profile", P],
        ["project", "info", "--json", d],
        ["review", d, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        ["review", d, "--apply", "--profile", P],
        ["finalize", d, "--profile", P, "--regenerate"],
    ]
    mapping = json.loads((state_dir / "state.json").read_text())["clips"]["clip-job-01"]
    assert mapping == {
        "path": d,
        "profile_id": PROFILE,
        "project": "burrow-clip-job-01",
        "tool_clip_id": "c2bbbbbbbb",
    }


def test_look_change_renders_through_a_derived_profile_then_removes_it(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    job = rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []})
    client = FakeJobClient(jobs=[job])
    assert run(client, state_dir)["status"] == "done"
    d = str(proj(shim))
    derived = f"{P}-job-job-02"
    assert shim.argvs()[n:] == [
        ["version", "--json"],
        ["profile", "path", P],
        ["doctor", "--json", "--profile", P],
        ["project", "info", "--json", d],
        ["review", d, "--overwrite"],
        ["config", "get", "outro.audio", "--profile", P],
        [
            "profile",
            "import",
            str(state_dir / "tmp" / f"{derived}.toml"),
            "--name",
            derived,
            "--force",
            "--yes",
        ],
        ["doctor", "--json", "--profile", derived],
        ["review", d, "--apply", "--profile", derived],
        ["finalize", d, "--profile", derived, "--regenerate"],
        ["profile", "path", derived],
    ]
    imp = logged(shim, "imported")[-1]  # [0] is the bare user profile the first new_clip made
    assert imp["imported"] == (
        f'extends = "{P}"\n\n[captions]\nhook_title = true\nprimary_color = "#FFEE00"\nsize_frac = 0.07\n'
    )
    assert not (shim.home / "profiles" / f"{derived}.toml").exists()
    assert not (state_dir / "tmp" / f"{derived}.toml").exists()
    assert (shim.home / "profiles" / f"{P}.toml").exists()  # the user profile itself stays


def test_derived_profile_is_removed_when_finalize_fails(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(finalize={"exit": 2, "stdout": {"ok": False, "error": {"code": "RENDER_FAILED"}}})
    client = FakeJobClient(jobs=[rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []})])
    outcome = run(client, state_dir)
    assert outcome["code"] == "RENDER_FAILED"
    derived = f"{P}-job-job-02"
    assert ["profile", "path", derived] == shim.argvs()[-1]
    assert not (shim.home / "profiles" / f"{derived}.toml").exists()


def test_derived_profile_is_removed_on_sigterm(shim, state_dir, tmp_path):
    first_new_clip(shim, state_dir)
    shim.script(finalize={"sleep": 30})
    job = rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []}, expected_rev=2)
    job.update(status="claimed", claimed_by_agent_id=AGENT)
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "clip_runner.py"), "--state-dir", str(state_dir), "run"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    proc.stdin.write(json.dumps({"job": job, "context": {"clip_rev": 1, "project_id": "p", "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}}))
    proc.stdin.close()
    derived = shim.home / "profiles" / f"{P}-job-job-02.toml"
    deadline = time.monotonic() + 10
    while not any(c["argv"][0] == "finalize" for c in shim.calls()[2:]) or not derived.exists():
        assert time.monotonic() < deadline
        time.sleep(0.05)
    time.sleep(0.3)
    proc.terminate()
    out = proc.stdout.read()
    assert proc.wait(timeout=10) == 1
    assert json.loads(out.splitlines()[-1])["args"]["code"] == "RUNNER_SIGTERM"
    assert not derived.exists()


def test_rerender_without_a_mapping_reprocesses_from_the_episode(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir)["status"] == "done"
    assert [a[0] for a in shim.argvs()].count("process") == 1


def test_save_default_imports_the_user_profile_over_how_to_computer(shim, state_dir, capsys):
    job = make_job("job-01", "save_default", clip_overrides={"mapped": LOOK, "unmapped": ["cap.hl", "music"]})
    client = FakeJobClient(jobs=[job])
    assert run(client, state_dir)["status"] == "done"
    imp = logged(shim, "imported")[-1]
    assert imp["imported"].startswith('extends = "how-to-computer"\n')
    assert "size_frac = 0.07" in imp["imported"]
    assert shim.argvs()[-1] == ["profile", "use", P]
    assert "LOOK_KEYS_UNMAPPED cap.hl,music" in capsys.readouterr().err
    [complete] = client.named("complete")
    assert "file_id" not in complete[2]


# ── review.toml: only start/end/decision of the target ──────────────────


def test_review_edit_touches_only_the_target_clip(shim, state_dir):
    first_new_clip(shim, state_dir, in_s=302.5, out_s=341.25)
    written = logged(shim, "written")[0]["written"]
    applied = logged(shim, "applied")[0]["applied"]
    before, after = written.splitlines(keepends=True), applied.splitlines(keepends=True)
    assert len(before) == len(after)
    changed = {i: (b, a) for i, (b, a) in enumerate(zip(before, after, strict=True)) if b != a}
    assert sorted(a for _, a in changed.values()) == sorted(
        ['decision = "approve"\n', "end = 341.250\n", "start = 302.500\n"]
    )
    c2 = before.index('id = "c2bbbbbbbb"\n')
    next_clip = before.index("[[clip]]\n", c2)
    assert all(c2 < i < next_clip for i in changed)


def test_best_overlap_ignores_alternates_and_keeps_crlf():
    from fake_clip import REVIEW_FIXTURE

    review = clip_runner.ReviewFile(REVIEW_FIXTURE.replace("\n", "\r\n"))
    assert [e.fields["id"] for e in review.entries] == [
        "c1aaaaaaaa",
        "c2bbbbbbbb",
        "c3cccccccc",
        "a1dddddddd",
    ]
    assert review.entries[3].alternate and not review.entries[2].alternate
    assert review.best_overlap(12.0, 38.0).fields["id"] == "c1aaaaaaaa"  # alternate overlaps, never chosen
    assert review.best_overlap(510.0, 560.0).fields["id"] == "c3cccccccc"
    entry = review.by_id("c3cccccccc")
    review.set_fields(entry, start=505, end=545.5, decision="approve")
    out = review.text()
    assert "start = 505.000\r\n" in out and "end = 545.500\r\n" in out
    assert out.count('\r\ndecision = "approve"\r\n') == 1
    with pytest.raises(ValueError):
        review.set_fields(entry, packaging="x")


def test_trim_keeps_the_mapped_tool_clip_even_without_overlap(shim, state_dir):
    first_new_clip(shim, state_dir)  # maps c2
    client = FakeJobClient(jobs=[rerender_job(in_s=600.0, out_s=640.0)])
    assert run(client, state_dir)["status"] == "done"
    applied = logged(shim, "applied")[-1]["applied"]
    block = applied[applied.index('id = "c2bbbbbbbb"') :]
    assert block.split("[[clip]]")[0].count("start = 600.000") == 1


# ── built-in profile is never written ───────────────────────────────────


def test_built_in_profile_is_never_opened_for_write(shim, state_dir):
    builtin = shim.home / "builtin" / "how-to-computer.toml"
    before = builtin.read_bytes()
    writes = []

    def hook(event, args):
        if event == "open" and args and isinstance(args[0], (str, bytes, os.PathLike)):
            mode = args[1] if len(args) > 1 and isinstance(args[1], str) else ""
            flags = args[2] if len(args) > 2 and isinstance(args[2], int) else 0
            if any(m in mode for m in "wax+") or flags & (os.O_WRONLY | os.O_RDWR):
                writes.append(os.fsdecode(args[0]))

    sys.addaudithook(hook)
    first_new_clip(shim, state_dir)
    for job in (
        rerender_job(clip_overrides={"mapped": LOOK, "unmapped": []}),
        make_job("job-03", "save_default", clip_overrides={"mapped": LOOK, "unmapped": []}),
    ):
        assert run(FakeJobClient(jobs=[job]), state_dir)["status"] == "done"
    assert writes, "audit hook saw nothing"
    assert not [w for w in writes if "how-to-computer" in w or str(shim.home / "builtin") in w]
    assert builtin.read_bytes() == before
    assert "how-to-computer" not in {a[a.index("--name") + 1] for a in shim.argvs() if "--name" in a}


def test_derived_profile_removal_refuses_a_built_in_path(shim, state_dir):
    runner = make_runner(FakeJobClient(), state_dir)
    shim.script(profile_path={"stdout": str(shim.home / "builtin" / "how-to-computer.toml")})
    clip_runner._remove_profile(runner, f"{P}-job-x")
    assert (shim.home / "builtin" / "how-to-computer.toml").exists()
    with pytest.raises(ValueError):
        clip_runner._remove_profile(runner, "how-to-computer")


def test_no_picks_json_is_ever_written(shim, state_dir, tmp_path):
    first_new_clip(shim, state_dir)
    assert not [p for p in tmp_path.rglob("*") if "pick" in p.name.lower()]


# ── privacy ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("privacy,inferred", [("local", "0"), ("cloud", "1")])
def test_local_mode_is_content_free_end_to_end(shim, state_dir, monkeypatch, privacy, inferred):
    monkeypatch.setenv("FAKE_PRIVACY", privacy)
    monkeypatch.setenv("FAKE_PRIVACY_INFERRED", inferred)  # an inferred cloud counts as local
    if inferred == "1":
        monkeypatch.setenv("FAKE_PRIVACY_EXPLICIT", "None")
    client = first_new_clip(shim, state_dir)
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in shim.calls())
    [complete] = client.named("complete")
    result = complete[2]
    assert {k: result[k] for k in clip_runner.META_KEYS} == dict.fromkeys(clip_runner.META_KEYS)
    assert set(result) == {*clip_runner.META_KEYS, "file_id", "duration_s", "source_label", "candidate_id"}
    blob = json.dumps(client.calls)
    assert not [w for w in SECRET_WORDS if w in blob]

    shim.script(
        finalize={"exit": 3, "stdout": {"ok": False, "title": "Secret T", "error": {"code": "X_FAIL"}}}
    )
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir)["code"] == "X_FAIL"
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in shim.calls())
    [fail] = client.named("fail")
    assert not [w for w in SECRET_WORDS if w in json.dumps(fail)]
    assert not [k for k in clip_runner.META_KEYS if k in json.dumps(fail)]


def test_cloud_mode_also_keeps_no_content(shim, state_dir):
    first_new_clip(shim, state_dir)
    by_cmd = {tuple(c["argv"][:2]): c["env"].get("CLIP_NO_CONTENT") for c in shim.calls()}
    assert by_cmd[("version", "--json")] == "1"  # before the mode is known: fail closed
    assert by_cmd[("config", "get")] == "1"
    assert by_cmd[("process", "/episodes/ep.mp4")] == "1"
    assert by_cmd[("finalize", str(proj(shim)))] == "1"


def test_a_payload_title_is_not_overwritten_in_cloud_mode(shim, state_dir):
    client = first_new_clip(shim, state_dir, title="Human Title")
    assert "title" not in client.named("complete")[0][2]


def test_finish_result_local_nulls_meta():
    assert clip_runner.finish_result({"file_id": "f", "title": "T", "speaker": "S"}, local=True) == {
        "file_id": "f",
        "title": None,
        "caption": None,
        "speaker": None,
        "episode_code": None,
        "source_label": "htc-clip-tool",
    }


# ── rev, preflight ──────────────────────────────────────────────────────


def test_expected_rev_mismatch_fails_before_any_clip_command(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job("job-03", expected_rev=5)])
    n = len(shim.calls())
    outcome = run(client, state_dir, context_for=lambda r, j: {"clip_rev": 3, "project_id": "p"})
    assert outcome["code"] == "REV_MISMATCH"
    assert len(shim.calls()) == n
    assert client.named("fail")[0][2] == "dispatch failed (expected 5, clip at 3)"


def test_rerender_without_the_clip_rev_fails(shim, state_dir):
    client = FakeJobClient(jobs=[rerender_job()])
    assert run(client, state_dir, context_for=lambda r, j: {})["code"] == "REV_UNKNOWN"
    assert shim.calls() == []


def test_new_clip_checks_rev_against_the_current_rev(shim, state_dir):
    client = FakeJobClient(jobs=[make_job("job-01", "new_clip", expected_rev=2)])
    assert run(client, state_dir)["status"] == "done"  # default context echoes it
    client = FakeJobClient(jobs=[make_job("job-02", "new_clip", expected_rev=2)])
    assert run(client, state_dir, context_for=lambda r, j: {"clip_rev": 1})["code"] == "REV_MISMATCH"


@pytest.mark.parametrize(
    "version,code", [("0.8.9", "CLIP_TOO_OLD"), ("garbage", "CLIP_VERSION_UNKNOWN"), ("0.9.0", None)]
)
def test_version_gate(shim, state_dir, monkeypatch, version, code):
    monkeypatch.setenv("FAKE_CLIP_VERSION", version)
    outcome = run(FakeJobClient(jobs=[make_job("job-01", "save_default")]), state_dir)
    assert outcome.get("code") == code


def test_content_free_capability_is_recorded(shim, state_dir, monkeypatch):
    seen = {}

    def upload(runner, job):
        seen["cf"] = runner.content_free
        return "file-1"

    first = make_runner(FakeJobClient(jobs=[make_job("job-01")]), state_dir, uploader=upload)
    first.poll_once([PROFILE])
    assert seen["cf"] is True
    monkeypatch.setenv("FAKE_CONTENT_FREE", "1")
    make_runner(FakeJobClient(jobs=[make_job("job-02")]), state_dir, uploader=upload).poll_once([PROFILE])
    assert seen["cf"] is False


def test_doctor_fix_fails_with_the_check_names(shim, state_dir):
    shim.script(
        doctor={
            "stdout": {
                "checks": [{"check": "whisper_model", "status": "fix", "message": "Secret"}],
                "summary": {"pass": 0, "warn": 0, "fix": 1},
            }
        }
    )
    client = FakeJobClient(jobs=[make_job("job-01", "save_default")])
    assert run(client, state_dir)["code"] == "CLIP_DOCTOR_FIX"
    assert client.named("fail")[0][2] == "doctor failed (whisper_model)"


# ── fetch ───────────────────────────────────────────────────────────────


def test_fetch_prefers_the_agents_local_copy_then_fails_closed(tmp_path, state_dir):
    runner = clip_runner.Runner(FakeJobClient(), state_dir=state_dir)
    job = make_job("job-01")
    ep = tmp_path / "ep.mp4"
    ep.write_bytes(b"x")
    runner.context = {"episode_path": str(ep), "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}
    assert clip_runner.fetch_episode(runner, job) == str(ep)
    runner.context = {}
    with pytest.raises(clip_runner.ClipError) as err:
        clip_runner.fetch_episode(runner, job)
    assert err.value.code == "SOURCE_FILE_NO_DOWNLOAD"


def test_fetch_source_url_with_ytdlp_is_cached_and_named_by_hash(tmp_path, state_dir, monkeypatch):
    fake = tmp_path / "yt-dlp"
    count = tmp_path / "count"
    fake.write_text(
        "#!/bin/sh\n"
        f'echo x >> "{count}"\n'
        'while [ "$1" != "-o" ]; do shift; done\n'
        'out=$(echo "$2" | sed "s/%(ext)s/mp4/")\n'
        'echo VIDEO > "$out"\n'
    )
    fake.chmod(0o755)
    monkeypatch.setenv("CLIP_RUNNER_YTDLP", str(fake))
    runner = clip_runner.Runner(FakeJobClient(), state_dir=state_dir)
    job = make_job(
        "job-01", episode={"source_url": "https://video.example/watch?v=Secret", "source_file_id": None}
    )
    runner._job = job
    first = clip_runner.fetch_episode(runner, job)
    second = clip_runner.fetch_episode(runner, job)
    assert first == second and first.endswith(".mp4") and "Secret" not in first
    assert count.read_text().count("x") == 1


# ── upload ──────────────────────────────────────────────────────────────


class Upload(http.server.BaseHTTPRequestHandler):
    seen: ClassVar[list] = []
    reply_hash = None

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Upload.seen.append(
            {
                "path": self.path,
                "auth": self.headers["Authorization"],
                "type": self.headers["Content-Type"],
                "body": body,
            }
        )
        doc = {
            "id": "file-777",
            "state": "ready",
            "content_hash": Upload.reply_hash or hashlib.sha256(body).hexdigest(),
        }
        data = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture
def upload_server(monkeypatch):
    Upload.seen, Upload.reply_hash = [], None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upload)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    monkeypatch.setenv("CLIP_RUNNER_BASE_URL", base)
    monkeypatch.setenv("CLIP_RUNNER_TOKEN", "tok-not-a-real-secret")
    yield base
    server.shutdown()


def test_upload_requests_file_add_then_posts_with_the_bearer(shim, state_dir, upload_server):
    client = FakeJobClient(jobs=[make_job("job-01", in_s=305.0, out_s=340.0)])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["status"] == "done"
    [req] = client.named("request")
    video = (proj(shim) / "final" / "02_secret-title-two.mp4").read_bytes()
    assert req == (
        "request",
        "file_add",
        {
            "project_id": "project-files-1",
            "filename": "clip-clip-job-01-r1.mp4",
            "content_type": "video/mp4",
            "byte_size": len(video),
        },
    )
    [post] = Upload.seen
    assert post == {
        "path": "/chat/attachments/upload/tok",
        "auth": "Bearer tok-not-a-real-secret",
        "type": "video/mp4",
        "body": video,
    }
    assert client.named("complete")[0][2]["file_id"] == "file-777"
    assert "tok-not-a-real-secret" not in json.dumps(client.calls)
    assert not [c for c in shim.calls() if "CLIP_RUNNER_TOKEN" in c["env"]]


def test_upload_hash_mismatch_fails(shim, state_dir, upload_server):
    Upload.reply_hash = "0" * 64
    client = FakeJobClient(jobs=[make_job("job-01")])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_HASH_MISMATCH"


def test_upload_never_sends_the_token_to_another_host(shim, state_dir, upload_server):
    client = FakeJobClient(jobs=[make_job("job-01")])
    client.replies["file_add"] = {"id": "f", "upload_url": "https://elsewhere.example/upload/x"}
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_HOST_MISMATCH"
    assert Upload.seen == []


def test_upload_without_token_is_unavailable(shim, state_dir, monkeypatch):
    monkeypatch.delenv("CLIP_RUNNER_TOKEN", raising=False)
    client = FakeJobClient(jobs=[make_job("job-01")])
    assert run(client, state_dir, uploader=clip_runner.upload_output)["code"] == "UPLOAD_UNAVAILABLE"


def test_cli_run_end_to_end_with_reply_file(shim, state_dir, tmp_path, upload_server):
    """The agent protocol: forward lines; answer a reply_file line with the tool result."""
    ep = tmp_path / "episode.mp4"
    ep.write_bytes(b"EPISODE")
    job = make_job("job-01", "new_clip", status="claimed", claimed_by=AGENT, in_s=305.0, out_s=340.0)
    proc = subprocess.Popen(
        [
            sys.executable,
            str(ROOT / "clip_runner.py"),
            "--state-dir",
            str(state_dir),
            "run",
            "--reply-timeout-s",
            "20",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        env=dict(os.environ),
    )
    context = {"clip_rev": 1, "project_id": "project-files-1", "episode_path": str(ep), "headline_voice": {"revision": "fixture-8", "direction": "Comedy; incomplete."}}
    proc.stdin.write(json.dumps({"job": job, "context": context}))
    proc.stdin.close()
    lines = []
    for raw in proc.stdout:
        line = json.loads(raw)
        lines.append(line)
        if "reply_file" in line:
            assert line["tool"] == "file_add"
            tmp = line["reply_file"] + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(
                    {"id": "file-777", "upload_url": "/chat/attachments/upload/tok", "state": "pending"}, fh
                )
            os.replace(tmp, line["reply_file"])
    assert proc.wait(timeout=30) == 0
    tools = [ln["tool"] for ln in lines]
    assert tools[-1] == "social_clip_job_complete" and "file_add" in tools
    assert set(tools[:-1]) == {"social_clip_job_progress", "file_add"}
    assert lines[-1]["args"]["file_id"] == "file-777"
    assert "tok-not-a-real-secret" not in json.dumps(lines)
