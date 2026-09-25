"""Unit tests for the MCP tool-surface wiring (task 01a0d4a0 stage 3).

Every test here is a pure seam test: the `mcp` package's real client
transport is never opened, only `MCPServerHTTP`/`MCPToolset` construction
(pure Python object creation, no network) and the local
`post_to_meeting_chat` hand-off wrapper (called directly, against a fake
toolset standing in for a connected one). No live network call — the
network-backed confirmation of this same wiring lives in
`tests/live/test_mcp_live.py`, marked `live_infra`.
"""

import base64
from unittest.mock import AsyncMock, patch

import pytest
from livekit.agents.llm import function_tool
from livekit.agents.llm.mcp import MCPServerHTTP, MCPToolset
from livekit.agents.llm.tool_context import ToolError

from meeting_voice_agent import mcp_tools
from meeting_voice_agent.config import AgentConfig

VALID_ROOM = "space-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"


def _fake_send_media_tool(impl):
    """A real `RawFunctionTool` named 'send_media', like `MCPServer._make_function_tool`
    would produce from Core's actual `send_media` MCP tool — but backed by `impl`
    instead of a real client round trip."""
    return function_tool(
        impl,
        raw_schema={
            "name": "send_media",
            "description": "send a message with attachments to a space",
            "parameters": {"type": "object", "properties": {}},
        },
    )


class _FakeToolset:
    """Stands in for a `MCPToolset` whose `.setup()` already ran — exposes
    `.tools` the same way the real one does, without opening a connection."""

    def __init__(self, tools):
        self.tools = tools


def test_space_id_from_room_name_matches_convention():
    space_id = mcp_tools.space_id_from_room_name(VALID_ROOM)
    assert space_id == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"


@pytest.mark.parametrize(
    "room_name",
    ["not-a-space-room", "space-not-a-uuid", "", "space--1", "meeting-0199a1b2"],
)
def test_space_id_from_room_name_returns_none_for_non_matching(room_name):
    assert mcp_tools.space_id_from_room_name(room_name) is None


def test_build_mcp_server_uses_config_url_and_bearer_token():
    config = AgentConfig.from_env().mcp.__class__(
        base_url="http://core.example/mcp",
        auth_token="s3cr3t",
        client_session_timeout_seconds=7.5,
    )

    with patch.object(mcp_tools, "MCPServerHTTP") as mock_ctor:
        mcp_tools.build_mcp_server(config)

    mock_ctor.assert_called_once_with(
        url="http://core.example/mcp",
        headers={"Authorization": "Bearer s3cr3t"},
        client_session_timeout_seconds=7.5,
    )


def test_build_mcp_toolset_wraps_injected_server():
    config = AgentConfig.from_env()
    fake_server = object()

    toolset = mcp_tools.build_mcp_toolset(config.mcp, mcp_server=fake_server)

    assert isinstance(toolset, MCPToolset)
    assert toolset._mcp_server is fake_server
    assert toolset.id == "suite"


def test_build_mcp_toolset_builds_server_from_config_when_not_injected():
    config = AgentConfig.from_env()

    with patch.object(mcp_tools, "build_mcp_server") as mock_build_server:
        mock_build_server.return_value = object()
        mcp_tools.build_mcp_toolset(config.mcp)

    mock_build_server.assert_called_once_with(config.mcp)


def test_handoff_tool_calls_send_media_with_pinned_space_id():
    send_media_impl = AsyncMock(return_value={"message_id": "m1"})
    toolset = _FakeToolset([_fake_send_media_tool(send_media_impl)])

    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, VALID_ROOM)
    result = _call_tool(handoff, content="here is the long answer")

    send_media_impl.assert_awaited_once()
    call_args = send_media_impl.await_args.args[0]
    assert call_args["space_id"] == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    assert call_args["content"] == "here is the long answer"
    # send_media's own Core-side implementation refuses a call with no
    # file_path/file_paths/file_base64 (see mcp_tools.py's docstring), so
    # the wrapper always attaches base64-encoded content as the attachment
    # -- task 01a0d4a0 stage 5: a local temp file path (the old approach)
    # is unreadable by Core once the worker and Core run on different
    # hosts, which is exactly what Dalton's live moon run hit (:enoent).
    assert call_args["filename"] == "response.md"
    assert base64.b64decode(call_args["file_base64"]).decode("utf-8") == "here is the long answer"
    assert "file_path" not in call_args
    assert "file_paths" not in call_args
    assert result == {"message_id": "m1"}


def test_handoff_tool_prefers_explicit_space_id_over_room_name_derivation():
    # Task 01a0d4a0 stage 5 item 3: the job metadata's space_id is the
    # authoritative source once agent.py parses it -- it must win over
    # (and not require) deriving from the room name.
    send_media_impl = AsyncMock(return_value={"message_id": "m1"})
    toolset = _FakeToolset([_fake_send_media_tool(send_media_impl)])

    explicit_space_id = "abababab-0000-4000-8000-000000000000"
    handoff = mcp_tools.build_meeting_chat_handoff_tool(
        toolset, VALID_ROOM, space_id=explicit_space_id
    )
    _call_tool(handoff, content="anything")

    call_args = send_media_impl.await_args.args[0]
    assert call_args["space_id"] == explicit_space_id


def test_handoff_tool_falls_back_to_room_name_when_no_explicit_space_id_given():
    send_media_impl = AsyncMock(return_value={"message_id": "m1"})
    toolset = _FakeToolset([_fake_send_media_tool(send_media_impl)])

    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, VALID_ROOM, space_id=None)
    _call_tool(handoff, content="anything")

    call_args = send_media_impl.await_args.args[0]
    assert call_args["space_id"] == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"


def test_handoff_tool_raises_when_no_space_id_resolvable_at_all():
    send_media_impl = AsyncMock()
    toolset = _FakeToolset([_fake_send_media_tool(send_media_impl)])

    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, "not-a-space-room", space_id=None)

    with pytest.raises(ToolError, match="no space_id was provided in the job metadata"):
        _call_tool(handoff, content="anything")

    send_media_impl.assert_not_awaited()


def test_handoff_tool_raises_when_send_media_not_granted():
    toolset = _FakeToolset([])  # e.g. messaging bundle not granted

    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, VALID_ROOM)

    with pytest.raises(ToolError, match="not in this runtime's granted MCP tool surface"):
        _call_tool(handoff, content="anything")


def test_handoff_tool_raises_for_room_name_outside_space_convention():
    send_media_impl = AsyncMock()
    toolset = _FakeToolset([_fake_send_media_tool(send_media_impl)])

    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, "not-a-space-room")

    with pytest.raises(ToolError, match="does not match Core's 'space-<uuid>'"):
        _call_tool(handoff, content="anything")

    send_media_impl.assert_not_awaited()


def test_mcp_server_http_transport_matches_core_mcp_route():
    # PlatformWeb's `/mcp` routes are streamable-HTTP (`post`/`get` under
    # `scope "/mcp"`), which MCPServerHTTP auto-detects from the URL suffix.
    # If this ever regresses to SSE-detection, tool calls to Core would use
    # the wrong wire protocol silently, so pin it explicitly here.
    server = MCPServerHTTP(url="https://suite.example.com/mcp", headers={})
    assert server._use_streamable_http is True


def _call_tool(tool, **kwargs):
    import asyncio

    return asyncio.run(tool(**kwargs))
