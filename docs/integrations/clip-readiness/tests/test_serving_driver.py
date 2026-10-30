"""Measured moon driver drives real helper subprocesses against fake MCP/CLI."""
import hashlib
import importlib.util
from pathlib import Path
import shutil

import pytest

from conftest import FakeJobClient, PROFILE, ROOT
from rebind_image_driver import rebind
from test_music import song_server  # noqa: F401 - pytest fixture
from test_stage2 import first_new_clip, rerender_job, upload_server  # noqa: F401


OLD_HELPER = "c55f6ceb913004ddfc3e947407847c2d768d78d4a40c081106fba97a8a066999"
OLD_DRIVER = "fe08fa40eacf3efd705055a1f144eebf4be83c629cf2e029ea6ece763521a06d"
MCP_SOURCE = "b0254651e7a28a7789e16136973659cd718ebc88d3b5ab744402b4ebce06b058"
NEW_HELPER = "0a5c4e0bb84c208c492682fda5b6ccb6d79d9bf306602d411362502a15e175c4"


@pytest.fixture
def serving_driver(tmp_path, state_dir, monkeypatch):
    sources = ROOT / "serving-driver"
    for name, digest in (("driver.py", OLD_DRIVER), ("burrow_mcp.py", MCP_SOURCE),
                         ("helper-0.7.0.py", OLD_HELPER)):
        assert hashlib.sha256((sources / name).read_bytes()).hexdigest() == digest
    driver = tmp_path / "driver.py"
    helper = tmp_path / "clip_runner.py"
    shutil.copyfile(sources / "driver.py", driver)
    shutil.copyfile(sources / "burrow_mcp.py", tmp_path / "burrow_mcp.py")
    shutil.copyfile(sources / "helper-0.7.0.py", helper)
    assert rebind(driver, helper, ROOT / "clip_runner.py", ROOT / "source-receipt.json",
                  OLD_DRIVER, OLD_HELPER) == NEW_HELPER
    monkeypatch.setenv("CLIP_RUNNER_HELPER", str(helper))
    monkeypatch.setenv("CLIP_RUNNER_HOME", str(state_dir))
    spec = importlib.util.spec_from_file_location("measured_serving_driver", driver)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.verify_helper()
    yield module


class Transport:
    def __init__(self, client, song_url=None):
        self.client, self.song_url, self.calls = client, song_url, []

    def call(self, tool, args):
        self.calls.append((tool, dict(args)))
        if tool == "social_clip_job_list":
            return {"jobs": self.client.list_jobs(args["profile_id"], args["status"]), "has_more": False}
        if tool == "social_clip_job_claim":
            return {"job": self.client.claim(args["job_id"])}
        if tool == "social_clip_list":
            return {"clips": [{"id": "clip-job-01", "rev": 1, "next_rev": 2,
                                "versions": [{"rev": 1, "id": "render-base"}]}]}
        if tool == "social_clip_job_source":
            assert args == {"job_id": "job-02", "asset": "music"}
            return {"file_id": "song-id", "project_id": "project-files-1", "url": self.song_url,
                    "content_type": "audio/wav", "byte_size": len(b"RIFF0000WAVEtest-audio")}
        if tool == "social_clip_job_progress":
            self.client.progress(args["job_id"], args["progress"], args.get("eta_s"))
            return {}
        if tool == "file_add":
            return {"id": "file-777", "upload_url": "/chat/attachments/upload/test-only"}
        if tool == "social_clip_job_complete":
            self.client.complete(args["job_id"], {k: v for k, v in args.items() if k != "job_id"})
            return {}
        if tool == "social_clip_job_fail":
            self.client.fail(args["job_id"], args["error"], args["code"])
            return {}
        raise AssertionError("unexpected MCP tool: " + tool)


def job():
    return rerender_job(appearance=True, candidate_id="c2bbbbbbbb", episode={},
        music={"enabled": True, "file_id": "song-id", "level_db": -12},
        clip_overrides={"mapped": {"captions.style": "karaoke"}, "unmapped": []})


def test_measured_driver_poll_claim_reply_upload_complete(shim, state_dir, serving_driver,
                                                        song_server, upload_server, capsys):
    serving_driver.verify_helper()
    first_new_clip(shim, state_dir)
    count = len(shim.calls())
    client = FakeJobClient(jobs=[job()])
    transport = Transport(client, song_server)
    assert serving_driver.poll_once(transport, {"profile_ids": [PROFILE]}, {PROFILE: "project-files-1"})
    assert client.jobs["job-02"]["status"] == "done"
    assert client.named("complete")[0][2]["file_id"] == "file-777"
    assert ("social_clip_job_source", {"job_id": "job-02", "asset": "music"}) in transport.calls
    calls = shim.calls()[count:]
    assert not any(c["argv"][0] == "process" for c in calls)
    assert ["doctor", "--json", "--profile", "burrow-profile-1-job-job-02"] in [c["argv"] for c in calls]
    assert "level_db = -12" in next(c["imported"] for c in calls if "imported" in c)
    assert not list((state_dir / "replies").glob("*.tmp"))
    assert not list(state_dir.rglob("track.audio"))
    assert not list((shim.home / "profiles").glob("*-job-*"))
    logs = capsys.readouterr().err
    assert "signed-secret-token" not in logs and "tok-not-a-real-secret" not in logs
    assert "(0.9.2)" in logs


def test_measured_driver_preserves_model_error_and_avoids_upload(shim, state_dir, serving_driver):
    first_new_clip(shim, state_dir)
    shim.script(doctor={"stdout": {"checks": [{"check": "model:base.en", "status": "fix"}],
                                    "summary": {"fix": 1}}})
    client = FakeJobClient(jobs=[job()])
    transport = Transport(client)
    assert serving_driver.poll_once(transport, {"profile_ids": [PROFILE]}, {PROFILE: "project-files-1"})
    assert client.jobs["job-02"]["status"] == "failed"
    assert client.named("fail")[0][2:] == ("doctor failed (model:base.en)", "CLIP_DOCTOR_FIX")
    assert not any(tool in ("file_add", "social_clip_job_complete", "social_clip_job_source")
                   for tool, _ in transport.calls)


def test_actual_driver_rejects_mutated_helper_before_polling(serving_driver):
    serving_driver.HELPER.write_bytes(b"changed helper")
    with pytest.raises(SystemExit) as exc:
        serving_driver.verify_helper()
    assert exc.value.code == 2
