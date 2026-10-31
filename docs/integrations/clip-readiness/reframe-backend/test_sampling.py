"""Explicit compatibility is data; current face sampling and all checks stay default."""
from pathlib import Path

import pytest
from clip_agent import cli, shots
from clip_agent.config import Config
from pydantic import ValidationError


@pytest.mark.parametrize("sampling,expected_start,expected_duration", [
    ("aligned", 2403.01, 53.87),
    ("legacy-half-step", 2403.26, 53.62),
])
def test_literal_source_sampling_clock(monkeypatch, sampling, expected_start, expected_duration):
    calls = []
    cfg = Config(reframe={"mode": "shots", "face_sampling": sampling})
    monkeypatch.setattr(shots, "detect_shots", lambda *a, **kw: [])
    monkeypatch.setattr(shots, "scene_cuts", lambda *a, **kw: [])
    def frames(src, start, dur, output, **kw):
        calls.append((start, dur))
        return [(0.25, Path("private-test-frame"))]
    monkeypatch.setattr(shots, "extract_frames_dense", frames)
    shots.analyse_shots("original-source", 2403.01, 53.87, cfg, detector=lambda path: [])
    assert calls == [(expected_start, expected_duration)]


def test_default_remains_aligned_and_bad_revision_is_rejected():
    assert Config().reframe.face_sampling == "aligned"
    with pytest.raises(ValidationError):
        Config(reframe={"face_sampling": "guess-another-clock"})


def test_cli_advertises_the_installed_sampling_contract():
    info = cli.install_info()
    assert info["reframe_sampling"] == 1
    assert info["reframe_sampling_modes"] == ["aligned", "legacy-half-step"]
    assert info["reframe_backend"] == 1
