"""Live confirmation: the MCP tool-call path executes a REAL Burrow tool
against a running Core instance, and the chat hand-off tool really posts.

Requires `MVA_MCP_BASE_URL` and `MVA_MCP_AUTH_TOKEN` — a real, active
voice-runtime token, e.g. printed once by
`mix platform.seed_meeting_voice_agent --owner <email>` (see
apps/platform/lib/mix/tasks/platform/seed_meeting_voice_agent.ex). Unlike
wave/test-host, Core is not LAN-gated: point this at a locally-run
`mix phx.server` or at a real deployed Core URL.

Each test opens and closes its own `MCPToolset` within a single `asyncio.run`
call (matching stage 1's `asyncio.run(...)`-per-test convention in
`tests/test_agent.py`) rather than sharing one across a fixture — the MCP
client's background connection task is bound to the event loop it was
created in, so splitting setup/act/teardown across separate `asyncio.run`
calls (each of which spins up and tears down its own loop) leaves the client
pointed at an already-closed loop by the time the test body runs.

Not run by default — see tests/live/README.md. `pytest -m live_infra` to run.
"""

from __future__ import annotations

import asyncio
import json
import os

import pytest

from meeting_voice_agent import mcp_tools
from meeting_voice_agent.config import McpConfig
from meeting_voice_agent.mcp_tools import find_raw_tool

pytestmark = pytest.mark.live_infra


def _config() -> McpConfig:
    base_url = os.environ.get("MVA_MCP_BASE_URL")
    token = os.environ.get("MVA_MCP_AUTH_TOKEN")
    if not base_url or not token:
        pytest.skip(
            "MVA_MCP_BASE_URL and MVA_MCP_AUTH_TOKEN are not set — no live Core "
            "instance/token to test against. Run `mix platform.seed_meeting_voice_agent "
            "--owner <email>` against a running Core instance to mint one, then set "
            "MVA_MCP_BASE_URL=http://<host>/mcp and MVA_MCP_AUTH_TOKEN=<printed token>."
        )
    return McpConfig(base_url=base_url, auth_token=token, client_session_timeout_seconds=10.0)


def _unwrap(mcp_text_result) -> dict:
    """MCP's default single-content resolver returns the content item's own
    `model_dump_json()` as a string; unwrap that, then the JSON text inside
    it (Core's actual tool return value) into a plain dict."""
    return json.loads(json.loads(mcp_text_result)["text"])


def test_tool_call_executes_a_real_mcp_tool_and_returns_its_result():
    """`space_create` (the `space` bundle stage 2 granted) really creates a
    Burrow space and really returns it — this is the tool-call path this
    stage wires, exercised against Core's real `Platform.Federation.ToolSurface`
    and `ToolAuthorization`, not a mock."""
    config = _config()

    async def run():
        toolset = mcp_tools.build_mcp_toolset(config)
        try:
            await toolset.setup()
        except Exception as exc:  # noqa: BLE001 - reachability probe, not a real handler
            pytest.skip(f"could not connect to Core MCP endpoint at {config.base_url}: {exc!r}")

        space_create = find_raw_tool(toolset, "space_create")
        assert space_create is not None, (
            "'space_create' not in this runtime's granted tools — check the 'space' "
            "bundle in stage 2's allowed_bundles grant"
        )

        result = await space_create({"name": "mva-stage3-live-test"})
        created = _unwrap(result)
        assert created["name"] == "mva-stage3-live-test"
        assert created["id"]

        await toolset.aclose()

    asyncio.run(run())


def test_handoff_tool_posts_to_the_correct_chat_space():
    """End-to-end: create a real space, derive its room name the same way
    Core does (`space-<uuid>`), then confirm `post_to_meeting_chat` really
    posts into THAT space (read back via the real `space_get_context`)."""
    config = _config()

    async def run():
        toolset = mcp_tools.build_mcp_toolset(config)
        try:
            await toolset.setup()
        except Exception as exc:  # noqa: BLE001 - reachability probe, not a real handler
            pytest.skip(f"could not connect to Core MCP endpoint at {config.base_url}: {exc!r}")

        space_create = find_raw_tool(toolset, "space_create")
        space_get_context = find_raw_tool(toolset, "space_get_context")
        assert space_create is not None
        assert space_get_context is not None

        created = _unwrap(await space_create({"name": "mva-stage3-handoff-live-test"}))
        space_id = created["id"]
        room_name = f"space-{space_id}"

        handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, room_name)
        marker_text = "mva-stage3-live-handoff-marker: the real answer goes here"
        result = await handoff(content=marker_text)
        assert "message_id" in str(result)

        ctx = _unwrap(await space_get_context({"space_id": space_id}))
        assert marker_text in ctx["recent_activity_summary"]

        await toolset.aclose()

    asyncio.run(run())
