"""External tool-call telemetry over the LiveKit data channel (task 01a0d4a0
stage 4, round 2).

A live test run found the latency harness's `tool_call` field is
*always* `False`: nothing in this service ever told an outside observer that
a tool call happened, so the harness had no signal to record even when the
worker's own logs showed a real ~3.0s tool-call turnaround. This module is
the fix's worker-side half:

- `attach_tool_call_telemetry` listens for the `AgentSession`'s
  `function_tools_executed` event (fired after every batch of tool calls
  finishes — see `livekit.agents.voice.events.FunctionToolsExecutedEvent`)
  and publishes one small JSON data message per batch on the room's data
  channel, topic `TOOL_CALL_TOPIC`.
- `tool_call_payload` / `parse_tool_call_names` are the pure
  serialize/parse pair, kept here (not duplicated) so the publisher and any
  reader — the live harness in `latency_harness_live.py`, or any other
  room observer — agree on the wire shape by construction.

This is in-room telemetry between two LiveKit participants, the same
transport class `AgentStateChangedEvent` already uses via a participant
attribute (`livekit.agents.voice.room_io.room_io.ATTRIBUTE_AGENT_STATE`) —
deliberately not a new Core/MCP surface, per this stage's "no new Core
plumbing" constraint.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from livekit import rtc
    from livekit.agents import AgentSession
    from livekit.agents.voice.events import FunctionToolsExecutedEvent

logger = logging.getLogger("meeting_voice_agent.tool_telemetry")

#: Data-channel topic external observers (the live latency harness) listen on.
TOOL_CALL_TOPIC = "mva.tool_call"


def tool_call_payload(event: FunctionToolsExecutedEvent) -> list[dict[str, Any]]:
    """Pure: the JSON-able payload for one `function_tools_executed` event.

    One dict per call: `{name, call_id, is_error, at}`. `at` is wall-clock
    (`time.time()`), recorded only for cross-process debugging/ordering —
    the live harness deliberately does NOT use it for latency arithmetic
    (see `latency_harness_live.py`'s `_ToolCallCollector`): it is a
    different process's wall clock, not safely comparable to the harness's
    own `time.monotonic()`.

    Takes anything with a `.zipped()` returning `(call, output)` pairs where
    `call` has `.name`/`.call_id` and `output` has `.is_error` — i.e. a real
    `FunctionToolsExecutedEvent`, or (for tests) any duck-typed stand-in —
    so this stays testable without constructing the real pydantic event.
    """
    return [
        {
            "name": call.name,
            "call_id": call.call_id,
            "is_error": bool(getattr(output, "is_error", False)),
            "at": time.time(),
        }
        for call, output in event.zipped()
    ]


def parse_tool_call_names(
    topic: str | None,
    participant_identity: str | None,
    data: bytes,
    agent_identity_prefix: str,
) -> list[str]:
    """Pure: the tool names named by one room data packet, or `[]`.

    Returns `[]` (never raises) for a packet that isn't `TOOL_CALL_TOPIC`
    telemetry, isn't from a participant matching `agent_identity_prefix`, or
    whose payload doesn't parse as the shape `tool_call_payload` produces —
    a malformed or foreign data packet is not a crash, it's just not tool-
    call telemetry.
    """
    if topic != TOOL_CALL_TOPIC:
        return []
    if participant_identity is None or not participant_identity.startswith(agent_identity_prefix):
        return []
    try:
        entries = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return []
    if not isinstance(entries, list):
        return []
    return [
        entry["name"]
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("name"), str) and entry["name"]
    ]


def attach_tool_call_telemetry(session: AgentSession, room: rtc.Room) -> None:
    """Publish a `TOOL_CALL_TOPIC` data message for every tool call this session executes.

    Best-effort: a publish failure (e.g. the room already disconnected) is
    logged, never raised into the session's event dispatch — telemetry must
    not be able to take down a live meeting.
    """

    def _on_function_tools_executed(event: FunctionToolsExecutedEvent) -> None:
        payload = tool_call_payload(event)
        if not payload:
            return
        data = json.dumps(payload).encode("utf-8")

        async def _publish() -> None:
            try:
                await room.local_participant.publish_data(
                    data, topic=TOOL_CALL_TOPIC, reliable=True
                )
            except Exception:
                logger.exception("failed to publish %s telemetry", TOOL_CALL_TOPIC)

        asyncio.ensure_future(_publish())

    session.on("function_tools_executed", _on_function_tools_executed)
