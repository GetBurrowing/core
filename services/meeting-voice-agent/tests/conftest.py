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
    yield
