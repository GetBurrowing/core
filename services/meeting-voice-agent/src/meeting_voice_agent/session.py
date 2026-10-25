"""Builds the livekit-agents AgentSession with barge-in and preemptive
generation wired from config.

This is the one place stage-1's required runtime shape comes together:
silero VAD + turn-detector, interruptions ON with a bounded short window,
and preemptive generation before end-of-turn is confirmed — all thresholds
sourced from `AgentConfig`, never hard-coded here.
"""

from __future__ import annotations

from livekit.agents import AgentSession

from meeting_voice_agent import backends
from meeting_voice_agent.config import AgentConfig

#: The dispatch `mode` Core's `Platform.Meetings.VoiceSession` sets for a
#: Voice-tab 1:1 session (task 01a1557a-eab7). Lives here, not in `agent.py`,
#: because the session shape depends on it and `agent.py` imports this module.
VOICE_1TO1_MODE = "voice_1to1"


def build_agent_session(config: AgentConfig, mode: str | None = None) -> AgentSession:
    """Build the session for one job.

    A Voice-tab 1:1 session (`mode == VOICE_1TO1_MODE`) uses
    `turn_detection="manual"`: push-to-talk, where the release commits the
    turn (`ask_floor_gate.attach_ask_floor_gate(..., commit_on_close=True)`,
    task 01a174e2). Every other mode keeps the turn-detector model.
    """
    vad = backends.build_vad(config)
    if mode == VOICE_1TO1_MODE:
        turn_detection = "manual"
    else:
        turn_detection = backends.build_turn_detector(config.turn_detector)
    stt = backends.build_stt(config)
    tts = backends.build_tts(config)
    llm = backends.build_llm(config)

    return AgentSession(
        vad=vad,
        turn_detection=turn_detection,
        stt=stt,
        llm=llm,
        tts=tts,
        allow_interruptions=config.interruption.allow_interruptions,
        min_interruption_duration=config.interruption.min_interruption_duration,
        min_interruption_words=config.interruption.min_interruption_words,
        min_endpointing_delay=config.endpointing.min_endpointing_delay,
        max_endpointing_delay=config.endpointing.max_endpointing_delay,
        preemptive_generation=config.preemptive_generation,
    )
