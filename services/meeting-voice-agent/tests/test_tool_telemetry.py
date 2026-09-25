"""Unit tests for the tool-call telemetry publish/parse pair (task 01a0d4a0
stage 4 round 2). Pure seam tests: no `AgentSession`, no `rtc.Room`, no
network -- `tool_call_payload` only needs something with a `.zipped()`
method, and `parse_tool_call_names` only needs plain strings/bytes.
`attach_tool_call_telemetry`'s wiring itself is covered by
`tests/test_agent.py` (patched call) since it needs a real `AgentSession`/
`rtc.Room` to do anything beyond registering a callback.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from meeting_voice_agent import tool_telemetry


@dataclass
class _FakeCall:
    name: str
    call_id: str


@dataclass
class _FakeOutput:
    is_error: bool = False


class _FakeEvent:
    """Stands in for `FunctionToolsExecutedEvent` -- `tool_call_payload` only
    ever calls `.zipped()`."""

    def __init__(self, pairs):
        self._pairs = pairs

    def zipped(self):
        return self._pairs


def test_tool_call_payload_serializes_name_call_id_and_error_flag():
    event = _FakeEvent(
        [
            (_FakeCall(name="space_list", call_id="call_1"), _FakeOutput(is_error=False)),
            (_FakeCall(name="mail_draft_create", call_id="call_2"), _FakeOutput(is_error=True)),
        ]
    )

    payload = tool_telemetry.tool_call_payload(event)

    assert [entry["name"] for entry in payload] == ["space_list", "mail_draft_create"]
    assert [entry["call_id"] for entry in payload] == ["call_1", "call_2"]
    assert [entry["is_error"] for entry in payload] == [False, True]
    assert all(isinstance(entry["at"], float) for entry in payload)


def test_tool_call_payload_empty_event_is_empty_list():
    assert tool_telemetry.tool_call_payload(_FakeEvent([])) == []


AGENT_IDENTITY = "meeting-voice-agent-worker-1"


def _payload_bytes(names):
    return json.dumps([{"name": name, "call_id": "c", "is_error": False} for name in names]).encode(
        "utf-8"
    )


def test_parse_tool_call_names_happy_path():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC,
        AGENT_IDENTITY,
        _payload_bytes(["space_list"]),
        "meeting-voice-agent",
    )
    assert names == ["space_list"]


def test_parse_tool_call_names_multiple_entries_in_one_packet():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC,
        AGENT_IDENTITY,
        _payload_bytes(["space_list", "post_to_meeting_chat"]),
        "meeting-voice-agent",
    )
    assert names == ["space_list", "post_to_meeting_chat"]


def test_parse_tool_call_names_ignores_wrong_topic():
    names = tool_telemetry.parse_tool_call_names(
        "some-other-topic", AGENT_IDENTITY, _payload_bytes(["space_list"]), "meeting-voice-agent"
    )
    assert names == []


def test_parse_tool_call_names_ignores_non_agent_participant():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC,
        "latency-harness-12345",
        _payload_bytes(["space_list"]),
        "meeting-voice-agent",
    )
    assert names == []


def test_parse_tool_call_names_none_participant_identity_is_ignored():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC, None, _payload_bytes(["space_list"]), "meeting-voice-agent"
    )
    assert names == []


def test_parse_tool_call_names_malformed_json_returns_empty_not_raise():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC, AGENT_IDENTITY, b"not json", "meeting-voice-agent"
    )
    assert names == []


def test_parse_tool_call_names_non_utf8_bytes_returns_empty_not_raise():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC, AGENT_IDENTITY, b"\xff\xfe\x00", "meeting-voice-agent"
    )
    assert names == []


def test_parse_tool_call_names_non_list_json_returns_empty():
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC,
        AGENT_IDENTITY,
        json.dumps({"name": "space_list"}).encode("utf-8"),
        "meeting-voice-agent",
    )
    assert names == []


def test_parse_tool_call_names_drops_entries_missing_a_name():
    payload = json.dumps([{"call_id": "c"}, {"name": "space_list", "call_id": "c2"}]).encode(
        "utf-8"
    )
    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC, AGENT_IDENTITY, payload, "meeting-voice-agent"
    )
    assert names == ["space_list"]
