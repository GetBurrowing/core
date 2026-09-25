import pytest


@pytest.fixture(autouse=True)
def clean_mva_env():
    """Overrides (shadows) the top-level `clean_mva_env` fixture for everything
    under `tests/live/`.

    Stage 1's fixture wipes every `MVA_*`/`LIVEKIT_*` env var before each test
    so a developer's shell exports can't silently change what a mocked unit
    test observes — correct for tests that assert on config defaults. It is
    wrong here: these tests are opt-in (`pytest -m live_infra`) specifically
    BECAUSE they need real ambient config (`MVA_MCP_BASE_URL`,
    `MVA_MCP_AUTH_TOKEN`, or overridden wave/moon URLs) to point at whatever
    is actually live. Wiping it would make every live test look unreachable
    regardless of what the operator configured. A no-op fixture of the same
    name shadows the outer one for this directory (pytest fixture resolution:
    nearest conftest wins) without touching stage 1's behavior anywhere else.
    """
    yield
