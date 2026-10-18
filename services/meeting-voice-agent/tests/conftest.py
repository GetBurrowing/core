import os

import pytest


@pytest.fixture(autouse=True)
def clean_mva_env(monkeypatch):
    """Every test starts from a clean slate of MVA_* / LIVEKIT_* env vars.

    Without this, a developer's shell exports (or a previous test) could
    silently change which defaults a test observes.
    """
    for key in list(os.environ):
        if key.startswith("MVA_") or key.startswith("LIVEKIT_"):
            monkeypatch.delenv(key, raising=False)
    # The deployment URLs are REQUIRED (no default: MVA_MCP_BASE_URL, task
    # 01a116de; the LLM/STT/TTS URLs, task 01a14b9e), so the clean slate
    # carries neutral placeholders; test_config.py removes each to prove the
    # requirement.
    monkeypatch.setenv("MVA_MCP_BASE_URL", "https://suite.example.test/mcp")
    monkeypatch.setenv("MVA_LLM_BASE_URL", "http://llm.example.test:8090/v1")
    monkeypatch.setenv("MVA_STT_BASE_URL", "http://stt.example.test:8081/v1")
    monkeypatch.setenv("MVA_TTS_BASE_URL", "http://tts.example.test:8081/v1")
    yield
