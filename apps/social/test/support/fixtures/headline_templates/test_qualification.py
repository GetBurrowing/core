"""Run with the pinned renderer Python, not a system/fake clip package."""

import importlib.util
from pathlib import Path

from clip_agent.config import FONTS_DIR

SCRIPT = Path(__file__).parents[4] / "priv/scripts/clip_headline_templates_qualify.py"
spec = importlib.util.spec_from_file_location("headline_qualification", SCRIPT)
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)
ASSETS = Path(__file__).parents[6] / "docs/integrations/clip-headlines"


def test_all_styles_decode_with_complete_wording_or_explicit_failure(tmp_path):
    assert FONTS_DIR.is_dir()
    rows = qualification.layout_matrix(
        tmp_path, ASSETS / "assets/htc-official-logo-crop.png", [[0.1, 0.32, 0.9, 0.86]]
    )
    assert len(rows) == 15
    for style in ("chrome-hook", "neon-broadcast", "arcade-punch"):
        found = {r["case"]: r for r in rows if r["template"] == style}
        assert set(found) == {
            "short",
            "long",
            "unbroken",
            "unicode",
            "unsupported-unicode",
        }
        assert found["unbroken"]["error"] == "HEADLINE_LAYOUT_SHORTEN_TEXT"
        assert found["unsupported-unicode"]["error"] == "HEADLINE_GLYPH_UNSUPPORTED"
        for name in ("short", "long", "unicode"):
            assert found[name]["error"] is None
            assert len(found[name]["sha256"]) == 64


def test_forwarding_contract_is_independently_literal():
    c = qualification.contract("chrome-hook", seconds=2.0)
    assert c["timing"] == {
        "entrance_s": 0.2,
        "hold_s": 1.55,
        "exit_s": 0.25,
        "total_s": 2.0,
    }
    assert (
        c["assets"]["logo_sha256"]
        == "7cbddeac97ad8fe3aa53e867cf0e5648329f500e528f2302e1b2ebcba8bf767f"
    )
    assert (
        c["renderer_sha256"]
        == "b36d7ec515da07e5e432d1eca57c639ecc6007126cc68110d1bb367c99b45d84"
    )


def test_music_speech_guard_allows_only_small_codec_phase_shift():
    import numpy as np

    a = np.random.default_rng(8675309).normal(0, 0.02, 16000)
    b = np.concatenate((np.zeros(16), a[:-16]))
    b += 0.006 * np.sin(2 * np.pi * 220 * np.arange(16000) / 16000)
    result = qualification.codec_speech_match(a, b)
    assert result["delay_ms"] == 1.0
    assert result["correlation"] > 0.995


def test_music_speech_guard_rejects_changed_source_timing():
    import numpy as np
    import pytest

    a = np.random.default_rng(8675309).normal(0, 0.02, 16000)
    b = np.concatenate((np.zeros(200), a[:-200]))
    with pytest.raises(AssertionError):
        qualification.codec_speech_match(a, b)
