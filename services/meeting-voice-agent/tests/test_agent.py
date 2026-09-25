"""Worker wiring tests. No real LiveKit connection, no real model load:
ctx.connect / session.start are AsyncMocks, build_agent_session is mocked.
"""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

from livekit.agents.types import NOT_GIVEN
from livekit.agents.voice.room_io import RoomOptions

from meeting_voice_agent import agent as agent_module
from meeting_voice_agent.config import AgentConfig


def _ctx_with_job_metadata(metadata: dict | None = None):
    ctx = MagicMock()
    ctx.connect = AsyncMock()
    ctx.room = MagicMock()
    ctx.room.name = "space-00000000-0000-4000-8000-000000000000"
    ctx.job = MagicMock()
    ctx.job.metadata = json.dumps(metadata) if metadata is not None else ""
    return ctx


def test_build_worker_options_uses_configured_agent_name(monkeypatch):
    monkeypatch.setenv("MVA_WORKER_AGENT_NAME", "custom-worker-name")
    config = AgentConfig.from_env()

    options = agent_module.build_worker_options(config)

    assert options.entrypoint_fnc is agent_module.entrypoint
    assert options.agent_name == "custom-worker-name"


def test_entrypoint_connects_builds_session_and_starts():
    ctx = _ctx_with_job_metadata({})

    mock_session = MagicMock()
    mock_session.start = AsyncMock()
    fake_tools = [MagicMock(name="toolset"), MagicMock(name="handoff_tool")]

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session) as mock_build,
        patch.object(agent_module, "build_tool_surface", return_value=fake_tools) as mock_tools,
        patch.object(agent_module, "MeetingVoiceAgent") as mock_persona_cls,
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry") as mock_attach,
    ):
        mock_agent_instance = MagicMock()
        mock_persona_cls.return_value = mock_agent_instance

        asyncio.run(agent_module.entrypoint(ctx))

    ctx.connect.assert_awaited_once()
    mock_build.assert_called_once()
    mock_tools.assert_called_once()
    assert mock_tools.call_args.args[1] == ctx.room.name
    assert mock_tools.call_args.kwargs["space_id"] is None
    mock_persona_cls.assert_called_once()
    assert mock_persona_cls.call_args.kwargs["tools"] == fake_tools
    assert mock_persona_cls.call_args.kwargs["space_id"] is None
    mock_attach.assert_called_once_with(mock_session, ctx.room)
    mock_session.start.assert_awaited_once_with(
        agent=mock_agent_instance, room=ctx.room, room_options=NOT_GIVEN
    )


def test_entrypoint_parses_job_metadata_for_space_id_and_human_identity():
    # Task 01a0d4a0 stage 5 items 2+3: the job metadata
    # `Platform.Meetings.dispatch_meeting_join_via_livekit/4` stamps carries
    # `space_id` and `human_identity` -- both must reach the tool surface /
    # persona / room pinning, not be silently ignored.
    ctx = _ctx_with_job_metadata(
        {
            "space_id": "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
            "meeting_id": "some-meeting-id",
            "human_identity": "user:abc-123",
        }
    )

    mock_session = MagicMock()
    mock_session.start = AsyncMock()

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session),
        patch.object(agent_module, "build_tool_surface", return_value=[]) as mock_tools,
        patch.object(agent_module, "MeetingVoiceAgent") as mock_persona_cls,
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry"),
    ):
        asyncio.run(agent_module.entrypoint(ctx))

    assert mock_tools.call_args.kwargs["space_id"] == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    assert mock_persona_cls.call_args.kwargs["space_id"] == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    room_options = mock_session.start.await_args.kwargs["room_options"]
    assert isinstance(room_options, RoomOptions)
    assert room_options.participant_identity == "user:abc-123"


def test_entrypoint_tolerates_missing_or_malformed_job_metadata():
    # A worker started outside `Platform.Meetings` (a manual dev run, a live
    # test fixture) has empty/garbage job metadata -- entrypoint must not
    # raise, and must fall back to the old behavior (no space_id override,
    # no participant pinning).
    ctx = _ctx_with_job_metadata(None)
    ctx.job.metadata = "not valid json {{{"

    mock_session = MagicMock()
    mock_session.start = AsyncMock()

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session),
        patch.object(agent_module, "build_tool_surface", return_value=[]) as mock_tools,
        patch.object(agent_module, "MeetingVoiceAgent"),
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry"),
    ):
        asyncio.run(agent_module.entrypoint(ctx))

    assert mock_tools.call_args.kwargs["space_id"] is None
    assert mock_session.start.await_args.kwargs["room_options"] is NOT_GIVEN


def test_build_tool_surface_wires_mcp_toolset_and_handoff_tool():
    config = AgentConfig.from_env()

    with (
        patch.object(agent_module.mcp_tools, "build_mcp_toolset") as mock_build_toolset,
        patch.object(
            agent_module.mcp_tools, "build_meeting_chat_handoff_tool"
        ) as mock_build_handoff,
    ):
        mock_toolset = MagicMock(name="toolset")
        mock_handoff = MagicMock(name="handoff")
        mock_build_toolset.return_value = mock_toolset
        mock_build_handoff.return_value = mock_handoff

        tools = agent_module.build_tool_surface(config, "space-abc")

    mock_build_toolset.assert_called_once_with(config.mcp)
    mock_build_handoff.assert_called_once_with(mock_toolset, "space-abc", space_id=None)
    assert tools == [mock_toolset, mock_handoff]


def test_build_tool_surface_passes_through_explicit_space_id():
    config = AgentConfig.from_env()

    with (
        patch.object(agent_module.mcp_tools, "build_mcp_toolset"),
        patch.object(
            agent_module.mcp_tools, "build_meeting_chat_handoff_tool"
        ) as mock_build_handoff,
    ):
        agent_module.build_tool_surface(config, "space-abc", space_id="explicit-id")

    assert mock_build_handoff.call_args.kwargs["space_id"] == "explicit-id"


def test_build_room_options_pins_participant_identity_when_given():
    options = agent_module.build_room_options("user:abc-123")

    assert isinstance(options, RoomOptions)
    assert options.participant_identity == "user:abc-123"


def test_build_room_options_falls_back_to_not_given_when_no_identity():
    assert agent_module.build_room_options(None) is NOT_GIVEN
    assert agent_module.build_room_options("") is NOT_GIVEN


def test_parse_job_metadata_returns_dict_for_valid_json():
    assert agent_module.parse_job_metadata('{"space_id": "abc"}') == {"space_id": "abc"}


def test_parse_job_metadata_returns_empty_dict_for_none_or_blank():
    assert agent_module.parse_job_metadata(None) == {}
    assert agent_module.parse_job_metadata("") == {}


def test_parse_job_metadata_returns_empty_dict_for_malformed_json():
    assert agent_module.parse_job_metadata("not json") == {}


def test_parse_job_metadata_returns_empty_dict_for_non_object_json():
    assert agent_module.parse_job_metadata("[1, 2, 3]") == {}
    assert agent_module.parse_job_metadata('"just a string"') == {}
