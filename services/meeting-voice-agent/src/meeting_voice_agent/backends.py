"""Backend factories: turn an `AgentConfig` into concrete livekit-agents plugin
objects (VAD, turn-detector, STT, TTS, LLM).

Every factory takes config and returns an SDK object; none of them read the
environment directly or hard-code a URL/model. This is the seam stage-1 tests
mock: each `build_*` function calls exactly one plugin constructor, so a test
can monkeypatch that constructor and assert it was called with the values
that came from config.
"""

from __future__ import annotations

from livekit.agents import llm as llm_types
from livekit.agents import stt as stt_types
from livekit.agents import tts as tts_types
from livekit.agents import vad as vad_types
from livekit.plugins import openai as lk_openai
from livekit.plugins import silero as lk_silero

# livekit-agents 1.8.x deprecates this module in favor of
# livekit.agents.inference.TurnDetector, which requires LiveKit Cloud
# inference credentials (api_key/api_secret) to reach a hosted model. We
# deliberately keep the local, deprecated-but-functional English/Multilingual
# models here so this service runs fully self-hosted against the test host/wave with
# no LiveKit Cloud dependency. Revisit if/when a local-inference path lands
# on the new API.
from livekit.plugins.turn_detector.english import EnglishModel
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from meeting_voice_agent.config import AgentConfig, TurnDetectorConfig


def build_vad(config: AgentConfig) -> vad_types.VAD:
    """Silero VAD, thresholds sourced from config.vad (experiment surface)."""
    return lk_silero.VAD.load(
        min_speech_duration=config.vad.min_speech_duration,
        min_silence_duration=config.vad.min_silence_duration,
        activation_threshold=config.vad.activation_threshold,
        prefix_padding_duration=config.vad.prefix_padding_duration,
        sample_rate=config.vad.sample_rate,
    )


def build_turn_detector(config: TurnDetectorConfig):
    """Turn-detector model selection, or None for VAD-only endpointing.

    `config.model` is one of "english" / "multilingual" / "none" — validated
    in TurnDetectorConfig.from_env, so this is exhaustive.
    """
    kwargs = {}
    if config.unlikely_threshold is not None:
        kwargs["unlikely_threshold"] = config.unlikely_threshold

    if config.model == "english":
        return EnglishModel(**kwargs)
    if config.model == "multilingual":
        return MultilingualModel(**kwargs)
    if config.model == "none":
        return None
    raise ValueError(f"unknown turn detector model: {config.model!r}")


def build_stt(config: AgentConfig) -> stt_types.STT:
    """STT client against an OpenAI-compatible endpoint (the test host's speaches by default)."""
    return lk_openai.STT(
        base_url=config.stt.base_url,
        model=config.stt.model,
        api_key=config.stt.api_key,
    )


def build_tts(config: AgentConfig) -> tts_types.TTS:
    """TTS client against an OpenAI-compatible endpoint.

    Defaults to the test host's speaches Kokoro.
    """
    return lk_openai.TTS(
        base_url=config.tts.base_url,
        model=config.tts.model,
        voice=config.tts_voice,
        api_key=config.tts.api_key,
    )


def build_llm(config: AgentConfig, *, use_fallback: bool = False) -> llm_types.LLM:
    """LLM client against an OpenAI-compatible endpoint (Dalton's wave box by default).

    `use_fallback` selects config.llm.fallback_model instead of the default
    model switch — the caller decides when to fail over, this just builds the
    right client for whichever model was selected.
    """
    model = config.llm.fallback_model if use_fallback else config.llm.model
    return lk_openai.LLM(
        base_url=config.llm.base_url,
        model=model,
        api_key=config.llm.api_key,
        extra_body=config.llm.extra_body,
    )


def select_llm_model(config: AgentConfig, *, primary_failed: bool) -> str:
    """Pure model-switch decision: which model name should be in use right now.

    Kept separate from build_llm so the switch logic is testable without
    constructing a real client.
    """
    return config.llm.fallback_model if primary_failed else config.llm.model
