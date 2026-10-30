"""Readiness must describe the actual selected render, never global defaults."""
import json

import pytest

from conftest import FakeJobClient, make_job
from test_stage2 import P, first_new_clip, rerender_job, run


PASS = {"checks": [], "summary": {"pass": 1, "warn": 0, "fix": 0}}
MODEL_FIX = {"checks": [{"check": "model:base.en", "status": "fix",
                          "message": "/private/model/location"}],
             "summary": {"pass": 0, "warn": 0, "fix": 1}}


@pytest.mark.parametrize("selected_ok", [False, True])
def test_selected_profile_wins_over_disagreeing_default(shim, state_dir, monkeypatch, selected_ok):
    monkeypatch.setenv("FAKE_DOCTOR_PROFILES", json.dumps({
        "default": MODEL_FIX if selected_ok else PASS,
        P: PASS if selected_ok else MODEL_FIX,
    }))
    client = FakeJobClient(jobs=[make_job("job-01")])
    result = run(client, state_dir)
    assert result["status"] == ("done" if selected_ok else "failed")
    assert [c["argv"] for c in shim.calls() if c["argv"][0] == "doctor"] == ([
        ["doctor", "--json", "--profile", "burrow-profile-1"],
        ["doctor", "--json", "--profile", "burrow-profile-1-job-job-01"]] if selected_ok else [
        ["doctor", "--json", "--profile", "burrow-profile-1"]])
    if not selected_ok:
        assert client.named("fail")[0][3] == "CLIP_DOCTOR_FIX"
        assert client.named("fail")[0][2] == "doctor failed (model:base.en)"
        assert not any(c["argv"][0] in ("process", "finalize") for c in shim.calls())
        assert "/private" not in json.dumps(client.calls)


def test_derived_render_profile_is_checked_before_finalize(shim, state_dir, monkeypatch):
    first_new_clip(shim, state_dir)
    count = len(shim.calls())
    monkeypatch.setenv("FAKE_DOCTOR_PROFILES", json.dumps({
        P: PASS, "burrow-profile-1-job-job-02": MODEL_FIX,
    }))
    client = FakeJobClient(jobs=[rerender_job(appearance=True,
        clip_overrides={"mapped": {"captions.style": "karaoke"}, "unmapped": []})])
    assert run(client, state_dir)["code"] == "CLIP_DOCTOR_FIX"
    calls = shim.calls()[count:]
    assert [c["argv"] for c in calls if c["argv"][0] == "doctor"] == [
        ["doctor", "--json", "--profile", "burrow-profile-1"],
        ["doctor", "--json", "--profile", "burrow-profile-1-job-job-02"]]
    assert not any(c["argv"][0] in ("process", "finalize") for c in calls)
    assert not list((shim.home / "profiles").glob("*-job-*"))


def test_valid_original_appearance_keeps_full_readiness_and_never_transcribes(shim, state_dir):
    first_new_clip(shim, state_dir)
    count = len(shim.calls())
    client = FakeJobClient(jobs=[rerender_job(appearance=True,
        candidate_id="c2bbbbbbbb",
        clip_overrides={"mapped": {"captions.style": "karaoke"}, "unmapped": []})])
    assert run(client, state_dir)["status"] == "done"
    calls = [c["argv"] for c in shim.calls()[count:]]
    assert ["doctor", "--json", "--profile", "burrow-profile-1-job-job-02"] in calls
    final = next(c for c in calls if c[0] == "finalize")
    assert final[final.index("--profile") + 1] == "burrow-profile-1-job-job-02"
    assert not any(c[0] == "process" for c in calls)


def test_episode_still_fails_model_readiness_before_source_request(shim, state_dir, monkeypatch):
    monkeypatch.setenv("FAKE_DOCTOR_PROFILES", json.dumps({P: MODEL_FIX}))
    client = FakeJobClient(jobs=[make_job("job-01", "episode")])
    assert run(client, state_dir)["code"] == "CLIP_DOCTOR_FIX"
    assert not client.named("request")
