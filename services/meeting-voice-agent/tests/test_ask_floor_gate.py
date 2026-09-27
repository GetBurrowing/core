"""Unit tests for the hold-to-ask listening-window gate (task 01a0e47c
stage 2).

Pure seam tests for `parse_ask_floor_event`/`AskFloorGate` (no `rtc.Room`,
no `AgentSession`, no asyncio event loop needed), plus wiring tests for
`attach_ask_floor_gate` against a mocked `room`/`session` -- same split as
`test_tool_telemetry.py` (pure parse/payload tests) vs `test_agent.py`
(wiring, patched calls).
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from unittest.mock import MagicMock

from meeting_voice_agent import ask_floor_gate

# ── parse_ask_floor_event ────────────────────────────────────────────────


def _payload(event: str) -> bytes:
    return json.dumps({"event": event}).encode("utf-8")


def test_parse_ask_floor_event_open():
    assert (
        ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
        == "open"
    )


def test_parse_ask_floor_event_closed():
    assert (
        ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("closed"))
        == "closed"
    )


def test_parse_ask_floor_event_ignores_wrong_topic():
    assert ask_floor_gate.parse_ask_floor_event("some-other-topic", _payload("open")) is None


def test_parse_ask_floor_event_ignores_unknown_event_value():
    assert (
        ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("sideways"))
        is None
    )


def test_parse_ask_floor_event_malformed_json_returns_none_not_raise():
    assert ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, b"not json") is None


def test_parse_ask_floor_event_non_utf8_bytes_returns_none_not_raise():
    assert (
        ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, b"\xff\xfe\x00")
        is None
    )


def test_parse_ask_floor_event_non_object_json_returns_none():
    payload = json.dumps(["open"]).encode("utf-8")
    assert ask_floor_gate.parse_ask_floor_event(ask_floor_gate.ASK_FLOOR_TOPIC, payload) is None


# ── AskFloorGate: discard-before-open / discard-after-close-plus-grace ──


def test_gate_starts_closed_before_any_open():
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    assert gate.should_forward_audio(now=0.0) is False
    assert gate.should_forward_audio(now=1000.0) is False


def test_gate_forwards_audio_while_open():
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    gate.open()
    assert gate.should_forward_audio(now=0.0) is True
    assert gate.should_forward_audio(now=500.0) is True


def test_gate_forwards_audio_during_grace_window_after_close():
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    gate.open()
    gate.close(now=10.0)
    # 150ms after close, well inside the 300ms grace window.
    assert gate.should_forward_audio(now=10.150) is True


def test_gate_stops_forwarding_audio_once_grace_window_elapses():
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    gate.open()
    gate.close(now=10.0)
    # 301ms after close -- one ms past the 300ms grace window.
    assert gate.should_forward_audio(now=10.301) is False


def test_gate_zero_grace_closes_immediately():
    gate = ask_floor_gate.AskFloorGate(grace_ms=0)
    gate.open()
    gate.close(now=10.0)
    assert gate.should_forward_audio(now=10.0) is False


def test_gate_reopen_during_grace_cancels_the_pending_close():
    """A fresh open() during the grace window must make should_forward_audio
    true again, and NOT re-close on its own once the original grace window's
    clock would have elapsed -- open() clears closed_at outright."""
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    gate.open()
    gate.close(now=10.0)
    gate.open()  # re-claimed mid-grace
    assert gate.should_forward_audio(now=10.150) is True
    # Past what would have been the original grace deadline (10.3) -- still
    # open, because open() is not itself time-bounded.
    assert gate.should_forward_audio(now=10.5) is True


def test_gate_close_without_ever_opening_is_a_noop_still_closed():
    gate = ask_floor_gate.AskFloorGate(grace_ms=300)
    gate.close(now=5.0)
    # A close before any open still starts a grace window from `closed_at`
    # -- but since is_open was already False, should_forward_audio is
    # governed only by the grace window arithmetic, exactly as any other
    # close would be. This pins that behavior rather than asserting a
    # stronger "double-close is special" rule that doesn't exist.
    assert gate.should_forward_audio(now=5.1) is True
    assert gate.should_forward_audio(now=5.301) is False


# ── attach_ask_floor_gate wiring ─────────────────────────────────────────


@dataclass
class _FakeParticipant:
    identity: str | None


class _FakeDataPacket:
    def __init__(self, topic: str | None, data: bytes, participant=None) -> None:
        self.topic = topic
        self.data = data
        self.participant = participant


def _mock_room():
    room = MagicMock()
    handlers: dict[str, callable] = {}

    def _on(event_name, handler):
        handlers[event_name] = handler

    room.on.side_effect = _on
    room._handlers = handlers
    return room


def test_attach_ask_floor_gate_detaches_input_immediately_before_any_signal():
    session = MagicMock()
    room = _mock_room()

    ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=300)

    session.input.set_audio_enabled.assert_called_once_with(False)


def test_attach_ask_floor_gate_registers_data_received_handler():
    session = MagicMock()
    room = _mock_room()

    ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=300)

    assert "data_received" in room._handlers


def test_attach_ask_floor_gate_open_signal_enables_input():
    session = MagicMock()
    room = _mock_room()
    ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=300)
    session.input.set_audio_enabled.reset_mock()

    room._handlers["data_received"](
        _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
    )

    session.input.set_audio_enabled.assert_called_once_with(True)


async def _drain_pending():
    # Let any asyncio.ensure_future(...) callbacks scheduled by the handler
    # under test actually run before assertions inspect their side effects.
    await asyncio.sleep(0)


def test_attach_ask_floor_gate_closed_signal_detaches_after_grace(monkeypatch):
    async def _run():
        session = MagicMock()
        room = _mock_room()
        ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=10)
        session.input.set_audio_enabled.reset_mock()

        room._handlers["data_received"](
            _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
        )
        session.input.set_audio_enabled.assert_called_once_with(True)
        session.input.set_audio_enabled.reset_mock()

        room._handlers["data_received"](
            _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("closed"))
        )
        # Not detached yet -- still inside the (tiny) grace window.
        session.input.set_audio_enabled.assert_not_called()

        await asyncio.sleep(0.03)  # > grace_ms
        session.input.set_audio_enabled.assert_called_once_with(False)

    asyncio.run(_run())


def test_attach_ask_floor_gate_reopen_during_grace_cancels_pending_detach():
    async def _run():
        session = MagicMock()
        room = _mock_room()
        ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=10)

        room._handlers["data_received"](
            _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
        )
        room._handlers["data_received"](
            _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("closed"))
        )
        session.input.set_audio_enabled.reset_mock()

        # Re-claimed before the grace window (10ms) elapses.
        room._handlers["data_received"](
            _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
        )

        await asyncio.sleep(0.03)  # past the original grace deadline

        # The pending detach must have been cancelled -- input must never
        # have been disabled after the re-open.
        for call in session.input.set_audio_enabled.call_args_list:
            assert call.args != (False,)

    asyncio.run(_run())


def test_attach_ask_floor_gate_ignores_unrelated_data_packets():
    session = MagicMock()
    room = _mock_room()
    ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=300)
    session.input.set_audio_enabled.reset_mock()

    room._handlers["data_received"](_FakeDataPacket("mva.tool_call", b'[{"name": "space_list"}]'))

    session.input.set_audio_enabled.assert_not_called()


def test_attach_ask_floor_gate_zero_grace_detaches_synchronously_on_close():
    session = MagicMock()
    room = _mock_room()
    ask_floor_gate.attach_ask_floor_gate(session, room, grace_ms=0)

    room._handlers["data_received"](
        _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("open"))
    )
    session.input.set_audio_enabled.reset_mock()

    room._handlers["data_received"](
        _FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, _payload("closed"))
    )

    session.input.set_audio_enabled.assert_called_once_with(False)
