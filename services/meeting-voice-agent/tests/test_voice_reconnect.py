"""Voice-tab 1:1: a client disconnect must not close the session (task 01a174e2 stage 2).

The SDK default `RoomOptions.close_on_disconnect=True` makes `RoomIO` call
`AgentSession._close_soon(PARTICIPANT_DISCONNECTED)` when the linked
participant leaves with CLIENT_INITIATED. The Voice tab drops and rejoins the
room as a matter of course, so that default closed the session the client was
about to come back to. `build_room_options(identity, "voice_1to1")` turns it
off; meeting mode keeps the default.

`RoomIO.start()` needs a real connected `rtc.Room`, so these tests build a
real `RoomIO` with the options under test on a fake room and drive its
`_on_participant_connected` / `_on_participant_disconnected` handlers
directly -- the same handlers `start()` registers on the room. The first
group uses a stub session; the second uses the real `AgentSession` from
`tests/test_voice_turn_commit.py`'s rig so the whole hold, disconnect,
reconnect, hold flow is exercised end to end.
"""

from __future__ import annotations

import asyncio
import logging
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from livekit import rtc
from livekit.agents.voice.events import CloseReason
from livekit.agents.voice.room_io import RoomIO

from meeting_voice_agent.agent import build_room_options
from tests.test_voice_turn_commit import TRANSCRIPT, _wait_until, build_rig

IDENTITY = "user:test-1"
CLOSE_LOG = "closing agent session due to participant disconnect"
NO_AUDIO_INPUT_LOG = "Cannot enable audio input when it's not set"


def _participant(identity: str = IDENTITY, *, reason=None) -> SimpleNamespace:
    return SimpleNamespace(
        sid=f"PA_{identity}",
        identity=identity,
        kind=rtc.ParticipantKind.PARTICIPANT_KIND_STANDARD,
        attributes={},
        disconnect_reason=reason,
    )


def _fake_room() -> SimpleNamespace:
    """What RoomIO's participant handlers read off the room."""
    return SimpleNamespace(
        name="voice-room",
        local_participant=SimpleNamespace(identity="agent:burrow"),
        remote_participants={},
        isconnected=lambda: True,
    )


def _stub_session() -> MagicMock:
    session = MagicMock()
    session._session_span = None
    return session


def _disconnect_and_reconnect(room_io: RoomIO) -> tuple[SimpleNamespace, SimpleNamespace]:
    first = _participant()
    room_io._on_participant_connected(first)
    assert room_io.linked_participant is first

    first.disconnect_reason = rtc.DisconnectReason.CLIENT_INITIATED
    room_io._on_participant_disconnected(first)
    assert room_io.linked_participant is None

    returning = _participant()
    room_io._on_participant_connected(returning)
    return first, returning


# ── stub session: the RoomIO decision itself ────────────────────────────


@pytest.mark.parametrize("identity", [IDENTITY, None])
def test_voice_1to1_client_disconnect_does_not_close_and_relinks(identity, caplog):
    async def _run():
        session = _stub_session()
        room_io = RoomIO(session, _fake_room(), options=build_room_options(identity, "voice_1to1"))

        first, returning = _disconnect_and_reconnect(room_io)

        session._close_soon.assert_not_called()
        assert room_io.linked_participant is returning
        assert [c.args[0] for c in session._on_room_io_participant_linked.call_args_list] == [
            first,
            returning,
        ]

    with caplog.at_level(logging.INFO):
        asyncio.run(_run())

    assert not any(CLOSE_LOG in r.getMessage() for r in caplog.records)


def test_voice_1to1_pinned_identity_ignores_a_different_participant():
    async def _run():
        session = _stub_session()
        room_io = RoomIO(session, _fake_room(), options=build_room_options(IDENTITY, "voice_1to1"))

        room_io._on_participant_connected(_participant("agent:other"))
        assert room_io.linked_participant is None

        _first, returning = _disconnect_and_reconnect(room_io)
        assert room_io.linked_participant is returning

    asyncio.run(_run())


@pytest.mark.parametrize("mode", [None, "meeting"])
@pytest.mark.parametrize("identity", [IDENTITY, None])
def test_meeting_mode_client_disconnect_still_closes_the_session(mode, identity, caplog):
    async def _run():
        session = _stub_session()
        room_io = RoomIO(session, _fake_room(), options=build_room_options(identity, mode))

        linked = _participant()
        room_io._on_participant_connected(linked)
        linked.disconnect_reason = rtc.DisconnectReason.CLIENT_INITIATED
        room_io._on_participant_disconnected(linked)

        session._close_soon.assert_called_once_with(reason=CloseReason.PARTICIPANT_DISCONNECTED)

    with caplog.at_level(logging.INFO):
        asyncio.run(_run())

    assert any(CLOSE_LOG in r.getMessage() for r in caplog.records)


# ── real AgentSession: hold, disconnect, reconnect, hold ────────────────


def _track_close(rig) -> tuple[list[CloseReason], list[object]]:
    close_soon_calls: list[CloseReason] = []
    close_events: list[object] = []
    real_close_soon = rig.session._close_soon

    def _close_soon(**kwargs):
        close_soon_calls.append(kwargs.get("reason"))
        return real_close_soon(**kwargs)

    rig.session._close_soon = _close_soon
    rig.session.on("close", close_events.append)
    return close_soon_calls, close_events


def test_voice_1to1_session_survives_reconnect_and_answers_the_next_hold(caplog):
    async def _run():
        rig = await build_rig(mode="voice_1to1", stt_delay=2.5)
        try:
            close_soon_calls, close_events = _track_close(rig)
            room_io = RoomIO(
                rig.session, _fake_room(), options=build_room_options(IDENTITY, "voice_1to1")
            )

            first = _participant()
            room_io._on_participant_connected(first)

            await rig.hold(3.1)
            assert await _wait_until(lambda: len(rig.llm.calls) == 1, timeout=7.0)

            first.disconnect_reason = rtc.DisconnectReason.CLIENT_INITIATED
            room_io._on_participant_disconnected(first)
            await asyncio.sleep(0.2)
            returning = _participant()
            room_io._on_participant_connected(returning)

            assert room_io.linked_participant is returning
            assert close_soon_calls == []

            await rig.hold(3.1)
            assert await _wait_until(lambda: len(rig.llm.calls) == 2, timeout=7.0), (
                "no second LLM call after the reconnect: the session did not survive"
            )
            await asyncio.sleep(0.5)

            assert close_soon_calls == []
            assert close_events == []
            assert rig.user_messages() == [TRANSCRIPT, TRANSCRIPT]
            assert [c.last_user_text() for c in rig.llm.calls] == [TRANSCRIPT, TRANSCRIPT]
        finally:
            await rig.aclose()

    with caplog.at_level(logging.INFO):
        asyncio.run(_run())

    messages = [r.getMessage() for r in caplog.records]
    assert not any(CLOSE_LOG in m for m in messages)
    assert not any(NO_AUDIO_INPUT_LOG in m for m in messages)


def test_meeting_mode_real_session_closes_on_client_disconnect(caplog):
    async def _run():
        rig = await build_rig(mode=None, stt_delay=2.5)
        try:
            close_soon_calls, close_events = _track_close(rig)
            room_io = RoomIO(rig.session, _fake_room(), options=build_room_options(IDENTITY, None))

            linked = _participant()
            room_io._on_participant_connected(linked)
            linked.disconnect_reason = rtc.DisconnectReason.CLIENT_INITIATED
            room_io._on_participant_disconnected(linked)

            assert close_soon_calls == [CloseReason.PARTICIPANT_DISCONNECTED]
            assert await _wait_until(lambda: close_events, timeout=3.0)
            assert close_events[0].reason == CloseReason.PARTICIPANT_DISCONNECTED
        finally:
            await rig.aclose()

    with caplog.at_level(logging.INFO):
        asyncio.run(_run())

    assert any(CLOSE_LOG in r.getMessage() for r in caplog.records)
