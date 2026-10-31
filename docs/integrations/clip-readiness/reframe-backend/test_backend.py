"""Run against the actual patched imported CLI, including native inference."""
import json
import sys
from types import SimpleNamespace

import pytest
from click.testing import CliRunner
from clip_agent import cli, opencv_faces, shots


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("CLIP_AGENT_HOME", str(tmp_path / ".clip-agent"))
    monkeypatch.delenv("CLIP_FACE_MODEL", raising=False)
    monkeypatch.delenv("CLIP_DEBUG", raising=False)
    monkeypatch.setattr(cli, "_ollama_reachable", lambda endpoint: False)
    monkeypatch.setattr(cli, "_whisper_version", lambda: None)
    opencv_faces._detector.cache_clear()


def reframe_checks(mode="shots"):
    checks = []
    cli._doctor_reframe_checks(SimpleNamespace(reframe=SimpleNamespace(
        mode=mode, seats=[], fallback="center")),
        lambda status, name, message: checks.append((status, name)))
    return checks


def test_real_verified_model_runs_native_inference():
    assert opencv_faces.available()
    assert opencv_faces.ready()
    assert shots.face_detection_available()
    assert reframe_checks() == [("pass", "reframe-backend")]


def test_missing_cv2_is_a_fatal_readiness_check(monkeypatch):
    monkeypatch.setitem(sys.modules, "cv2", None)
    monkeypatch.setattr(shots, "vision_available", lambda: False)
    assert reframe_checks() == [("fix", "reframe-backend")]
    with pytest.raises(RuntimeError):
        shots.detect_faces("unused")


def test_tampered_model_is_not_adopted(tmp_path, monkeypatch):
    path = tmp_path / "wrong-model.onnx"
    path.write_bytes(b"not the pinned face model")
    monkeypatch.setenv("CLIP_FACE_MODEL", str(path))
    monkeypatch.setattr(shots, "vision_available", lambda: False)
    assert not opencv_faces.available()
    assert reframe_checks() == [("fix", "reframe-backend")]


def test_native_inference_failure_does_not_pass_doctor(monkeypatch):
    monkeypatch.setattr(shots, "vision_available", lambda: False)
    def broken(_path):
        raise RuntimeError("native inference failed")
    monkeypatch.setattr(opencv_faces, "_detector", broken)
    assert reframe_checks() == [("fix", "reframe-backend")]


def test_other_modes_keep_their_existing_requirements():
    assert reframe_checks("off") == []
    assert reframe_checks("seats") == [("warn", "seats")]


def test_selected_profile_doctor_reports_backend_fix_without_removing_model_checks(tmp_path, monkeypatch):
    profiles = tmp_path / ".clip-agent" / "profiles"
    profiles.mkdir(parents=True)
    (profiles / "selected-shots.toml").write_text('extends = "how-to-computer"\n')
    monkeypatch.setattr(shots, "face_detection_available", lambda: False)
    result = CliRunner().invoke(cli.cli, ["doctor", "--json", "--profile", "selected-shots"])
    assert result.exit_code == 0  # Doctor's existing informational exit contract stays intact.
    checks = json.loads(result.output)["checks"]
    assert {c["check"]: c["status"] for c in checks}["reframe-backend"] == "fix"
    assert any(c["check"].startswith("model:") and c["status"] == "fix" for c in checks)


def test_vision_backend_is_preserved(monkeypatch):
    monkeypatch.setattr(shots, "vision_available", lambda: True)
    monkeypatch.setattr(opencv_faces, "ready", lambda: False)
    assert shots.face_detection_available()


def test_cli_reports_only_installed_backend_contract():
    info = cli.install_info()
    assert info["reframe_backend"] == 1
    assert info["reframe_backends"] == ["vision", "yunet"]
    assert info["headline_review"] == 1
