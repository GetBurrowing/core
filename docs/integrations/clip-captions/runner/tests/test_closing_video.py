"""Protocol tests only. Real frame/audio evidence is in the repository harness."""

import hashlib
import http.server
import json
import signal
import threading
from pathlib import Path

import clip_runner
import pytest
from conftest import FakeJobClient, make_runner
from test_stage2 import first_new_clip, rerender_job, run

VIDEO = b"\x00\x00\x00\x18ftypmp42-protocol-fixture"
HASH = hashlib.sha256(VIDEO).hexdigest()


@pytest.fixture
def video_server():
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, dict(self.headers)))
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/signed-private-video")
                self.end_headers()
                return
            if self.path == "/bad-redirect":
                self.send_response(302)
                self.send_header("Location", "file:///etc/passwd")
                self.end_headers()
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(VIDEO)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield "http://127.0.0.1:" + str(server.server_address[1]), requests
    server.shutdown()
    server.server_close()


def contract(**kw):
    return dict(
        enabled=True,
        file_id="closing-A",
        audio="keep",
        project_id="project-files-1",
        content_hash=HASH,
        content_type="video/mp4",
        byte_size=len(VIDEO),
        **kw,
    )


def client(job, source_url, **changes):
    c = FakeJobClient(jobs=[job])
    d = dict(contract())
    d.pop("enabled")
    d.pop("audio")
    d.update(url=source_url, max_bytes=209715200)
    d.update(changes)
    c.replies["social_clip_job_source"] = d
    return c


def job(**changes):
    closing = contract()
    closing.update(changes)
    return rerender_job(closing_video=closing, candidate_id="c2bbbbbbbb")


def clean(state_dir, shim):
    assert not list(state_dir.rglob("closing.video"))
    assert not list(state_dir.rglob("closing.part"))
    assert not list((shim.home / "profiles").glob("*-job-*"))


@pytest.mark.parametrize("audio", ["keep", "mute"])
def test_private_exact_asset_profile_and_cleanup(
    shim, state_dir, video_server, monkeypatch, audio
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    for key in (
        "CLIP_RUNNER_TOKEN",
        "BURROW_TOKEN",
        "BURROW_API_TOKEN",
        "CF_ACCESS_CLIENT_ID",
        "CF_ACCESS_CLIENT_SECRET",
    ):
        monkeypatch.setenv(key, "secret-burrow-token")
    url, requests = video_server
    c = client(job(audio=audio), url + "/redirect")
    assert run(c, state_dir)["status"] == "done"
    assert c.named("request") == [
        (
            "request",
            "social_clip_job_source",
            {"job_id": "job-02", "asset": "closing_video"},
        )
    ]
    imports = [x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]]
    text = imports[-1]["imported"]
    assert (
        "[outro]" in text and f'audio = "{audio}"' in text and "closing.video" in text
    )
    complete = c.named("complete")[-1][-1]
    assert "duration_s" not in complete
    assert requests and all(
        not any(
            k.lower()
            in ("authorization", "cf-access-client-id", "cf-access-client-secret")
            for k in h
        )
        for _, h in requests
    )
    assert all("secret-burrow-token" not in json.dumps(x["env"]) for x in shim.calls())
    for p in state_dir.rglob("*.json"):
        assert (
            "signed-private" not in p.read_text()
            and "secret-burrow-token" not in p.read_text()
        )
    assert "signed-private" not in json.dumps(shim.calls())
    clean(state_dir, shim)


@pytest.mark.parametrize(
    "change,code",
    [
        ({"file_id": "foreign"}, "CLOSING_ASSET_INVALID"),
        ({"project_id": "foreign"}, "CLOSING_ASSET_INVALID"),
        ({"content_type": "audio/wav"}, "CLOSING_ASSET_INVALID"),
        ({"byte_size": 0}, "CLOSING_ASSET_INVALID"),
        ({"byte_size": 209715201}, "CLOSING_ASSET_INVALID"),
        ({"content_hash": "0" * 64}, "CLOSING_ASSET_INVALID"),
        ({"max_bytes": 0}, "CLOSING_ASSET_INVALID"),
        ({"url": "file:///etc/passwd"}, "CLOSING_URL_INVALID"),
        ({"url": "https://user:password@example.com/media"}, "CLOSING_URL_INVALID"),
        ({"url": "http://example.com/media"}, "CLOSING_URL_INVALID"),
        ({"url": "http://127.0.0.1:1/private-token"}, "CLOSING_DOWNLOAD_FAILED"),
    ],
)
def test_reject_identity_contract_and_download_errors(
    shim, state_dir, video_server, monkeypatch, change, code
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    c = client(job(), url + "/signed-private-video", **change)
    result = run(c, state_dir)
    assert result["status"] == "failed" and result["code"] == code
    clean(state_dir, shim)
    assert not c.named("complete")
    assert "private-token" not in json.dumps(c.named("fail"))


@pytest.mark.parametrize(
    "size,hash_value,code",
    [
        (len(VIDEO) - 1, HASH, "CLOSING_DOWNLOAD_SIZE"),
        (len(VIDEO) + 1, HASH, "CLOSING_DOWNLOAD_SIZE"),
        (len(VIDEO), "0" * 64, "CLOSING_HASH_MISMATCH"),
    ],
)
def test_streamed_bytes_and_hash_enforced(
    shim, state_dir, video_server, monkeypatch, size, hash_value, code
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job(byte_size=size, content_hash=hash_value)
    c = client(
        j, url + "/signed-private-video", byte_size=size, content_hash=hash_value
    )
    assert run(c, state_dir)["code"] == code
    clean(state_dir, shim)


@pytest.mark.parametrize("legacy", [False, True])
def test_disabled_or_legacy_clears_inherited_path_without_download(
    shim, state_dir, monkeypatch, legacy
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "keep")
    j = rerender_job() if legacy else job(enabled=False)
    c = FakeJobClient(jobs=[j])
    assert run(c, state_dir)["status"] == "done"
    assert not c.named("request")
    text = [
        x["imported"] for x in shim.calls() if x["argv"][:2] == ["profile", "import"]
    ][-1]
    assert "[outro]" in text and 'path = ""' in text
    clean(state_dir, shim)


def test_unsupported_cli_enabled_fails_disabled_succeeds(shim, state_dir, video_server):
    first_new_clip(shim, state_dir)
    url, _ = video_server
    c = client(job(), url)
    assert run(c, state_dir)["code"] == "CLOSING_CLI_UNSUPPORTED"
    assert not c.named("request")
    c = FakeJobClient(jobs=[job(enabled=False)])
    assert run(c, state_dir)["status"] == "done"


@pytest.mark.parametrize("audio", ["bad", None, True])
def test_invalid_audio_contract(shim, state_dir, audio):
    first_new_clip(shim, state_dir)
    c = FakeJobClient(jobs=[job(audio=audio)])
    assert run(c, state_dir)["code"] == "CLOSING_CONTRACT_INVALID"


def test_render_failure_and_sigterm_clean(shim, state_dir, video_server, monkeypatch):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    shim.script(finalize={"exit": 1})
    c = client(job(), url)
    assert run(c, state_dir)["status"] == "failed"
    clean(state_dir, shim)
    shim.script()
    c = client(job(), url)
    r = make_runner(c, state_dir)
    original = r.clip

    def interrupted(step, *a, **kw):
        if step == "finalize":
            raise clip_runner.RunnerInterrupted(signal.SIGTERM)
        return original(step, *a, **kw)

    r.clip = interrupted
    assert r.poll_once(["profile-1"])["code"] == "RUNNER_SIGTERM"
    clean(state_dir, shim)


def test_restart_reclaims_orphan_bytes_profiles_and_replies(shim, state_dir):
    first_new_clip(shim, state_dir)
    j = job()
    j.update(status="running", claimed_by_agent_id="agent-self")
    c = FakeJobClient(jobs=[j])
    r = make_runner(c, state_dir)
    r.journal.write(j, "finalize")
    folder = r.tmp_dir() / "closing-job-02"
    folder.mkdir()
    (folder / "closing.video").write_bytes(VIDEO)
    (folder / "closing.part").write_bytes(b"partial")
    (shim.home / "profiles" / "burrow-profile-1-job-job-02.toml").write_text(
        'extends="how-to-computer"'
    )
    replies = state_dir / "replies"
    replies.mkdir()
    (replies / "12-1-social_clip_job_source.json").write_text('{"url":"private"}')
    assert r.startup_reclaim(["profile-1"]) == ["job-02"]
    clean(state_dir, shim)
    assert not list(replies.iterdir())


def test_single_profile_combines_look_music_and_closing(
    shim, state_dir, video_server, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job()
    j["payload"].update(
        music={"enabled": False, "file_id": "song", "level_db": -18},
        clip_overrides={"mapped": {"captions.style": "plain"}, "unmapped": []},
    )
    c = client(j, url)
    before = len([x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]])
    assert run(c, state_dir)["status"] == "done"
    imports = [x for x in shim.calls() if x["argv"][:2] == ["profile", "import"]][
        before:
    ]
    assert len(imports) == 1
    assert all(
        section in imports[0]["imported"]
        for section in ("[music]", "[captions]", "[outro]")
    )
    clean(state_dir, shim)


def test_private_modes_while_live(shim, state_dir, video_server, monkeypatch):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job()
    c = client(j, url)
    r = make_runner(c, state_dir)
    r._job = j
    r.context = {"project_id": "project-files-1"}
    with clip_runner.closing_profile(r, j, "burrow-profile-1", {}) as mapped:
        video = Path(mapped["outro.path"])
        assert video.stat().st_mode & 0o777 == 0o600
        assert video.parent.stat().st_mode & 0o777 == 0o700
        with clip_runner.derived_profile(r, j, "burrow-profile-1", mapped) as profile:
            assert (
                shim.home / "profiles" / (profile + ".toml")
            ).stat().st_mode & 0o777 == 0o600
    clean(state_dir, shim)


@pytest.mark.parametrize(
    "change", [{"profile_id": "foreign-profile"}, {"org_id": "foreign-org"}]
)
def test_pinned_profile_and_org_match_current_context(
    shim, state_dir, video_server, monkeypatch, change
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    j = job(**change)
    c = client(j, url)
    r = make_runner(c, state_dir)
    r._job = j
    r.context = {"project_id": "project-files-1", "org_id": "org-current"}
    with (
        pytest.raises(clip_runner.ClipError, match="closing_video") as err,
        clip_runner.closing_profile(r, j, "burrow-profile-1", {}),
    ):
        pass
    assert err.value.code == "CLOSING_ASSET_INVALID"
    assert not c.named("request")


def test_cleanup_failure_cannot_upload_or_complete(
    shim, state_dir, video_server, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    c = client(job(), url)
    unlink = Path.unlink

    def fail_cleanup(path, *a, **kw):
        if path.name == "closing.video":
            raise PermissionError("private pathname must not leak")
        return unlink(path, *a, **kw)

    monkeypatch.setattr(Path, "unlink", fail_cleanup)
    assert run(c, state_dir)["code"] == "CLOSING_CLEANUP_FAILED"
    assert not c.named("complete")
    assert "private pathname" not in json.dumps(c.named("fail"))


def test_restart_cleans_headline_and_music_partial(shim, state_dir):
    first_new_clip(shim, state_dir)
    j = job()
    j.update(status="running", claimed_by_agent_id="agent-self")
    c = FakeJobClient(jobs=[j])
    r = make_runner(c, state_dir)
    r.journal.write(j, "finalize")
    tmp = r.tmp_dir()
    (tmp / "headline-request.json").write_text("private")
    music = tmp / "music"
    music.mkdir()
    (music / "track.part").write_bytes(b"partial")
    r.startup_reclaim(["profile-1"])
    assert not (tmp / "headline-request.json").exists() and not music.exists()


def test_reply_timeout_removes_private_partial(shim, state_dir):
    import io

    replies = state_dir / "replies"
    client = clip_runner.OutboxClient(
        out=io.StringIO(), reply_dir=replies, reply_timeout_s=0
    )
    emit = client._emit

    def partial(tool, args, extra):
        path = Path(extra["reply_file"])
        path.with_suffix(".json.tmp").write_text('{"url":"private-signed-value"}')
        emit(tool, args, extra)

    client._emit = partial
    with pytest.raises(clip_runner.ClipError) as err:
        client.request(
            "social_clip_job_source", {"job_id": "job-02", "asset": "closing_video"}
        )
    assert err.value.code == "REPLY_TIMEOUT"
    assert replies.stat().st_mode & 0o777 == 0o700
    assert not list(replies.iterdir())


def test_episode_children_each_resolve_their_pinned_closing(
    shim, state_dir, video_server, monkeypatch
):
    from test_episode import EpisodeClient, episode

    monkeypatch.setenv("FAKE_OUTRO_AUDIO", "mute")
    url, _ = video_server
    source = client(job(), url).replies["social_clip_job_source"]

    class ClosingEpisodeClient(EpisodeClient):
        def request(self, tool, args, wait=None):
            if (
                tool == "social_clip_job_source"
                and args.get("asset") == "closing_video"
            ):
                self.calls.append(("request", tool, dict(args)))
                return dict(source)
            reply = super().request(tool, args, wait)
            if tool == "social_clip_job_progress" and "picks" in args:
                for child in reply["jobs"]:
                    child["payload"]["closing_video"] = contract()
            return reply

    parent = episode()
    parent["payload"]["closing_video"] = contract()
    c = ClosingEpisodeClient(jobs=[parent])
    assert make_runner(c, state_dir).poll_once(["profile-1"])["status"] == "done"
    assert [
        call[2]["job_id"]
        for call in c.calls
        if call[:2] == ("request", "social_clip_job_source")
        and call[2].get("asset") == "closing_video"
    ] == ["child-0", "child-1"]
    imports = [
        x["imported"]
        for x in shim.calls()
        if x["argv"][:2] == ["profile", "import"] and "[outro]" in x["imported"]
    ]
    assert len(imports) == 2 and all(
        'audio = "keep"' in x and "closing.video" in x for x in imports
    )
    assert sum(a[0] == "process" for a in shim.argvs()) == 1
    clean(state_dir, shim)
