"""Guards for real original-source validation, not production success evidence."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

spec = importlib.util.spec_from_file_location("original_validation",
    Path(__file__).parents[1] / "validate_original_render.py")
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


def test_missing_original_source_refuses_candidate_fallback(tmp_path):
    with pytest.raises(RuntimeError, match="^INPUT_MISSING_OR_HASH_MISMATCH$"):
        validation.require_bytes(tmp_path / "absent", validation.SOURCE_SHA)
    wrong = tmp_path / "delivered.mp4"
    wrong.write_bytes(b"delivered candidate is not the original source")
    with pytest.raises(RuntimeError, match="^INPUT_MISSING_OR_HASH_MISMATCH$"):
        validation.require_bytes(wrong, validation.SOURCE_SHA)


def test_zero_exit_doctor_fix_is_still_fatal():
    with pytest.raises(RuntimeError, match="^DOCTOR_FIX$"):
        validation.require_doctor({"checks": [{"check": "model:base.en", "status": "fix"}]})
    assert validation.require_doctor({"checks": [{"check": "model:large-v3", "status": "pass"}]}) == {
        "pass": 1, "warn": 0, "fix": 0}
    with pytest.raises(RuntimeError, match="^DOCTOR_INVALID$"):
        validation.require_doctor({"checks": []})


def test_exact_original_candidate_and_bounds_are_required():
    good = SimpleNamespace(fields={"id": "c8bedfe6da"}, start=2403.01, end=2456.88, alternate=False)
    validation.require_candidate(good)
    for changed in (
        SimpleNamespace(fields={"id": "other"}, start=2403.01, end=2456.88, alternate=False),
        SimpleNamespace(fields={"id": "c8bedfe6da"}, start=2404.01, end=2456.88, alternate=False),
        SimpleNamespace(fields={"id": "c8bedfe6da"}, start=2403.01, end=2456.88, alternate=True),
    ):
        with pytest.raises(RuntimeError, match="^ORIGINAL_CANDIDATE_MISMATCH$"):
            validation.require_candidate(changed)


def test_original_framing_dimensions_and_cut_duration_are_required():
    validation.require_measurements({"width": 1080, "height": 1920}, 53.428375)
    with pytest.raises(RuntimeError, match="^OUTPUT_DIMENSIONS_CHANGED$"):
        validation.require_measurements({"width": 1920, "height": 1080}, 53.428375)
    with pytest.raises(RuntimeError, match="^OUTPUT_CUT_DURATION_CHANGED$"):
        validation.require_measurements({"width": 1080, "height": 1920}, 54.0)
