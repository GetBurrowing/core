"""Voice-tab 1:1: the push-to-talk release commits the user turn (task 01a174e2).

Driven against a REAL `AgentSession` built through `build_agent_session`'s
voice_1to1 path (so `turn_detection="manual"` comes from the code under
test), with the network edges replaced by `tests/fakes.py`. The ask-floor
gate is attached the way `entrypoint` attaches it and fed `mva.ask_floor`
packets through a fake room's `data_received` handler.

The STT fake answers 2.5 s after the segment ends, roughly the production
trace (final transcript about 2.1 s after release). Before this task the
voice gate detached 1000 ms after release and never committed, so the turn
waited on auto turn detection, which in production overlapped the session
closing; case (a) is the regression test for that.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from unittest.mock import MagicMock, patch

from livekit.agents import AgentSession

from meeting_voice_agent import ask_floor_gate
from meeting_voice_agent import session as session_module
from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.persona import MeetingVoiceAgent
from tests.fakes import (
    FakeAudioInput,
    FakeAudioOutput,
    FakeLLM,
    FakeSTT,
    FakeTTS,
    FakeVAD,
    speech_frames,
)

TRANSCRIPT = "what is on my calendar tomorrow"
GATE_LOGGER = "meeting_voice_agent.ask_floor_gate"


class _FakeDataPacket:
    def __init__(self, topic: str, data: bytes) -> None:
        self.topic = topic
        self.data = data
        self.participant = None


class FakeRoom:
    """Just enough of `rtc.Room` for the gate: `on("data_received", ...)`."""

    def __init__(self) -> None:
        self.handlers: dict[str, object] = {}

    def on(self, event: str, handler) -> None:
        self.handlers[event] = handler

    def send(self, event: str) -> None:
        payload = json.dumps({"event": event}).encode("utf-8")
        self.handlers["data_received"](_FakeDataPacket(ask_floor_gate.ASK_FLOOR_TOPIC, payload))


@dataclass
class Rig:
    session: AgentSession
    room: FakeRoom
    audio_in: FakeAudioInput
    audio_out: FakeAudioOutput
    stt: FakeSTT
    llm: FakeLLM
    tts: FakeTTS
    turn_detector_builder: MagicMock
    interrupt_calls: list[float]
    commit_calls: list[dict]

    def user_messages(self) -> list[str]:
        return [
            item.text_content
            for item in self.session.history.items
            if getattr(item, "role", None) == "user"
        ]

    def assistant_messages(self) -> list[str]:
        return [
            item.text_content
            for item in self.session.history.items
            if getattr(item, "role", None) == "assistant"
        ]

    async def hold(self, seconds_of_speech: float) -> float:
        """open, speech frames, then (like the Voice tab, which mutes its mic
        on release) nothing more, then closed. Returns time.monotonic() at
        "closed"."""
        self.room.send("open")
        await asyncio.sleep(0.05)
        self.audio_in.push(speech_frames(seconds_of_speech))
        await asyncio.sleep(0.1)  # let the session forward the frames
        self.room.send("closed")
        return time.monotonic()

    async def aclose(self) -> None:
        await self.session.aclose()


async def build_rig(
    *, mode: str | None, stt_delay: float, transcript: str | list[str] = TRANSCRIPT
) -> Rig:
    config = AgentConfig.from_env()
    vad = FakeVAD()
    stt = FakeSTT(transcript=transcript, delay=stt_delay)
    llm = FakeLLM()
    tts = FakeTTS()
    # Meeting mode still builds a turn detector; a real one loads a model,
    # so it gets the SDK's "vad" mode. voice_1to1 must not call it at all.
    turn_detector_builder = MagicMock(return_value="vad")

    with patch.multiple(
        session_module.backends,
        build_vad=MagicMock(return_value=vad),
        build_turn_detector=turn_detector_builder,
        build_stt=MagicMock(return_value=stt),
        build_tts=MagicMock(return_value=tts),
        build_llm=MagicMock(return_value=llm),
    ):
        session = session_module.build_agent_session(config, mode)

    interrupt_calls: list[float] = []
    commit_calls: list[dict] = []
    real_interrupt = session.interrupt
    real_commit = session.commit_user_turn

    def _interrupt(**kwargs):
        interrupt_calls.append(time.monotonic())
        return real_interrupt(**kwargs)

    def _commit(**kwargs):
        commit_calls.append(kwargs)
        return real_commit(**kwargs)

    session.interrupt = _interrupt
    session.commit_user_turn = _commit

    audio_in = FakeAudioInput()
    audio_out = FakeAudioOutput()
    session.input.audio = audio_in
    session.output.audio = audio_out

    room = FakeRoom()
    # Same branch as `agent.entrypoint`, attached before `session.start()`.
    if mode == session_module.VOICE_1TO1_MODE:
        ask_floor_gate.attach_ask_floor_gate(
            session,
            room,
            config.ask_floor.grace_ms,
            commit_on_close=True,
            commit_timeout_s=config.ask_floor.voice_commit_timeout_s,
        )
    else:
        ask_floor_gate.attach_ask_floor_gate(session, room, config.ask_floor.grace_ms)

    # The worker's own agent, built the way `entrypoint` builds it (no tools).
    agent = MeetingVoiceAgent(config, drop_empty_turns=mode == session_module.VOICE_1TO1_MODE)
    await session.start(agent=agent)

    return Rig(
        session=session,
        room=room,
        audio_in=audio_in,
        audio_out=audio_out,
        stt=stt,
        llm=llm,
        tts=tts,
        turn_detector_builder=turn_detector_builder,
        interrupt_calls=interrupt_calls,
        commit_calls=commit_calls,
    )


async def _wait_until(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.02)
    return predicate()


def _gate_lines(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name == GATE_LOGGER]


# ── (a) the release commits the turn and the LLM is asked ───────────────


def test_voice_release_commits_turn_and_llm_receives_transcript(caplog):
    async def _run():
        rig = await build_rig(mode="voice_1to1", stt_delay=2.5)
        try:
            rig.turn_detector_builder.assert_not_called()
            assert rig.session.turn_detection == "manual"

            closed_at = await rig.hold(3.1)

            assert await _wait_until(lambda: rig.llm.calls, timeout=7.0), (
                "no LLM call within 7s of release: the turn was never committed"
            )
            # Give a second, unwanted call a chance to show up.
            await asyncio.sleep(0.5)

            assert len(rig.stt.recognize_returned) == 1
            stt_after = rig.stt.recognize_returned[0] - closed_at
            assert 2.4 <= stt_after <= 3.5, stt_after

            assert rig.user_messages() == [TRANSCRIPT]
            assert len(rig.llm.calls) == 1
            call = rig.llm.calls[0]
            assert call.last_user_text() == TRANSCRIPT
            assert call.at - closed_at < 4.5
            assert call.at >= rig.stt.recognize_returned[0]

            assert rig.commit_calls == [{"transcript_timeout": 4.0, "stt_flush_duration": 2.0}]
            assert await _wait_until(lambda: rig.assistant_messages(), timeout=3.0)
            assert rig.assistant_messages() == [rig.llm.reply]
        finally:
            await rig.aclose()

    with caplog.at_level(logging.INFO, logger=GATE_LOGGER):
        asyncio.run(_run())

    committed = [r for r in _gate_lines(caplog) if "committed user turn" in r.getMessage()]
    assert len(committed) == 1
    assert f"transcript {len(TRANSCRIPT)} chars" in committed[0].getMessage()


# ── (b) STT slower than the bound: bounded wait, no reply, next hold ok ─


def test_voice_commit_is_bounded_when_stt_is_slower_than_timeout(caplog):
    async def _run():
        rig = await build_rig(mode="voice_1to1", stt_delay=5.0)
        try:
            closed_wall = time.time()
            closed_at = await rig.hold(3.1)
            closed_wall += time.monotonic() - closed_at  # align to "closed"

            def _timed_out():
                return any(
                    "no transcript within 4.0s" in r.getMessage() for r in _gate_lines(caplog)
                )

            assert await _wait_until(_timed_out, timeout=6.0)
            line = next(r for r in _gate_lines(caplog) if "no transcript" in r.getMessage())
            assert line.levelno == logging.INFO
            resolved_after = line.created - closed_wall
            assert 3.9 <= resolved_after <= 4.5, resolved_after

            # the bounded commit produced no reply
            await asyncio.sleep(0.3)
            assert rig.llm.calls == []
            assert rig.user_messages() == []

            # A following hold still commits (STT back to normal speed).
            rig.stt.delay = 2.5
            await rig.hold(2.0)
            assert await _wait_until(lambda: rig.llm.calls, timeout=7.0)
            await asyncio.sleep(0.5)
            assert len(rig.llm.calls) == 1
            assert rig.llm.calls[0].last_user_text() == TRANSCRIPT
            assert rig.user_messages() == [TRANSCRIPT]
        finally:
            await rig.aclose()

    with caplog.at_level(logging.INFO, logger=GATE_LOGGER):
        asyncio.run(_run())


# ── (b2) the next press drops a late transcript, keeps a pending one ────


def test_voice_open_clears_a_late_transcript_from_a_timed_out_hold():
    """A hold whose STT outran the bound must not leak into the next hold:
    "open" clears the user turn, so the second turn carries only its own
    words."""

    async def _run():
        rig = await build_rig(
            mode="voice_1to1", stt_delay=5.0, transcript=["first hold words", "second hold words"]
        )
        try:
            closed_at = await rig.hold(2.0)
            # the late transcript of hold 1 lands (5 s), then the user presses again
            assert await _wait_until(lambda: rig.stt.recognize_returned, timeout=6.0)
            assert time.monotonic() - closed_at >= 4.9
            await asyncio.sleep(0.3)
            assert rig.llm.calls == []

            rig.stt.delay = 2.5
            await rig.hold(2.0)
            assert await _wait_until(lambda: rig.llm.calls, timeout=7.0)
            await asyncio.sleep(0.5)
            assert rig.user_messages() == ["second hold words"]
            assert [c.last_user_text() for c in rig.llm.calls] == ["second hold words"]
        finally:
            await rig.aclose()

    asyncio.run(_run())


def test_voice_quick_repress_does_not_cancel_the_pending_commit():
    """A press that lands while the previous release is still waiting for its
    transcript must not clear that turn: both questions are answered."""

    async def _run():
        rig = await build_rig(
            mode="voice_1to1", stt_delay=2.5, transcript=["first question", "second question"]
        )
        try:
            closed_at = await rig.hold(2.0)
            await asyncio.sleep(1.0 - (time.monotonic() - closed_at))
            # second press 1 s after release, before hold 1's STT (2.5 s) answers
            rig.room.send("open")
            await asyncio.sleep(0.05)
            rig.audio_in.push(speech_frames(1.0))
            assert await _wait_until(lambda: rig.llm.calls, timeout=3.0), (
                "hold 1's pending commit was lost"
            )
            await asyncio.sleep(3.0 - (time.monotonic() - closed_at))
            rig.room.send("closed")

            assert await _wait_until(lambda: len(rig.llm.calls) >= 2, timeout=7.0)
            await asyncio.sleep(0.5)
            assert rig.user_messages() == ["first question", "second question"]
            assert [c.last_user_text() for c in rig.llm.calls] == [
                "first question",
                "second question",
            ]
        finally:
            await rig.aclose()

    asyncio.run(_run())


# ── (c) a press during agent speech interrupts it ───────────────────────


def test_voice_open_during_agent_speech_interrupts_it():
    async def _run():
        rig = await build_rig(mode="voice_1to1", stt_delay=2.5)
        try:
            handle = rig.session.say("This is a long spoken answer " * 4)
            assert await _wait_until(lambda: rig.session.agent_state == "speaking", timeout=3.0)

            rig.room.send("open")

            assert len(rig.interrupt_calls) == 1
            await asyncio.wait_for(handle.wait_for_playout(), timeout=2.0)
            assert handle.interrupted
            assert rig.audio_out.interrupted, "playback was never cut short"
            assert rig.session.input.audio_enabled is True
        finally:
            await rig.aclose()

    asyncio.run(_run())


# ── (d) meeting mode: unchanged grace detach, no commit, no interrupt ───


def test_meeting_mode_keeps_grace_detach_and_never_commits():
    async def _run():
        rig = await build_rig(mode=None, stt_delay=2.5)
        try:
            rig.turn_detector_builder.assert_called_once()
            assert rig.session.input.audio_enabled is False

            rig.room.send("open")
            assert rig.session.input.audio_enabled is True
            rig.room.send("closed")

            await asyncio.sleep(0.8)  # inside the 1000 ms grace
            assert rig.session.input.audio_enabled is True
            await asyncio.sleep(0.4)  # past it
            assert rig.session.input.audio_enabled is False

            assert rig.commit_calls == []
            assert rig.interrupt_calls == []
        finally:
            await rig.aclose()

    asyncio.run(_run())


def test_build_agent_session_meeting_mode_still_uses_turn_detector():
    config = AgentConfig.from_env()
    with (
        patch.multiple(
            session_module.backends,
            build_vad=MagicMock(return_value="vad-obj"),
            build_turn_detector=MagicMock(return_value="turn-detector-obj"),
            build_stt=MagicMock(return_value="stt-obj"),
            build_tts=MagicMock(return_value="tts-obj"),
            build_llm=MagicMock(return_value="llm-obj"),
        ),
        patch.object(session_module, "AgentSession") as mock_cls,
    ):
        session_module.build_agent_session(config)
        assert mock_cls.call_args.kwargs["turn_detection"] == "turn-detector-obj"
        session_module.build_agent_session(config, "meeting")
        assert mock_cls.call_args.kwargs["turn_detection"] == "turn-detector-obj"
        session_module.build_agent_session(config, "voice_1to1")
        assert mock_cls.call_args.kwargs["turn_detection"] == "manual"


def test_voice_commit_timeout_defaults_to_4s_and_env_overrides(monkeypatch):
    assert AgentConfig.from_env().ask_floor.voice_commit_timeout_s == 4.0
    monkeypatch.setenv("MVA_VOICE_COMMIT_TIMEOUT_S", "6.5")
    assert AgentConfig.from_env().ask_floor.voice_commit_timeout_s == 6.5
