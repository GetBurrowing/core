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
        patch.object(agent_module.ask_floor_gate, "attach_ask_floor_gate") as mock_ask_floor,
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
    assert mock_persona_cls.call_args.kwargs["agent_roster"] == []
    mock_attach.assert_called_once_with(mock_session, ctx.room)
    mock_ask_floor.assert_called_once()
    assert mock_ask_floor.call_args.args[0] is mock_session
    assert mock_ask_floor.call_args.args[1] is ctx.room
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
    # no participant pinning, no agent roster).
    ctx = _ctx_with_job_metadata(None)
    ctx.job.metadata = "not valid json {{{"

    mock_session = MagicMock()
    mock_session.start = AsyncMock()

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session),
        patch.object(agent_module, "build_tool_surface", return_value=[]) as mock_tools,
        patch.object(agent_module, "MeetingVoiceAgent") as mock_persona_cls,
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry"),
    ):
        asyncio.run(agent_module.entrypoint(ctx))

    assert mock_tools.call_args.kwargs["space_id"] is None
    assert mock_persona_cls.call_args.kwargs["agent_roster"] == []
    assert mock_session.start.await_args.kwargs["room_options"] is NOT_GIVEN


def test_entrypoint_passes_agent_roster_from_job_metadata():
    # Task 01a0f8f5 stage 1/2: `Platform.Meetings.dispatch_meeting_join_via_livekit/4`
    # stamps `agent_roster` into the same job-metadata blob as `space_id`/
    # `human_identity` -- it must reach the persona, not be silently dropped.
    roster = [
        {"name": "Dana", "slug": "dana", "capability": "Visual design, UI/UX, branding"},
        {"name": "Scout", "slug": "scout", "capability": None},
    ]
    ctx = _ctx_with_job_metadata(
        {
            "space_id": "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
            "meeting_id": "some-meeting-id",
            "human_identity": "user:abc-123",
            "agent_roster": roster,
        }
    )

    mock_session = MagicMock()
    mock_session.start = AsyncMock()

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session),
        patch.object(agent_module, "build_tool_surface", return_value=[]),
        patch.object(agent_module, "MeetingVoiceAgent") as mock_persona_cls,
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry"),
    ):
        asyncio.run(agent_module.entrypoint(ctx))

    assert mock_persona_cls.call_args.kwargs["agent_roster"] == roster


def test_entrypoint_defaults_agent_roster_to_empty_when_key_absent():
    # A dispatch predating task 01a0f8f5 (no `agent_roster` key at all)
    # must degrade to today's generic-only behavior, not crash.
    ctx = _ctx_with_job_metadata({"space_id": "some-space-id", "meeting_id": "some-meeting-id"})

    mock_session = MagicMock()
    mock_session.start = AsyncMock()

    with (
        patch.object(agent_module, "build_agent_session", return_value=mock_session),
        patch.object(agent_module, "build_tool_surface", return_value=[]),
        patch.object(agent_module, "MeetingVoiceAgent") as mock_persona_cls,
        patch.object(agent_module.tool_telemetry, "attach_tool_call_telemetry"),
    ):
        asyncio.run(agent_module.entrypoint(ctx))

    assert mock_persona_cls.call_args.kwargs["agent_roster"] == []


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


# ── Join identity (task 01a1117f stage 2) ──────────────────────────────────

BURROW_ID = "01a0db75-037c-7001-96ff-d2a14fdb707f"

FULL_METADATA = {
    "space_id": "01a11174-c5b0-7002-9800-9145a91c7455",
    "human_identity": "user:00000000-0000-4000-8000-000000000001",
    "agent_id": BURROW_ID,
    "agent_identity": f"agent:{BURROW_ID}",
    "agent_name": "Burrow",
}


def test_accept_arguments_joins_under_the_agent_identity_core_sent():
    assert agent_module.accept_arguments(FULL_METADATA) == {
        "identity": f"agent:{BURROW_ID}",
        "name": "Burrow",
        "attributes": {"suite.agent_id": BURROW_ID},
    }


def test_accept_arguments_falls_back_to_the_sdk_default_without_metadata():
    # `{}` means `req.accept()` with no arguments: the SDK mints
    # `"agent-" + job.id`, which is what the worker did before this stage, so
    # a new worker under an old Core joins exactly as it always has.
    assert agent_module.accept_arguments({}) == {}
    assert agent_module.accept_arguments(agent_module.parse_job_metadata(None)) == {}
    assert agent_module.accept_arguments(agent_module.parse_job_metadata("{not json")) == {}
    assert agent_module.accept_arguments(agent_module.parse_job_metadata('["a"]')) == {}


def test_accept_arguments_falls_back_when_agent_identity_is_not_agent_prefixed():
    for bad in (
        "burrow",
        f"user:{BURROW_ID}",
        f"agent-{BURROW_ID}",
        "agent:",
        "",
        None,
        42,
        ["agent:x"],
    ):
        metadata = {**FULL_METADATA, "agent_identity": bad}
        assert agent_module.accept_arguments(metadata) == {}, bad


def test_accept_arguments_never_derives_the_identity_from_the_worker_name(monkeypatch):
    # Several Suite agents can share one worker name, so only the dispatch
    # metadata may name the agent.
    monkeypatch.setenv("MVA_WORKER_AGENT_NAME", "meeting-voice-agent")
    metadata = {k: v for k, v in FULL_METADATA.items() if k != "agent_identity"}
    assert agent_module.accept_arguments(metadata) == {}


def test_accept_arguments_omits_blank_name_and_agent_id():
    metadata = {"agent_identity": f"agent:{BURROW_ID}", "agent_name": "", "agent_id": None}
    assert agent_module.accept_arguments(metadata) == {"identity": f"agent:{BURROW_ID}"}


def _job_request(metadata_json: str):
    req = MagicMock()
    req.id = "AJ_testJob1"
    req.job = MagicMock()
    req.job.metadata = metadata_json
    req.accept = AsyncMock()
    req.reject = AsyncMock()
    return req


def test_request_fnc_accepts_with_the_agent_identity_from_job_metadata():
    req = _job_request(json.dumps(FULL_METADATA))

    asyncio.run(agent_module.request_fnc(req))

    req.accept.assert_awaited_once_with(
        identity=f"agent:{BURROW_ID}",
        name="Burrow",
        attributes={"suite.agent_id": BURROW_ID},
    )
    req.reject.assert_not_called()


def test_request_fnc_accepts_with_sdk_defaults_and_never_rejects_on_bad_metadata():
    for raw in ("", "{not json", json.dumps({"space_id": "s"})):
        req = _job_request(raw)

        asyncio.run(agent_module.request_fnc(req))

        req.accept.assert_awaited_once_with()
        req.reject.assert_not_called()


def test_build_worker_options_wires_request_fnc():
    options = agent_module.build_worker_options(AgentConfig.from_env())

    assert options.request_fnc is agent_module.request_fnc
