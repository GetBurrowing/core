"""Preemptive-generation triggering logic.

`AgentSession(preemptive_generation=True)` tells the SDK it is allowed to
start an LLM completion before the user's turn is confirmed over, but the
SDK's own internal timing is opaque — it is not something a unit test in
this repo can exercise without a live session. `PreemptiveGenerationPolicy`
is the decision this stage owns and can test directly: given the turn
detector's end-of-turn probability, how long the user has been silent, and
how much interim transcript exists, decide whether now is a safe point to
kick off a preemptive completion.

The AgentSession-level flags (preemptive_generation, min/max_endpointing_delay,
turn_detector.unlikely_threshold) are what actually govern the SDK's runtime
behavior; this policy mirrors that decision in a pure, independently testable
form, and the same config drives both (see session.py). It also gives the
entrypoint an explicit hook for latency instrumentation: logging the moment
the policy would fire is how first-audio-latency numbers eventually get
measured in stage 4's harness.
"""

from __future__ import annotations

from dataclasses import dataclass

from meeting_voice_agent.config import AgentConfig


@dataclass(frozen=True)
class TurnSignal:
    """A snapshot of what the session knows mid-turn."""

    # Turn-detector's probability [0, 1] that the user's turn has ended.
    # None if no turn-detector model is configured (VAD-only mode).
    end_of_turn_probability: float | None
    # How long, in seconds, VAD has observed continuous silence since the
    # user's last speech.
    silence_duration: float
    # Length of the interim (not-yet-final) transcript, in characters.
    interim_transcript_chars: int


def should_start_preemptive_generation(signal: TurnSignal, config: AgentConfig) -> bool:
    """Decide whether to eagerly start an LLM completion for the current turn.

    Rules, in order:
    1. If preemptive generation is disabled in config, never fire.
    2. Never fire on an empty/near-empty interim transcript — there is
       nothing to generate against yet.
    3. Never fire before config.endpointing.min_endpointing_delay has
       elapsed — that delay exists precisely to avoid reacting to a normal
       mid-sentence pause.
    4. If a turn-detector model is configured, only fire once its end-of-turn
       probability has crossed the configured (or model-default) unlikely
       threshold. "unlikely_threshold" names the probability above which the
       model considers it unlikely the user will keep talking, so a HIGHER
       probability than the threshold reads as "turn is probably over" here.
    5. In VAD-only mode (no turn-detector model), silence past
       min_endpointing_delay is itself the signal — fire once rules 1-3 pass.
    """
    if not config.preemptive_generation:
        return False
    if signal.interim_transcript_chars <= 0:
        return False
    if signal.silence_duration < config.endpointing.min_endpointing_delay:
        return False

    if config.turn_detector.model == "none":
        return True
    if signal.end_of_turn_probability is None:
        # A turn-detector model is configured but hasn't produced a reading
        # yet for this turn — nothing to decide on, so wait.
        return False

    threshold = config.turn_detector.unlikely_threshold
    if threshold is None:
        # No explicit override: any nonzero end-of-turn signal at this point
        # (silence already past min_endpointing_delay) is treated as license
        # to start generating.
        threshold = 0.0
    return signal.end_of_turn_probability >= threshold
