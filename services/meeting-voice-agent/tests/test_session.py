"""Session wiring tests: confirm build_agent_session passes barge-in and
preemptive-generation config through to AgentSession, and that it sources
its VAD/STT/TTS/LLM/turn-detector objects from the backend factories (all
mocked — no real model load, no network).
"""

from unittest.mock import MagicMock, patch

from meeting_voice_agent import session as session_module
from meeting_voice_agent.config import AgentConfig


def _mock_all_backends():
    return patch.multiple(
        session_module.backends,
        build_vad=MagicMock(return_value="vad-obj"),
        build_turn_detector=MagicMock(return_value="turn-detector-obj"),
        build_stt=MagicMock(return_value="stt-obj"),
        build_tts=MagicMock(return_value="tts-obj"),
        build_llm=MagicMock(return_value="llm-obj"),
    )


def test_build_agent_session_wires_barge_in_on_by_default():
    config = AgentConfig.from_env()

    with _mock_all_backends(), patch.object(session_module, "AgentSession") as mock_cls:
        mock_cls.return_value = MagicMock()
        session_module.build_agent_session(config)

    _, kwargs = mock_cls.call_args
    assert kwargs["allow_interruptions"] is True
    assert kwargs["min_interruption_duration"] == 0.3
    assert kwargs["preemptive_generation"] is True
    assert kwargs["vad"] == "vad-obj"
    assert kwargs["turn_detection"] == "turn-detector-obj"
    assert kwargs["stt"] == "stt-obj"
    assert kwargs["tts"] == "tts-obj"
    assert kwargs["llm"] == "llm-obj"


def test_build_agent_session_honors_disabled_interruptions(monkeypatch):
    monkeypatch.setenv("MVA_ALLOW_INTERRUPTIONS", "false")
    config = AgentConfig.from_env()

    with _mock_all_backends(), patch.object(session_module, "AgentSession") as mock_cls:
        session_module.build_agent_session(config)

    _, kwargs = mock_cls.call_args
    assert kwargs["allow_interruptions"] is False


def test_build_agent_session_bounded_interruption_window_from_config(monkeypatch):
    monkeypatch.setenv("MVA_MIN_INTERRUPTION_DURATION", "0.12")
    config = AgentConfig.from_env()

    with _mock_all_backends(), patch.object(session_module, "AgentSession") as mock_cls:
        session_module.build_agent_session(config)

    _, kwargs = mock_cls.call_args
    assert kwargs["min_interruption_duration"] == 0.12


def test_build_agent_session_preemptive_generation_can_be_disabled(monkeypatch):
    monkeypatch.setenv("MVA_PREEMPTIVE_GENERATION", "false")
    config = AgentConfig.from_env()

    with _mock_all_backends(), patch.object(session_module, "AgentSession") as mock_cls:
        session_module.build_agent_session(config)

    _, kwargs = mock_cls.call_args
    assert kwargs["preemptive_generation"] is False
