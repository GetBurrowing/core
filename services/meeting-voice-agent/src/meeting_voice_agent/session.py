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


def build_agent_session(config: AgentConfig) -> AgentSession:
    vad = backends.build_vad(config)
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
